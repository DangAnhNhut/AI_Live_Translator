import asyncio
import gc
import inspect
import json
import logging

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect
from uvicorn.protocols.utils import ClientDisconnected

from app.ai.stt import (
    ProviderStreamError,
    ProviderUnavailableError,
    SttTranscript,
    get_stt_provider_factory,
    unconfigured_stt_provider_factory,
)
from app.main import app
from app.realtime.stt_protocol import SttStart, SttStateMachine
from app.realtime.stt_socket import (
    _cancel,
    _cleanup_stream_tasks,
    _run_stream,
    websocket_stt,
)
from tests.fakes.stt import FakeSttProviderStream


VALID_START = {
    "type": "stt.start",
    "audio": {
        "encoding": "pcm_s16le",
        "sample_rate_hz": 16000,
        "channels": 1,
    },
    "language": "vi",
}


def test_task_cleanup_uses_only_python_310_asyncio_apis():
    source = inspect.getsource(_cancel) + inspect.getsource(_cleanup_stream_tasks)

    assert ".cancelling(" not in source


@pytest.fixture
def provider_override():
    def install(stream):
        app.dependency_overrides[get_stt_provider_factory] = lambda: lambda: stream
        return stream

    yield install
    app.dependency_overrides.clear()


def test_unconfigured_endpoint_reports_provider_unavailable_without_raw_detail(
    provider_override,
):
    app.dependency_overrides[get_stt_provider_factory] = (
        lambda: unconfigured_stt_provider_factory
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)

        error = websocket.receive_json()
        closed = websocket.receive_json()

    assert error == {
        "type": "stt.error",
        "code": "provider_unavailable",
        "message": "STT provider is unavailable.",
        "recoverable": False,
    }
    assert closed == {"type": "stt.closed"}


def test_streams_binary_audio_and_normalized_transcripts_then_closes(provider_override):
    stream = provider_override(FakeSttProviderStream(
        audio_events=(
            SttTranscript("interim", "seg_001", "xin chào"),
            SttTranscript("final", "seg_001", "Xin chào."),
        )
    ))

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}

        websocket.send_bytes(b"\x00\x00" * 1600)
        assert websocket.receive_json() == {
            "type": "transcript.interim",
            "segment_id": "seg_001",
            "text": "xin chào",
            "language": "vi",
        }

        assert websocket.receive_json() == {
            "type": "transcript.final",
            "segment_id": "seg_001",
            "text": "Xin chào.",
            "language": "vi",
        }
        assert stream.audio_chunks == [b"\x00\x00" * 1600]

        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.finish_calls == 1
    assert stream.close_calls == 1


class ScriptedStoppingWebSocket:
    def __init__(self):
        self.incoming: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self.sent: list[dict[str, object]] = []

    async def receive(self):
        return await self.incoming.get()

    async def send_json(self, event):
        self.sent.append(event)
        if event == {"type": "stt.ready"}:
            await self.incoming.put(
                {
                    "type": "websocket.receive",
                    "text": json.dumps({"type": "stt.stop"}),
                }
            )


class DirectEndpointWebSocket:
    def __init__(self, messages, *, close_error=None):
        self._messages = asyncio.Queue()
        first, *after_ready = messages
        self._messages.put_nowait(first)
        self._after_ready = after_ready
        self._close_error = close_error
        self.accept_calls = 0
        self.close_calls = 0
        self.receive_cancellations = 0
        self.sent = []

    async def accept(self):
        self.accept_calls += 1

    async def receive(self):
        try:
            return await self._messages.get()
        except asyncio.CancelledError:
            self.receive_cancellations += 1
            raise

    async def send_json(self, event):
        self.sent.append(event)
        if event == {"type": "stt.ready"}:
            for message in self._after_ready:
                await self._messages.put(message)
            self._after_ready.clear()

    async def close(self):
        self.close_calls += 1
        if self._close_error is not None:
            raise self._close_error


class EventsEndDuringFinishCancellation:
    def __init__(self):
        self._end_events = asyncio.Event()
        self._events_ended = asyncio.Event()
        self._finish_blocker = asyncio.Event()
        self.finish_calls = 0
        self.close_calls = 0

    async def start(self, audio, language):
        return None

    async def send_audio(self, chunk):
        return None

    async def finish_input(self):
        self.finish_calls += 1
        try:
            await self._finish_blocker.wait()
        except asyncio.CancelledError:
            self._end_events.set()
            await self._events_ended.wait()
            raise

    async def events(self):
        try:
            await self._end_events.wait()
            return
            yield
        finally:
            self._events_ended.set()

    async def close(self):
        self.close_calls += 1


class TaskTrackingProviderStream(FakeSttProviderStream):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.events_closed = False

    async def events(self):
        try:
            async for event in super().events():
                yield event
        finally:
            self.events_closed = True


class CancellationResistantEventsStream(FakeSttProviderStream):
    def __init__(self):
        super().__init__()
        self.events_started = asyncio.Event()
        self.cleanup_started = asyncio.Event()
        self.cleanup_release = asyncio.Event()

    async def events(self):
        try:
            self.events_started.set()
            await asyncio.Event().wait()
            yield
        finally:
            self.cleanup_started.set()
            try:
                await self.cleanup_release.wait()
            except asyncio.CancelledError:
                await self.cleanup_release.wait()


class EventGatedEndpointWebSocket(DirectEndpointWebSocket):
    def __init__(self, messages, *, event_gate):
        super().__init__(messages)
        self._event_gate = event_gate
        self._receive_calls = 0

    async def receive(self):
        self._receive_calls += 1
        if self._receive_calls > 1:
            await self._event_gate.wait()
        return await super().receive()


class CancellationPhaseWebSocket:
    def __init__(self):
        self.incoming: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self.ready = asyncio.Event()
        self.sent: list[dict[str, object]] = []

    async def receive(self):
        return await self.incoming.get()

    async def send_json(self, event):
        self.sent.append(event)
        if event == {"type": "stt.ready"}:
            self.ready.set()


def start_then_stop_then_disconnect_messages():
    return (
        {
            "type": "websocket.receive",
            "text": json.dumps(VALID_START),
        },
        {
            "type": "websocket.receive",
            "text": json.dumps({"type": "stt.stop"}),
        },
        {"type": "websocket.disconnect", "code": 1000},
    )


def test_finish_completion_does_not_starve_final_event_drain():
    final = SttTranscript("final", "seg_001", "Xin chào.")
    stream = FakeSttProviderStream(finish_events=(final,))
    websocket = ScriptedStoppingWebSocket()
    state = SttStateMachine()
    state.begin_start()
    start = SttStart.model_validate(VALID_START)

    async def exercise():
        await asyncio.wait_for(
            _run_stream(websocket, state, stream, start),
            timeout=0.5,
        )

    asyncio.run(exercise())

    assert stream.finish_completed is True
    assert stream.finish_events_drained_after_finish is True
    assert [event["type"] for event in websocket.sent] == [
        "stt.ready",
        "transcript.final",
        "stt.closed",
    ]


@pytest.mark.parametrize(
    "close_error",
    (WebSocketDisconnect(code=1006), ClientDisconnected()),
)
def test_peer_disconnect_during_stop_is_normal_cleanup_with_one_summary(
    close_error,
):
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    websocket = DirectEndpointWebSocket(
        start_then_stop_then_disconnect_messages(),
        close_error=close_error,
    )
    stream = FakeSttProviderStream(block_finish=True)
    lines = []
    clock = iter((10.0, 10.5))
    benchmark = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=lambda: next(clock),
        sink=lines.append,
    )
    assert benchmark is not None

    asyncio.run(
        websocket_stt(
            websocket,
            provider_factory=lambda: stream,
            benchmark_factory=lambda: benchmark,
        )
    )

    summaries = [
        json.loads(line.removeprefix("STT_BENCHMARK "))
        for line in lines
        if '"event":"session_summary"' in line
    ]
    assert websocket.accept_calls == 1
    assert websocket.close_calls == 1
    assert stream.finish_calls == 1
    assert stream.close_calls == 1
    assert len(summaries) == 1
    assert summaries[0]["close_reason"] == "client_disconnect"


def test_provider_event_completion_during_shutdown_has_no_unretrieved_task():
    websocket = DirectEndpointWebSocket(
        start_then_stop_then_disconnect_messages(),
    )
    stream = EventsEndDuringFinishCancellation()

    async def exercise():
        loop = asyncio.get_running_loop()
        contexts = []
        previous_handler = loop.get_exception_handler()
        loop.set_exception_handler(lambda _loop, context: contexts.append(context))
        try:
            await websocket_stt(
                websocket,
                provider_factory=lambda: stream,
                benchmark_factory=lambda: None,
            )
            gc.collect()
            await asyncio.sleep(0)
            return contexts
        finally:
            loop.set_exception_handler(previous_handler)

    contexts = asyncio.run(exercise())

    assert contexts == []
    assert stream.finish_calls == 1
    assert stream.close_calls == 1


@pytest.mark.parametrize(
    ("second_message", "stream", "expected_receive_cancellations"),
    (
        (
            {"type": "websocket.receive", "bytes": b"\x00\x00"},
            TaskTrackingProviderStream(
                send_error=ProviderStreamError("send failed")
            ),
            1,
        ),
        (
            {
                "type": "websocket.receive",
                "text": json.dumps({"type": "stt.stop"}),
            },
            TaskTrackingProviderStream(
                finish_error=ProviderStreamError("finish failed")
            ),
            2,
        ),
        (
            {"type": "websocket.receive", "bytes": b"\x00\x00"},
            TaskTrackingProviderStream(
                event_error=ProviderStreamError("events failed")
            ),
            2,
        ),
        (
            {"type": "websocket.receive", "text": "not-json"},
            TaskTrackingProviderStream(),
            1,
        ),
    ),
)
def test_all_stream_exit_paths_await_owned_tasks(
    second_message,
    stream,
    expected_receive_cancellations,
):
    websocket = DirectEndpointWebSocket(
        (
            {
                "type": "websocket.receive",
                "text": json.dumps(VALID_START),
            },
            second_message,
        )
    )

    async def exercise():
        await websocket_stt(
            websocket,
            provider_factory=lambda: stream,
            benchmark_factory=lambda: None,
        )
        current = asyncio.current_task()
        remaining = [
            task
            for task in asyncio.all_tasks()
            if task is not current and not task.done()
        ]
        return remaining, websocket.receive_cancellations

    remaining, receive_cancellations = asyncio.run(exercise())

    assert remaining == []
    assert receive_cancellations == expected_receive_cancellations


def test_parent_cancellation_during_child_cleanup_is_not_swallowed():
    stream = CancellationResistantEventsStream()
    websocket = EventGatedEndpointWebSocket(
        (
            {
                "type": "websocket.receive",
                "text": json.dumps(VALID_START),
            },
            {"type": "websocket.receive", "text": "not-json"},
        ),
        event_gate=stream.events_started,
    )

    async def exercise():
        runner = asyncio.create_task(
            websocket_stt(
                websocket,
                provider_factory=lambda: stream,
                benchmark_factory=lambda: None,
            )
        )
        await stream.cleanup_started.wait()
        runner.cancel()
        stream.cleanup_release.set()
        try:
            with pytest.raises(asyncio.CancelledError):
                await runner
        finally:
            if not runner.done():
                runner.cancel()
                with pytest.raises(asyncio.CancelledError):
                    await runner

        current = asyncio.current_task()
        assert [
            task
            for task in asyncio.all_tasks()
            if task is not current and not task.done()
        ] == []

    asyncio.run(exercise())


@pytest.mark.parametrize("phase", ("startup", "active", "finish"))
def test_run_stream_parent_cancellation_cleans_tasks_in_each_phase(phase):
    websocket = CancellationPhaseWebSocket()
    stream = FakeSttProviderStream(
        block_start=phase == "startup",
        block_finish=phase == "finish",
    )

    async def exercise():
        state = SttStateMachine()
        state.begin_start()
        start = SttStart.model_validate(VALID_START)
        runner = asyncio.create_task(_run_stream(websocket, state, stream, start))

        if phase == "startup":
            while not stream.start_calls:
                await asyncio.sleep(0)
        else:
            await websocket.ready.wait()
            if phase == "finish":
                await websocket.incoming.put(
                    {
                        "type": "websocket.receive",
                        "text": json.dumps({"type": "stt.stop"}),
                    }
                )
                while stream.finish_calls == 0:
                    await asyncio.sleep(0)

        runner.cancel()
        with pytest.raises(asyncio.CancelledError):
            await runner

        current = asyncio.current_task()
        assert [
            task
            for task in asyncio.all_tasks()
            if task is not current and not task.done()
        ] == []

    asyncio.run(exercise())


def test_normal_server_initiated_stop_still_closes_once():
    websocket = DirectEndpointWebSocket(start_then_stop_then_disconnect_messages()[:2])
    stream = FakeSttProviderStream()

    asyncio.run(
        websocket_stt(
            websocket,
            provider_factory=lambda: stream,
            benchmark_factory=lambda: None,
        )
    )

    assert [event["type"] for event in websocket.sent] == [
        "stt.ready",
        "stt.closed",
    ]
    assert websocket.close_calls == 1
    assert stream.finish_calls == 1
    assert stream.finish_completed is True
    assert stream.close_calls == 1


def assert_terminal_error(websocket, code):
    error = websocket.receive_json()
    assert error["type"] == "stt.error"
    assert error["code"] == code
    assert error["recoverable"] is False
    assert set(error) == {"type", "code", "message", "recoverable"}
    assert websocket.receive_json() == {"type": "stt.closed"}
    with pytest.raises(WebSocketDisconnect):
        websocket.receive_json()


@pytest.mark.parametrize(
    ("send", "code"),
    [
        (lambda ws: ws.send_bytes(b"\x00\x00"), "invalid_state"),
        (lambda ws: ws.send_text("not-json"), "invalid_message"),
        (lambda ws: ws.send_json({"type": "unknown"}), "invalid_message"),
        (lambda ws: ws.send_json({"type": "stt.stop"}), "invalid_state"),
        (
            lambda ws: ws.send_json(
                {
                    **VALID_START,
                    "audio": {**VALID_START["audio"], "encoding": "opus"},
                }
            ),
            "unsupported_audio",
        ),
    ],
)
def test_rejects_invalid_first_frame(provider_override, send, code):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        send(websocket)
        assert_terminal_error(websocket, code)

    assert stream.start_calls == []
    assert stream.close_calls == 0


def test_rejects_binary_audio_before_ready(provider_override):
    stream = provider_override(FakeSttProviderStream(block_start=True))
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        websocket.send_bytes(b"\x00\x00")
        assert_terminal_error(websocket, "invalid_state")

    assert stream.audio_chunks == []
    assert stream.close_calls == 1


def test_rejects_duplicate_start(provider_override):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json(VALID_START)
        assert_terminal_error(websocket, "invalid_state")

    assert stream.close_calls == 1


def test_rejects_audio_after_stop(provider_override):
    stream = provider_override(FakeSttProviderStream(block_finish=True))
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json({"type": "stt.stop"})
        websocket.send_bytes(b"\x00\x00")
        assert_terminal_error(websocket, "invalid_state")

    assert stream.close_calls == 1


@pytest.mark.parametrize(
    ("stream", "expected_code", "forbidden_text"),
    [
        (
            FakeSttProviderStream(
                start_error=ProviderUnavailableError("secret startup detail")
            ),
            "provider_unavailable",
            "secret startup detail",
        ),
        (
            FakeSttProviderStream(
                send_error=ProviderStreamError("secret midstream detail")
            ),
            "provider_error",
            "secret midstream detail",
        ),
    ],
)
def test_provider_failures_are_normalized(
    provider_override, stream, expected_code, forbidden_text
):
    provider_override(stream)
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        if stream.start_error is None:
            assert websocket.receive_json() == {"type": "stt.ready"}
            websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error["type"] == "stt.error"
        assert error["code"] == expected_code
        assert forbidden_text not in error["message"]
        assert error["recoverable"] is False
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.close_calls == 1


def test_unexpected_error_is_sanitized_for_client_and_logs(provider_override, caplog):
    stream = provider_override(
        FakeSttProviderStream(send_error=RuntimeError("secret internal detail"))
    )
    with caplog.at_level(logging.ERROR, logger="app.realtime.stt_socket"):
        with TestClient(app).websocket_connect("/ws/stt") as websocket:
            websocket.send_json(VALID_START)
            assert websocket.receive_json() == {"type": "stt.ready"}
            websocket.send_bytes(b"\x00\x00")
            error = websocket.receive_json()
            assert error == {
                "type": "stt.error",
                "code": "internal_error",
                "message": "Internal STT error.",
                "recoverable": False,
            }
            assert websocket.receive_json() == {"type": "stt.closed"}

    assert "secret internal detail" not in error["message"]
    assert "secret internal detail" not in caplog.text
    assert "exception_type=RuntimeError" in caplog.text
    assert stream.close_calls == 1


def test_provider_event_failure_is_normalized(provider_override):
    stream = provider_override(
        FakeSttProviderStream(event_error=ProviderStreamError("raw event failure"))
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error["code"] == "provider_error"
        assert "raw event failure" not in error["message"]
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.close_calls == 1


def test_repeated_interims_for_same_segment_are_allowed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("interim", "seg_001", "xin"),
                SttTranscript("interim", "seg_001", "xin chào"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["text"] == "xin"
        assert websocket.receive_json()["text"] == "xin chào"
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_final_after_interim_is_allowed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("interim", "seg_001", "xin chào"),
                SttTranscript("final", "seg_001", "Xin chào."),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.interim"
        assert websocket.receive_json()["type"] == "transcript.final"
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_interim_after_final_is_rejected(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("final", "seg_001", "Xin chào."),
                SttTranscript("interim", "seg_001", "invalid revision"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.final"
        assert_terminal_error(websocket, "provider_error")


def test_duplicate_final_is_rejected(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("final", "seg_001", "Xin chào."),
                SttTranscript("final", "seg_001", "duplicate"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.final"
        assert_terminal_error(websocket, "provider_error")


def assert_malformed_transcript_is_provider_error(
    provider_override,
    event,
    forbidden_public_value=None,
):
    stream = provider_override(FakeSttProviderStream(audio_events=(event,)))
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error == {
            "type": "stt.error",
            "code": "provider_error",
            "message": "STT provider stream failed.",
            "recoverable": False,
        }
        if forbidden_public_value is not None:
            assert forbidden_public_value not in error["message"]
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_unsupported_transcript_kind_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("partial", "seg_001", "invalid kind"),
        "partial",
    )


def test_non_vi_transcript_language_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "seg_001", "wrong language", language="en"),
        "en",
    )


def test_non_string_segment_id_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", 12345, "invalid segment ID"),
        "12345",
    )


def test_blank_segment_id_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "   ", "blank segment ID"),
    )


def test_non_string_transcript_text_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "seg_001", ["secret malformed text"]),
        "secret malformed text",
    )


def test_stop_flushes_final_before_closed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            finish_events=(SttTranscript("final", "seg_001", "Xin chào."),)
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json()["type"] == "transcript.final"
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.finish_calls == 1
    assert stream.finish_completed is True
    assert stream.finish_events_drained_after_finish is True
    assert stream.close_calls == 1


def test_abrupt_client_disconnect_closes_provider(provider_override):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.close()

    assert stream.close_calls == 1


def test_enabled_benchmark_records_socket_milestones_without_sensitive_values(
    provider_override,
):
    from app.benchmark.stt_benchmark import (
        create_stt_benchmark_recorder,
        get_stt_benchmark_factory,
    )

    transcript = "xin chao Authorization Token test-deepgram-key"
    raw_audio = b"raw-secret-audio"
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("interim", "seg_001", transcript),
                SttTranscript("final", "seg_001", transcript),
            )
        )
    )
    lines: list[str] = []
    clock = iter((10.0, 10.1, 10.3, 10.6, 11.0))
    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=lambda: next(clock),
        sink=lines.append,
    )
    assert recorder is not None
    app.dependency_overrides[get_stt_benchmark_factory] = lambda: lambda: recorder

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(raw_audio)
        assert websocket.receive_json()["type"] == "transcript.interim"
        assert websocket.receive_json()["type"] == "transcript.final"
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}

    payloads = [
        json.loads(line.removeprefix("STT_BENCHMARK ")) for line in lines
    ]
    summary = payloads[-1]
    assert summary["event"] == "session_summary"
    assert summary["audio_chunk_count"] == 1
    assert summary["audio_byte_count"] == len(raw_audio)
    assert summary["interim_count"] == 1
    assert summary["final_count"] == 1
    assert summary["close_reason"] == "client_stop"
    assert summary["first_audio_to_first_interim_ms"] == 200.0
    assert summary["first_audio_to_first_final_ms"] == 500.0
    assert summary["first_interim_to_first_final_ms"] == 300.0
    rendered = "\n".join(lines)
    assert transcript not in rendered
    assert raw_audio.decode() not in rendered
    assert "Authorization" not in rendered
    assert "test-deepgram-key" not in rendered


def test_provider_error_is_counted_once_without_error_detail(provider_override):
    from app.benchmark.stt_benchmark import (
        create_stt_benchmark_recorder,
        get_stt_benchmark_factory,
    )

    raw_detail = "Authorization Token test-deepgram-key raw provider failure"
    stream = provider_override(
        FakeSttProviderStream(send_error=ProviderStreamError(raw_detail))
    )
    lines: list[str] = []
    clock = iter((20.0, 20.1, 20.5))
    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=lambda: next(clock),
        sink=lines.append,
    )
    assert recorder is not None
    app.dependency_overrides[get_stt_benchmark_factory] = lambda: lambda: recorder

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["code"] == "provider_error"
        assert websocket.receive_json() == {"type": "stt.closed"}

    summaries = [
        json.loads(line.removeprefix("STT_BENCHMARK "))
        for line in lines
        if '"event":"session_summary"' in line
    ]
    assert len(summaries) == 1
    assert summaries[0]["provider_error_count"] == 1
    assert summaries[0]["close_reason"] == "provider_error"
    assert raw_detail not in "\n".join(lines)
    assert "Authorization" not in "\n".join(lines)
