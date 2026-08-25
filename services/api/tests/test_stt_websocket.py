import asyncio
import json

import pytest
from fastapi.testclient import TestClient

from app.ai.stt import SttTranscript, get_stt_provider_factory
from app.main import app
from app.realtime.stt_protocol import SttStart, SttStateMachine
from app.realtime.stt_socket import _run_stream
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


@pytest.fixture(autouse=True)
def clear_overrides():
    app.dependency_overrides.clear()
    yield
    app.dependency_overrides.clear()


def use_stream(stream):
    app.dependency_overrides[get_stt_provider_factory] = lambda: lambda: stream


def test_unconfigured_endpoint_reports_provider_unavailable_without_raw_detail():
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


def test_streams_binary_audio_and_normalized_transcripts_then_closes():
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript("interim", "seg_001", "xin chào"),
            SttTranscript("final", "seg_001", "Xin chào."),
        )
    )
    use_stream(stream)

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
