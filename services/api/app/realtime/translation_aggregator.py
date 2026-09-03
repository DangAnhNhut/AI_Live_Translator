from dataclasses import dataclass
from typing import Literal

from app.ai.stt import SttTranscript


MIN_NATURAL_BOUNDARY_CHARS = 100
MAX_UTTERANCE_CHARS = 300
MAX_FINAL_SEGMENTS = 6
INACTIVITY_FLUSH_MS = 1000

_NATURAL_BOUNDARY_PUNCTUATION = (".", "?", "!", "…")


@dataclass(frozen=True, slots=True)
class TranslationUtterance:
    stream_id: str
    utterance_id: str
    source_segment_ids: tuple[str, ...]
    source_text: str
    source_language: Literal["vi"]


class TranslationUtteranceAggregator:
    def __init__(
        self,
        *,
        stream_id: str,
        source_language: Literal["vi"],
    ) -> None:
        self._stream_id = stream_id
        self._source_language = source_language
        self._seen_final_segment_ids: set[str] = set()
        self._pending_segment_ids: list[str] = []
        self._pending_texts: list[str] = []
        self._next_utterance_number = 1
        self._accepted_final_count = 0

    @property
    def accepted_final_count(self) -> int:
        return self._accepted_final_count

    def add(self, event: SttTranscript) -> TranslationUtterance | None:
        if event.kind != "final":
            return None
        if event.segment_id in self._seen_final_segment_ids:
            return None

        normalized_text = _normalize_whitespace(event.text)
        if not normalized_text:
            return None

        self._seen_final_segment_ids.add(event.segment_id)
        self._accepted_final_count += 1
        self._pending_segment_ids.append(event.segment_id)
        self._pending_texts.append(normalized_text)

        source_text = " ".join(self._pending_texts)
        has_natural_boundary = (
            len(source_text) >= MIN_NATURAL_BOUNDARY_CHARS
            and source_text.endswith(_NATURAL_BOUNDARY_PUNCTUATION)
        )
        if (
            event.utterance_boundary
            or has_natural_boundary
            or len(source_text) >= MAX_UTTERANCE_CHARS
            or len(self._pending_segment_ids) >= MAX_FINAL_SEGMENTS
        ):
            return self.flush()
        return None

    def flush(self) -> TranslationUtterance | None:
        if not self._pending_segment_ids:
            return None

        utterance = TranslationUtterance(
            stream_id=self._stream_id,
            utterance_id=f"utt_{self._next_utterance_number:06d}",
            source_segment_ids=tuple(self._pending_segment_ids),
            source_text=" ".join(self._pending_texts),
            source_language=self._source_language,
        )
        self._next_utterance_number += 1
        self._pending_segment_ids.clear()
        self._pending_texts.clear()
        return utterance


def _normalize_whitespace(text: str) -> str:
    return " ".join(text.split())
