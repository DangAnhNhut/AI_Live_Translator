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

    async def publish(self, event: dict[str, object]) -> None:
        async with self._send_lock:
            if not self._active:
                return
            await self._producer.send_json(event)
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
            await self._producer.send_json(event)
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

    async def close(self) -> None:
        self._active = False
