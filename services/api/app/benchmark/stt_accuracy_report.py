"""Aggregate and serialize provider-neutral STT accuracy results."""

import csv
from dataclasses import dataclass
import json
import math
from pathlib import Path
from statistics import median

from app.benchmark.stt_accuracy import AccuracyCaseResult, EditCounts


@dataclass(frozen=True, slots=True)
class ReportPaths:
    json_path: Path
    csv_path: Path


def aggregate_results(
    results: tuple[AccuracyCaseResult, ...] | list[AccuracyCaseResult],
) -> dict[str, object]:
    successful = [result for result in results if result.provider_error is None]
    overall = {
        "case_count": len(results),
        "successful_cases": len(successful),
        "failed_cases": len(results) - len(successful),
        "macro_wer": _mean([result.wer for result in successful]),
        "macro_cer": _mean([result.cer for result in successful]),
        "global_wer": _global_rate(successful, "word_edits"),
        "global_cer": _global_rate(successful, "character_edits"),
        "first_interim_ms": _latency_summary(
            [result.first_interim_ms for result in successful]
        ),
        "final_ms": _latency_summary(
            [result.final_ms for result in successful]
        ),
    }
    categories: dict[str, dict[str, int | float | None]] = {}
    for category in sorted({result.category for result in results}):
        category_results = [
            result for result in results if result.category == category
        ]
        category_successes = [
            result
            for result in category_results
            if result.provider_error is None
        ]
        categories[category] = {
            "case_count": len(category_results),
            "successful_cases": len(category_successes),
            "failure_count": len(category_results) - len(category_successes),
            "mean_wer": _mean([result.wer for result in category_successes]),
            "mean_cer": _mean([result.cer for result in category_successes]),
        }
    return {"overall": overall, "categories": categories}


def write_reports(
    output_dir: Path,
    results: tuple[AccuracyCaseResult, ...] | list[AccuracyCaseResult],
) -> ReportPaths:
    output_dir.mkdir(parents=True, exist_ok=True)
    json_path = output_dir / "stt_accuracy_results.json"
    csv_path = output_dir / "stt_accuracy_results.csv"
    result_rows = [_result_to_dict(result) for result in results]
    payload = {
        "schema_version": 1,
        "scoring_policy": {
            "normalization": (
                "Unicode NFC, lowercase, Unicode punctuation replaced by spaces, "
                "and whitespace collapsed; no translation or vocabulary correction"
            ),
            "character_units": "Unicode code points including normalized spaces",
            "empty_reference": "rates divide edit errors by max(1, reference_count)",
            "failed_cases": (
                "counted as failures and excluded from accuracy and latency aggregates"
            ),
            "macro": "arithmetic mean of successful per-case rates",
            "global": (
                "sum of successful-case edit errors divided by the summed "
                "reference count"
            ),
        },
        "summary": aggregate_results(results),
        "results": result_rows,
    }
    json_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    fieldnames = [
        "case_id",
        "category",
        "provider",
        "model",
        "configured_language",
        "raw_reference",
        "raw_hypothesis",
        "normalized_reference",
        "normalized_hypothesis",
        "wer",
        "cer",
        "word_substitutions",
        "word_deletions",
        "word_insertions",
        "word_reference_count",
        "character_substitutions",
        "character_deletions",
        "character_insertions",
        "character_reference_count",
        "first_interim_ms",
        "final_ms",
        "provider_error",
    ]
    with csv_path.open("w", encoding="utf-8", newline="") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=fieldnames)
        writer.writeheader()
        for result in results:
            writer.writerow(_result_to_csv_row(result))
    return ReportPaths(json_path=json_path, csv_path=csv_path)


def _mean(values: list[float | None]) -> float | None:
    present = [value for value in values if value is not None]
    if not present:
        return None
    return sum(present) / len(present)


def _global_rate(
    results: list[AccuracyCaseResult],
    attribute: str,
) -> float | None:
    if not results:
        return None
    edits = [getattr(result, attribute) for result in results]
    present: list[EditCounts] = [edit for edit in edits if edit is not None]
    if not present:
        return None
    errors = sum(edit.errors for edit in present)
    reference_count = sum(edit.reference_count for edit in present)
    return errors / max(1, reference_count)


def _latency_summary(values: list[float | None]) -> dict[str, int | float | None]:
    present = sorted(value for value in values if value is not None)
    if not present:
        return {
            "count": 0,
            "mean": None,
            "min": None,
            "median": None,
            "p95": None,
            "max": None,
        }
    p95_index = math.ceil(0.95 * len(present)) - 1
    return {
        "count": len(present),
        "mean": sum(present) / len(present),
        "min": present[0],
        "median": median(present),
        "p95": present[p95_index],
        "max": present[-1],
    }


def _edit_to_dict(edits: EditCounts | None) -> dict[str, int] | None:
    if edits is None:
        return None
    return {
        "substitutions": edits.substitutions,
        "deletions": edits.deletions,
        "insertions": edits.insertions,
        "reference_count": edits.reference_count,
    }


def _result_to_dict(result: AccuracyCaseResult) -> dict[str, object]:
    return {
        "case_id": result.case_id,
        "category": result.category,
        "provider": result.provider,
        "model": result.model,
        "configured_language": result.configured_language,
        "raw_reference": result.raw_reference,
        "raw_hypothesis": result.raw_hypothesis,
        "normalized_reference": result.normalized_reference,
        "normalized_hypothesis": result.normalized_hypothesis,
        "wer": result.wer,
        "cer": result.cer,
        "word_edits": _edit_to_dict(result.word_edits),
        "character_edits": _edit_to_dict(result.character_edits),
        "first_interim_ms": result.first_interim_ms,
        "final_ms": result.final_ms,
        "provider_error": result.provider_error,
    }


def _result_to_csv_row(result: AccuracyCaseResult) -> dict[str, object]:
    row = _result_to_dict(result)
    row.pop("word_edits")
    row.pop("character_edits")
    word_edits = result.word_edits
    character_edits = result.character_edits
    row.update(
        {
            "word_substitutions": _edit_value(word_edits, "substitutions"),
            "word_deletions": _edit_value(word_edits, "deletions"),
            "word_insertions": _edit_value(word_edits, "insertions"),
            "word_reference_count": _edit_value(word_edits, "reference_count"),
            "character_substitutions": _edit_value(
                character_edits, "substitutions"
            ),
            "character_deletions": _edit_value(character_edits, "deletions"),
            "character_insertions": _edit_value(character_edits, "insertions"),
            "character_reference_count": _edit_value(
                character_edits, "reference_count"
            ),
        }
    )
    return row


def _edit_value(edits: EditCounts | None, attribute: str) -> int | str:
    return "" if edits is None else getattr(edits, attribute)
