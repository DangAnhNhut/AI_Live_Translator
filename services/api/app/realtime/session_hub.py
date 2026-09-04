import asyncio
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from dataclasses import dataclass
from typing import Protocol


class JsonWebSocket(Protocol):
    async def send_json(self, event: dict[str, object]) -> None:
        ...

    async def send_bytes(self, data: bytes) -> None:
        ...


@dataclass(frozen=True, slots=True)
class ViewerDeliverySnapshot:
    session_id: str
    _targets: tuple[tuple[JsonWebSocket, asyncio.Lock], ...]


@dataclass(slots=True)
class _SessionLockEntry:
    lock: asyncio.Lock
    references: int = 0


class SessionHub:
    def __init__(
        self,
        *,
        viewer_send_timeout_seconds: float = 1.0,
    ) -> None:
        if viewer_send_timeout_seconds <= 0:
            raise ValueError("viewer_send_timeout_seconds must be positive")
        self._viewers: dict[str, set[JsonWebSocket]] = {}
        self._viewer_send_locks: dict[JsonWebSocket, asyncio.Lock] = {}
        self._producers: dict[str, object] = {}
        self._translation_configs: dict[
            str, tuple[object, dict[str, object]]
        ] = {}
        self._tts_configs: dict[str, tuple[object, dict[str, object]]] = {}
        self._membership_lock = asyncio.Lock()
        self._session_locks: dict[str, _SessionLockEntry] = {}
        self._session_lock_registry = asyncio.Lock()
        self._viewer_send_timeout_seconds = viewer_send_timeout_seconds

    @asynccontextmanager
    async def _session_guard(
        self,
        session_id: str,
    ) -> AsyncIterator[None]:
        async with self._session_lock_registry:
            entry = self._session_locks.get(session_id)
            if entry is None:
                entry = _SessionLockEntry(asyncio.Lock())
                self._session_locks[session_id] = entry
            entry.references += 1
        try:
            async with entry.lock:
                yield
        finally:
            async with self._session_lock_registry:
                entry.references -= 1
                if (
                    entry.references == 0
                    and self._session_locks.get(session_id) is entry
                ):
                    self._session_locks.pop(session_id, None)

    async def claim_producer(
        self,
        session_id: str,
        producer_identity: object,
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if session_id in self._producers:
                    return False
                self._producers[session_id] = producer_identity
                return True

    async def release_producer(
        self,
        session_id: str,
        producer_identity: object,
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if self._producers.get(session_id) is not producer_identity:
                    return False
                self._producers.pop(session_id, None)
                self._translation_configs.pop(session_id, None)
                self._tts_configs.pop(session_id, None)
                return True

    async def set_translation_config(
        self,
        session_id: str,
        producer_identity: object,
        event: dict[str, object],
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if self._producers.get(session_id) is not producer_identity:
                    return False
                self._translation_configs[session_id] = (
                    producer_identity,
                    dict(event),
                )
                return True

    async def publish_translation_config(
        self,
        session_id: str,
        producer_identity: object,
        event: dict[str, object],
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if self._producers.get(session_id) is not producer_identity:
                    return False
                stored_event = dict(event)
                self._translation_configs[session_id] = (
                    producer_identity,
                    stored_event,
                )
                viewers = self._viewer_targets(session_id)
            await self._send_to_viewers(
                session_id,
                viewers,
                stored_event,
            )
            return True

    async def set_tts_config(
        self,
        session_id: str,
        producer_identity: object,
        event: dict[str, object],
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if self._producers.get(session_id) is not producer_identity:
                    return False
                self._tts_configs[session_id] = (
                    producer_identity,
                    dict(event),
                )
                return True

    async def publish_tts_config(
        self,
        session_id: str,
        producer_identity: object,
        event: dict[str, object],
    ) -> bool:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                if self._producers.get(session_id) is not producer_identity:
                    return False
                stored_event = dict(event)
                self._tts_configs[session_id] = (
                    producer_identity,
                    stored_event,
                )
                viewers = self._viewer_targets(session_id)
            await self._send_to_viewers(
                session_id,
                viewers,
                stored_event,
            )
            return True

    async def join_viewer(
        self,
        session_id: str,
        websocket: JsonWebSocket,
    ) -> None:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                self._viewers.setdefault(session_id, set()).add(websocket)
                send_lock = self._viewer_send_locks.setdefault(
                    websocket,
                    asyncio.Lock(),
                )
                configs = tuple(
                    config[1]
                    for config in (
                        self._translation_configs.get(session_id),
                        self._tts_configs.get(session_id),
                    )
                    if config is not None
                )

            if not configs:
                return
            try:
                await self._send_events_to_viewers(
                    session_id,
                    ((websocket, send_lock),),
                    configs,
                )
            except asyncio.CancelledError:
                await asyncio.shield(
                    self._remove_viewer(session_id, websocket)
                )
                raise

    async def leave_viewer(
        self,
        session_id: str,
        websocket: JsonWebSocket,
    ) -> None:
        async with self._session_guard(session_id):
            await self._remove_viewer(session_id, websocket)

    async def _remove_viewer(
        self,
        session_id: str,
        websocket: JsonWebSocket,
    ) -> None:
        async with self._membership_lock:
            viewers = self._viewers.get(session_id)
            if viewers is None:
                return

            viewers.discard(websocket)
            self._viewer_send_locks.pop(websocket, None)
            if not viewers:
                self._viewers.pop(session_id, None)

    async def _remove_viewers(
        self,
        session_id: str,
        viewers_to_remove: set[JsonWebSocket],
    ) -> None:
        async with self._membership_lock:
            active_viewers = self._viewers.get(session_id)
            if active_viewers is None:
                return

            active_viewers.difference_update(viewers_to_remove)
            for viewer in viewers_to_remove:
                self._viewer_send_locks.pop(viewer, None)
            if not active_viewers:
                self._viewers.pop(session_id, None)

    async def _remove_viewers_shielded(
        self,
        session_id: str,
        viewers_to_remove: set[JsonWebSocket],
    ) -> None:
        cleanup_task = asyncio.create_task(
            self._remove_viewers(session_id, viewers_to_remove)
        )
        try:
            await asyncio.shield(cleanup_task)
        except asyncio.CancelledError:
            await asyncio.shield(cleanup_task)
            raise

    async def broadcast(
        self,
        session_id: str,
        event: dict[str, object],
    ) -> None:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                viewers = self._viewer_targets(session_id)

        await self._send_to_viewers(session_id, viewers, event)

    async def snapshot_viewers(
        self,
        session_id: str,
    ) -> ViewerDeliverySnapshot:
        async with self._session_guard(session_id):
            async with self._membership_lock:
                return ViewerDeliverySnapshot(
                    session_id,
                    self._viewer_targets(session_id),
                )

    async def deliver_audio_pair(
        self,
        snapshot: ViewerDeliverySnapshot,
        metadata: dict[str, object],
        audio_bytes: bytes,
    ) -> None:
        async def send_pair(
            viewer: JsonWebSocket,
            send_lock: asyncio.Lock,
        ) -> None:
            async with send_lock:
                await viewer.send_json(metadata)
                await viewer.send_bytes(audio_bytes)

        tasks = tuple(
            asyncio.create_task(
                asyncio.wait_for(
                    send_pair(viewer, send_lock),
                    timeout=self._viewer_send_timeout_seconds,
                )
            )
            for viewer, send_lock in snapshot._targets
        )
        try:
            results = await asyncio.shield(
                asyncio.gather(*tasks, return_exceptions=True)
            )
            failed_viewers = {
                viewer
                for (viewer, _), result in zip(snapshot._targets, results)
                if isinstance(result, BaseException)
            }
            if failed_viewers:
                await self._remove_viewers_shielded(
                    snapshot.session_id,
                    failed_viewers,
                )
        except asyncio.CancelledError:
            unfinished_viewers = {
                viewer
                for (viewer, _), task in zip(snapshot._targets, tasks)
                if not task.done()
            }
            for task in tasks:
                task.cancel()
            results = await asyncio.gather(*tasks, return_exceptions=True)
            failed_viewers = {
                viewer
                for (viewer, _), result in zip(snapshot._targets, results)
                if isinstance(result, BaseException)
            }
            viewers_to_remove = unfinished_viewers | failed_viewers
            if viewers_to_remove:
                await self._remove_viewers_shielded(
                    snapshot.session_id,
                    viewers_to_remove,
                )
            raise

    def _viewer_targets(
        self,
        session_id: str,
    ) -> tuple[tuple[JsonWebSocket, asyncio.Lock], ...]:
        return tuple(
            (viewer, self._viewer_send_locks[viewer])
            for viewer in self._viewers.get(session_id, ())
        )

    async def _send_to_viewers(
        self,
        session_id: str,
        viewers: tuple[tuple[JsonWebSocket, asyncio.Lock], ...],
        event: dict[str, object],
    ) -> None:
        await self._send_events_to_viewers(session_id, viewers, (event,))

    async def _send_events_to_viewers(
        self,
        session_id: str,
        viewers: tuple[tuple[JsonWebSocket, asyncio.Lock], ...],
        events: tuple[dict[str, object], ...],
    ) -> None:
        async def send(
            viewer: JsonWebSocket,
            send_lock: asyncio.Lock,
        ) -> None:
            async with send_lock:
                for event in events:
                    await viewer.send_json(event)

        if not viewers:
            return

        results = await asyncio.gather(
            *(
                asyncio.wait_for(
                    send(viewer, send_lock),
                    timeout=self._viewer_send_timeout_seconds,
                )
                for viewer, send_lock in viewers
            ),
            return_exceptions=True,
        )
        failed_viewers = {
            viewer
            for (viewer, _), result in zip(viewers, results)
            if isinstance(result, BaseException)
        }
        if not failed_viewers:
            return

        await self._remove_viewers(session_id, failed_viewers)

    def viewer_count(self, session_id: str) -> int:
        return len(self._viewers.get(session_id, ()))


_session_hub = SessionHub()


def get_session_hub() -> SessionHub:
    return _session_hub
