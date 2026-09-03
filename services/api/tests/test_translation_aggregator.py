from app.ai.stt import SttTranscript
from app.realtime.translation_aggregator import (
    TranslationUtteranceAggregator,
)


def make_aggregator():
    return TranslationUtteranceAggregator(
        stream_id="stream_123",
        source_language="vi",
    )


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


def normalize(text: str) -> str:
    return " ".join(text.split())


def test_interim_transcript_is_never_accepted_for_translation():
    aggregator = make_aggregator()

    result = aggregator.add(
        SttTranscript("interim", "seg_001", "xin chào")
    )

    assert result is None
    assert aggregator.flush() is None


def test_provider_semantic_boundary_commits_even_a_short_utterance():
    aggregator = make_aggregator()

    utterance = aggregator.add(
        final("seg_001", "Có.", utterance_boundary=True)
    )

    assert utterance is not None
    assert utterance.stream_id == "stream_123"
    assert utterance.utterance_id == "utt_000001"
    assert utterance.source_segment_ids == ("seg_001",)
    assert utterance.source_text == "Có."
    assert utterance.source_language == "vi"


def test_punctuation_below_minimum_does_not_commit():
    aggregator = make_aggregator()

    assert aggregator.add(final("seg_001", "Có.")) is None


def test_punctuation_at_minimum_character_boundary_commits():
    aggregator = make_aggregator()
    text = ("a" * 99) + "."

    utterance = aggregator.add(final("seg_001", text))

    assert utterance is not None
    assert utterance.source_text == text


def test_maximum_character_boundary_commits_without_punctuation():
    aggregator = make_aggregator()

    assert aggregator.add(final("seg_001", "a" * 299)) is None
    utterance = aggregator.add(final("seg_002", "b"))

    assert utterance is not None
    assert utterance.source_segment_ids == ("seg_001", "seg_002")
    assert utterance.source_text == f"{'a' * 299} b"


def test_six_final_segments_commit_as_safety_boundary():
    aggregator = make_aggregator()

    for index in range(1, 6):
        assert aggregator.add(final(f"seg_{index:03d}", "một")) is None
    utterance = aggregator.add(final("seg_006", "hai"))

    assert utterance is not None
    assert utterance.source_segment_ids == (
        "seg_001",
        "seg_002",
        "seg_003",
        "seg_004",
        "seg_005",
        "seg_006",
    )
    assert utterance.source_text == "một một một một một hai"


def test_flush_commits_pending_text_for_inactivity_or_stop():
    aggregator = make_aggregator()
    aggregator.add(final("seg_001", "Xin chào"))
    aggregator.add(final("seg_002", "mọi người"))

    utterance = aggregator.flush()

    assert utterance is not None
    assert utterance.source_segment_ids == ("seg_001", "seg_002")
    assert utterance.source_text == "Xin chào mọi người"
    assert aggregator.flush() is None


def test_repeated_final_segment_is_ignored_without_duplicate_text():
    aggregator = make_aggregator()
    assert aggregator.add(final("seg_001", "Xin chào")) is None

    assert (
        aggregator.add(
            final(
                "seg_001",
                "duplicate must be ignored",
                utterance_boundary=True,
            )
        )
        is None
    )
    utterance = aggregator.add(
        final("seg_002", "mọi người.", utterance_boundary=True)
    )

    assert utterance is not None
    assert utterance.source_segment_ids == ("seg_001", "seg_002")
    assert utterance.source_text == "Xin chào mọi người."


def test_empty_final_text_is_not_accepted_or_committed():
    aggregator = make_aggregator()

    assert aggregator.add(final("seg_001", "  \n\t ")) is None
    assert aggregator.flush() is None


def test_whitespace_is_normalized_without_rewriting_words_or_punctuation():
    aggregator = make_aggregator()
    aggregator.add(final("seg_001", "  Xin   chào  "))
    utterance = aggregator.add(
        final("seg_002", " mọi\nngười! ", utterance_boundary=True)
    )

    assert utterance is not None
    assert utterance.source_text == "Xin chào mọi người!"


def test_utterance_ids_advance_only_when_an_utterance_is_committed():
    aggregator = make_aggregator()

    first = aggregator.add(
        final("seg_001", "Một.", utterance_boundary=True)
    )
    aggregator.add(SttTranscript("interim", "seg_002", "revision"))
    second = aggregator.add(
        final("seg_002", "Hai.", utterance_boundary=True)
    )

    assert first is not None
    assert second is not None
    assert first.utterance_id == "utt_000001"
    assert second.utterance_id == "utt_000002"


def test_concatenated_committed_text_equals_accepted_final_text():
    aggregator = make_aggregator()
    accepted = (
        final("seg_001", "  Xin chào "),
        final("seg_002", "mọi   người."),
        final("seg_003", " Hôm nay ", utterance_boundary=True),
        final("seg_004", "chúng ta nói về"),
        final("seg_005", " phiên dịch trực tiếp. "),
    )
    committed = []

    for event in accepted:
        utterance = aggregator.add(event)
        if utterance is not None:
            committed.append(utterance)
    trailing = aggregator.flush()
    if trailing is not None:
        committed.append(trailing)

    assert normalize(" ".join(event.text for event in accepted)) == normalize(
        " ".join(utterance.source_text for utterance in committed)
    )
    committed_ids = [
        segment_id
        for utterance in committed
        for segment_id in utterance.source_segment_ids
    ]
    assert committed_ids == [event.segment_id for event in accepted]
    assert len(committed_ids) == len(set(committed_ids))
