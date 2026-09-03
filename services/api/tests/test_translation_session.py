import asyncio
from collections.abc import Callable
from dataclasses import dataclass

from app.ai.stt import SttTranscript
from app.ai.translation import TranslationProviderError
from app.realtime.translation_session import TranslationSession
from tests.fakes.translation import FakeTranslator

import pytest


def final(
    segment_id: str,
    text: str,
    *,
    utterance_boundary: bool = False,
) -> SttTranscript:
    return SttTranscript(
        "final",
        segment_id,
        text,
        utterance_boundary=utterance_boundary,
    )


async def wait_until(
    predicate: Callable[[], bool],
    *,
    turns: int = 1000,
) -> None:
    for _ in range(turns):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition was not reached")


@dataclass(slots=True)
class SleepRequest:
    delay_seconds: float
    future: asyncio.Future[None]


class ControlledSleeper:
    def __init__(self) -> None:
        self.requests: list[SleepRequest] = []

    async def __call__(self, delay_seconds: float) -> None:
        future = asyncio.get_running_loop().create_future()
        self.requests.append(SleepRequest(delay_seconds, future))
        await future

    def fire(self, index: int) -> None:
        request = self.requests[index]
        if not request.future.done():
            request.future.set_result(None)


class CancellationResistantSleeper:
    def __init__(self) -> None:
        self.started = asyncio.Event()
        self.release = asyncio.Event()

    async def __call__(self, delay_seconds: float) -> None:
        del delay_seconds
        self.started.set()
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            await self.release.wait()
            raise


def make_session(
    *,
    translator: FakeTranslator,
    events: list[dict[str, object]],
    queue_max_size: int = 8,
    request_timeout_seconds: float = 1.0,
    sleep: Callable[[float], object] = asyncio.sleep,
):
    async def publish(event: dict[str, object]) -> None:
        events.append(event)

    return TranslationSession(
        translator=translator,
        stream_id="stream_123",
        source_language="vi",
        target_language="en",
        publish_event=publish,
        queue_max_size=queue_max_size,
        request_timeout_seconds=request_timeout_seconds,
        sleep=sleep,
    )


def test_interim_and_repeated_final_do_not_create_duplicate_provider_cost():
    async def exercise():
        events: list[dict[str, object]] = []
        translator = FakeTranslator(outcomes=("Hello.",))
        session = make_session(translator=translator, events=events)
        await session.start()

        await session.accept_transcript(
            SttTranscript("interim", "seg_001", "Xin chao")
        )
        await session.accept_transcript(final("seg_001", "Xin chao"))
        await session.accept_transcript(
            final(
                "seg_001",
                "duplicate must not be used",
                utterance_boundary=True,
            )
        )
        drained = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return drained, events, translator.calls

    drained, events, calls = asyncio.run(exercise())

    assert drained is True
    assert [event["type"] for event in events] == [
        "translation.pending",
        "translation.final",
    ]
    assert len(calls) == 1
    assert calls[0].text == "Xin chao"


def test_committed_utterance_emits_pending_then_final_with_source_mapping():
    async def exercise():
        events: list[dict[str, object]] = []
        translator = FakeTranslator(outcomes=("Hello everyone.",))
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(final("seg_001", "  Xin   chao  "))
        await session.accept_transcript(
            final("seg_002", "moi nguoi.", utterance_boundary=True)
        )
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return events, translator.calls

    events, calls = asyncio.run(exercise())

    assert [event["type"] for event in events] == [
        "translation.pending",
        "translation.final",
    ]
    assert events[0] == {
        "type": "translation.pending",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "source_segment_ids": ["seg_001", "seg_002"],
        "source_text": "Xin chao moi nguoi.",
        "source_language": "vi",
        "target_language": "en",
    }
    assert events[1]["translated_text"] == "Hello everyone."
    assert calls[0].text == "Xin chao moi nguoi."


def test_two_utterances_translate_sequentially_and_preserve_event_order():
    async def exercise():
        events: list[dict[str, object]] = []
        first_gate = asyncio.Event()
        translator = FakeTranslator(
            outcomes=("One", "Two"),
            gates=(first_gate, None),
        )
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await session.accept_transcript(
            final("seg_002", "Hai", utterance_boundary=True)
        )
        await wait_until(lambda: len(translator.calls) == 1)
        assert translator.maximum_active_calls == 1
        first_gate.set()
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return events, translator

    events, translator = asyncio.run(exercise())

    assert [call.text for call in translator.calls] == ["Mot", "Hai"]
    assert translator.maximum_active_calls == 1
    assert [(event["type"], event["utterance_id"]) for event in events] == [
        ("translation.pending", "utt_000001"),
        ("translation.final", "utt_000001"),
        ("translation.pending", "utt_000002"),
        ("translation.final", "utt_000002"),
    ]


def test_provider_failure_emits_safe_error_and_worker_continues():
    async def exercise():
        events: list[dict[str, object]] = []
        translator = FakeTranslator(
            outcomes=(TranslationProviderError("secret provider detail"), "Two")
        )
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await session.accept_transcript(
            final("seg_002", "Hai", utterance_boundary=True)
        )
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return events, translator.calls

    events, calls = asyncio.run(exercise())

    assert len(calls) == 2
    error = next(event for event in events if event["type"] == "translation.error")
    assert error["code"] == "provider_error"
    assert error["utterance_id"] == "utt_000001"
    assert "secret" not in error["message"]
    assert events[-1]["type"] == "translation.final"
    assert events[-1]["utterance_id"] == "utt_000002"


def test_provider_timeout_cancels_request_and_worker_continues():
    async def exercise():
        events: list[dict[str, object]] = []
        blocked = asyncio.Event()
        translator = FakeTranslator(
            outcomes=("never", "Two"),
            gates=(blocked, None),
        )
        session = make_session(
            translator=translator,
            events=events,
            request_timeout_seconds=0.01,
        )
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await session.accept_transcript(
            final("seg_002", "Hai", utterance_boundary=True)
        )
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return events, translator

    events, translator = asyncio.run(exercise())

    assert translator.cancelled_calls == 1
    timeout = next(event for event in events if event["type"] == "translation.error")
    assert timeout["code"] == "request_timeout"
    assert timeout["utterance_id"] == "utt_000001"
    assert events[-1]["type"] == "translation.final"
    assert events[-1]["utterance_id"] == "utt_000002"


def test_queue_overflow_is_bounded_observable_and_non_blocking():
    async def exercise():
        events: list[dict[str, object]] = []
        first_gate = asyncio.Event()
        translator = FakeTranslator(
            outcomes=("One", "Two"),
            gates=(first_gate, None),
        )
        session = make_session(
            translator=translator,
            events=events,
            queue_max_size=1,
        )
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await wait_until(lambda: len(translator.calls) == 1)
        await session.accept_transcript(
            final("seg_002", "Hai", utterance_boundary=True)
        )
        await session.accept_transcript(
            final("seg_003", "Ba", utterance_boundary=True)
        )
        overflow_visible_before_release = any(
            event.get("code") == "queue_overflow" for event in events
        )
        first_gate.set()
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return overflow_visible_before_release, events, translator.calls

    overflow_visible, events, calls = asyncio.run(exercise())

    assert overflow_visible is True
    overflow = next(
        event for event in events if event.get("code") == "queue_overflow"
    )
    assert overflow["utterance_id"] == "utt_000003"
    assert overflow["source_segment_ids"] == ["seg_003"]
    assert [call.text for call in calls] == ["Mot", "Hai"]


def test_inactivity_flush_resets_timer_and_stale_timer_cannot_duplicate():
    async def exercise():
        events: list[dict[str, object]] = []
        sleeper = ControlledSleeper()
        translator = FakeTranslator(outcomes=("Combined",))
        session = make_session(
            translator=translator,
            events=events,
            sleep=sleeper,
        )
        await session.start()
        await session.accept_transcript(final("seg_001", "Xin chao"))
        await wait_until(lambda: len(sleeper.requests) == 1)
        await session.accept_transcript(final("seg_002", "moi nguoi"))
        await wait_until(lambda: len(sleeper.requests) == 2)
        first_cancelled = sleeper.requests[0].future.cancelled()
        sleeper.fire(0)
        await asyncio.sleep(0)
        sleeper.fire(1)
        await wait_until(lambda: len(translator.calls) == 1)
        await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return first_cancelled, sleeper.requests, events, translator.calls

    first_cancelled, requests, events, calls = asyncio.run(exercise())

    assert first_cancelled is True
    assert [request.delay_seconds for request in requests] == [1.0, 1.0]
    assert len(calls) == 1
    assert calls[0].text == "Xin chao moi nguoi"
    assert [event["type"] for event in events] == [
        "translation.pending",
        "translation.final",
    ]


def test_explicit_flush_and_drain_commits_buffered_remainder():
    async def exercise():
        events: list[dict[str, object]] = []
        translator = FakeTranslator(outcomes=("Hello",))
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(final("seg_001", "Xin chao"))
        drained = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return drained, events, translator.calls

    drained, events, calls = asyncio.run(exercise())

    assert drained is True
    assert len(calls) == 1
    assert calls[0].text == "Xin chao"
    assert events[-1]["type"] == "translation.final"


def test_bounded_drain_timeout_aborts_in_flight_translation():
    async def exercise():
        events: list[dict[str, object]] = []
        blocked = asyncio.Event()
        translator = FakeTranslator(gates=(blocked,))
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await wait_until(lambda: len(translator.calls) == 1)
        drained = await session.flush_and_drain(timeout_seconds=0.01)
        await session.close()
        return drained, translator

    drained, translator = asyncio.run(exercise())

    assert drained is False
    assert translator.cancelled_calls == 1
    assert translator.active_calls == 0


def test_drain_deadline_includes_inactivity_timer_cancellation():
    async def exercise():
        events: list[dict[str, object]] = []
        sleeper = CancellationResistantSleeper()
        translator = FakeTranslator()
        session = make_session(
            translator=translator,
            events=events,
            sleep=sleeper,
        )
        await session.start()
        await session.accept_transcript(final("seg_001", "Xin chao"))
        await sleeper.started.wait()

        drain_task = asyncio.create_task(
            session.flush_and_drain(timeout_seconds=0.005)
        )
        await asyncio.sleep(0.02)
        completed_within_bound = drain_task.done()
        sleeper.release.set()
        drained = await drain_task
        await session.close()
        return completed_within_bound, drained

    completed_within_bound, drained = asyncio.run(exercise())

    assert completed_within_bound is True
    assert drained is False


@pytest.mark.parametrize(
    ("failing_event_type", "provider_outcome"),
    (
        ("translation.pending", "Hello"),
        ("translation.final", "Hello"),
        (
            "translation.error",
            TranslationProviderError("raw provider detail"),
        ),
    ),
)
def test_publisher_failure_is_controlled_and_drain_reports_failure(
    failing_event_type,
    provider_outcome,
):
    async def exercise():
        translator = FakeTranslator(outcomes=(provider_outcome,))

        async def publish(event: dict[str, object]) -> None:
            if event["type"] == failing_event_type:
                raise RuntimeError("transport write failed")

        session_type = TranslationSession
        session = session_type(
            translator=translator,
            stream_id="stream_123",
            source_language="vi",
            target_language="en",
            publish_event=publish,
            request_timeout_seconds=1.0,
        )
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Xin chao", utterance_boundary=True)
        )
        drained = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return drained

    assert asyncio.run(exercise()) is False


def test_abort_cancels_in_flight_and_close_is_idempotent():
    async def exercise():
        events: list[dict[str, object]] = []
        blocked = asyncio.Event()
        translator = FakeTranslator(gates=(blocked,))
        session = make_session(translator=translator, events=events)
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Mot", utterance_boundary=True)
        )
        await wait_until(lambda: len(translator.calls) == 1)
        await session.abort()
        await session.abort()
        await session.close()
        await session.close()
        return translator

    translator = asyncio.run(exercise())

    assert translator.cancelled_calls == 1
    assert translator.active_calls == 0


def test_abort_is_prompt_and_prevents_late_work_when_publisher_resists_cancel():
    async def exercise():
        translator = FakeTranslator()
        publisher_started = asyncio.Event()
        publisher_release = asyncio.Event()

        async def publish(event: dict[str, object]) -> None:
            assert event["type"] == "translation.pending"
            publisher_started.set()
            try:
                await asyncio.Event().wait()
            except asyncio.CancelledError:
                await publisher_release.wait()

        session = TranslationSession(
            translator=translator,
            stream_id="stream_123",
            source_language="vi",
            target_language="en",
            publish_event=publish,
        )
        await session.start()
        await session.accept_transcript(
            final("seg_001", "Xin chao", utterance_boundary=True)
        )
        await publisher_started.wait()

        abort_task = asyncio.create_task(session.abort())
        await asyncio.sleep(0.02)
        abort_was_prompt = abort_task.done()
        publisher_release.set()
        await abort_task
        await wait_until(lambda: translator.active_calls == 0)
        await session.close()
        return abort_was_prompt, translator.calls

    abort_was_prompt, calls = asyncio.run(exercise())

    assert abort_was_prompt is True
    assert calls == []
