import asyncio

import pytest
from fastapi.testclient import TestClient

from app.ai.stt import SttTranscript, get_stt_provider_factory
from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
)
from app.main import app
from app.realtime.session_hub import SessionHub, get_session_hub
from app.realtime.stt_socket import get_session_translator_factory
from tests.fakes.stt import FakeSttProviderStream
from tests.fakes.translation import FakeTranslator


VALID_START = {
    "type": "stt.start",
    "audio": {
        "encoding": "pcm_s16le",
        "sample_rate_hz": 16000,
        "channels": 1,
    },
    "language": "vi",
}


class SequencedFakeSttProviderStream(FakeSttProviderStream):
    def __init__(self, audio_event_batches):
        super().__init__()
        self._audio_event_batches = iter(audio_event_batches)

    async def send_audio(self, chunk):
        self.audio_chunks.append(chunk)
        for event in next(self._audio_event_batches, ()):
            await self._events.put(event)


@pytest.fixture
def realtime_translation_override():
    hub = SessionHub()
    app.dependency_overrides[get_session_hub] = lambda: hub

    def install(stream, translator_factory):
        app.dependency_overrides[get_stt_provider_factory] = (
            lambda: lambda: stream
        )
        app.dependency_overrides[get_session_translator_factory] = (
            lambda: translator_factory
        )
        return hub

    yield install
    app.dependency_overrides.clear()


def receive_ready(websocket):
    event = websocket.receive_json()
    assert event["type"] == "stt.ready"
    return event


def translation_start(*, session_id=None):
    start = {
        **VALID_START,
        "translation": {"target_language": "en"},
    }
    if session_id is not None:
        start["session_id"] = session_id
    return start


def test_stt_only_start_never_constructs_translator_and_stays_compatible(
    realtime_translation_override,
):
    constructed = 0

    def forbidden_translator_factory():
        nonlocal constructed
        constructed += 1
        raise AssertionError("STT-only session constructed Translator")

    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("final", "seg_001", "Xin chao."),)
    )
    realtime_translation_override(stream, forbidden_translator_factory)

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        ready = receive_ready(websocket)
        websocket.send_bytes(b"audio")
        transcript = websocket.receive_json()
        websocket.send_json({"type": "stt.stop"})
        closed = websocket.receive_json()

    assert constructed == 0
    assert transcript == {
        "type": "transcript.final",
        "stream_id": ready["stream_id"],
        "segment_id": "seg_001",
        "text": "Xin chao.",
        "language": "vi",
    }
    assert closed == {"type": "stt.closed"}


def test_translation_success_reaches_producer_and_viewer_in_source_order(
    realtime_translation_override,
):
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript(
                "interim",
                "seg_001",
                "Xin",
            ),
            SttTranscript(
                "final",
                "seg_001",
                "Xin chao.",
                utterance_boundary=True,
            ),
        )
    )
    translator = FakeTranslator(outcomes=("Hello.",))
    realtime_translation_override(stream, lambda: translator)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as viewer, client.websocket_connect("/ws/stt") as producer:
            producer.send_json(translation_start(session_id="demo-001"))
            ready = receive_ready(producer)
            configured = producer.receive_json()
            assert viewer.receive_json() == configured

            producer.send_bytes(b"audio")
            producer_events = [producer.receive_json() for _ in range(4)]
            viewer_events = [viewer.receive_json() for _ in range(4)]
            producer.send_json({"type": "stt.stop"})
            assert producer.receive_json() == {"type": "stt.closed"}

    assert configured == {
        "type": "translation.configured",
        "stream_id": ready["stream_id"],
        "source_language": "vi",
        "target_language": "en",
    }
    assert [event["type"] for event in producer_events] == [
        "transcript.interim",
        "transcript.final",
        "translation.pending",
        "translation.final",
    ]
    assert viewer_events == producer_events
    assert len(translator.calls) == 1
    assert translator.calls[0].text == "Xin chao."
    mapped_events = producer_events[1:]
    assert all(event["stream_id"] == ready["stream_id"] for event in mapped_events)
    assert mapped_events[1]["source_segment_ids"] == ["seg_001"]
    assert mapped_events[1]["source_text"] == "Xin chao."
    assert mapped_events[2]["translated_text"] == "Hello."


def test_translation_provider_error_reaches_producer_and_viewer_then_stt_continues(
    realtime_translation_override,
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
    translator = FakeTranslator(
        outcomes=(TranslationProviderError("secret detail"), "Two.")
    )
    realtime_translation_override(stream, lambda: translator)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as viewer, client.websocket_connect("/ws/stt") as producer:
            producer.send_json(translation_start(session_id="demo-001"))
            receive_ready(producer)
            assert producer.receive_json()["type"] == "translation.configured"
            assert viewer.receive_json()["type"] == "translation.configured"

            producer.send_bytes(b"first")
            first_events = [producer.receive_json() for _ in range(3)]
            assert [viewer.receive_json() for _ in range(3)] == first_events
            producer.send_bytes(b"second")
            second_events = [producer.receive_json() for _ in range(3)]
            assert [viewer.receive_json() for _ in range(3)] == second_events
            producer.send_json({"type": "stt.stop"})
            assert producer.receive_json() == {"type": "stt.closed"}

    assert [event["type"] for event in first_events] == [
        "transcript.final",
        "translation.pending",
        "translation.error",
    ]
    assert first_events[-1]["scope"] == "utterance"
    assert first_events[-1]["code"] == "provider_error"
    assert "secret" not in first_events[-1]["message"]
    assert [event["type"] for event in second_events] == [
        "transcript.final",
        "translation.pending",
        "translation.final",
    ]


def test_translation_provider_unavailable_degrades_to_stt_with_session_error(
    realtime_translation_override,
):
    def unavailable_translator_factory():
        raise TranslationProviderUnavailable("raw ADC detail")

    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("final", "seg_001", "Xin chao."),)
    )
    realtime_translation_override(stream, unavailable_translator_factory)

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as viewer, client.websocket_connect("/ws/stt") as producer:
            producer.send_json(translation_start(session_id="demo-001"))
            ready = receive_ready(producer)
            unavailable = producer.receive_json()
            assert viewer.receive_json() == unavailable
            producer.send_bytes(b"audio")
            transcript = producer.receive_json()
            assert viewer.receive_json() == transcript
            producer.send_json({"type": "stt.stop"})
            assert producer.receive_json() == {"type": "stt.closed"}

    assert unavailable == {
        "type": "translation.error",
        "scope": "session",
        "stream_id": ready["stream_id"],
        "source_language": "vi",
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Translation provider is unavailable.",
    }
    assert transcript["type"] == "transcript.final"
    assert transcript["stream_id"] == ready["stream_id"]


def test_blocked_translation_and_queue_overflow_do_not_block_stt(
    realtime_translation_override,
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    monkeypatch.setattr(
        stt_socket.settings,
        "translation_queue_max_size",
        1,
    )
    first_gate = asyncio.Event()
    translator = FakeTranslator(
        outcomes=("One.", "Two."),
        gates=(first_gate, None),
    )
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
            (
                SttTranscript(
                    "final",
                    "seg_003",
                    "Ba.",
                    utterance_boundary=True,
                ),
            ),
            (SttTranscript("interim", "seg_004", "Bon"),),
        )
    )
    realtime_translation_override(stream, lambda: translator)

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(translation_start())
            receive_ready(producer)
            assert producer.receive_json()["type"] == "translation.configured"

            producer.send_bytes(b"first")
            assert producer.receive_json()["type"] == "transcript.final"
            assert producer.receive_json()["type"] == "translation.pending"
            producer.send_bytes(b"second")
            assert producer.receive_json()["type"] == "transcript.final"
            producer.send_bytes(b"third")
            assert producer.receive_json()["type"] == "transcript.final"
            overflow = producer.receive_json()
            producer.send_bytes(b"fourth")
            interim = producer.receive_json()

            assert overflow["type"] == "translation.error"
            assert overflow["code"] == "queue_overflow"
            assert overflow["source_segment_ids"] == ["seg_003"]
            assert interim["type"] == "transcript.interim"
            assert [call.text for call in translator.calls] == ["Mot."]

            client.portal.call(first_gate.set)
            producer.send_json({"type": "stt.stop"})
            shutdown_events = []
            while True:
                event = producer.receive_json()
                shutdown_events.append(event)
                if event["type"] == "stt.closed":
                    break

    assert [event["type"] for event in shutdown_events] == [
        "translation.final",
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]
    assert [call.text for call in translator.calls] == ["Mot.", "Hai."]


def test_second_producer_for_same_session_is_rejected_without_harming_owner(
    realtime_translation_override,
):
    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("interim", "seg_001", "Xin"),)
    )
    realtime_translation_override(stream, lambda: FakeTranslator())

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as owner:
            owner.send_json({**VALID_START, "session_id": "demo-001"})
            receive_ready(owner)
            with client.websocket_connect("/ws/stt") as conflicting:
                conflicting.send_json(
                    {**VALID_START, "session_id": "demo-001"}
                )
                error = conflicting.receive_json()
                assert conflicting.receive_json() == {"type": "stt.closed"}

            owner.send_bytes(b"audio")
            assert owner.receive_json()["type"] == "transcript.interim"
            owner.send_json({"type": "stt.stop"})
            assert owner.receive_json() == {"type": "stt.closed"}

    assert error["type"] == "stt.error"
    assert error["code"] == "session_producer_conflict"


def test_late_viewer_gets_active_config_but_no_event_history(
    realtime_translation_override,
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
    hub = realtime_translation_override(
        stream,
        lambda: FakeTranslator(outcomes=("Hello.",)),
    )
    marker = {"type": "test.marker"}

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as producer:
            producer.send_json(translation_start(session_id="demo-001"))
            receive_ready(producer)
            configured = producer.receive_json()
            producer.send_bytes(b"audio")
            assert [producer.receive_json()["type"] for _ in range(3)] == [
                "transcript.final",
                "translation.pending",
                "translation.final",
            ]

            with client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as late_viewer:
                assert late_viewer.receive_json() == configured
                client.portal.call(hub.broadcast, "demo-001", marker)
                assert late_viewer.receive_json() == marker

            producer.send_json({"type": "stt.stop"})
            assert producer.receive_json() == {"type": "stt.closed"}


def test_producer_cleanup_clears_config_before_later_stt_only_session(
    realtime_translation_override,
):
    stream = FakeSttProviderStream()
    hub = realtime_translation_override(stream, lambda: FakeTranslator())
    marker = {"type": "test.marker"}

    with TestClient(app) as client:
        with client.websocket_connect("/ws/stt") as translated:
            translated.send_json(
                translation_start(session_id="demo-001")
            )
            receive_ready(translated)
            assert translated.receive_json()["type"] == "translation.configured"
            translated.send_json({"type": "stt.stop"})
            assert translated.receive_json() == {"type": "stt.closed"}

        with client.websocket_connect("/ws/stt") as stt_only:
            stt_only.send_json({**VALID_START, "session_id": "demo-001"})
            receive_ready(stt_only)
            with client.websocket_connect(
                "/ws/sessions/demo-001/viewer"
            ) as late_viewer:
                client.portal.call(hub.broadcast, "demo-001", marker)
                assert late_viewer.receive_json() == marker
            stt_only.send_json({"type": "stt.stop"})
            assert stt_only.receive_json() == {"type": "stt.closed"}


def test_clean_stop_flushes_buffered_translation_before_closed(
    realtime_translation_override,
):
    stream = FakeSttProviderStream(
        audio_events=(SttTranscript("final", "seg_001", "Xin chao"),)
    )
    translator = FakeTranslator(outcomes=("Hello",))
    realtime_translation_override(stream, lambda: translator)

    with TestClient(app).websocket_connect("/ws/stt") as producer:
        producer.send_json(translation_start())
        receive_ready(producer)
        assert producer.receive_json()["type"] == "translation.configured"
        producer.send_bytes(b"audio")
        assert producer.receive_json()["type"] == "transcript.final"
        producer.send_json({"type": "stt.stop"})
        shutdown_events = [producer.receive_json() for _ in range(3)]

    assert [event["type"] for event in shutdown_events] == [
        "translation.pending",
        "translation.final",
        "stt.closed",
    ]
    assert translator.calls[0].text == "Xin chao"


def test_translation_drain_timeout_still_closes_socket(
    realtime_translation_override,
    monkeypatch,
):
    import app.realtime.stt_socket as stt_socket

    monkeypatch.setattr(
        stt_socket,
        "_TRANSLATION_DRAIN_TIMEOUT_SECONDS",
        0.01,
    )
    blocked = asyncio.Event()
    translator = FakeTranslator(gates=(blocked,))
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
    realtime_translation_override(stream, lambda: translator)

    with TestClient(app).websocket_connect("/ws/stt") as producer:
        producer.send_json(translation_start())
        receive_ready(producer)
        assert producer.receive_json()["type"] == "translation.configured"
        producer.send_bytes(b"audio")
        assert producer.receive_json()["type"] == "transcript.final"
        assert producer.receive_json()["type"] == "translation.pending"
        producer.send_json({"type": "stt.stop"})
        assert producer.receive_json() == {"type": "stt.closed"}

    assert translator.cancelled_calls == 1
    assert translator.active_calls == 0


def test_unexpected_disconnect_aborts_translation_without_late_viewer_event(
    realtime_translation_override,
):
    blocked = asyncio.Event()
    translator = FakeTranslator(outcomes=("Late result",), gates=(blocked,))
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
    hub = realtime_translation_override(stream, lambda: translator)
    marker = {"type": "test.marker"}

    with TestClient(app) as client:
        with client.websocket_connect(
            "/ws/sessions/demo-001/viewer"
        ) as viewer:
            with client.websocket_connect("/ws/stt") as producer:
                producer.send_json(
                    translation_start(session_id="demo-001")
                )
                receive_ready(producer)
                assert producer.receive_json()["type"] == "translation.configured"
                assert viewer.receive_json()["type"] == "translation.configured"
                producer.send_bytes(b"audio")
                assert producer.receive_json()["type"] == "transcript.final"
                assert producer.receive_json()["type"] == "translation.pending"
                assert viewer.receive_json()["type"] == "transcript.final"
                assert viewer.receive_json()["type"] == "translation.pending"

            client.portal.call(blocked.set)
            client.portal.call(hub.broadcast, "demo-001", marker)
            assert viewer.receive_json() == marker

    assert translator.cancelled_calls == 1
    assert translator.active_calls == 0
