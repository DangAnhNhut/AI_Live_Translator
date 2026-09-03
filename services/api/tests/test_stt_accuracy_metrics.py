import pytest


def test_normalization_preserves_vietnamese_diacritics_and_lowercases():
    from app.benchmark.stt_accuracy import normalize_for_scoring

    assert normalize_for_scoring("  XIN CHÀO, Việt Nam!  ") == "xin chào việt nam"


def test_normalization_replaces_unicode_punctuation_with_word_boundaries():
    from app.benchmark.stt_accuracy import normalize_for_scoring

    assert (
        normalize_for_scoring("Flutter—FastAPI... WebSocket?")
        == "flutter fastapi websocket"
    )


def test_normalization_collapses_whitespace_and_preserves_mixed_language():
    from app.benchmark.stt_accuracy import normalize_for_scoring

    text = "Tôi\tđang dùng\nFlutter và BACKEND bằng FastAPI."
    assert normalize_for_scoring(text) == (
        "tôi đang dùng flutter và backend bằng fastapi"
    )


def test_wer_exact_match_has_no_edits():
    from app.benchmark.stt_accuracy import score_transcript

    score = score_transcript("xin chào", "xin chào")

    assert score.wer == 0.0
    assert score.word_edits.substitutions == 0
    assert score.word_edits.deletions == 0
    assert score.word_edits.insertions == 0
    assert score.word_edits.reference_count == 2


@pytest.mark.parametrize(
    ("reference", "hypothesis", "substitutions", "deletions", "insertions", "wer"),
    (
        ("xin chào bạn", "xin chào tôi", 1, 0, 0, 1 / 3),
        ("xin chào", "xin chào bạn", 0, 0, 1, 1 / 2),
        ("xin chào bạn", "xin chào", 0, 1, 0, 1 / 3),
        ("xin chào", "", 0, 2, 0, 1.0),
    ),
)
def test_wer_reports_each_edit_type(
    reference,
    hypothesis,
    substitutions,
    deletions,
    insertions,
    wer,
):
    from app.benchmark.stt_accuracy import score_transcript

    score = score_transcript(reference, hypothesis)

    assert score.wer == pytest.approx(wer)
    assert score.word_edits.substitutions == substitutions
    assert score.word_edits.deletions == deletions
    assert score.word_edits.insertions == insertions


def test_wer_empty_reference_uses_one_as_explicit_denominator():
    from app.benchmark.stt_accuracy import score_transcript

    empty = score_transcript("", "")
    inserted = score_transcript("", "xin chào")

    assert empty.wer == 0.0
    assert empty.word_edits.reference_count == 0
    assert inserted.wer == 2.0
    assert inserted.word_edits.insertions == 2
    assert inserted.word_edits.reference_count == 0


def test_cer_treats_vietnamese_unicode_code_points_as_characters():
    from app.benchmark.stt_accuracy import score_transcript

    score = score_transcript("Tiếng Việt", "Tiếng Việt")

    assert score.cer == 0.0
    assert score.character_edits.reference_count == len("tiếng việt")


@pytest.mark.parametrize(
    ("reference", "hypothesis", "substitutions", "deletions", "insertions"),
    (
        ("bạn", "bàn", 1, 0, 0),
        ("bạn", "bn", 0, 1, 0),
        ("bạn", "bạạn", 0, 0, 1),
    ),
)
def test_cer_reports_each_edit_type(
    reference,
    hypothesis,
    substitutions,
    deletions,
    insertions,
):
    from app.benchmark.stt_accuracy import score_transcript

    score = score_transcript(reference, hypothesis)

    assert score.character_edits.substitutions == substitutions
    assert score.character_edits.deletions == deletions
    assert score.character_edits.insertions == insertions
    assert score.cer == pytest.approx(1 / 3)


def test_cer_empty_cases_follow_the_same_explicit_policy_as_wer():
    from app.benchmark.stt_accuracy import score_transcript

    empty = score_transcript("", "")
    inserted = score_transcript("", "ạ")

    assert empty.cer == 0.0
    assert inserted.cer == 1.0
    assert inserted.character_edits.insertions == 1
    assert inserted.character_edits.reference_count == 0
