import asyncio
from collections.abc import Awaitable, Callable

from app.ai.stt import SttTranscript
from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
    Translator,
)
from app.realtime.stt_protocol import TargetLanguage
from app.realtime.translation_aggregator import (
    INACTIVITY_FLUSH_MS,
    TranslationUtterance,
    TranslationUtteranceAggregator,
)
from app.realtime.translation_protocol import (
    SourceLanguage,
    TranslationErrorCode,
    translation_final_event,
    translation_pending_event,
    translation_utterance_error_event,
)


TranslationEventPublisher = Callable[
    [dict[str, object]], Awaitable[None]
]
Sleep = Callable[[float], Awaitable[None]]

_ERROR_MESSAGES: dict[TranslationErrorCode, str] = {
    "provider_unavailable": "Translation provider is unavailable.",
    "provider_error": "Translation failed for this passage.",
    "queue_overflow": "Translation queue is full.",
    "request_timeout": "Translation request timed out.",
    "internal_error": "Translation failed for this passage.",
}
_ABORT_SETTLE_TIMEOUT_SECONDS = 0.01


class TranslationSession:
    """Owns aggregation and ordered translation, independent of transport."""

    def __init__(
        self,
        *,
        translator: Translator,
        stream_id: str,
        source_language: SourceLanguage,
        target_language: TargetLanguage,
        publish_event: TranslationEventPublisher,
        queue_max_size: int = 8,
        request_timeout_seconds: float = 10.0,
        sleep: Sleep = asyncio.sleep,
    ) -> None:
        if queue_max_size < 1:
            raise ValueError("queue_max_size must be at least 1")
        if request_timeout_seconds <= 0:
            raise ValueError("request_timeout_seconds must be positive")

        self._translator = translator
        self._stream_id = stream_id
        self._source_language = source_language
        self._target_language = target_language
        self._publish_event = publish_event
        self._request_timeout_seconds = request_timeout_seconds
        self._sleep = sleep
        self._aggregator = TranslationUtteranceAggregator(
            stream_id=stream_id,
            source_language=source_language,
        )
        self._queue: asyncio.Queue[TranslationUtterance] = asyncio.Queue(
            maxsize=queue_max_size
        )
        self._worker_task: asyncio.Task[None] | None = None
        self._inactivity_task: asyncio.Task[None] | None = None
        self._cleanup_tasks: set[asyncio.Task[object]] = set()
        self._inactivity_generation = 0
        self._accepting = False
        self._closed = False
        self._publisher_failed = False

    async def start(self) -> None:
        if self._closed:
            raise RuntimeError("TranslationSession is closed")
        if self._worker_task is not None:
            return
        self._accepting = True
        self._worker_task = asyncio.create_task(
            self._run_worker(),
            name=f"translation-worker:{self._stream_id}",
        )

    async def accept_transcript(self, event: SttTranscript) -> None:
        if not self._accepting or self._closed:
            raise RuntimeError("TranslationSession is not accepting events")

        accepted_before = self._aggregator.accepted_final_count
        utterance = self._aggregator.add(event)
        accepted = self._aggregator.accepted_final_count > accepted_before
        if not accepted:
            return

        await self._cancel_inactivity_timer()
        if utterance is not None:
            await self._enqueue(utterance)
            return
        self._schedule_inactivity_flush()

    async def flush_and_drain(self, *, timeout_seconds: float) -> bool:
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if self._closed:
            return False
        if self._worker_task is None:
            raise RuntimeError("TranslationSession has not been started")

        self._accepting = False
        drain_operation = asyncio.create_task(
            self._flush_remainder_and_wait(),
            name=f"translation-drain:{self._stream_id}",
        )
        done, _ = await asyncio.wait(
            (drain_operation,),
            timeout=timeout_seconds,
        )
        if drain_operation not in done:
            self._cancel_and_track(drain_operation)
            self._begin_abort()
            await asyncio.sleep(0)
            return False
        try:
            drain_operation.result()
        except asyncio.CancelledError:
            raise
        except Exception:
            self._publisher_failed = True
            self._begin_abort()
            return False

        if self._publisher_failed:
            self._begin_abort()
            return False
        return True

    async def abort(self) -> None:
        self._begin_abort()
        cleanup_tasks = tuple(self._cleanup_tasks)
        if cleanup_tasks:
            await asyncio.wait(
                cleanup_tasks,
                timeout=_ABORT_SETTLE_TIMEOUT_SECONDS,
            )

    async def close(self) -> None:
        await self.abort()

    async def _enqueue(self, utterance: TranslationUtterance) -> None:
        try:
            self._queue.put_nowait(utterance)
        except asyncio.QueueFull:
            try:
                await self._publish_utterance_error(
                    utterance,
                    code="queue_overflow",
                )
            except asyncio.CancelledError:
                raise
            except Exception:
                self._publisher_failed = True
                self._accepting = False
                self._discard_queued_utterances()
                worker = self._worker_task
                if worker is not None:
                    self._cancel_and_track(worker)

    async def _run_worker(self) -> None:
        try:
            while not self._closed:
                utterance = await self._queue.get()
                try:
                    if self._closed:
                        return
                    await self._translate_utterance(utterance)
                finally:
                    self._queue.task_done()
        except asyncio.CancelledError:
            raise
        except Exception:
            self._publisher_failed = True
            self._accepting = False
            self._discard_queued_utterances()

    async def _translate_utterance(
        self,
        utterance: TranslationUtterance,
    ) -> None:
        await self._publish_event(
            translation_pending_event(
                stream_id=utterance.stream_id,
                utterance_id=utterance.utterance_id,
                source_segment_ids=utterance.source_segment_ids,
                source_text=utterance.source_text,
                source_language=utterance.source_language,
                target_language=self._target_language,
            )
        )
        if self._closed:
            return

        try:
            result = await asyncio.wait_for(
                self._translator.translate(
                    text=utterance.source_text,
                    source_language=utterance.source_language,
                    target_language=self._target_language,
                ),
                timeout=self._request_timeout_seconds,
            )
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            if self._closed:
                return
            await self._publish_utterance_error(
                utterance,
                code="request_timeout",
            )
            return
        except TranslationProviderUnavailable:
            if self._closed:
                return
            await self._publish_utterance_error(
                utterance,
                code="provider_unavailable",
            )
            return
        except TranslationProviderError:
            if self._closed:
                return
            await self._publish_utterance_error(
                utterance,
                code="provider_error",
            )
            return
        except Exception:
            if self._closed:
                return
            await self._publish_utterance_error(
                utterance,
                code="internal_error",
            )
            return

        if self._closed:
            return
        await self._publish_event(
            translation_final_event(
                stream_id=utterance.stream_id,
                utterance_id=utterance.utterance_id,
                source_segment_ids=utterance.source_segment_ids,
                source_text=utterance.source_text,
                translated_text=result.translated_text,
                source_language=utterance.source_language,
                target_language=self._target_language,
            )
        )

    async def _publish_utterance_error(
        self,
        utterance: TranslationUtterance,
        *,
        code: TranslationErrorCode,
    ) -> None:
        await self._publish_event(
            translation_utterance_error_event(
                stream_id=utterance.stream_id,
                utterance_id=utterance.utterance_id,
                source_segment_ids=utterance.source_segment_ids,
                source_text=utterance.source_text,
                source_language=utterance.source_language,
                target_language=self._target_language,
                code=code,
                message=_ERROR_MESSAGES[code],
            )
        )

    def _schedule_inactivity_flush(self) -> None:
        self._inactivity_generation += 1
        generation = self._inactivity_generation
        self._inactivity_task = asyncio.create_task(
            self._flush_after_inactivity(generation),
            name=f"translation-inactivity:{self._stream_id}",
        )

    async def _flush_after_inactivity(self, generation: int) -> None:
        try:
            await self._sleep(INACTIVITY_FLUSH_MS / 1000)
        except asyncio.CancelledError:
            raise

        if (
            self._closed
            or not self._accepting
            or generation != self._inactivity_generation
        ):
            return
        self._inactivity_task = None
        utterance = self._aggregator.flush()
        if utterance is not None:
            await self._enqueue(utterance)

    async def _cancel_inactivity_timer(self) -> None:
        self._inactivity_generation += 1
        task = self._inactivity_task
        if task is None:
            return
        task.cancel()
        try:
            await asyncio.gather(task, return_exceptions=True)
        finally:
            if self._inactivity_task is task:
                self._inactivity_task = None

    async def _flush_remainder_and_wait(self) -> None:
        await self._cancel_inactivity_timer()
        remainder = self._aggregator.flush()
        if remainder is not None:
            await self._enqueue(remainder)
        await self._queue.join()

    def _begin_abort(self) -> None:
        if not self._closed:
            self._closed = True
            self._accepting = False
            self._inactivity_generation += 1

        inactivity_task = self._inactivity_task
        self._inactivity_task = None
        if inactivity_task is not None:
            self._cancel_and_track(inactivity_task)

        worker = self._worker_task
        self._worker_task = None
        if worker is not None:
            self._cancel_and_track(worker)

        self._discard_queued_utterances()

    def _cancel_and_track(self, task: asyncio.Task[object]) -> None:
        if task.done():
            self._consume_task_result(task)
            return
        task.cancel()
        self._cleanup_tasks.add(task)
        task.add_done_callback(self._cleanup_task_done)

    def _cleanup_task_done(self, task: asyncio.Task[object]) -> None:
        self._cleanup_tasks.discard(task)
        self._consume_task_result(task)

    @staticmethod
    def _consume_task_result(task: asyncio.Task[object]) -> None:
        if not task.cancelled():
            task.exception()

    def _discard_queued_utterances(self) -> None:
        while True:
            try:
                self._queue.get_nowait()
            except asyncio.QueueEmpty:
                return
            else:
                self._queue.task_done()
