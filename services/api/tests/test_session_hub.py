import asyncio

from app.realtime.session_hub import SessionHub


class FakeWebSocket:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.sent_events: list[dict[str, object]] = []

    async def send_json(self, event: dict[str, object]) -> None:
        if self.fail:
            raise RuntimeError("viewer disconnected")
        self.sent_events.append(event)


class BlockingWebSocket(FakeWebSocket):
    def __init__(self) -> None:
        super().__init__()
        self.send_started = asyncio.Event()
        self.release_send = asyncio.Event()

    async def send_json(self, event: dict[str, object]) -> None:
        self.send_started.set()
        await self.release_send.wait()
        await super().send_json(event)


def test_get_session_hub_returns_shared_instance():
    from app.realtime.session_hub import get_session_hub

    assert get_session_hub() is get_session_hub()


def test_join_viewer_adds_viewer_to_session():
    async def exercise():
        hub = SessionHub()
        viewer = FakeWebSocket()

        await hub.join_viewer("session-1", viewer)

        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_duplicate_join_does_not_duplicate_viewer():
    async def exercise():
        hub = SessionHub()
        viewer = FakeWebSocket()
        event = {"type": "transcript.final", "text": "Xin chào."}

        await hub.join_viewer("session-1", viewer)
        await hub.join_viewer("session-1", viewer)
        await hub.broadcast("session-1", event)

        assert hub.viewer_count("session-1") == 1
        assert viewer.sent_events == [event]

    asyncio.run(exercise())


def test_leave_viewer_removes_viewer_from_session():
    async def exercise():
        hub = SessionHub()
        first = FakeWebSocket()
        second = FakeWebSocket()
        await hub.join_viewer("session-1", first)
        await hub.join_viewer("session-1", second)

        await hub.leave_viewer("session-1", first)

        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_leave_unknown_viewer_and_session_is_safe():
    async def exercise():
        hub = SessionHub()
        known_viewer = FakeWebSocket()
        await hub.join_viewer("session-1", known_viewer)

        await hub.leave_viewer("session-1", FakeWebSocket())
        await hub.leave_viewer("missing-session", FakeWebSocket())

        assert hub.viewer_count("session-1") == 1
        assert hub.viewer_count("missing-session") == 0

    asyncio.run(exercise())


def test_leaving_last_viewer_cleans_up_empty_session():
    async def exercise():
        hub = SessionHub()
        viewer = FakeWebSocket()
        await hub.join_viewer("session-1", viewer)

        await hub.leave_viewer("session-1", viewer)

        assert hub.viewer_count("session-1") == 0
        assert "session-1" not in hub._viewers

    asyncio.run(exercise())


def test_broadcast_sends_event_to_one_viewer():
    async def exercise():
        hub = SessionHub()
        viewer = FakeWebSocket()
        event = {"type": "transcript.final", "text": "Xin chào."}
        await hub.join_viewer("session-1", viewer)

        await hub.broadcast("session-1", event)

        assert viewer.sent_events == [event]

    asyncio.run(exercise())


def test_broadcast_sends_same_event_to_multiple_viewers():
    async def exercise():
        hub = SessionHub()
        first = FakeWebSocket()
        second = FakeWebSocket()
        event = {"type": "transcript.final", "text": "Xin chào."}
        await hub.join_viewer("session-1", first)
        await hub.join_viewer("session-1", second)

        await hub.broadcast("session-1", event)

        assert first.sent_events == [event]
        assert second.sent_events == [event]

    asyncio.run(exercise())


def test_broadcast_to_unknown_session_is_safe_no_op():
    async def exercise():
        hub = SessionHub()

        await hub.broadcast("missing-session", {"type": "session.update"})

        assert hub.viewer_count("missing-session") == 0

    asyncio.run(exercise())


def test_broadcast_removes_failed_viewer():
    async def exercise():
        hub = SessionHub()
        failed_viewer = FakeWebSocket(fail=True)
        await hub.join_viewer("session-1", failed_viewer)

        await hub.broadcast("session-1", {"type": "session.update"})

        assert hub.viewer_count("session-1") == 0
        assert "session-1" not in hub._viewers

    asyncio.run(exercise())


def test_failed_viewer_does_not_prevent_healthy_viewer_broadcast():
    async def exercise():
        hub = SessionHub()
        failed_viewer = FakeWebSocket(fail=True)
        healthy_viewer = FakeWebSocket()
        event = {"type": "transcript.final", "text": "Xin chào."}
        await hub.join_viewer("session-1", failed_viewer)
        await hub.join_viewer("session-1", healthy_viewer)

        await hub.broadcast("session-1", event)

        assert healthy_viewer.sent_events == [event]
        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_broadcast_does_not_hold_membership_lock_during_send():
    async def exercise():
        hub = SessionHub()
        blocking_viewer = BlockingWebSocket()
        joining_viewer = FakeWebSocket()
        await hub.join_viewer("session-1", blocking_viewer)

        broadcast_task = asyncio.create_task(
            hub.broadcast("session-1", {"type": "session.update"})
        )
        await asyncio.wait_for(blocking_viewer.send_started.wait(), timeout=0.5)

        await asyncio.wait_for(
            hub.join_viewer("session-1", joining_viewer),
            timeout=0.5,
        )
        assert hub.viewer_count("session-1") == 2

        blocking_viewer.release_send.set()
        await broadcast_task

    asyncio.run(exercise())


def test_first_producer_claim_succeeds_and_second_same_session_fails():
    async def exercise():
        hub = SessionHub()
        first = object()
        second = object()

        assert await hub.claim_producer("session-1", first) is True
        assert await hub.claim_producer("session-1", second) is False

    asyncio.run(exercise())


def test_producer_claims_for_different_sessions_are_independent():
    async def exercise():
        hub = SessionHub()
        first = object()
        second = object()

        assert await hub.claim_producer("session-1", first) is True
        assert await hub.claim_producer("session-2", second) is True

    asyncio.run(exercise())


def test_only_current_producer_can_release_session_ownership():
    async def exercise():
        hub = SessionHub()
        owner = object()
        wrong_owner = object()
        replacement = object()
        await hub.claim_producer("session-1", owner)

        assert await hub.release_producer("session-1", wrong_owner) is False
        assert await hub.claim_producer("session-1", replacement) is False
        assert await hub.release_producer("session-1", owner) is True
        assert await hub.claim_producer("session-1", replacement) is True

    asyncio.run(exercise())


def test_late_viewer_receives_only_active_translation_configuration():
    async def exercise():
        hub = SessionHub()
        producer = object()
        earlier_viewer = FakeWebSocket()
        late_viewer = FakeWebSocket()
        transcript = {"type": "transcript.final", "text": "Xin chao."}
        configured = {
            "type": "translation.configured",
            "stream_id": "stream_123",
            "source_language": "vi",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", producer)
        await hub.join_viewer("session-1", earlier_viewer)
        await hub.broadcast("session-1", transcript)
        assert await hub.set_translation_config(
            "session-1", producer, configured
        ) is True

        await hub.join_viewer("session-1", late_viewer)

        assert earlier_viewer.sent_events == [transcript]
        assert late_viewer.sent_events == [configured]

    asyncio.run(exercise())


def test_wrong_producer_cannot_replace_translation_configuration():
    async def exercise():
        hub = SessionHub()
        owner = object()
        wrong_owner = object()
        viewer = FakeWebSocket()
        configured = {
            "type": "translation.configured",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", owner)

        stored = await hub.set_translation_config(
            "session-1", wrong_owner, configured
        )
        await hub.join_viewer("session-1", viewer)

        assert stored is False
        assert viewer.sent_events == []

    asyncio.run(exercise())


def test_releasing_producer_clears_translation_configuration_snapshot():
    async def exercise():
        hub = SessionHub()
        translated_owner = object()
        stt_only_owner = object()
        late_viewer = FakeWebSocket()
        configured = {
            "type": "translation.configured",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", translated_owner)
        await hub.set_translation_config(
            "session-1", translated_owner, configured
        )

        assert await hub.release_producer(
            "session-1", translated_owner
        ) is True
        assert await hub.claim_producer("session-1", stt_only_owner) is True
        await hub.join_viewer("session-1", late_viewer)

        assert late_viewer.sent_events == []

    asyncio.run(exercise())


def test_failed_viewer_does_not_break_translation_delivery_to_healthy_viewer():
    async def exercise():
        hub = SessionHub()
        failed_viewer = FakeWebSocket(fail=True)
        healthy_viewer = FakeWebSocket()
        event = {
            "type": "translation.final",
            "translated_text": "Hello.",
        }
        await hub.join_viewer("session-1", failed_viewer)
        await hub.join_viewer("session-1", healthy_viewer)

        await hub.broadcast("session-1", event)

        assert healthy_viewer.sent_events == [event]
        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_stalled_viewer_is_timed_out_without_blocking_healthy_delivery():
    async def exercise():
        hub = SessionHub(viewer_send_timeout_seconds=0.01)
        stalled = BlockingWebSocket()
        healthy = FakeWebSocket()
        event = {"type": "translation.final", "translated_text": "Hello."}
        await hub.join_viewer("session-1", stalled)
        await hub.join_viewer("session-1", healthy)

        await asyncio.wait_for(
            hub.broadcast("session-1", event),
            timeout=0.1,
        )

        assert healthy.sent_events == [event]
        assert hub.viewer_count("session-1") == 1

    asyncio.run(exercise())


def test_atomic_config_publication_reaches_existing_and_late_viewer_once():
    async def exercise():
        hub = SessionHub()
        producer = object()
        existing = FakeWebSocket()
        late = FakeWebSocket()
        configured = {
            "type": "translation.configured",
            "stream_id": "stream_123",
            "source_language": "vi",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", producer)
        await hub.join_viewer("session-1", existing)

        published = await hub.publish_translation_config(
            "session-1",
            producer,
            configured,
        )
        await hub.join_viewer("session-1", late)

        assert published is True
        assert existing.sent_events == [configured]
        assert late.sent_events == [configured]

    asyncio.run(exercise())


def test_producer_release_waits_for_started_snapshot_delivery():
    async def exercise():
        hub = SessionHub()
        producer = object()
        viewer = BlockingWebSocket()
        configured = {
            "type": "translation.configured",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", producer)
        await hub.set_translation_config(
            "session-1",
            producer,
            configured,
        )
        join_task = asyncio.create_task(
            hub.join_viewer("session-1", viewer)
        )
        await viewer.send_started.wait()

        release_task = asyncio.create_task(
            hub.release_producer("session-1", producer)
        )
        await asyncio.sleep(0)
        release_waited = not release_task.done()
        viewer.release_send.set()
        await join_task
        released = await release_task

        assert release_waited is True
        assert released is True

    asyncio.run(exercise())


def test_cancelled_snapshot_delivery_does_not_leave_viewer_registered():
    async def exercise():
        hub = SessionHub()
        producer = object()
        viewer = BlockingWebSocket()
        configured = {
            "type": "translation.configured",
            "target_language": "en",
        }
        await hub.claim_producer("session-1", producer)
        await hub.set_translation_config(
            "session-1",
            producer,
            configured,
        )
        join_task = asyncio.create_task(
            hub.join_viewer("session-1", viewer)
        )
        await viewer.send_started.wait()

        join_task.cancel()
        try:
            await join_task
        except asyncio.CancelledError:
            pass

        assert hub.viewer_count("session-1") == 0

    asyncio.run(exercise())


def test_completed_unique_session_operations_release_lock_registry_entries():
    async def exercise():
        hub = SessionHub()

        for index in range(100):
            await hub.broadcast(
                f"unknown-{index}",
                {"type": "test.marker"},
            )

        assert hub._session_locks == {}

    asyncio.run(exercise())
