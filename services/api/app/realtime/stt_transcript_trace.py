import json
from collections.abc import Callable
from typing import Literal, Protocol, runtime_checkable

from app.core.config import settings


_PREFIX = "STT_TRANSCRIPT_TRACE "
TranscriptKind = Literal["interim", "final"]


class SttTranscriptTraceRecorder:
    def __init__(self, *, sink: Callable[[str], None]) -> None:
        self._sink = sink
        self._provider_sequence = 0
        self._websocket_sequence = 0

    def record_provider_result(
        self,
        *,
        kind: TranscriptKind,
        text: str,
        language: str,
        provider_segment_metadata: dict[str, object],
    ) -> None:
        self._provider_sequence += 1
        self._emit(
            "provider_result",
            provider_sequence=self._provider_sequence,
            kind=kind,
            text=text,
            text_length=len(text),
            language=language,
            provider_segment_metadata=provider_segment_metadata,
        )

    def record_websocket_transcript_sent(
        self,
        *,
        segment_id: str,
        kind: TranscriptKind,
        text: str,
        language: str,
    ) -> None:
        self._websocket_sequence += 1
        self._emit(
            "websocket_transcript_sent",
            sequence=self._websocket_sequence,
            segment_id=segment_id,
            kind=kind,
            text=text,
            language=language,
        )

    def _emit(self, event: str, **fields: object) -> None:
        payload = {
            "category": "stt_transcript_trace",
            "source": "backend",
            "event": event,
            **fields,
        }
        self._sink(
            _PREFIX
            + json.dumps(payload, separators=(",", ":"), sort_keys=True)
        )


def _print_trace_line(line: str) -> None:
    print(line, flush=True)


def create_stt_transcript_trace(
    *,
    enabled: bool,
    sink: Callable[[str], None] = _print_trace_line,
) -> SttTranscriptTraceRecorder | None:
    if not enabled:
        return None
    return SttTranscriptTraceRecorder(sink=sink)


SttTranscriptTraceFactory = Callable[[], SttTranscriptTraceRecorder | None]


def get_stt_transcript_trace_factory() -> SttTranscriptTraceFactory:
    enabled = settings.stt_transcript_trace

    def factory() -> SttTranscriptTraceRecorder | None:
        return create_stt_transcript_trace(enabled=enabled)

    return factory


@runtime_checkable
class SupportsSttTranscriptTrace(Protocol):
    def set_stt_transcript_trace(
        self,
        trace: SttTranscriptTraceRecorder,
    ) -> None: ...


def attach_stt_transcript_trace(
    stream: object,
    trace: SttTranscriptTraceRecorder | None,
) -> None:
    if trace is not None and isinstance(stream, SupportsSttTranscriptTrace):
        stream.set_stt_transcript_trace(trace)
