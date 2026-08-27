import asyncio
import json
import logging

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.ai.stt import (
    ProviderStreamError,
    ProviderUnavailableError,
    SttTranscript,
    get_stt_provider_factory,
    unconfigured_stt_provider_factory,
)
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
