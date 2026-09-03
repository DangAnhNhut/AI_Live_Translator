import csv
import json

import pytest

from app.benchmark.stt_accuracy import AccuracyCaseResult, EditCounts


def successful_result(
    *,
    case_id,
    category,
    wer,
    cer,
    word_edits,
    character_edits,
    first_interim_ms,
    final_ms,
):
    return AccuracyCaseResult(
        case_id=case_id,
        category=category,
        provider="deepgram",
        model="nova-3",
        configured_language="vi",
        raw_reference="Tiếng Việt",
        raw_hypothesis="tiếng việt",
        normalized_reference="tiếng việt",
        normalized_hypothesis="tiếng việt",
        wer=wer,
        cer=cer,
        word_edits=word_edits,
        character_edits=character_edits,
        first_interim_ms=first_interim_ms,
        final_ms=final_ms,
        provider_error=None,
    )


def failed_result():
    return AccuracyCaseResult(
        case_id="en_phrase_001",
        category="en_phrase",
        provider="deepgram",
        model="nova-3",
        configured_language="vi",
        raw_reference="Hello world",
        raw_hypothesis="",
        normalized_reference="hello world",
        normalized_hypothesis="",
        wer=None,
        cer=None,
        word_edits=None,
        character_edits=None,
        first_interim_ms=None,
        final_ms=None,
        provider_error="no_usable_final_transcript",
    )


def sample_results():
    return (
        successful_result(
            case_id="vi_normal_001",
            category="vi_normal",
            wer=0.5,
            cer=0.25,
            word_edits=EditCounts(1, 0, 0, 2),
            character_edits=EditCounts(1, 0, 0, 4),
            first_interim_ms=100.0,
            final_ms=500.0,
        ),
        successful_result(
            case_id="vi_normal_002",
            category="vi_normal",
            wer=0.0,
            cer=0.0,
            word_edits=EditCounts(0, 0, 0, 2),
            character_edits=EditCounts(0, 0, 0, 4),
            first_interim_ms=200.0,
            final_ms=600.0,
        ),
        failed_result(),
    )


def test_report_aggregation_has_macro_global_latency_and_category_metrics():
    from app.benchmark.stt_accuracy_report import aggregate_results

    summary = aggregate_results(sample_results())

    overall = summary["overall"]
    assert overall["case_count"] == 3
    assert overall["successful_cases"] == 2
    assert overall["failed_cases"] == 1
    assert overall["macro_wer"] == pytest.approx(0.25)
    assert overall["macro_cer"] == pytest.approx(0.125)
    assert overall["global_wer"] == pytest.approx(0.25)
    assert overall["global_cer"] == pytest.approx(0.125)
    assert overall["first_interim_ms"]["count"] == 2
    assert overall["first_interim_ms"]["mean"] == 150.0
    assert overall["final_ms"]["mean"] == 550.0

    vi_normal = summary["categories"]["vi_normal"]
    assert vi_normal == {
        "case_count": 2,
        "successful_cases": 2,
        "failure_count": 0,
        "mean_wer": 0.25,
        "mean_cer": 0.125,
    }
    english = summary["categories"]["en_phrase"]
    assert english["case_count"] == 1
    assert english["failure_count"] == 1
    assert english["mean_wer"] is None
    assert english["mean_cer"] is None


def test_report_aggregation_handles_no_cases_without_division_by_zero():
    from app.benchmark.stt_accuracy_report import aggregate_results

    summary = aggregate_results(())

    assert summary["overall"] == {
        "case_count": 0,
        "successful_cases": 0,
        "failed_cases": 0,
        "macro_wer": None,
        "macro_cer": None,
        "global_wer": None,
        "global_cer": None,
        "first_interim_ms": {
            "count": 0,
            "mean": None,
            "min": None,
            "median": None,
            "p95": None,
            "max": None,
        },
        "final_ms": {
            "count": 0,
            "mean": None,
            "min": None,
            "median": None,
            "p95": None,
            "max": None,
        },
    }
    assert summary["categories"] == {}


def test_json_and_csv_reports_preserve_raw_text_and_flatten_edit_counts(tmp_path):
    from app.benchmark.stt_accuracy_report import write_reports

    results = sample_results()
    paths = write_reports(tmp_path, results)

    json_payload = json.loads(paths.json_path.read_text(encoding="utf-8"))
    assert json_payload["schema_version"] == 1
    assert json_payload["scoring_policy"]["failed_cases"] == (
        "counted as failures and excluded from accuracy and latency aggregates"
    )
    assert json_payload["results"][0]["raw_reference"] == "Tiếng Việt"
    assert json_payload["results"][0]["word_edits"] == {
        "substitutions": 1,
        "deletions": 0,
        "insertions": 0,
        "reference_count": 2,
    }

    with paths.csv_path.open(encoding="utf-8", newline="") as csv_file:
        rows = list(csv.DictReader(csv_file))
    assert len(rows) == 3
    assert rows[0]["raw_reference"] == "Tiếng Việt"
    assert rows[0]["word_substitutions"] == "1"
    assert rows[2]["provider_error"] == "no_usable_final_transcript"
    assert rows[2]["wer"] == ""
