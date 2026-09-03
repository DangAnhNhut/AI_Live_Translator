import asyncio

import pytest

from app.realtime.session_event_publisher import SessionEventPublisher
from app.realtime.session_hub import SessionHub


class RecordingSocket:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.sent_events: list[dict[str, object]] = []

    async def send_json(self, event: dict[str, object]) -> None:
        if self.fail:
            raise RuntimeError("socket send failed")
        self.sent_events.append(event)


class ConcurrencyDetectingSocket(RecordingSocket):
    def __init__(self) -> None:
        super().__init__()
        self.active_sends = 0
        self.maximum_active_sends = 0
        self.first_send_started = asyncio.Event()
        self.release_first_send = asyncio.Event()

    async def send_json(self, event: dict[str, object]) -> None:
        self.active_sends += 1
        self.maximum_active_sends = max(
            self.maximum_active_sends,
            self.active_sends,
        )
        try:
            if not self.sent_events:
                self.first_send_started.set()
                await self.release_first_send.wait()
            self.sent_events.append(event)
        finally:
            self.active_sends -= 1


def test_concurrent_publications_serialize_producer_sends():
    async def exercise():
        producer = ConcurrencyDetectingSocket()
        publisher = SessionEventPublisher(producer=producer)
        first = {"type": "translation.pending"}
        second = {"type": "translation.final"}

        first_task = asyncio.create_task(publisher.publish(first))
        await producer.first_send_started.wait()
        second_task = asyncio.create_task(publisher.publish(second))
        await asyncio.sleep(0)
        assert producer.maximum_active_sends == 1
        producer.release_first_send.set()
        await asyncio.gather(first_task, second_task)

        assert producer.maximum_active_sends == 1
        assert producer.sent_events == [first, second]

    asyncio.run(exercise())


def test_publication_broadcasts_same_event_to_session_viewers():
    async def exercise():
        hub = SessionHub()
        producer = RecordingSocket()
        viewer = RecordingSocket()
        event = {"type": "translation.final", "translated_text": "Hello."}
        await hub.join_viewer("session-1", viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish(event)

        assert producer.sent_events == [event]
        assert viewer.sent_events == [event]

    asyncio.run(exercise())


def test_failed_viewer_does_not_surface_as_publication_failure():
    async def exercise():
        hub = SessionHub()
        producer = RecordingSocket()
        failed_viewer = RecordingSocket(fail=True)
        healthy_viewer = RecordingSocket()
        event = {"type": "translation.error", "code": "provider_error"}
        await hub.join_viewer("session-1", failed_viewer)
        await hub.join_viewer("session-1", healthy_viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish(event)

        assert producer.sent_events == [event]
        assert healthy_viewer.sent_events == [event]
        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_producer_send_failure_is_surfaced():
    async def exercise():
        publisher = SessionEventPublisher(
            producer=RecordingSocket(fail=True)
        )

        with pytest.raises(RuntimeError, match="socket send failed"):
            await publisher.publish({"type": "translation.pending"})

    asyncio.run(exercise())


def test_hub_infrastructure_failure_is_surfaced():
    class FailingHub(SessionHub):
        async def broadcast(self, session_id, event):
            raise RuntimeError("hub unavailable")

    async def exercise():
        publisher = SessionEventPublisher(
            producer=RecordingSocket(),
            session_hub=FailingHub(),
            session_id="session-1",
        )

        with pytest.raises(RuntimeError, match="hub unavailable"):
            await publisher.publish({"type": "translation.pending"})

    asyncio.run(exercise())


def test_closed_publisher_drops_future_events_for_producer_and_viewers():
    async def exercise():
        hub = SessionHub()
        producer = RecordingSocket()
        viewer = RecordingSocket()
        await hub.join_viewer("session-1", viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )
        await publisher.close()

        await publisher.publish({"type": "translation.final"})

        assert producer.sent_events == []
        assert viewer.sent_events == []

    asyncio.run(exercise())


def test_close_is_prompt_and_stops_inflight_event_before_hub_broadcast():
    async def exercise():
        hub = SessionHub()
        producer = ConcurrencyDetectingSocket()
        viewer = RecordingSocket()
        event = {"type": "translation.pending"}
        await hub.join_viewer("session-1", viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )
        publish_task = asyncio.create_task(publisher.publish(event))
        await producer.first_send_started.wait()

        await asyncio.wait_for(publisher.close(), timeout=0.01)
        producer.release_first_send.set()
        await publish_task

        assert producer.sent_events == [event]
        assert viewer.sent_events == []

    asyncio.run(exercise())


def test_translation_config_is_atomically_sent_and_snapshotted():
    async def exercise():
        hub = SessionHub()
        producer_identity = object()
        producer = RecordingSocket()
        existing_viewer = RecordingSocket()
        late_viewer = RecordingSocket()
        configured = {
            "type": "translation.configured",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", producer_identity)
        await hub.join_viewer("session-1", existing_viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish_translation_config(
            configured,
            producer_identity=producer_identity,
        )
        await hub.join_viewer("session-1", late_viewer)

        assert producer.sent_events == [configured]
        assert existing_viewer.sent_events == [configured]
        assert late_viewer.sent_events == [configured]

    asyncio.run(exercise())
