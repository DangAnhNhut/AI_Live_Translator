"""Provider-neutral transcript accuracy scoring primitives."""

from dataclasses import dataclass
import unicodedata


@dataclass(frozen=True, slots=True)
class EditCounts:
    substitutions: int
    deletions: int
    insertions: int
    reference_count: int

    @property
    def errors(self) -> int:
        return self.substitutions + self.deletions + self.insertions

    @property
    def rate(self) -> float:
        return self.errors / max(1, self.reference_count)


@dataclass(frozen=True, slots=True)
class TranscriptScore:
    normalized_reference: str
    normalized_hypothesis: str
    wer: float
    cer: float
    word_edits: EditCounts
    character_edits: EditCounts


@dataclass(frozen=True, slots=True)
class AccuracyCaseResult:
    case_id: str
    category: str
    provider: str
    model: str
    configured_language: str
    raw_reference: str
    raw_hypothesis: str
    normalized_reference: str
    normalized_hypothesis: str
    wer: float | None
    cer: float | None
    word_edits: EditCounts | None
    character_edits: EditCounts | None
    first_interim_ms: float | None
    final_ms: float | None
    provider_error: str | None


def normalize_for_scoring(text: str) -> str:
    """Normalize scoring text without translating or removing language tokens."""

    normalized = unicodedata.normalize("NFC", text).lower()
    punctuation_spaced = "".join(
        " " if unicodedata.category(character).startswith("P") else character
        for character in normalized
    )
    return " ".join(punctuation_spaced.split())


def score_transcript(reference: str, hypothesis: str) -> TranscriptScore:
    normalized_reference = normalize_for_scoring(reference)
    normalized_hypothesis = normalize_for_scoring(hypothesis)
    word_edits = _edit_counts(
        normalized_reference.split(),
        normalized_hypothesis.split(),
    )
    character_edits = _edit_counts(
        list(normalized_reference),
        list(normalized_hypothesis),
    )
    return TranscriptScore(
        normalized_reference=normalized_reference,
        normalized_hypothesis=normalized_hypothesis,
        wer=word_edits.rate,
        cer=character_edits.rate,
        word_edits=word_edits,
        character_edits=character_edits,
    )


def _edit_counts(reference: list[str], hypothesis: list[str]) -> EditCounts:
    previous = [
        EditCounts(0, 0, insertions, len(reference))
        for insertions in range(len(hypothesis) + 1)
    ]
    for reference_index, reference_item in enumerate(reference, start=1):
        current = [EditCounts(0, reference_index, 0, len(reference))]
        for hypothesis_index, hypothesis_item in enumerate(hypothesis, start=1):
            diagonal = previous[hypothesis_index - 1]
            if reference_item == hypothesis_item:
                current.append(diagonal)
                continue
            substitution = EditCounts(
                diagonal.substitutions + 1,
                diagonal.deletions,
                diagonal.insertions,
                len(reference),
            )
            above = previous[hypothesis_index]
            deletion = EditCounts(
                above.substitutions,
                above.deletions + 1,
                above.insertions,
                len(reference),
            )
            left = current[hypothesis_index - 1]
            insertion = EditCounts(
                left.substitutions,
                left.deletions,
                left.insertions + 1,
                len(reference),
            )
            current.append(
                min(
                    (substitution, deletion, insertion),
                    key=lambda counts: counts.errors,
                )
            )
        previous = current
    return previous[-1]
