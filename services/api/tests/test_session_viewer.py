import pytest
from fastapi.testclient import TestClient

from app.ai.stt import SttTranscript, get_stt_provider_factory
from app.main import app
from app.realtime.session_hub import SessionHub, get_session_hub
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


def receive_stream_id(speaker) -> str:
    ready = speaker.receive_json()
    assert ready["type"] == "stt.ready"
    assert isinstance(ready.get("stream_id"), str)
    assert ready["stream_id"]
    return ready["stream_id"]


class SequencedFakeSttProviderStream(FakeSttProviderStream):
    def __init__(self, audio_event_batches):
        super().__init__()
        self._audio_event_batches = iter(audio_event_batches)

    async def send_audio(self, chunk):
        self.audio_chunks.append(chunk)
        for event in next(self._audio_event_batches, ()):
            await self._events.put(event)


class FailingViewer:
    async def send_json(self, event):
        raise RuntimeError("viewer disconnected")


@pytest.fixture
def session_hub():
    hub = SessionHub()
    app.dependency_overrides[get_session_hub] = lambda: hub
    yield hub
    app.dependency_overrides.pop(get_session_hub, None)


@pytest.fixture
def realtime_override():
    def install(stream):
        hub = SessionHub()
        app.dependency_overrides[get_session_hub] = lambda: hub
        app.dependency_overrides[get_stt_provider_factory] = lambda: lambda: stream
        return hub

    yield install
    app.dependency_overrides.pop(get_session_hub, None)
    app.dependency_overrides.pop(get_stt_provider_factory, None)


def test_viewer_connect_registers_in_requested_session(session_hub):
    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ):
            assert session_hub.viewer_count("demo-001") == 1


def test_viewer_disconnect_removes_registration(session_hub):
    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ):
            assert session_hub.viewer_count("demo-001") == 1

        assert session_hub.viewer_count("demo-001") == 0


def test_two_viewers_can_join_same_session(session_hub):
    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ), client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ):
            assert session_hub.viewer_count("demo-001") == 2


def test_viewers_in_different_sessions_are_isolated(session_hub):
    first_event = {"type": "transcript.interim", "text": "first"}
    second_event = {"type": "transcript.interim", "text": "second"}

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as first, client.websocket_connect(
            "/ws/sessions/demo-002/viewer"
        ) as second:
            client.portal.call(session_hub.broadcast, "demo-001", first_event)
            client.portal.call(session_hub.broadcast, "demo-002", second_event)

            assert first.receive_json() == first_event
            assert second.receive_json() == second_event


def test_speaker_and_two_viewers_receive_same_transcripts_then_one_leaves(
    realtime_override,
):
    first_marker = {"type": "test.first-marker"}
    second_marker = {"type": "test.second-marker"}
    interim = {
        "type": "transcript.interim",
        "segment_id": "seg_001",
        "text": "xin chào",
        "language": "vi",
    }
    final = {
        "type": "transcript.final",
        "segment_id": "seg_001",
        "text": "Xin chào mọi người.",
        "language": "vi",
    }
    second_final = {
        "type": "transcript.final",
        "segment_id": "seg_002",
        "text": "Hẹn gặp lại.",
        "language": "vi",
    }
    stream = SequencedFakeSttProviderStream(
        (
            (
                SttTranscript("interim", "seg_001", "xin chào"),
                SttTranscript("final", "seg_001", "Xin chào mọi người."),
            ),
            (SttTranscript("final", "seg_002", "Hẹn gặp lại."),),
        )
    )
    hub = realtime_override(stream)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as first, client.websocket_connect("/ws/stt") as speaker:
            with client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as second:
                assert hub.viewer_count("demo-001") == 2
                speaker.send_json({**VALID_START, "session_id": "demo-001"})
                stream_id = receive_stream_id(speaker)
                interim["stream_id"] = stream_id
                final["stream_id"] = stream_id
                second_final["stream_id"] = stream_id

                speaker.send_bytes(b"first audio")
                assert speaker.receive_json() == interim
                assert speaker.receive_json() == final
                client.portal.call(hub.broadcast, "demo-001", first_marker)
                assert first.receive_json() == interim
                assert first.receive_json() == final
                assert first.receive_json() == first_marker
                assert second.receive_json() == interim
                assert second.receive_json() == final
                assert second.receive_json() == first_marker

            assert hub.viewer_count("demo-001") == 1
            speaker.send_bytes(b"second audio")
            assert speaker.receive_json() == second_final
            client.portal.call(hub.broadcast, "demo-001", second_marker)
            assert first.receive_json() == second_final
            assert first.receive_json() == second_marker
            speaker.send_json({"type": "stt.stop"})
            assert speaker.receive_json() == {"type": "stt.closed"}

        assert hub.viewer_count("demo-001") == 0


def test_stt_broadcast_does_not_cross_sessions(realtime_override):
    transcript = {
        "type": "transcript.interim",
        "segment_id": "seg_001",
        "text": "xin chào",
        "language": "vi",
    }
    marker = {"type": "test.marker"}
    stream = SequencedFakeSttProviderStream(
        ((SttTranscript("interim", "seg_001", "xin chào"),),)
    )
    hub = realtime_override(stream)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-002/viewer"
        ) as other_session, client.websocket_connect("/ws/stt") as speaker:
            speaker.send_json({**VALID_START, "session_id": "demo-001"})
            transcript["stream_id"] = receive_stream_id(speaker)
            speaker.send_bytes(b"audio")
            assert speaker.receive_json() == transcript

            client.portal.call(hub.broadcast, "demo-002", marker)
            assert other_session.receive_json() == marker
            speaker.send_json({"type": "stt.stop"})
            assert speaker.receive_json() == {"type": "stt.closed"}


def test_stt_without_session_id_does_not_broadcast(realtime_override):
    transcript = {
        "type": "transcript.final",
        "segment_id": "seg_001",
        "text": "Xin chào.",
        "language": "vi",
    }
    marker = {"type": "test.marker"}
    stream = SequencedFakeSttProviderStream(
        ((SttTranscript("final", "seg_001", "Xin chào."),),)
    )
    hub = realtime_override(stream)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as viewer, client.websocket_connect("/ws/stt") as speaker:
            speaker.send_json(VALID_START)
            transcript["stream_id"] = receive_stream_id(speaker)
            speaker.send_bytes(b"audio")
            assert speaker.receive_json() == transcript

            client.portal.call(hub.broadcast, "demo-001", marker)
            assert viewer.receive_json() == marker
            speaker.send_json({"type": "stt.stop"})
            assert speaker.receive_json() == {"type": "stt.closed"}


def test_failed_viewer_does_not_interrupt_speaker_or_healthy_viewer(
    realtime_override,
):
    first_marker = {"type": "test.first-marker"}
    second_marker = {"type": "test.second-marker"}
    interim = {
        "type": "transcript.interim",
        "segment_id": "seg_001",
        "text": "xin chào",
        "language": "vi",
    }
    final = {
        "type": "transcript.final",
        "segment_id": "seg_001",
        "text": "Xin chào.",
        "language": "vi",
    }
    stream = SequencedFakeSttProviderStream(
        (
            (SttTranscript("interim", "seg_001", "xin chào"),),
            (SttTranscript("final", "seg_001", "Xin chào."),),
        )
    )
    hub = realtime_override(stream)

    with TestClient(app) as client:
        client.portal.call(hub.join_viewer, "demo-001", FailingViewer())
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as healthy, client.websocket_connect("/ws/stt") as speaker:
            speaker.send_json({**VALID_START, "session_id": "demo-001"})
            stream_id = receive_stream_id(speaker)
            interim["stream_id"] = stream_id
            final["stream_id"] = stream_id

            speaker.send_bytes(b"first audio")
            assert speaker.receive_json() == interim
            client.portal.call(hub.broadcast, "demo-001", first_marker)
            assert healthy.receive_json() == interim
            assert healthy.receive_json() == first_marker
            assert hub.viewer_count("demo-001") == 1

            speaker.send_bytes(b"second audio")
            assert speaker.receive_json() == final
            client.portal.call(hub.broadcast, "demo-001", second_marker)
            assert healthy.receive_json() == final
            assert healthy.receive_json() == second_marker
            speaker.send_json({"type": "stt.stop"})
            assert speaker.receive_json() == {"type": "stt.closed"}
