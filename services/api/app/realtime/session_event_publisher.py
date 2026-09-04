import asyncio

from app.realtime.session_hub import JsonWebSocket, SessionHub


class SessionEventPublisher:
    """Serializes producer sends and mirrors events to session viewers."""

    def __init__(
        self,
        *,
        producer: JsonWebSocket,
        session_hub: SessionHub | None = None,
        session_id: str | None = None,
    ) -> None:
        self._producer = producer
        self._session_hub = session_hub
        self._session_id = session_id
        self._send_lock = asyncio.Lock()
        self._active = True
        self._producer_delivery_failed = False
        self._producer_delivery_failure_event = asyncio.Event()

    @property
    def producer_delivery_failed(self) -> bool:
        return self._producer_delivery_failed

    async def wait_for_producer_delivery_failure(self) -> None:
        await self._producer_delivery_failure_event.wait()

    def _mark_producer_delivery_failed(self) -> None:
        self._producer_delivery_failed = True
        self._producer_delivery_failure_event.set()
        self._active = False

    async def publish(self, event: dict[str, object]) -> None:
        async with self._send_lock:
            if not self._active:
                return
            try:
                await self._producer.send_json(event)
            except BaseException:
                self._mark_producer_delivery_failed()
                raise
            if not self._active:
                return
            if self._session_hub is not None and self._session_id is not None:
                await self._session_hub.broadcast(self._session_id, event)

    async def publish_translation_config(
        self,
        event: dict[str, object],
        *,
        producer_identity: object,
    ) -> None:
        async with self._send_lock:
            if not self._active:
                return
            try:
                await self._producer.send_json(event)
            except BaseException:
                self._mark_producer_delivery_failed()
                raise
            if not self._active:
                return
            if self._session_hub is None or self._session_id is None:
                return
            stored = await self._session_hub.publish_translation_config(
                self._session_id,
                producer_identity,
                event,
            )
            if not stored:
                raise RuntimeError(
                    "Translation configuration producer is not active"
                )

    async def publish_tts_config(
        self,
        event: dict[str, object],
        *,
        producer_identity: object,
    ) -> None:
        async with self._send_lock:
            if not self._active:
                return
            try:
                await self._producer.send_json(event)
            except BaseException:
                self._mark_producer_delivery_failed()
                raise
            if not self._active:
                return
            if self._session_hub is None or self._session_id is None:
                return
            stored = await self._session_hub.publish_tts_config(
                self._session_id,
                producer_identity,
                event,
            )
            if not stored:
                raise RuntimeError("TTS configuration producer is not active")

    async def publish_audio_pair(
        self,
        metadata: dict[str, object],
        audio_bytes: bytes,
    ) -> None:
        async with self._send_lock:
            if not self._active:
                return
            snapshot = None
            if self._session_hub is not None and self._session_id is not None:
                snapshot = await self._session_hub.snapshot_viewers(
                    self._session_id
                )
            try:
                await self._producer.send_json(metadata)
                await self._producer.send_bytes(audio_bytes)
            except BaseException:
                self._mark_producer_delivery_failed()
                raise
            if snapshot is not None:
                await self._session_hub.deliver_audio_pair(
                    snapshot,
                    metadata,
                    audio_bytes,
                )

    async def close(self) -> None:
        self._active = False
