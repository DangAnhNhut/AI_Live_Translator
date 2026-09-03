"""Run one validated WAV case through an existing STT provider stream."""

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from pathlib import Path
import time

from app.ai.stt import (
    ProviderStreamError,
    ProviderUnavailableError,
    SttProviderFactory,
    SttProviderStream,
)
from app.benchmark.stt_accuracy import (
    AccuracyCaseResult,
    normalize_for_scoring,
    score_transcript,
)
from app.benchmark.stt_accuracy_audio import (
    UnsupportedWavError,
    WavAudio,
    load_wav_audio,
)
from app.benchmark.stt_accuracy_manifest import BenchmarkCase
from app.realtime.stt_protocol import AudioConfig


DEFAULT_CHUNK_DURATION_SECONDS = 0.1


@dataclass(frozen=True, slots=True)
class _CollectedTranscript:
    final_segments: tuple[str, ...]
    first_interim_ms: float | None
    final_ms: float | None


async def run_benchmark_case(
    case: BenchmarkCase,
    audio_path: Path,
    *,
    provider_factory: SttProviderFactory,
    provider: str,
    model: str,
    configured_language: str,
    pace_audio: bool = True,
    sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    monotonic: Callable[[], float] = time.perf_counter,
) -> AccuracyCaseResult:
    try:
        audio = load_wav_audio(audio_path)
    except (OSError, UnsupportedWavError) as error:
        return _failure_result(
            case,
            provider,
            model,
            configured_language,
            f"audio_error: {error}",
        )

    stream: SttProviderStream | None = None
    event_task: asyncio.Task[_CollectedTranscript] | None = None
    collection: _CollectedTranscript | None = None
    provider_error: str | None = None
    try:
        stream = provider_factory()
        await stream.start(
            AudioConfig(
                encoding="pcm_s16le",
                sample_rate_hz=16000,
                channels=1,
            ),
            "vi",
        )
        audio_started_at = monotonic()
        event_task = asyncio.create_task(
            _collect_transcript_events(stream, audio_started_at, monotonic)
        )
        await _stream_audio(
            stream,
            audio,
            pace_audio=pace_audio,
            sleep=sleep,
        )
        await stream.finish_input()
        collection = await event_task
    except (ProviderUnavailableError, ProviderStreamError) as error:
        provider_error = str(error)
    except Exception:
        provider_error = "unexpected_benchmark_runner_error"
    finally:
        if event_task is not None and not event_task.done():
            event_task.cancel()
            await asyncio.gather(event_task, return_exceptions=True)
        if stream is not None:
            try:
                await stream.close()
            except Exception:
                if provider_error is None:
                    provider_error = "provider_close_failed"

    if provider_error is not None:
        return _failure_result(
            case,
            provider,
            model,
            configured_language,
            provider_error,
        )
    assert collection is not None
    raw_hypothesis = " ".join(collection.final_segments)
    if not raw_hypothesis:
        return _failure_result(
            case,
            provider,
            model,
            configured_language,
            "no_usable_final_transcript",
            first_interim_ms=collection.first_interim_ms,
        )
    score = score_transcript(case.reference_text, raw_hypothesis)
    return AccuracyCaseResult(
        case_id=case.case_id,
        category=case.category,
        provider=provider,
        model=model,
        configured_language=configured_language,
        raw_reference=case.reference_text,
        raw_hypothesis=raw_hypothesis,
        normalized_reference=score.normalized_reference,
        normalized_hypothesis=score.normalized_hypothesis,
        wer=score.wer,
        cer=score.cer,
        word_edits=score.word_edits,
        character_edits=score.character_edits,
        first_interim_ms=collection.first_interim_ms,
        final_ms=collection.final_ms,
        provider_error=None,
    )


async def _stream_audio(
    stream: SttProviderStream,
    audio: WavAudio,
    *,
    pace_audio: bool,
    sleep: Callable[[float], Awaitable[None]],
) -> None:
    chunk_size = int(audio.bytes_per_second * DEFAULT_CHUNK_DURATION_SECONDS)
    for offset in range(0, len(audio.pcm_bytes), chunk_size):
        chunk = audio.pcm_bytes[offset : offset + chunk_size]
        await stream.send_audio(chunk)
        if pace_audio:
            await sleep(len(chunk) / audio.bytes_per_second)


async def _collect_transcript_events(
    stream: SttProviderStream,
    audio_started_at: float,
    monotonic: Callable[[], float],
) -> _CollectedTranscript:
    final_segments: list[str] = []
    first_interim_ms: float | None = None
    final_ms: float | None = None
    async for event in stream.events():
        text = event.text.strip()
        if not text:
            continue
        elapsed_ms = round((monotonic() - audio_started_at) * 1000, 3)
        if event.kind == "interim":
            if first_interim_ms is None:
                first_interim_ms = elapsed_ms
            continue
        final_segments.append(text)
        final_ms = elapsed_ms
    return _CollectedTranscript(
        final_segments=tuple(final_segments),
        first_interim_ms=first_interim_ms,
        final_ms=final_ms,
    )


def _failure_result(
    case: BenchmarkCase,
    provider: str,
    model: str,
    configured_language: str,
    provider_error: str,
    *,
    first_interim_ms: float | None = None,
) -> AccuracyCaseResult:
    return AccuracyCaseResult(
        case_id=case.case_id,
        category=case.category,
        provider=provider,
        model=model,
        configured_language=configured_language,
        raw_reference=case.reference_text,
        raw_hypothesis="",
        normalized_reference=normalize_for_scoring(case.reference_text),
        normalized_hypothesis="",
        wer=None,
        cer=None,
        word_edits=None,
        character_edits=None,
        first_interim_ms=first_interim_ms,
        final_ms=None,
        provider_error=provider_error,
    )
