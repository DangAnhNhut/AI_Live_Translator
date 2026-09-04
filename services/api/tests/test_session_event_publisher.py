import asyncio

import pytest

from app.realtime.session_event_publisher import SessionEventPublisher
from app.realtime.session_hub import SessionHub


class RecordingSocket:
    def __init__(
        self,
        *,
        fail: bool = False,
        fail_bytes: bool = False,
    ) -> None:
        self.fail = fail
        self.fail_bytes = fail_bytes
        self.sent_events: list[dict[str, object]] = []
        self.sent_bytes: list[bytes] = []
        self.sent_frames: list[dict[str, object] | bytes] = []

    async def send_json(self, event: dict[str, object]) -> None:
        if self.fail:
            raise RuntimeError("socket send failed")
        self.sent_events.append(event)
        self.sent_frames.append(event)

    async def send_bytes(self, data: bytes) -> None:
        if self.fail_bytes:
            raise RuntimeError("socket byte send failed")
        self.sent_bytes.append(data)
        self.sent_frames.append(data)


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
            self.sent_frames.append(event)
        finally:
            self.active_sends -= 1


class AudioPairConcurrencySocket(RecordingSocket):
    def __init__(self) -> None:
        super().__init__()
        self.active_sends = 0
        self.maximum_active_sends = 0
        self.bytes_send_started = asyncio.Event()
        self.release_bytes_send = asyncio.Event()

    async def send_json(self, event: dict[str, object]) -> None:
        self.active_sends += 1
        self.maximum_active_sends = max(
            self.maximum_active_sends,
            self.active_sends,
        )
        try:
            await super().send_json(event)
        finally:
            self.active_sends -= 1

    async def send_bytes(self, data: bytes) -> None:
        self.active_sends += 1
        self.maximum_active_sends = max(
            self.maximum_active_sends,
            self.active_sends,
        )
        try:
            self.bytes_send_started.set()
            await self.release_bytes_send.wait()
            await super().send_bytes(data)
        finally:
            self.active_sends -= 1


class MetadataBlockingSocket(RecordingSocket):
    def __init__(self) -> None:
        super().__init__()
        self.metadata_send_started = asyncio.Event()
        self.release_metadata_send = asyncio.Event()

    async def send_json(self, event: dict[str, object]) -> None:
        self.metadata_send_started.set()
        await self.release_metadata_send.wait()
        await super().send_json(event)


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


def test_audio_pair_sends_metadata_then_binary_to_producer_and_viewer():
    async def exercise():
        hub = SessionHub()
        producer = RecordingSocket()
        viewer = RecordingSocket()
        metadata = {"type": "tts.audio", "voice": "alloy"}
        audio_bytes = b"audio-frame"
        await hub.join_viewer("session-1", viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish_audio_pair(metadata, audio_bytes)

        assert producer.sent_frames == [metadata, audio_bytes]
        assert viewer.sent_frames == [metadata, audio_bytes]

    asyncio.run(exercise())


def test_concurrent_json_waits_until_audio_pair_binary_completes():
    async def exercise():
        producer = AudioPairConcurrencySocket()
        publisher = SessionEventPublisher(producer=producer)
        metadata = {"type": "tts.audio", "sequence": 1}
        audio_bytes = b"audio-frame"
        marker = {"type": "translation.pending"}

        pair_task = asyncio.create_task(
            publisher.publish_audio_pair(metadata, audio_bytes)
        )
        await producer.bytes_send_started.wait()
        marker_task = asyncio.create_task(publisher.publish(marker))
        await asyncio.sleep(0)

        assert not marker_task.done()
        assert producer.maximum_active_sends == 1
        producer.release_bytes_send.set()
        await asyncio.gather(pair_task, marker_task)

        assert producer.sent_frames == [metadata, audio_bytes, marker]
        assert producer.maximum_active_sends == 1

    asyncio.run(exercise())


def test_two_audio_pairs_cannot_cross():
    async def exercise():
        producer = RecordingSocket()
        publisher = SessionEventPublisher(producer=producer)
        first_metadata = {"type": "tts.audio", "sequence": 1}
        first_audio = b"one"
        second_metadata = {"type": "tts.audio", "sequence": 2}
        second_audio = b"two"

        first = asyncio.create_task(
            publisher.publish_audio_pair(first_metadata, first_audio)
        )
        second = asyncio.create_task(
            publisher.publish_audio_pair(second_metadata, second_audio)
        )
        await asyncio.gather(first, second)

        assert producer.sent_frames == [
            first_metadata,
            first_audio,
            second_metadata,
            second_audio,
        ]

    asyncio.run(exercise())


def test_audio_pair_captures_viewers_before_producer_send():
    async def exercise():
        hub = SessionHub()
        producer = MetadataBlockingSocket()
        existing_viewer = RecordingSocket()
        late_viewer = RecordingSocket()
        metadata = {"type": "tts.audio", "sequence": 1}
        audio_bytes = b"audio-frame"
        await hub.join_viewer("session-1", existing_viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        pair_task = asyncio.create_task(
            publisher.publish_audio_pair(metadata, audio_bytes)
        )
        await producer.metadata_send_started.wait()
        await hub.join_viewer("session-1", late_viewer)
        producer.release_metadata_send.set()
        await pair_task

        assert existing_viewer.sent_frames == [metadata, audio_bytes]
        assert late_viewer.sent_frames == []

    asyncio.run(exercise())


def test_failed_producer_binary_send_is_surfaced_and_deactivates_publisher():
    async def exercise():
        producer = RecordingSocket(fail_bytes=True)
        publisher = SessionEventPublisher(producer=producer)
        metadata = {"type": "tts.audio", "sequence": 1}

        with pytest.raises(RuntimeError, match="socket byte send failed"):
            await publisher.publish_audio_pair(metadata, b"audio-frame")

        assert publisher.producer_delivery_failed is True
        await publisher.publish({"type": "translation.pending"})
        assert producer.sent_frames == [metadata]

    asyncio.run(exercise())


def test_failed_producer_send_wakes_failure_waiter_once():
    async def exercise():
        producer = RecordingSocket(fail=True)
        publisher = SessionEventPublisher(producer=producer)
        waiter = asyncio.create_task(
            publisher.wait_for_producer_delivery_failure()
        )
        await asyncio.sleep(0)

        with pytest.raises(RuntimeError, match="socket send failed"):
            await publisher.publish({"type": "translation.pending"})
        await asyncio.wait_for(waiter, timeout=0.1)
        await publisher.close()
        await publisher.close()
        await asyncio.wait_for(
            publisher.wait_for_producer_delivery_failure(),
            timeout=0.1,
        )

        assert publisher.producer_delivery_failed is True
        await publisher.publish({"type": "translation.final"})
        assert producer.sent_frames == []

    asyncio.run(exercise())


def test_failed_viewer_pair_does_not_fail_producer_or_healthy_viewer():
    async def exercise():
        hub = SessionHub()
        producer = RecordingSocket()
        failed_viewer = RecordingSocket(fail_bytes=True)
        healthy_viewer = RecordingSocket()
        metadata = {"type": "tts.audio", "sequence": 1}
        audio_bytes = b"audio-frame"
        await hub.join_viewer("session-1", failed_viewer)
        await hub.join_viewer("session-1", healthy_viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish_audio_pair(metadata, audio_bytes)

        assert publisher.producer_delivery_failed is False
        assert healthy_viewer.sent_frames == [metadata, audio_bytes]
        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_tts_config_is_atomically_sent_and_snapshotted():
    async def exercise():
        hub = SessionHub()
        producer_identity = object()
        producer = RecordingSocket()
        existing_viewer = RecordingSocket()
        late_viewer = RecordingSocket()
        configured = {
            "type": "tts.configured",
            "voice": "alloy",
        }
        await hub.claim_producer("session-1", producer_identity)
        await hub.join_viewer("session-1", existing_viewer)
        publisher = SessionEventPublisher(
            producer=producer,
            session_hub=hub,
            session_id="session-1",
        )

        await publisher.publish_tts_config(
            configured,
            producer_identity=producer_identity,
        )
        await hub.join_viewer("session-1", late_viewer)

        assert producer.sent_events == [configured]
        assert existing_viewer.sent_events == [configured]
        assert late_viewer.sent_events == [configured]

    asyncio.run(exercise())
