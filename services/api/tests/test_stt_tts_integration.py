import asyncio
import json

import anyio
import pytest
from fastapi.testclient import TestClient

from app.ai.stt import SttTranscript, get_stt_provider_factory
from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
)
from app.ai.tts import SynthesizedAudio, TtsProviderError
from app.main import app
from app.realtime.session_event_publisher import SessionEventPublisher
from app.realtime.session_hub import SessionHub, get_session_hub
from app.realtime.stt_socket import (
    _run_stream,
    get_session_speech_synthesizer_factory,
    get_session_translator_factory,
    websocket_stt,
)
from app.realtime.stt_protocol import SttStart, SttStateMachine
from app.realtime.translation_session import TranslationSession
from app.realtime.tts_session import TtsSession
from tests.fakes.stt import FakeSttProviderStream
from tests.fakes.translation import FakeTranslator
from tests.fakes.tts import FakeSpeechSynthesizer


VALID_START = {
    "type": "stt.start",
    "audio": {
        "encoding": "pcm_s16le",
        "sample_rate_hz": 16000,
        "channels": 1,
    },
    "language": "vi",
}
_FRAME_TIMEOUT_SECONDS = 1.0


class SequencedFakeSttProviderStream(FakeSttProviderStream):
    def __init__(self, audio_event_batches):
        super().__init__()
        self._audio_event_batches = iter(audio_event_batches)

    async def send_audio(self, chunk):
        self.audio_chunks.append(chunk)
        for event in next(self._audio_event_batches, ()):
            await self._events.put(event)


class LifecycleRecordingSttProviderStream(FakeSttProviderStream):
    def __init__(self, lifecycle):
        super().__init__()
        self._lifecycle = lifecycle

    async def events(self):
        self._lifecycle.append("provider.events")
        async for event in super().events():
            yield event


class RegistrationTrackingSessionHub(SessionHub):
    def __init__(self):
        super().__init__()
        self._viewer_registration_events = {}

    async def join_viewer(self, session_id, websocket):
        await super().join_viewer(session_id, websocket)
        self._viewer_registration_events.setdefault(
            session_id,
            asyncio.Event(),
        ).set()

    async def wait_for_viewers(self, session_id, expected_count):
        with anyio.fail_after(_FRAME_TIMEOUT_SECONDS):
            while self.viewer_count(session_id) < expected_count:
                changed = self._viewer_registration_events.setdefault(
                    session_id,
                    asyncio.Event(),
                )
                changed.clear()
                if self.viewer_count(session_id) >= expected_count:
                    return
                await changed.wait()


@pytest.fixture
def realtime_tts_override():
    hub = RegistrationTrackingSessionHub()
    app.dependency_overrides[get_session_hub] = lambda: hub

    def install(
        stream,
        *,
        translator_factory=None,
        synthesizer_factory=None,
    ):
        app.dependency_overrides[get_stt_provider_factory] = (
            lambda: lambda: stream
        )
        app.dependency_overrides[get_session_translator_factory] = (
            lambda: translator_factory
        )
        app.dependency_overrides[
            get_session_speech_synthesizer_factory
        ] = lambda: synthesizer_factory
        return hub

    yield install
    app.dependency_overrides.clear()


def tts_start(*, session_id=None, voice=None):
    payload = {
        **VALID_START,
        "translation": {"target_language": "en"},
        "tts": {"enabled": True},
    }
    if voice is not None:
        payload["tts"]["voice"] = voice
    if session_id is not None:
        payload["session_id"] = session_id
    return payload


def _forbidden_factory_counter():
    calls = []

    def forbidden_factory():
        calls.append(None)
        raise AssertionError("disabled TTS constructed a synthesizer")

    return forbidden_factory, calls


def _receive_until_closed(websocket):
    events = []
    while True:
        event = websocket.receive_json()
        events.append(event)
        if event["type"] == "stt.closed":
            return events


def _receive_frame(websocket):
    async def receive_with_timeout():
        with anyio.fail_after(_FRAME_TIMEOUT_SECONDS):
            return await websocket._send_rx.receive()

    try:
        message = websocket.portal.call(receive_with_timeout)
    except TimeoutError:
        pytest.fail(
            "Timed out after "
            f"{_FRAME_TIMEOUT_SECONDS:.1f}s waiting for WebSocket frame"
        )
    assert message["type"] == "websocket.send"
    return message


def _receive_json_frame(websocket):
    message = _receive_frame(websocket)
    assert isinstance(message.get("text"), str)
    return json.loads(message["text"])


def _receive_json_frames(websocket, count):
    return [_receive_json_frame(websocket) for _ in range(count)]


def _receive_bytes_frame(websocket):
    message = _receive_frame(websocket)
    assert isinstance(message.get("bytes"), bytes)
    return message["bytes"]


def _receive_tts_success_frames(websocket, *, json_count):
    return [
        *(("json", _receive_json_frame(websocket)) for _ in range(json_count)),
        ("bytes", _receive_bytes_frame(websocket)),
    ]


class DirectRunWebSocket:
    def __init__(self):
        self.sent = []
        self._ready = asyncio.Event()
        self._receive_calls = 0

    async def send_json(self, event):
        self.sent.append(event)
        if event["type"] == "stt.ready":
            self._ready.set()

    async def receive(self):
        await self._ready.wait()
        self._receive_calls += 1
        if self._receive_calls > 1:
            await asyncio.Event().wait()
        return {
            "type": "websocket.receive",
            "text": json.dumps({"type": "stt.stop"}),
        }


class FailingProducerWebSocket:
    def __init__(
        self,
        first_message,
        *,
        after_ready=(),
        failed_json_type=None,
        fail_bytes=False,
        block_bytes=False,
    ):
        self._messages = asyncio.Queue()
        self._messages.put_nowait(first_message)
        self._after_ready = list(after_ready)
        self._failed_json_type = failed_json_type
        self._fail_bytes = fail_bytes
        self._block_bytes = block_bytes
        self.accept_calls = 0
        self.close_calls = 0
        self.receive_cancellations = 0
        self.binary_send_cancellations = 0
        self.binary_send_started = asyncio.Event()
        self.binary_send_release = asyncio.Event()
        self.json_attempts = []
        self.sent_frames = []

    async def accept(self):
        self.accept_calls += 1

    async def receive(self):
        try:
            return await self._messages.get()
        except asyncio.CancelledError:
            self.receive_cancellations += 1
            raise

    async def send_json(self, event):
        self.json_attempts.append(event)
        if event["type"] == self._failed_json_type:
            raise RuntimeError("producer JSON send failed")
        self.sent_frames.append(event)
        if event["type"] == "stt.ready":
            for message in self._after_ready:
                await self._messages.put(message)
            self._after_ready.clear()

    async def send_bytes(self, payload):
        self.binary_send_started.set()
        try:
            if self._block_bytes:
                await self.binary_send_release.wait()
            if self._fail_bytes:
                raise RuntimeError("producer binary send failed")
        except asyncio.CancelledError:
            self.binary_send_cancellations += 1
            raise
        self.sent_frames.append(payload)

    async def close(self):
        self.close_calls += 1

    async def queue_receive(self, message):
        await self._messages.put(message)


class RecordingViewerWebSocket:
    def __init__(self):
        self.sent_frames = []

    async def send_json(self, event):
        self.sent_frames.append(event)

    async def send_bytes(self, payload):
        self.sent_frames.append(payload)


def _capture_publishers(monkeypatch, *, lifecycle=None):
    import app.realtime.stt_socket as stt_socket

    publishers = []

    class CapturingPublisher(SessionEventPublisher):
        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            self.failure_wait_calls = 0
            self.failure_wait_completions = 0
            self.close_calls = 0
            publishers.append(self)

        async def wait_for_producer_delivery_failure(self):
            self.failure_wait_calls += 1
            await super().wait_for_producer_delivery_failure()
            self.failure_wait_completions += 1

        async def close(self):
            self.close_calls += 1
            if lifecycle is not None:
                lifecycle.append("publisher.close")
            await super().close()

    monkeypatch.setattr(
        stt_socket,
        "SessionEventPublisher",
        CapturingPublisher,
    )
    return publishers


async def _live_owned_task_names(*prefixes):
    current = asyncio.current_task()
    return [
        task.get_name()
        for task in asyncio.all_tasks()
        if task is not current
        and not task.done()
        and task.get_name().startswith(prefixes)
    ]


class CloseReasonRecorder:
    def __init__(self):
        self.close_reasons = []

    def record_audio_chunk(self, _chunk):
        pass

    def record_transcript(self, _kind, _segment_id):
        pass

    def record_keepalive(self):
        pass

    def record_provider_error(self):
        pass

    def finish(self, close_reason):
        self.close_reasons.append(close_reason)


class RecordingStartupHub:
    def __init__(self):
        self.broadcasts = []

    async def broadcast(self, session_id, event):
        self.broadcasts.append((session_id, event))


def test_direct_run_stream_fallback_broadcasts_startup_error_without_identity():
    websocket = DirectRunWebSocket()
    hub = RecordingStartupHub()
    state = SttStateMachine()
    state.begin_start()
    start = SttStart.model_validate(
        {
            **VALID_START,
            "session_id": "demo-001",
            "translation": {"target_language": "en"},
        }
    )
    startup_error = {
        "type": "translation.error",
        "scope": "session",
        "stream_id": "stream_test",
        "source_language": "vi",
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Translation provider is unavailable.",
    }

    close_reason = asyncio.run(
        _run_stream(
            websocket,
            state,
            FakeSttProviderStream(),
            start,
            session_hub=hub,
            stream_id="stream_test",
            translation_startup_event=startup_error,
        )
    )

    assert close_reason == "client_stop"
    assert [event["type"] for event in websocket.sent] == [
        "stt.ready",
        "translation.error",
        "stt.closed",
    ]
    assert hub.broadcasts == [("demo-001", startup_error)]


def test_stt_only_with_tts_omitted_never_constructs_synthesizer(
    realtime_tts_override,
):
    forbidden_factory, factory_calls = _forbidden_factory_counter()
    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("final", "seg_001", "Xin chao."),)
    )
    realtime_tts_override(
        stream,
        synthesizer_factory=forbidden_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        ready = websocket.receive_json()
        websocket.send_bytes(b"audio")
        transcript = websocket.receive_json()
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == []
    assert [ready["type"], transcript["type"], closed["type"]] == [
        "stt.ready",
        "transcript.final",
        "stt.closed",
    ]
    assert transcript["stream_id"] == ready["stream_id"]


def test_stt_only_with_tts_disabled_never_constructs_synthesizer(
    realtime_tts_override,
):
    forbidden_factory, factory_calls = _forbidden_factory_counter()
    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("final", "seg_001", "Xin chao."),)
    )
    realtime_tts_override(
        stream,
        synthesizer_factory=forbidden_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json({**VALID_START, "tts": {"enabled": False}})
        ready = websocket.receive_json()
        websocket.send_bytes(b"audio")
        transcript = websocket.receive_json()
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == []
    assert [ready["type"], transcript["type"], closed["type"]] == [
        "stt.ready",
        "transcript.final",
        "stt.closed",
    ]


def test_translation_only_with_tts_omitted_preserves_existing_events(
    realtime_tts_override,
):
    forbidden_factory, factory_calls = _forbidden_factory_counter()
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("Hello.",)),
        synthesizer_factory=forbidden_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(
            {**VALID_START, "translation": {"target_language": "en"}}
        )
        ready = websocket.receive_json()
        configured = websocket.receive_json()
        websocket.send_bytes(b"audio")
        translated = [websocket.receive_json() for _ in range(3)]
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == []
    assert [
        ready["type"],
        configured["type"],
        *(event["type"] for event in translated),
        closed["type"],
    ] == [
        "stt.ready",
        "translation.configured",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]


def test_translation_with_tts_disabled_preserves_existing_events(
    realtime_tts_override,
):
    forbidden_factory, factory_calls = _forbidden_factory_counter()
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("Hello.",)),
        synthesizer_factory=forbidden_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(
            {
                **VALID_START,
                "translation": {"target_language": "en"},
                "tts": {"enabled": False},
            }
        )
        ready = websocket.receive_json()
        configured = websocket.receive_json()
        websocket.send_bytes(b"audio")
        translated = [websocket.receive_json() for _ in range(3)]
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == []
    assert [
        ready["type"],
        configured["type"],
        *(event["type"] for event in translated),
        closed["type"],
    ] == [
        "stt.ready",
        "translation.configured",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]


def test_tts_available_start_orders_ready_translation_and_tts_configuration(
    realtime_tts_override,
):
    factory_calls = []
    synthesizer = FakeSpeechSynthesizer()

    def synthesizer_factory():
        factory_calls.append(None)
        return synthesizer

    realtime_tts_override(
        FakeSttProviderStream(),
        translator_factory=lambda: FakeTranslator(),
        synthesizer_factory=synthesizer_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(tts_start(voice="northern-voice"))
        startup = [websocket.receive_json() for _ in range(3)]
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == [None]
    assert [event["type"] for event in startup] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
    ]
    assert startup[2] == {
        "type": "tts.configured",
        "stream_id": startup[0]["stream_id"],
        "target_language": "en",
        "voice": "northern-voice",
    }
    assert closed == {"type": "stt.closed"}


def test_tts_unavailable_emits_one_session_error_and_translation_continues(
    realtime_tts_override,
):
    stream = SequencedFakeSttProviderStream(
        (
            (
                SttTranscript(
                    "final",
                    "seg_001",
                    "Mot.",
                    utterance_boundary=True,
                ),
            ),
            (
                SttTranscript(
                    "final",
                    "seg_002",
                    "Hai.",
                    utterance_boundary=True,
                ),
            ),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("One.", "Two.")),
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(tts_start())
        events = [websocket.receive_json() for _ in range(4)]
        websocket.send_bytes(b"first")
        events.extend(websocket.receive_json() for _ in range(3))
        websocket.send_bytes(b"second")
        events.extend(websocket.receive_json() for _ in range(3))
        websocket.send_json({"type": "stt.stop"})
        events.extend(_receive_until_closed(websocket))

    event_types = [event["type"] for event in events]
    assert event_types == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
        "tts.error",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]
    tts_errors = [event for event in events if event["type"] == "tts.error"]
    assert tts_errors == [
        {
            "type": "tts.error",
            "scope": "session",
            "stream_id": events[0]["stream_id"],
            "target_language": "en",
            "code": "provider_unavailable",
            "message": "Speech synthesis is unavailable.",
        }
    ]
    assert event_types.count("translation.final") == 2
    assert not any(
        event_type in {"tts.pending", "tts.audio"}
        for event_type in event_types
    )


@pytest.mark.parametrize(
    "factory_outcome",
    ("raises", "nonconforming"),
)
def test_invalid_synthesizer_construction_degrades_once_and_translation_continues(
    realtime_tts_override,
    factory_outcome,
):
    factory_calls = []

    def synthesizer_factory():
        factory_calls.append(None)
        if factory_outcome == "raises":
            raise RuntimeError("secret provider detail")
        return object()

    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Mot.",
                utterance_boundary=True,
            ),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("One.",)),
        synthesizer_factory=synthesizer_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(tts_start())
        events = [websocket.receive_json() for _ in range(4)]
        websocket.send_bytes(b"audio")
        events.extend(websocket.receive_json() for _ in range(3))
        websocket.send_json({"type": "stt.stop"})
        events.append(websocket.receive_json())

    assert factory_calls == [None]
    assert [event["type"] for event in events] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
        "tts.error",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]
    assert events[2] == {
        "type": "tts.configured",
        "stream_id": events[0]["stream_id"],
        "target_language": "en",
    }
    assert events[3] == {
        "type": "tts.error",
        "scope": "session",
        "stream_id": events[0]["stream_id"],
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Speech synthesis is unavailable.",
    }


def _record_tts_clean_stop_lifecycle(
    realtime_tts_override,
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    lifecycle = []

    class RecordingTtsSession:
        def __init__(self, **_kwargs):
            pass

        async def start(self):
            lifecycle.append("tts.start")

        async def flush_and_drain(self, *, timeout_seconds):
            lifecycle.append(("tts.drain", timeout_seconds))
            return True

        async def close(self):
            lifecycle.append("tts.close")

        async def abort(self):
            lifecycle.append("tts.abort")

        async def submit(self, **_kwargs):
            pass

    class RecordingTranslationSession:
        def __init__(self, **_kwargs):
            pass

        async def start(self):
            lifecycle.append("translation.start")

        async def accept_transcript(self, _event):
            pass

        async def flush_and_drain(self, *, timeout_seconds):
            lifecycle.append(("translation.drain", timeout_seconds))
            return True

        async def close(self):
            lifecycle.append("translation.close")

        async def abort(self):
            lifecycle.append("translation.abort")

    monkeypatch.setattr(stt_socket, "TtsSession", RecordingTtsSession)
    monkeypatch.setattr(
        stt_socket,
        "TranslationSession",
        RecordingTranslationSession,
    )
    realtime_tts_override(
        LifecycleRecordingSttProviderStream(lifecycle),
        translator_factory=lambda: FakeTranslator(),
        synthesizer_factory=lambda: FakeSpeechSynthesizer(),
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(tts_start())
        assert [websocket.receive_json()["type"] for _ in range(3)] == [
            "stt.ready",
            "translation.configured",
            "tts.configured",
        ]
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}

    return lifecycle


def test_clean_stop_drains_translation_then_tts_once_before_close(
    realtime_tts_override,
    monkeypatch,
):
    lifecycle = _record_tts_clean_stop_lifecycle(
        realtime_tts_override,
        monkeypatch,
    )

    assert lifecycle.count(("translation.drain", 5.0)) == 1
    assert lifecycle.count(("tts.drain", 5.0)) == 1
    assert lifecycle.index(("translation.drain", 5.0)) < lifecycle.index(
        ("tts.drain", 5.0)
    )
    assert lifecycle.index(("tts.drain", 5.0)) < lifecycle.index(
        "translation.close"
    )
    assert lifecycle.index("translation.close") < lifecycle.index(
        "tts.close"
    )


def test_tts_starts_before_translation_and_first_provider_event_task(
    realtime_tts_override,
    monkeypatch,
):
    lifecycle = _record_tts_clean_stop_lifecycle(
        realtime_tts_override,
        monkeypatch,
    )

    assert lifecycle.index("tts.start") < lifecycle.index(
        "translation.start"
    )
    assert lifecycle.index("translation.start") < lifecycle.index(
        "provider.events"
    )


def test_clean_stop_drains_buffered_translation_and_tts_before_closed(
    realtime_tts_override,
):
    synthesis_gate = asyncio.Event()
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=False,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),),
        gates=(synthesis_gate,),
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(tts_start())
            assert [
                event["type"]
                for event in _receive_json_frames(producer, 3)
            ] == [
                "stt.ready",
                "translation.configured",
                "tts.configured",
            ]
            producer.send_bytes(b"audio")
            assert _receive_json_frame(producer)["type"] == "transcript.final"

            producer.send_json({"type": "stt.stop"})
            tail = [
                *(('json', event) for event in _receive_json_frames(producer, 3)),
            ]
            assert [frame[1]["type"] for frame in tail] == [
                "translation.pending",
                "translation.final",
                "tts.pending",
            ]
            client.portal.call(synthesizer.call_started.wait)
            client.portal.call(synthesis_gate.set)
            tail.extend(
                (
                    ("json", _receive_json_frame(producer)),
                    ("bytes", _receive_bytes_frame(producer)),
                    ("json", _receive_json_frame(producer)),
                )
            )

    assert [
        frame[0] if frame[0] == "bytes" else frame[1]["type"]
        for frame in tail
    ] == [
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
        "bytes",
        "stt.closed",
    ]
    assert tail[-2] == ("bytes", b"speech")
    assert len(translator.calls) == 1
    assert len(synthesizer.calls) == 1


def test_clean_stop_uses_one_short_total_tts_drain_and_settles_tasks(
    realtime_tts_override,
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    synthesis_gate = asyncio.Event()
    created_sessions = []

    class DrainRecordingTtsSession(TtsSession):
        def __init__(self, **kwargs):
            super().__init__(**kwargs)
            self.drain_timeouts = []
            created_sessions.append(self)

        async def flush_and_drain(self, *, timeout_seconds):
            self.drain_timeouts.append(timeout_seconds)
            return await super().flush_and_drain(
                timeout_seconds=timeout_seconds,
            )

    monkeypatch.setattr(stt_socket, "TtsSession", DrainRecordingTtsSession)
    monkeypatch.setattr(stt_socket, "_TTS_DRAIN_TIMEOUT_SECONDS", 0.01)
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    synthesizer = FakeSpeechSynthesizer(gates=(synthesis_gate,))
    realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("Hello.",)),
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(tts_start())
            _receive_json_frames(producer, 3)
            producer.send_bytes(b"audio")
            active_events = _receive_json_frames(producer, 4)
            assert [event["type"] for event in active_events] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
                "tts.pending",
            ]
            client.portal.call(synthesizer.call_started.wait)

            producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(producer) == {"type": "stt.closed"}

        live_tts_tasks = client.portal.call(
            _live_owned_task_names,
            "tts-",
        )

    assert len(created_sessions) == 1
    assert created_sessions[0].drain_timeouts == [0.01]
    assert synthesizer.cancelled_calls == 1
    assert synthesizer.active_calls == 0
    assert live_tts_tasks == []


def test_unexpected_producer_disconnect_aborts_downstream_and_releases_owner(
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    lifecycle = []

    class AbortRecordingTranslationSession(TranslationSession):
        async def flush_and_drain(self, *, timeout_seconds):
            lifecycle.append("translation.drain")
            return await super().flush_and_drain(
                timeout_seconds=timeout_seconds,
            )

        async def abort(self):
            lifecycle.append("translation.abort")
            await super().abort()

    class AbortRecordingTtsSession(TtsSession):
        async def flush_and_drain(self, *, timeout_seconds):
            lifecycle.append("tts.drain")
            return await super().flush_and_drain(
                timeout_seconds=timeout_seconds,
            )

        async def abort(self):
            lifecycle.append("tts.abort")
            await super().abort()

    monkeypatch.setattr(
        stt_socket,
        "TranslationSession",
        AbortRecordingTranslationSession,
    )
    monkeypatch.setattr(stt_socket, "TtsSession", AbortRecordingTtsSession)
    publishers = _capture_publishers(monkeypatch, lifecycle=lifecycle)
    synthesis_gate = asyncio.Event()
    websocket = FailingProducerWebSocket(
        {
            "type": "websocket.receive",
            "text": json.dumps(tts_start(session_id="demo-001")),
        },
        after_ready=(
            {"type": "websocket.receive", "bytes": b"audio"},
        ),
    )
    viewer = RecordingViewerWebSocket()
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    synthesizer = FakeSpeechSynthesizer(gates=(synthesis_gate,))
    hub = SessionHub()
    benchmark = CloseReasonRecorder()
    marker = {"type": "session.marker", "sequence": 1}

    async def exercise():
        await hub.join_viewer("demo-001", viewer)
        runner = asyncio.create_task(
            websocket_stt(
                websocket,
                provider_factory=lambda: stream,
                benchmark_factory=lambda: benchmark,
                transcript_trace_factory=lambda: None,
                session_hub=hub,
                translator_factory=lambda: translator,
                synthesizer_factory=lambda: synthesizer,
            )
        )
        try:
            await asyncio.wait_for(
                synthesizer.call_started.wait(),
                timeout=0.5,
            )
            assert websocket.sent_frames[-1]["type"] == "tts.pending"
            assert viewer.sent_frames[-1]["type"] == "tts.pending"

            await websocket.queue_receive(
                {"type": "websocket.disconnect", "code": 1006}
            )
            await asyncio.wait_for(runner, timeout=0.5)
        finally:
            if not runner.done():
                runner.cancel()
                await asyncio.gather(runner, return_exceptions=True)

        replacement_claimed = await hub.claim_producer(
            "demo-001",
            object(),
        )
        frames_before_marker = len(viewer.sent_frames)
        await hub.broadcast("demo-001", marker)
        remaining = await _live_owned_task_names(
            "translation-",
            "tts-",
            "publisher-failure:",
        )
        return replacement_claimed, frames_before_marker, remaining

    replacement_claimed, frames_before_marker, remaining = asyncio.run(
        exercise()
    )

    assert lifecycle == [
        "translation.abort",
        "tts.abort",
        "publisher.close",
    ]
    assert len(publishers) == 1
    assert publishers[0].close_calls == 1
    assert benchmark.close_reasons == ["client_disconnect"]
    assert synthesizer.cancelled_calls == 1
    assert synthesizer.active_calls == 0
    assert translator.active_calls == 0
    assert replacement_claimed is True
    assert viewer.sent_frames[frames_before_marker:] == [marker]
    assert not any(isinstance(frame, bytes) for frame in viewer.sent_frames)
    assert not any(
        frame["type"] == "tts.audio"
        for frame in viewer.sent_frames
        if isinstance(frame, dict)
    )
    assert remaining == []


def test_late_viewer_gets_translation_and_tts_configs_but_no_old_audio(
    realtime_tts_override,
):
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"old-speech", "audio/wav", 16000),)
    )
    hub = realtime_tts_override(
        stream,
        translator_factory=lambda: FakeTranslator(outcomes=("Hello.",)),
        synthesizer_factory=lambda: synthesizer,
    )
    marker = {"type": "session.marker", "sequence": 2}

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(tts_start(session_id="demo-001"))
            startup = _receive_json_frames(producer, 3)
            producer.send_bytes(b"audio")
            completed = _receive_tts_success_frames(
                producer,
                json_count=5,
            )

            with client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as late_viewer:
                client.portal.call(hub.wait_for_viewers, "demo-001", 1)
                snapshot = _receive_json_frames(late_viewer, 2)
                client.portal.call(hub.broadcast, "demo-001", marker)
                next_frame = _receive_json_frame(late_viewer)

            producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(producer) == {"type": "stt.closed"}

    assert [event["type"] for event in startup] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
    ]
    assert [
        frame[0] if frame[0] == "bytes" else frame[1]["type"]
        for frame in completed
    ] == [
        "transcript.final",
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
        "bytes",
    ]
    assert completed[-1] == ("bytes", b"old-speech")
    assert snapshot == startup[1:]
    assert next_frame == marker


def test_producer_release_clears_tts_config_before_next_stt_only_producer(
    realtime_tts_override,
):
    first_stream = FakeSttProviderStream()
    second_stream = FakeSttProviderStream()
    streams = iter((first_stream, second_stream))
    hub = realtime_tts_override(
        first_stream,
        translator_factory=lambda: FakeTranslator(),
        synthesizer_factory=lambda: FakeSpeechSynthesizer(),
    )
    app.dependency_overrides[get_stt_provider_factory] = (
        lambda: lambda: next(streams)
    )
    marker = {"type": "session.marker", "sequence": 3}

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as tts_producer:
            tts_producer.send_json(tts_start(session_id="demo-001"))
            assert [
                event["type"]
                for event in _receive_json_frames(tts_producer, 3)
            ] == [
                "stt.ready",
                "translation.configured",
                "tts.configured",
            ]
            tts_producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(tts_producer) == {
                "type": "stt.closed"
            }

        with client.websocket_connect("/ws/stt") as stt_only_producer:
            stt_only_producer.send_json(
                {**VALID_START, "session_id": "demo-001"}
            )
            assert _receive_json_frame(stt_only_producer)["type"] == (
                "stt.ready"
            )

            with client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as viewer:
                client.portal.call(hub.wait_for_viewers, "demo-001", 1)
                client.portal.call(hub.broadcast, "demo-001", marker)
                assert _receive_json_frame(viewer) == marker

            stt_only_producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(stt_only_producer) == {
                "type": "stt.closed"
            }


def test_failed_tts_binary_send_wakes_waiter_and_disconnects_without_tail(
    monkeypatch,
):
    publishers = _capture_publishers(monkeypatch)
    start = tts_start(session_id="demo-001")
    websocket = FailingProducerWebSocket(
        {
            "type": "websocket.receive",
            "text": json.dumps(start),
        },
        after_ready=(
            {"type": "websocket.receive", "bytes": b"audio"},
        ),
        fail_bytes=True,
    )
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),),
    )
    hub = SessionHub()
    benchmark = CloseReasonRecorder()

    async def exercise():
        await asyncio.wait_for(
            websocket_stt(
                websocket,
                provider_factory=lambda: stream,
                benchmark_factory=lambda: benchmark,
                transcript_trace_factory=lambda: None,
                session_hub=hub,
                translator_factory=lambda: translator,
                synthesizer_factory=lambda: synthesizer,
            ),
            timeout=0.5,
        )
        replacement_claimed = await hub.claim_producer(
            "demo-001",
            object(),
        )
        remaining = await _live_owned_task_names(
            "translation-",
            "tts-",
            "publisher-failure:",
        )
        return replacement_claimed, remaining

    replacement_claimed, remaining = asyncio.run(exercise())

    assert len(publishers) == 1
    publisher = publishers[0]
    assert publisher.producer_delivery_failed is True
    assert publisher.failure_wait_calls == 1
    assert publisher.failure_wait_completions == 1
    assert publisher.close_calls == 1
    assert benchmark.close_reasons == ["client_disconnect"]
    assert websocket.accept_calls == 1
    assert websocket.close_calls == 1
    assert websocket.receive_cancellations == 2
    assert [event["type"] for event in websocket.sent_frames] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
    ]
    assert not any(
        event["type"] in {"tts.error", "stt.error", "stt.closed"}
        for event in websocket.sent_frames
    )
    assert synthesizer.active_calls == 0
    assert translator.active_calls == 0
    assert stream.close_calls == 1
    assert replacement_claimed is True
    assert remaining == []


def test_failed_tts_startup_send_is_disconnect_without_terminal_write(
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    publishers = _capture_publishers(monkeypatch)
    terminal_error_calls = []
    original_send_terminal_error = stt_socket._send_terminal_error

    async def recording_send_terminal_error(*args, **kwargs):
        terminal_error_calls.append((args, kwargs))
        await original_send_terminal_error(*args, **kwargs)

    monkeypatch.setattr(
        stt_socket,
        "_send_terminal_error",
        recording_send_terminal_error,
    )
    websocket = FailingProducerWebSocket(
        {
            "type": "websocket.receive",
            "text": json.dumps(tts_start(session_id="demo-001")),
        },
        failed_json_type="tts.configured",
    )
    stream = FakeSttProviderStream()
    translator = FakeTranslator()
    synthesizer = FakeSpeechSynthesizer()
    hub = SessionHub()
    benchmark = CloseReasonRecorder()

    async def exercise():
        await websocket_stt(
            websocket,
            provider_factory=lambda: stream,
            benchmark_factory=lambda: benchmark,
            transcript_trace_factory=lambda: None,
            session_hub=hub,
            translator_factory=lambda: translator,
            synthesizer_factory=lambda: synthesizer,
        )
        replacement_claimed = await hub.claim_producer(
            "demo-001",
            object(),
        )
        remaining = await _live_owned_task_names(
            "translation-",
            "tts-",
            "publisher-failure:",
        )
        return replacement_claimed, remaining

    replacement_claimed, remaining = asyncio.run(exercise())

    assert len(publishers) == 1
    publisher = publishers[0]
    assert publisher.producer_delivery_failed is True
    assert publisher.failure_wait_calls == 0
    assert publisher.failure_wait_completions == 0
    assert publisher.close_calls >= 1
    assert terminal_error_calls == []
    assert benchmark.close_reasons == ["client_disconnect"]
    assert [event["type"] for event in websocket.json_attempts] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
    ]
    assert [event["type"] for event in websocket.sent_frames] == [
        "stt.ready",
        "translation.configured",
    ]
    assert websocket.close_calls == 1
    assert stream.close_calls == 1
    assert replacement_claimed is True
    assert remaining == []


def test_cleanup_pair_cancellation_is_disconnect_without_terminal_write(
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    publishers = _capture_publishers(monkeypatch)
    terminal_error_calls = []
    original_send_terminal_error = stt_socket._send_terminal_error

    async def recording_send_terminal_error(*args, **kwargs):
        terminal_error_calls.append(
            {
                "producer_delivery_failed": (
                    publishers[0].producer_delivery_failed
                ),
                "args": args,
                "kwargs": kwargs,
            }
        )
        await original_send_terminal_error(*args, **kwargs)

    monkeypatch.setattr(
        stt_socket,
        "_send_terminal_error",
        recording_send_terminal_error,
    )
    websocket = FailingProducerWebSocket(
        {
            "type": "websocket.receive",
            "text": json.dumps(tts_start(session_id="demo-001")),
        },
        after_ready=(
            {"type": "websocket.receive", "bytes": b"audio"},
        ),
        block_bytes=True,
    )
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),),
    )
    hub = SessionHub()
    benchmark = CloseReasonRecorder()

    async def exercise():
        runner = asyncio.create_task(
            websocket_stt(
                websocket,
                provider_factory=lambda: stream,
                benchmark_factory=lambda: benchmark,
                transcript_trace_factory=lambda: None,
                session_hub=hub,
                translator_factory=lambda: translator,
                synthesizer_factory=lambda: synthesizer,
            )
        )
        try:
            await asyncio.wait_for(
                websocket.binary_send_started.wait(),
                timeout=0.5,
            )
            assert len(publishers) == 1
            healthy_before_cleanup = not (
                publishers[0].producer_delivery_failed
            )
            await websocket.queue_receive(
                {
                    "type": "websocket.receive",
                    "text": "not-json",
                }
            )
            await asyncio.wait_for(runner, timeout=0.5)
        finally:
            if not runner.done():
                runner.cancel()
                await asyncio.gather(runner, return_exceptions=True)

        replacement_claimed = await hub.claim_producer(
            "demo-001",
            object(),
        )
        remaining = await _live_owned_task_names(
            "translation-",
            "tts-",
            "publisher-failure:",
        )
        return healthy_before_cleanup, replacement_claimed, remaining

    healthy_before_cleanup, replacement_claimed, remaining = asyncio.run(
        exercise()
    )

    publisher = publishers[0]
    assert healthy_before_cleanup is True
    assert publisher.producer_delivery_failed is True
    assert terminal_error_calls == []
    assert benchmark.close_reasons == ["client_disconnect"]
    assert websocket.binary_send_cancellations == 1
    assert [event["type"] for event in websocket.sent_frames] == [
        "stt.ready",
        "translation.configured",
        "tts.configured",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
    ]
    assert synthesizer.active_calls == 0
    assert translator.active_calls == 0
    assert stream.close_calls == 1
    assert replacement_claimed is True
    assert remaining == []


def test_translation_unavailable_skips_tts_construction_and_tts_events(
    realtime_tts_override,
):
    factory_calls = []

    def unavailable_translator_factory():
        raise TranslationProviderUnavailable("raw provider detail")

    def forbidden_synthesizer_factory():
        factory_calls.append(None)
        raise AssertionError("TTS inspected after Translation failure")

    realtime_tts_override(
        FakeSttProviderStream(),
        translator_factory=unavailable_translator_factory,
        synthesizer_factory=forbidden_synthesizer_factory,
    )

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(tts_start())
        ready = websocket.receive_json()
        translation_error = websocket.receive_json()
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert factory_calls == []
    assert ready["type"] == "stt.ready"
    assert translation_error == {
        "type": "translation.error",
        "scope": "session",
        "stream_id": ready["stream_id"],
        "source_language": "vi",
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Translation provider is unavailable.",
    }
    assert closed == {"type": "stt.closed"}


def test_one_synthesis_fans_out_identical_audio_pair_to_many_viewers(
    realtime_tts_override,
):
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),)
    )
    hub = realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app) as client:
        with (
            client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as first_viewer,
            client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as second_viewer,
        ):
            client.portal.call(hub.wait_for_viewers, "demo-001", 2)
            assert hub.viewer_count("demo-001") == 2
            with client.websocket_connect("/ws/stt") as producer:
                producer.send_json(
                    tts_start(
                        session_id="demo-001",
                        voice="northern-voice",
                    )
                )
                ready = _receive_json_frame(producer)
                producer.send_bytes(b"audio")

                producer_frames = _receive_tts_success_frames(
                    producer,
                    json_count=7,
                )
                first_viewer_frames = _receive_tts_success_frames(
                    first_viewer,
                    json_count=7,
                )
                second_viewer_frames = _receive_tts_success_frames(
                    second_viewer,
                    json_count=7,
                )

                producer.send_json({"type": "stt.stop"})
                assert _receive_json_frame(producer) == {
                    "type": "stt.closed"
                }

    expected_event_types = [
        "translation.configured",
        "tts.configured",
        "transcript.final",
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
    ]
    assert ready["type"] == "stt.ready"
    for frames in (
        producer_frames,
        first_viewer_frames,
        second_viewer_frames,
    ):
        assert [frame[0] for frame in frames] == [
            *("json" for _ in expected_event_types),
            "bytes",
        ]
        assert [frame[1]["type"] for frame in frames[:-1]] == (
            expected_event_types
        )

    assert first_viewer_frames == producer_frames
    assert second_viewer_frames == producer_frames
    metadata = producer_frames[-2][1]
    assert metadata == {
        "type": "tts.audio",
        "stream_id": ready["stream_id"],
        "utterance_id": producer_frames[4][1]["utterance_id"],
        "audio_id": "audio_000001",
        "target_language": "en",
        "mime_type": "audio/wav",
        "byte_length": 6,
        "sample_rate_hz": 16000,
    }
    assert all(
        frames[-1] == ("bytes", b"speech")
        for frames in (
            producer_frames,
            first_viewer_frames,
            second_viewer_frames,
        )
    )
    assert not any(isinstance(value, bytes) for value in metadata.values())
    assert "speech" not in json.dumps(metadata)
    assert "c3BlZWNo" not in json.dumps(metadata)
    assert len(synthesizer.calls) == 1
    assert synthesizer.calls[0].text == "Hello."
    assert synthesizer.calls[0].language == "en"
    assert synthesizer.calls[0].voice == "northern-voice"


def test_translation_pending_does_not_start_tts(realtime_tts_override):
    blocked = asyncio.Event()
    translator = FakeTranslator(
        outcomes=("Hello.",),
        gates=(blocked,),
    )
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),)
    )
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(tts_start())
            assert [
                event["type"]
                for event in _receive_json_frames(producer, 3)
            ] == [
                "stt.ready",
                "translation.configured",
                "tts.configured",
            ]
            producer.send_bytes(b"audio")
            transcript, pending = _receive_json_frames(producer, 2)

            client.portal.call(translator.call_started.wait)
            assert transcript["type"] == "transcript.final"
            assert pending["type"] == "translation.pending"
            assert synthesizer.calls == []

            client.portal.call(blocked.set)
            completed = _receive_tts_success_frames(
                producer,
                json_count=3,
            )
            producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(producer) == {"type": "stt.closed"}

    assert [frame[1]["type"] for frame in completed[:-1]] == [
        "translation.final",
        "tts.pending",
        "tts.audio",
    ]
    assert completed[-1] == ("bytes", b"speech")
    assert len(synthesizer.calls) == 1


def test_translation_error_never_starts_tts(realtime_tts_override):
    stream = SequencedFakeSttProviderStream(
        (
            (
                SttTranscript(
                    "final",
                    "seg_001",
                    "Mot.",
                    utterance_boundary=True,
                ),
            ),
            (
                SttTranscript(
                    "final",
                    "seg_002",
                    "Hai.",
                    utterance_boundary=True,
                ),
            ),
        )
    )
    translator = FakeTranslator(
        outcomes=(TranslationProviderError("secret"), "Two.")
    )
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(SynthesizedAudio(b"two", "audio/wav", 16000),)
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app).websocket_connect("/ws/stt") as producer:
        producer.send_json(tts_start())
        assert [
            event["type"] for event in _receive_json_frames(producer, 3)
        ] == [
            "stt.ready",
            "translation.configured",
            "tts.configured",
        ]
        producer.send_bytes(b"first")
        first_events = _receive_json_frames(producer, 3)
        assert synthesizer.calls == []

        producer.send_bytes(b"second")
        second_frames = _receive_tts_success_frames(
            producer,
            json_count=5,
        )
        producer.send_json({"type": "stt.stop"})
        assert _receive_json_frame(producer) == {"type": "stt.closed"}

    assert [event["type"] for event in first_events] == [
        "transcript.final",
        "translation.pending",
        "translation.error",
    ]
    assert first_events[-1]["code"] == "provider_error"
    assert [frame[1]["type"] for frame in second_frames[:-1]] == [
        "transcript.final",
        "translation.pending",
        "translation.final",
        "tts.pending",
        "tts.audio",
    ]
    assert second_frames[-1] == ("bytes", b"two")
    assert [call.text for call in synthesizer.calls] == ["Two."]


def test_tts_provider_failure_emits_safe_error_and_later_utterance_succeeds(
    realtime_tts_override,
):
    stream = SequencedFakeSttProviderStream(
        (
            (
                SttTranscript(
                    "final",
                    "seg_001",
                    "Mot.",
                    utterance_boundary=True,
                ),
            ),
            (
                SttTranscript(
                    "final",
                    "seg_002",
                    "Hai.",
                    utterance_boundary=True,
                ),
            ),
        )
    )
    translator = FakeTranslator(outcomes=("One.", "Two."))
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(
            TtsProviderError("secret"),
            SynthesizedAudio(b"two", "audio/wav", 16000),
        )
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app).websocket_connect("/ws/stt") as producer:
        producer.send_json(tts_start())
        assert [
            event["type"] for event in _receive_json_frames(producer, 3)
        ] == [
            "stt.ready",
            "translation.configured",
            "tts.configured",
        ]
        producer.send_bytes(b"first")
        first_events = _receive_json_frames(producer, 5)
        assert [event["type"] for event in first_events] == [
            "transcript.final",
            "translation.pending",
            "translation.final",
            "tts.pending",
            "tts.error",
        ]
        first_translation_final = first_events[2]
        first_tts_error = first_events[4]
        assert first_tts_error == {
            "type": "tts.error",
            "scope": "utterance",
            "stream_id": first_translation_final["stream_id"],
            "utterance_id": first_translation_final["utterance_id"],
            "target_language": "en",
            "code": "provider_error",
            "message": "Speech synthesis failed for this passage.",
        }
        assert "secret" not in json.dumps(first_events)

        producer.send_bytes(b"second")
        second_events = _receive_json_frames(producer, 5)
        assert [event["type"] for event in second_events] == [
            "transcript.final",
            "translation.pending",
            "translation.final",
            "tts.pending",
            "tts.audio",
        ]
        second_audio = _receive_bytes_frame(producer)
        producer.send_json({"type": "stt.stop"})
        assert _receive_json_frame(producer) == {"type": "stt.closed"}

    assert second_audio == b"two"
    assert [call.text for call in translator.calls] == ["Mot.", "Hai."]
    assert [call.text for call in synthesizer.calls] == ["One.", "Two."]


def test_tts_queue_overflow_emits_no_pending_and_stt_translation_continue(
    realtime_tts_override,
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    monkeypatch.setattr(stt_socket, "_TTS_QUEUE_MAX_SIZE", 1)
    first_gate = asyncio.Event()
    stream = SequencedFakeSttProviderStream(
        tuple(
            (
                SttTranscript(
                    "final",
                    f"seg_{number:03d}",
                    source_text,
                    utterance_boundary=True,
                ),
            )
            for number, source_text in enumerate(
                ("Mot.", "Hai.", "Ba.", "Bon."),
                start=1,
            )
        )
    )
    translator = FakeTranslator(
        outcomes=("One.", "Two.", "Three.", "Four.")
    )
    synthesizer = FakeSpeechSynthesizer(
        outcomes=(
            SynthesizedAudio(b"one", "audio/wav", 16000),
            SynthesizedAudio(b"two", "audio/wav", 16000),
            SynthesizedAudio(b"four", "audio/wav", 16000),
        ),
        gates=(first_gate, None, None),
    )
    realtime_tts_override(
        stream,
        translator_factory=lambda: translator,
        synthesizer_factory=lambda: synthesizer,
    )

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(tts_start())
            assert [
                event["type"]
                for event in _receive_json_frames(producer, 3)
            ] == [
                "stt.ready",
                "translation.configured",
                "tts.configured",
            ]

            producer.send_bytes(b"first")
            first_events = _receive_json_frames(producer, 4)
            client.portal.call(synthesizer.call_started.wait)
            assert [event["type"] for event in first_events] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
                "tts.pending",
            ]

            producer.send_bytes(b"second")
            second_events = _receive_json_frames(producer, 3)
            producer.send_bytes(b"third")
            third_events = _receive_json_frames(producer, 4)
            overflow_identity = third_events[2]["utterance_id"]

            assert [event["type"] for event in second_events] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
            ]
            assert [event["type"] for event in third_events] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
                "tts.error",
            ]
            assert third_events[-1]["code"] == "queue_overflow"
            assert third_events[-1]["utterance_id"] == overflow_identity
            assert not any(
                event["type"] == "tts.pending"
                and event.get("utterance_id") == overflow_identity
                for event in (*first_events, *second_events, *third_events)
            )
            assert [call.text for call in synthesizer.calls] == ["One."]

            client.portal.call(first_gate.set)
            first_audio = _receive_tts_success_frames(
                producer,
                json_count=1,
            )
            second_audio = _receive_tts_success_frames(
                producer,
                json_count=2,
            )

            producer.send_bytes(b"fourth")
            fourth_events = _receive_json_frames(producer, 5)
            assert [event["type"] for event in fourth_events] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
                "tts.pending",
                "tts.audio",
            ]
            fourth_audio = _receive_bytes_frame(producer)
            producer.send_json({"type": "stt.stop"})
            assert _receive_json_frame(producer) == {"type": "stt.closed"}

    assert [frame[1]["type"] for frame in first_audio[:-1]] == [
        "tts.audio"
    ]
    assert first_audio[-1] == ("bytes", b"one")
    assert [frame[1]["type"] for frame in second_audio[:-1]] == [
        "tts.pending",
        "tts.audio",
    ]
    assert second_audio[-1] == ("bytes", b"two")
    assert fourth_audio == b"four"
    assert [call.text for call in translator.calls] == [
        "Mot.",
        "Hai.",
        "Ba.",
        "Bon.",
    ]
    assert [call.text for call in synthesizer.calls] == [
        "One.",
        "Two.",
        "Four.",
    ]
    assert all(call.text != "Three." for call in synthesizer.calls)
