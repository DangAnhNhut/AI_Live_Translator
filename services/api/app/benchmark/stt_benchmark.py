import json
import math
import struct
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable
from uuid import uuid4

from app.core.config import settings


_PREFIX = "STT_BENCHMARK "
_SAMPLE_RATE_HZ = 16000
_DEFAULT_SPEECH_RMS_THRESHOLD = 1200.0
_DEFAULT_SILENCE_RMS_THRESHOLD = 400.0
_DEFAULT_MINIMUM_SILENCE_SECONDS = 0.350
_DEFAULT_MINIMUM_SILENCE_CHUNKS = 3
_DEFAULT_MAX_COMPLETED_SAMPLES = 2048
_DEFAULT_MAX_PENDING_UTTERANCES = 256

SttBenchmarkCloseReason = Literal[
    "client_stop",
    "client_disconnect",
    "protocol_error",
    "provider_unavailable",
    "provider_error",
    "internal_error",
]


class SttBenchmarkObserver(Protocol):
    def record_audio_chunk(self, chunk: bytes) -> None: ...

    def record_transcript(
        self,
        kind: Literal["interim", "final"],
        segment_id: str,
    ) -> None: ...

    def record_keepalive(self) -> None: ...

    def record_provider_error(self) -> None: ...

    def finish(self, close_reason: SttBenchmarkCloseReason) -> None: ...


@runtime_checkable
class SupportsSttBenchmarkObserver(Protocol):
    def set_stt_benchmark_observer(
        self,
        observer: SttBenchmarkObserver,
    ) -> None: ...


def attach_stt_benchmark_observer(
    stream: object,
    observer: SttBenchmarkObserver | None,
) -> None:
    if observer is not None and isinstance(stream, SupportsSttBenchmarkObserver):
        stream.set_stt_benchmark_observer(observer)


@dataclass
class _BackendUtterance:
    id: int
    onset_at: float
    segment_id: str | None = None
    first_interim_at: float | None = None
    audio_chunk_count: int = 0
    audio_byte_count: int = 0
    max_audio_chunk_gap_ms: float | None = None


def _s16le_rms(pcm: bytes) -> float:
    sample_count = len(pcm) // 2
    if sample_count == 0:
        return 0.0
    square_sum = 0
    samples = memoryview(pcm)[: sample_count * 2]
    for (sample,) in struct.iter_unpack("<h", samples):
        square_sum += sample * sample
    return math.sqrt(square_sum / sample_count)


class SttBenchmarkRecorder:
    def __init__(
        self,
        *,
        monotonic: Callable[[], float],
        sink: Callable[[str], None],
        rms_calculator: Callable[[bytes], float] = _s16le_rms,
        speech_rms_threshold: float = _DEFAULT_SPEECH_RMS_THRESHOLD,
        silence_rms_threshold: float = _DEFAULT_SILENCE_RMS_THRESHOLD,
        minimum_silence_seconds: float = _DEFAULT_MINIMUM_SILENCE_SECONDS,
        minimum_silence_chunks: int = _DEFAULT_MINIMUM_SILENCE_CHUNKS,
        max_completed_samples: int = _DEFAULT_MAX_COMPLETED_SAMPLES,
        max_pending_utterances: int = _DEFAULT_MAX_PENDING_UTTERANCES,
    ) -> None:
        if speech_rms_threshold <= silence_rms_threshold:
            raise ValueError("speech RMS threshold must exceed silence threshold")
        if minimum_silence_seconds < 0:
            raise ValueError("minimum silence cannot be negative")
        if minimum_silence_chunks <= 0:
            raise ValueError("minimum silence chunks must be positive")
        if max_completed_samples <= 0 or max_pending_utterances <= 0:
            raise ValueError("benchmark bounds must be positive")

        self._monotonic = monotonic
        self._sink = sink
        self._rms_calculator = rms_calculator
        self._speech_rms_threshold = speech_rms_threshold
        self._silence_rms_threshold = silence_rms_threshold
        self._minimum_silence_seconds = minimum_silence_seconds
        self._minimum_silence_chunks = minimum_silence_chunks
        self._max_completed_samples = max_completed_samples
        self._max_pending_utterances = max_pending_utterances

        self._session_id = uuid4().hex
        self._opened_at = monotonic()
        self._first_audio_at: float | None = None
        self._first_interim_at: float | None = None
        self._first_final_at: float | None = None
        self._last_audio_at: float | None = None
        self._audio_chunk_count = 0
        self._audio_byte_count = 0
        self._interim_count = 0
        self._final_count = 0
        self._keepalive_count = 0
        self._provider_error_count = 0
        self._finished = False

        self._silence_seconds = 0.0
        self._silence_chunks = 0
        self._speech_active = False
        self._speech_armed = False
        self._backend_utterance_count = 0
        self._current_utterance: _BackendUtterance | None = None
        self._pending_utterances: list[_BackendUtterance] = []
        self._segment_utterances: dict[str, _BackendUtterance] = {}
        self._retired_segment_ids: set[str] = set()
        self._retired_segment_order: list[str] = []
        self._ambiguous_unassigned_results = 0

        self._audio_chunk_gaps: list[float] = []
        self._speech_to_first_interim: list[float] = []
        self._speech_to_first_final: list[float] = []
        self._interim_to_final: list[float] = []

        self._emit(
            "session_open",
            session_opened_at_monotonic_s=self._opened_at,
        )

    def record_audio_chunk(self, chunk: bytes) -> None:
        if self._finished:
            return
        now = self._monotonic()
        byte_count = len(chunk)
        self._audio_chunk_count += 1
        self._audio_byte_count += byte_count
        if self._first_audio_at is None:
            self._first_audio_at = now
            self._emit("first_audio")

        rearmed_after_no_pcm_gap = False
        if self._last_audio_at is not None:
            gap_seconds = max(0.0, now - self._last_audio_at)
            gap_ms = self._milliseconds(gap_seconds)
            self._append_bounded(self._audio_chunk_gaps, gap_ms)
            if self._current_utterance is not None:
                previous_max = self._current_utterance.max_audio_chunk_gap_ms
                self._current_utterance.max_audio_chunk_gap_ms = (
                    gap_ms if previous_max is None else max(previous_max, gap_ms)
                )
            if gap_seconds >= self._minimum_silence_seconds:
                rearmed_after_no_pcm_gap = not self._speech_armed
                self._speech_active = False
                self._speech_armed = True
                self._reset_silence_run()
        self._last_audio_at = now

        rms = self._rms_calculator(chunk)
        if rms <= self._silence_rms_threshold:
            self._silence_chunks += 1
            self._silence_seconds += (byte_count // 2) / _SAMPLE_RATE_HZ
            if (
                self._silence_chunks >= self._minimum_silence_chunks
                and self._silence_seconds >= self._minimum_silence_seconds
            ):
                self._speech_active = False
                self._speech_armed = True
        elif rms < self._speech_rms_threshold:
            self._reset_silence_run()
        else:
            if not self._speech_active and self._speech_armed:
                self._start_utterance(
                    now,
                    discard_ambiguous=not rearmed_after_no_pcm_gap,
                )
                self._speech_active = True
                self._speech_armed = False
            self._reset_silence_run()

        if self._current_utterance is not None:
            self._current_utterance.audio_chunk_count += 1
            self._current_utterance.audio_byte_count += byte_count

    def record_transcript(
        self,
        kind: Literal["interim", "final"],
        segment_id: str,
    ) -> None:
        if self._finished:
            return
        now = self._monotonic()
        if kind == "interim":
            self._interim_count += 1
            if self._first_interim_at is None:
                self._first_interim_at = now
                self._emit("first_interim")
        else:
            self._final_count += 1
            if self._first_final_at is None:
                self._first_final_at = now
                self._emit("first_final")

        if segment_id in self._retired_segment_ids:
            if kind == "final":
                self._forget_retired_segment(segment_id)
            return

        if (
            segment_id not in self._segment_utterances
            and self._ambiguous_unassigned_results > 0
        ):
            self._ambiguous_unassigned_results -= 1
            if kind == "interim":
                self._retire_segment(segment_id)
            return

        utterance = self._utterance_for_segment(segment_id)
        if utterance is None:
            return
        if kind == "interim":
            if utterance.first_interim_at is not None:
                return
            utterance.first_interim_at = now
            speech_to_interim = self._between(utterance.onset_at, now)
            assert speech_to_interim is not None
            self._append_bounded(
                self._speech_to_first_interim,
                speech_to_interim,
            )
            self._emit(
                "utterance_first_interim",
                backend_utterance_id=utterance.id,
                speech_to_first_interim_ms=speech_to_interim,
            )
            return

        speech_to_final = self._between(utterance.onset_at, now)
        assert speech_to_final is not None
        self._append_bounded(self._speech_to_first_final, speech_to_final)
        speech_to_interim = self._between(
            utterance.onset_at,
            utterance.first_interim_at,
        )
        interim_to_final = self._between(utterance.first_interim_at, now)
        if interim_to_final is not None:
            self._append_bounded(self._interim_to_final, interim_to_final)
        self._emit(
            "utterance_complete",
            backend_utterance_id=utterance.id,
            speech_to_first_interim_ms=speech_to_interim,
            speech_to_first_final_ms=speech_to_final,
            interim_to_final_ms=interim_to_final,
            audio_chunk_count=utterance.audio_chunk_count,
            audio_byte_count=utterance.audio_byte_count,
            max_audio_chunk_gap_ms=utterance.max_audio_chunk_gap_ms,
        )
        self._complete_utterance(utterance)

    def record_keepalive(self) -> None:
        if not self._finished:
            self._keepalive_count += 1

    def record_provider_error(self) -> None:
        if not self._finished:
            self._provider_error_count += 1

    def finish(self, close_reason: SttBenchmarkCloseReason) -> None:
        if self._finished:
            return
        self._finished = True
        finished_at = self._monotonic()
        self._emit(
            "session_summary",
            session_opened_at_monotonic_s=self._opened_at,
            audio_chunk_count=self._audio_chunk_count,
            audio_byte_count=self._audio_byte_count,
            interim_count=self._interim_count,
            final_count=self._final_count,
            keepalive_count=self._keepalive_count,
            provider_error_count=self._provider_error_count,
            session_duration_ms=self._milliseconds(finished_at - self._opened_at),
            first_audio_to_first_interim_ms=self._between(
                self._first_audio_at,
                self._first_interim_at,
            ),
            first_audio_to_first_final_ms=self._between(
                self._first_audio_at,
                self._first_final_at,
            ),
            first_interim_to_first_final_ms=self._between(
                self._first_interim_at,
                self._first_final_at,
            ),
            backend_utterance_count=self._backend_utterance_count,
            speech_to_first_interim_ms=self._stats(
                self._speech_to_first_interim
            ),
            speech_to_first_final_ms=self._stats(self._speech_to_first_final),
            interim_to_final_ms=self._stats(self._interim_to_final),
            audio_chunk_gap_ms=self._stats(self._audio_chunk_gaps),
            close_reason=close_reason,
        )
        self._current_utterance = None
        self._pending_utterances.clear()
        self._segment_utterances.clear()
        self._retired_segment_ids.clear()
        self._retired_segment_order.clear()
        self._ambiguous_unassigned_results = 0

    def _start_utterance(
        self,
        now: float,
        *,
        discard_ambiguous: bool,
    ) -> None:
        abandoned = self._abandon_unassigned_utterances()
        if discard_ambiguous:
            self._ambiguous_unassigned_results = min(
                self._max_pending_utterances,
                self._ambiguous_unassigned_results + abandoned,
            )
        self._backend_utterance_count += 1
        utterance = _BackendUtterance(
            id=self._backend_utterance_count,
            onset_at=now,
        )
        self._pending_utterances.append(utterance)
        self._current_utterance = utterance
        self._cap_pending_utterances()
        self._emit(
            "utterance_onset",
            backend_utterance_id=utterance.id,
        )

    def _utterance_for_segment(
        self,
        segment_id: str,
    ) -> _BackendUtterance | None:
        existing = self._segment_utterances.get(segment_id)
        if existing is not None:
            return existing
        for utterance in self._pending_utterances:
            if utterance.segment_id is None:
                utterance.segment_id = segment_id
                self._segment_utterances[segment_id] = utterance
                return utterance
        return None

    def _complete_utterance(self, utterance: _BackendUtterance) -> None:
        if utterance in self._pending_utterances:
            self._pending_utterances.remove(utterance)
        if utterance.segment_id is not None:
            self._segment_utterances.pop(utterance.segment_id, None)
        if self._current_utterance is utterance:
            self._current_utterance = None

    def _abandon_unassigned_utterances(self) -> int:
        abandoned = 0
        retained: list[_BackendUtterance] = []
        for utterance in self._pending_utterances:
            if utterance.segment_id is None:
                abandoned += 1
                if self._current_utterance is utterance:
                    self._current_utterance = None
                continue
            retained.append(utterance)
        self._pending_utterances = retained
        return abandoned

    def _cap_pending_utterances(self) -> None:
        while len(self._pending_utterances) > self._max_pending_utterances:
            removed = self._pending_utterances.pop(0)
            if removed.segment_id is not None:
                self._segment_utterances.pop(removed.segment_id, None)
                self._retire_segment(removed.segment_id)
            if self._current_utterance is removed:
                self._current_utterance = None

    def _retire_segment(self, segment_id: str) -> None:
        if segment_id in self._retired_segment_ids:
            return
        if len(self._retired_segment_order) == self._max_pending_utterances:
            oldest = self._retired_segment_order.pop(0)
            self._retired_segment_ids.remove(oldest)
        self._retired_segment_order.append(segment_id)
        self._retired_segment_ids.add(segment_id)

    def _forget_retired_segment(self, segment_id: str) -> None:
        self._retired_segment_ids.remove(segment_id)
        self._retired_segment_order.remove(segment_id)

    def _append_bounded(self, samples: list[float], value: float) -> None:
        if len(samples) == self._max_completed_samples:
            samples.pop(0)
        samples.append(value)

    @staticmethod
    def _stats(samples: list[float]) -> dict[str, int | float | None]:
        if not samples:
            return {
                "count": 0,
                "min": None,
                "median": None,
                "p95": None,
                "max": None,
            }
        sorted_samples = sorted(samples)
        middle = len(sorted_samples) // 2
        if len(sorted_samples) % 2:
            median = sorted_samples[middle]
        else:
            median = (
                sorted_samples[middle - 1] + sorted_samples[middle]
            ) / 2
        p95_index = math.ceil(0.95 * len(sorted_samples)) - 1
        return {
            "count": len(sorted_samples),
            "min": sorted_samples[0],
            "median": median,
            "p95": sorted_samples[p95_index],
            "max": sorted_samples[-1],
        }

    def _reset_silence_run(self) -> None:
        self._silence_seconds = 0.0
        self._silence_chunks = 0

    def _between(self, start: float | None, end: float | None) -> float | None:
        if start is None or end is None:
            return None
        return self._milliseconds(end - start)

    @staticmethod
    def _milliseconds(seconds: float) -> float:
        return round(seconds * 1000, 3)

    def _emit(self, event: str, **fields: object) -> None:
        payload = {
            "category": "stt_benchmark",
            "source": "backend",
            "event": event,
            "session_id": self._session_id,
            **fields,
        }
        self._sink(
            _PREFIX
            + json.dumps(payload, separators=(",", ":"), sort_keys=True)
        )


def _log_benchmark_line(line: str) -> None:
    print(line, flush=True)


def create_stt_benchmark_recorder(
    *,
    enabled: bool,
    monotonic: Callable[[], float] = time.monotonic,
    sink: Callable[[str], None] = _log_benchmark_line,
    rms_calculator: Callable[[bytes], float] = _s16le_rms,
    speech_rms_threshold: float = _DEFAULT_SPEECH_RMS_THRESHOLD,
    silence_rms_threshold: float = _DEFAULT_SILENCE_RMS_THRESHOLD,
    minimum_silence_seconds: float = _DEFAULT_MINIMUM_SILENCE_SECONDS,
    minimum_silence_chunks: int = _DEFAULT_MINIMUM_SILENCE_CHUNKS,
    max_completed_samples: int = _DEFAULT_MAX_COMPLETED_SAMPLES,
    max_pending_utterances: int = _DEFAULT_MAX_PENDING_UTTERANCES,
) -> SttBenchmarkRecorder | None:
    if not enabled:
        return None
    return SttBenchmarkRecorder(
        monotonic=monotonic,
        sink=sink,
        rms_calculator=rms_calculator,
        speech_rms_threshold=speech_rms_threshold,
        silence_rms_threshold=silence_rms_threshold,
        minimum_silence_seconds=minimum_silence_seconds,
        minimum_silence_chunks=minimum_silence_chunks,
        max_completed_samples=max_completed_samples,
        max_pending_utterances=max_pending_utterances,
    )


SttBenchmarkFactory = Callable[[], SttBenchmarkRecorder | None]


def get_stt_benchmark_factory() -> SttBenchmarkFactory:
    enabled = settings.stt_benchmark

    def factory() -> SttBenchmarkRecorder | None:
        return create_stt_benchmark_recorder(enabled=enabled)

    return factory
