import asyncio
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass

from app.ai.tts import (
    InvalidSynthesizedAudio,
    SpeechSynthesizer,
    SynthesizedAudio,
    TtsProviderError,
    TtsProviderUnavailable,
)
from app.realtime.stt_protocol import TargetLanguage
from app.realtime.tts_protocol import (
    TtsErrorCode,
    tts_audio_event,
    tts_pending_event,
    tts_utterance_error_event,
)


TtsEventPublisher = Callable[[dict[str, object]], Awaitable[None]]
TtsAudioPublisher = Callable[
    [dict[str, object], bytes], Awaitable[None]
]

_ERROR_MESSAGES: dict[TtsErrorCode, str] = {
    "provider_unavailable": "Speech synthesis is unavailable.",
    "provider_error": "Speech synthesis failed for this passage.",
    "queue_overflow": "Speech synthesis queue is full.",
    "request_timeout": "Speech synthesis request timed out.",
    "invalid_audio": "Speech synthesis returned invalid audio.",
    "internal_error": "Speech synthesis failed for this passage.",
}


@dataclass(frozen=True, slots=True)
class _TtsWorkItem:
    stream_id: str
    utterance_id: str
    source_segment_ids: tuple[str, ...]
    translated_text: str
    target_language: TargetLanguage


class TtsSession:
    """Owns bounded, ordered speech synthesis independent of transport."""

    def __init__(
        self,
        *,
        synthesizer: SpeechSynthesizer,
        stream_id: str,
        target_language: TargetLanguage,
        publish_event: TtsEventPublisher,
        publish_audio: TtsAudioPublisher,
        voice: str | None = None,
        queue_max_size: int = 8,
        request_timeout_seconds: float = 10.0,
    ) -> None:
        if queue_max_size < 1:
            raise ValueError("queue_max_size must be at least 1")
        if request_timeout_seconds <= 0:
            raise ValueError("request_timeout_seconds must be positive")
        if not isinstance(stream_id, str) or not stream_id.strip():
            raise ValueError("stream_id must be non-empty")
        if voice is not None and (
            not isinstance(voice, str) or not voice.strip()
        ):
            raise ValueError("voice must be non-empty or None")

        self._synthesizer = synthesizer
        self._stream_id = stream_id
        self._target_language = target_language
        self._publish_event = publish_event
        self._publish_audio = publish_audio
        self._voice = voice
        self._request_timeout_seconds = request_timeout_seconds
        self._queue: asyncio.Queue[_TtsWorkItem] = asyncio.Queue(
            maxsize=queue_max_size
        )
        self._seen_identities: set[tuple[str, str]] = set()
        self._worker_task: asyncio.Task[None] | None = None
        self._drain_task: asyncio.Task[None] | None = None
        self._cleanup_tasks: set[asyncio.Task[object]] = set()
        self._accepting = False
        self._closed = False
        self._publisher_failed = False
        self._drain_succeeded = False
        self._next_audio_number = 1

    async def start(self) -> None:
        if self._closed:
            raise RuntimeError("TtsSession is closed")
        if self._worker_task is not None:
            return
        self._accepting = True
        self._worker_task = asyncio.create_task(
            self._run_worker(),
            name=f"tts-worker:{self._stream_id}",
        )

    async def submit(
        self,
        *,
        stream_id: str,
        utterance_id: str,
        source_segment_ids: Sequence[str],
        translated_text: str,
        target_language: TargetLanguage,
    ) -> None:
        if not self._accepting or self._closed:
            raise RuntimeError("TtsSession is not accepting events")
        if stream_id != self._stream_id:
            raise ValueError("stream_id does not match TtsSession")
        if target_language != self._target_language:
            raise ValueError("target_language does not match TtsSession")
        if not isinstance(utterance_id, str) or not utterance_id.strip():
            raise ValueError("utterance_id must be non-empty")
        if not isinstance(translated_text, str) or not translated_text.strip():
            raise ValueError("translated_text must be non-empty")

        normalized_source_segment_ids = tuple(source_segment_ids)
        if not normalized_source_segment_ids or any(
            not isinstance(segment_id, str) or not segment_id.strip()
            for segment_id in normalized_source_segment_ids
        ):
            raise ValueError("source_segment_ids must contain non-empty strings")

        identity = (stream_id, utterance_id)
        if identity in self._seen_identities:
            return
        self._seen_identities.add(identity)

        item = _TtsWorkItem(
            stream_id=stream_id,
            utterance_id=utterance_id,
            source_segment_ids=normalized_source_segment_ids,
            translated_text=translated_text,
            target_language=target_language,
        )
        try:
            self._queue.put_nowait(item)
        except asyncio.QueueFull:
            try:
                await self._publish_utterance_error(
                    item,
                    code="queue_overflow",
                )
            except asyncio.CancelledError:
                raise
            except Exception:
                self._publisher_failed = True
                self._accepting = False
                self._discard_queued_items()
                worker = self._worker_task
                if worker is not None:
                    self._worker_task = None
                    self._cancel_and_track(worker)

    async def flush_and_drain(self, *, timeout_seconds: float) -> bool:
        if timeout_seconds <= 0:
            raise ValueError("timeout_seconds must be positive")
        if self._closed:
            return False
        if self._publisher_failed:
            self._begin_abort()
            await self._settle_cleanup_tasks()
            return False
        if self._worker_task is None:
            raise RuntimeError("TtsSession has not been started")
        if self._drain_succeeded:
            return True

        self._accepting = False
        drain_task = self._drain_task
        if drain_task is None:
            drain_task = asyncio.create_task(
                self._queue.join(),
                name=f"tts-drain:{self._stream_id}",
            )
            self._drain_task = drain_task

        done, _ = await asyncio.wait(
            (drain_task,),
            timeout=timeout_seconds,
        )
        if drain_task not in done:
            self._begin_abort()
            await self._settle_cleanup_tasks()
            return False

        try:
            drain_task.result()
        except asyncio.CancelledError:
            raise
        except Exception:
            self._publisher_failed = True
            self._begin_abort()
            await self._settle_cleanup_tasks()
            return False
        finally:
            if self._drain_task is drain_task:
                self._drain_task = None

        if self._publisher_failed:
            self._begin_abort()
            await self._settle_cleanup_tasks()
            return False
        self._drain_succeeded = True
        return True

    async def abort(self) -> None:
        self._begin_abort()
        await self._settle_cleanup_tasks()

    async def close(self) -> None:
        await self.abort()

    async def _run_worker(self) -> None:
        try:
            while not self._closed:
                item = await self._queue.get()
                try:
                    if self._closed:
                        return
                    await self._synthesize_item(item)
                finally:
                    self._queue.task_done()
        except asyncio.CancelledError:
            raise
        except Exception:
            self._publisher_failed = True
            self._accepting = False
            self._discard_queued_items()

    async def _synthesize_item(self, item: _TtsWorkItem) -> None:
        await self._publish_event(
            tts_pending_event(
                stream_id=item.stream_id,
                utterance_id=item.utterance_id,
                target_language=item.target_language,
            )
        )
        if self._closed:
            return

        try:
            result = await asyncio.wait_for(
                self._synthesizer.synthesize(
                    text=item.translated_text,
                    language=item.target_language,
                    voice=self._voice,
                ),
                timeout=self._request_timeout_seconds,
            )
        except asyncio.CancelledError:
            raise
        except asyncio.TimeoutError:
            if not self._closed:
                await self._publish_utterance_error(
                    item,
                    code="request_timeout",
                )
            return
        except TtsProviderUnavailable:
            if not self._closed:
                await self._publish_utterance_error(
                    item,
                    code="provider_unavailable",
                )
            return
        except TtsProviderError:
            if not self._closed:
                await self._publish_utterance_error(
                    item,
                    code="provider_error",
                )
            return
        except InvalidSynthesizedAudio:
            if not self._closed:
                await self._publish_utterance_error(
                    item,
                    code="invalid_audio",
                )
            return
        except Exception:
            if not self._closed:
                await self._publish_utterance_error(
                    item,
                    code="internal_error",
                )
            return

        if self._closed:
            return
        if not isinstance(result, SynthesizedAudio):
            await self._publish_utterance_error(
                item,
                code="invalid_audio",
            )
            return

        audio_id = f"audio_{self._next_audio_number:06d}"
        self._next_audio_number += 1
        await self._publish_audio(
            tts_audio_event(
                stream_id=item.stream_id,
                utterance_id=item.utterance_id,
                audio_id=audio_id,
                target_language=item.target_language,
                mime_type=result.mime_type,
                byte_length=len(result.audio_bytes),
                sample_rate_hz=result.sample_rate_hz,
            ),
            result.audio_bytes,
        )

    async def _publish_utterance_error(
        self,
        item: _TtsWorkItem,
        *,
        code: TtsErrorCode,
    ) -> None:
        await self._publish_event(
            tts_utterance_error_event(
                stream_id=item.stream_id,
                utterance_id=item.utterance_id,
                target_language=item.target_language,
                code=code,
                message=_ERROR_MESSAGES[code],
            )
        )

    def _discard_queued_items(self) -> None:
        while True:
            try:
                self._queue.get_nowait()
            except asyncio.QueueEmpty:
                return
            else:
                self._queue.task_done()

    def _begin_abort(self) -> None:
        self._closed = True
        self._accepting = False

        drain_task = self._drain_task
        self._drain_task = None
        if drain_task is not None:
            self._cancel_and_track(drain_task)

        worker = self._worker_task
        self._worker_task = None
        if worker is not None:
            self._cancel_and_track(worker)

        self._discard_queued_items()

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

    async def _settle_cleanup_tasks(self) -> None:
        while self._cleanup_tasks:
            tasks = tuple(self._cleanup_tasks)
            await asyncio.gather(*tasks, return_exceptions=True)
