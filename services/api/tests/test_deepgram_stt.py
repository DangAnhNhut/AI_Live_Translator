import asyncio
import json

import pytest
from pydantic import SecretStr

from app.ai.stt import ProviderStreamError
from app.ai.deepgram import DeepgramSttStream
from app.realtime.stt_protocol import AudioConfig


_UPSTREAM_CLOSED = object()


class FakeDeepgramWebSocket:
    def __init__(
        self,
        *,
        send_error: Exception | None = None,
        close_stream_messages: tuple[str, ...] = (),
        close_on_close_stream: bool = True,
    ) -> None:
        self.incoming: asyncio.Queue[object] = asyncio.Queue()
        self.sent: list[str | bytes] = []
        self.close_calls = 0
        self.send_error = send_error
        self.close_stream_messages = close_stream_messages
        self.close_on_close_stream = close_on_close_stream
        self.message_received = asyncio.Event()
        self.iteration_cancelled = asyncio.Event()

    def __aiter__(self):
        return self

    async def __anext__(self):
        try:
            message = await self.incoming.get()
        except asyncio.CancelledError:
            self.iteration_cancelled.set()
            raise
        if message is _UPSTREAM_CLOSED:
            raise StopAsyncIteration
        if isinstance(message, Exception):
            raise message
        self.message_received.set()
        return message

    async def send(self, message: str | bytes) -> None:
        if self.send_error is not None:
            raise self.send_error
        self.sent.append(message)
        if message == '{"type":"CloseStream"}' and self.close_on_close_stream:
            for upstream_message in self.close_stream_messages:
                await self.incoming.put(upstream_message)
            await self.incoming.put(_UPSTREAM_CLOSED)

    async def close(self) -> None:
        self.close_calls += 1
        await self.incoming.put(_UPSTREAM_CLOSED)


class RecordingConnector:
    def __init__(self, websocket: FakeDeepgramWebSocket) -> None:
        self.websocket = websocket
        self.calls: list[tuple[str, dict[str, object]]] = []

    async def __call__(self, uri: str, **kwargs: object):
        self.calls.append((uri, kwargs))
        return self.websocket


class FailingConnector:
    def __init__(self, error: Exception) -> None:
        self.error = error

    async def __call__(self, uri: str, **kwargs: object):
        raise self.error


def make_stream(connector: RecordingConnector) -> DeepgramSttStream:
    return DeepgramSttStream(
        api_key=SecretStr("test-deepgram-key"),
        model="nova-3",
        language="vi",
        endpointing_ms=300,
        connector=connector,
    )


def valid_audio() -> AudioConfig:
    return AudioConfig(
        encoding="pcm_s16le",
        sample_rate_hz=16000,
        channels=1,
    )


def results_message(
    transcript: str,
    *,
    is_final: bool,
    speech_final: bool = False,
) -> str:
    return json.dumps(
        {
            "type": "Results",
            "channel_index": [0, 1],
            "duration": 0.8,
            "start": 0.0,
            "is_final": is_final,
            "speech_final": speech_final,
            "from_finalize": False,
            "channel": {
                "alternatives": [
                    {
                        "transcript": transcript,
                        "confidence": 0.99,
                        "words": [],
                    }
                ]
            },
        }
    )


def test_start_connects_with_deepgram_mvp_configuration_and_authentication():
    websocket = FakeDeepgramWebSocket()
    connector = RecordingConnector(websocket)
    stream = make_stream(connector)

    async def exercise() -> None:
        await stream.start(valid_audio(), "vi")
        await stream.close()

    asyncio.run(exercise())

    assert connector.calls == [
        (
            "wss://api.deepgram.com/v1/listen"
            "?model=nova-3&language=vi&encoding=linear16&sample_rate=16000"
            "&channels=1&interim_results=true&punctuate=true"
            "&smart_format=true&endpointing=300",
            {
                "additional_headers": {
                    "Authorization": "Token test-deepgram-key",
                }
            },
        )
    ]
    assert websocket.close_calls == 1


def test_send_audio_forwards_binary_pcm_chunk_unchanged():
    websocket = FakeDeepgramWebSocket()
    connector = RecordingConnector(websocket)
    stream = make_stream(connector)
    chunk = b"\x00\x80\xff\x7f"

    async def exercise() -> None:
        await stream.start(valid_audio(), "vi")
        await stream.send_audio(chunk)
        await stream.close()

    asyncio.run(exercise())

    assert websocket.sent == [chunk]


def test_results_map_to_ordered_interim_and_final_transcripts():
    websocket = FakeDeepgramWebSocket()
    connector = RecordingConnector(websocket)
    stream = make_stream(connector)

    async def exercise():
        await stream.start(valid_audio(), "vi")
        events = stream.events()
        await websocket.incoming.put(results_message("xin", is_final=False))
        await websocket.incoming.put(
            results_message("xin chào", is_final=True, speech_final=False)
        )
        await websocket.incoming.put(results_message("bạn", is_final=False))
        received = [
            await asyncio.wait_for(anext(events), timeout=0.5)
            for _ in range(3)
        ]
        await stream.close()
        return received

    received = asyncio.run(exercise())

    assert [event.kind for event in received] == ["interim", "final", "interim"]
    assert [event.segment_id for event in received] == [
        "seg_001",
        "seg_001",
        "seg_002",
    ]
    assert [event.text for event in received] == ["xin", "xin chào", "bạn"]
    assert [event.language for event in received] == ["vi", "vi", "vi"]


def test_empty_final_result_is_ignored_without_advancing_segment():
    websocket = FakeDeepgramWebSocket()
    connector = RecordingConnector(websocket)
    stream = make_stream(connector)

    async def exercise():
        await stream.start(valid_audio(), "vi")
        events = stream.events()
        await websocket.incoming.put(results_message("   ", is_final=True))
        await websocket.incoming.put(results_message("xin chào", is_final=False))
        event = await asyncio.wait_for(anext(events), timeout=0.5)
        await stream.close()
        return event

    event = asyncio.run(exercise())

    assert event.kind == "interim"
    assert event.segment_id == "seg_001"
    assert event.text == "xin chào"


def test_result_with_no_alternatives_is_ignored_safely():
    websocket = FakeDeepgramWebSocket()
    stream = make_stream(RecordingConnector(websocket))
    empty_results = json.dumps(
        {
            "type": "Results",
            "channel_index": [0, 1],
            "duration": 0.0,
            "start": 0.0,
            "is_final": False,
            "speech_final": False,
            "from_finalize": False,
            "channel": {"alternatives": []},
        }
    )

    async def exercise():
        await stream.start(valid_audio(), "vi")
        await websocket.incoming.put(empty_results)
        await websocket.incoming.put(results_message("xin chào", is_final=False))
        event = await asyncio.wait_for(anext(stream.events()), timeout=0.5)
        await stream.close()
        return event

    event = asyncio.run(exercise())

    assert event.kind == "interim"
    assert event.segment_id == "seg_001"
    assert event.text == "xin chào"


def test_connect_failure_is_sanitized_without_exposing_api_key():
    api_key = "test-deepgram-key"
    stream = DeepgramSttStream(
        api_key=SecretStr(api_key),
        model="nova-3",
        language="vi",
        endpointing_ms=300,
        connector=FailingConnector(
            RuntimeError(f"authentication rejected Token {api_key}")
        ),
    )

    async def exercise() -> str:
        with pytest.raises(ProviderStreamError) as error:
            await stream.start(valid_audio(), "vi")
        return str(error.value)

    message = asyncio.run(exercise())

    assert message == "Deepgram upstream connection failed"
    assert api_key not in message
    assert "authentication rejected" not in message


def test_send_failure_is_sanitized_and_closes_upstream():
    api_key = "test-deepgram-key"
    websocket = FakeDeepgramWebSocket(
        send_error=RuntimeError(f"send failed with Token {api_key}")
    )
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> str:
        await stream.start(valid_audio(), "vi")
        with pytest.raises(ProviderStreamError) as error:
            await stream.send_audio(b"\x00\x00")
        await stream.close()
        return str(error.value)

    message = asyncio.run(exercise())

    assert message == "Deepgram upstream stream failed"
    assert api_key not in message
    assert "send failed" not in message
    assert websocket.close_calls == 1


def test_send_audio_after_reader_failure_is_sanitized_provider_error():
    api_key = "test-deepgram-key"
    raw_detail = "raw reader failure detail"
    websocket = FakeDeepgramWebSocket()
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> str:
        await stream.start(valid_audio(), "vi")
        await websocket.incoming.put(
            RuntimeError(f"{raw_detail} Token {api_key}")
        )

        async def wait_until_upstream_is_cleared() -> None:
            while stream._websocket is not None:
                await asyncio.sleep(0)

        await asyncio.wait_for(wait_until_upstream_is_cleared(), timeout=0.5)
        try:
            with pytest.raises(ProviderStreamError) as error:
                await stream.send_audio(b"\x00\x00")
            return str(error.value)
        finally:
            await stream.close()

    message = asyncio.run(exercise())

    assert message == "Deepgram upstream stream failed"
    assert api_key not in message
    assert raw_detail not in message
    assert "AssertionError" not in message


def test_reader_failure_is_sanitized_and_closes_upstream():
    api_key = "test-deepgram-key"
    websocket = FakeDeepgramWebSocket()
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> str:
        await stream.start(valid_audio(), "vi")
        events = stream.events()
        await websocket.incoming.put(
            RuntimeError(f"reader failed with Token {api_key}")
        )
        with pytest.raises(ProviderStreamError) as error:
            await asyncio.wait_for(anext(events), timeout=0.5)
        await stream.close()
        return str(error.value)

    message = asyncio.run(exercise())

    assert message == "Deepgram upstream stream failed"
    assert api_key not in message
    assert "reader failed" not in message
    assert websocket.close_calls == 1


def test_finish_flushes_final_then_closes_upstream_idempotently():
    websocket = FakeDeepgramWebSocket(
        close_stream_messages=(
            results_message("Xin chào.", is_final=True, speech_final=False),
        )
    )
    stream = make_stream(RecordingConnector(websocket))

    async def exercise():
        await stream.start(valid_audio(), "vi")
        events = stream.events()
        finish_task = asyncio.create_task(stream.finish_input())
        final = await asyncio.wait_for(anext(events), timeout=0.5)
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(anext(events), timeout=0.5)
        await asyncio.wait_for(finish_task, timeout=0.5)
        await stream.finish_input()
        await stream.close()
        await stream.close()
        return final

    final = asyncio.run(exercise())

    assert final.kind == "final"
    assert final.segment_id == "seg_001"
    assert final.text == "Xin chào."
    assert websocket.sent == ['{"type":"CloseStream"}']
    assert websocket.close_calls == 1


def test_abrupt_downstream_close_cancels_reader_and_discards_stale_events():
    websocket = FakeDeepgramWebSocket()
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> None:
        await stream.start(valid_audio(), "vi")
        await websocket.incoming.put(results_message("stale", is_final=False))
        await asyncio.wait_for(websocket.message_received.wait(), timeout=0.5)
        await asyncio.sleep(0)
        await stream.close()
        await stream.close()
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(anext(stream.events()), timeout=0.5)

    asyncio.run(exercise())

    assert websocket.iteration_cancelled.is_set()
    assert websocket.close_calls == 1


def test_cancelling_finish_closes_socket_and_reader():
    websocket = FakeDeepgramWebSocket(close_on_close_stream=False)
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> None:
        await stream.start(valid_audio(), "vi")
        finish_task = asyncio.create_task(stream.finish_input())
        await asyncio.sleep(0)
        assert websocket.sent == ['{"type":"CloseStream"}']
        finish_task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await finish_task
        await stream.close()

    asyncio.run(exercise())

    assert websocket.iteration_cancelled.is_set()
    assert websocket.close_calls == 1


def test_unexpected_upstream_close_is_normalized_provider_failure():
    websocket = FakeDeepgramWebSocket()
    stream = make_stream(RecordingConnector(websocket))

    async def exercise() -> str:
        await stream.start(valid_audio(), "vi")
        await websocket.incoming.put(_UPSTREAM_CLOSED)
        with pytest.raises(ProviderStreamError) as error:
            await asyncio.wait_for(anext(stream.events()), timeout=0.5)
        await stream.close()
        return str(error.value)

    message = asyncio.run(exercise())

    assert message == "Deepgram upstream stream failed"
    assert websocket.close_calls == 1
