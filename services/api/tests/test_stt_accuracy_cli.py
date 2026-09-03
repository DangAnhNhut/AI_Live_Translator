import pytest

from app.benchmark.stt_accuracy_manifest import (
    BenchmarkCase,
    BenchmarkManifest,
)


def manifest(tmp_path):
    return BenchmarkManifest(
        path=tmp_path / "manifest.json",
        schema_version=1,
        cases=(
            BenchmarkCase(
                "vi_normal_001",
                "vi_normal",
                "Xin chào bạn.",
                "recordings/vi_normal_001.wav",
            ),
            BenchmarkCase(
                "vi_short_001",
                "vi_short",
                "Chào bạn.",
                "recordings/vi_short_001.wav",
            ),
            BenchmarkCase(
                "vi_short_002",
                "vi_short",
                "Cảm ơn.",
                "recordings/vi_short_002.wav",
            ),
        ),
    )


def test_case_filters_support_category_case_id_and_intersection(tmp_path):
    from app.benchmark.stt_accuracy_manifest import select_cases

    dataset = manifest(tmp_path)

    assert [case.case_id for case in select_cases(dataset, categories={"vi_short"})] == [
        "vi_short_001",
        "vi_short_002",
    ]
    assert [
        case.case_id
        for case in select_cases(dataset, case_ids={"vi_normal_001"})
    ] == ["vi_normal_001"]
    assert [
        case.case_id
        for case in select_cases(
            dataset,
            categories={"vi_short"},
            case_ids={"vi_short_002", "vi_normal_001"},
        )
    ] == ["vi_short_002"]


def test_cli_parser_has_manifest_output_and_filters_but_no_api_key_option():
    from scripts.stt_accuracy_benchmark import build_parser

    parser = build_parser()
    args = parser.parse_args(
        [
            "--manifest",
            "benchmark.json",
            "--output-dir",
            "results",
            "--category",
            "vi_short",
            "--case-id",
            "vi_short_001",
        ]
    )

    assert str(args.manifest) == "benchmark.json"
    assert str(args.output_dir) == "results"
    assert args.categories == ["vi_short"]
    assert args.case_ids == ["vi_short_001"]
    with pytest.raises(SystemExit):
        parser.parse_args(
            [
                "--manifest",
                "benchmark.json",
                "--output-dir",
                "results",
                "--api-key",
                "secret",
            ]
        )


def test_terminal_summary_distinguishes_macro_and_global_rates():
    from scripts.stt_accuracy_benchmark import format_terminal_summary

    summary = {
        "overall": {
            "case_count": 3,
            "successful_cases": 2,
            "failed_cases": 1,
            "macro_wer": 0.25,
            "macro_cer": 0.125,
            "global_wer": 0.2,
            "global_cer": 0.1,
            "first_interim_ms": {"median": 150.0},
            "final_ms": {"median": 550.0},
        },
        "categories": {},
    }

    rendered = format_terminal_summary(summary)

    assert "cases=3 successful=2 failed=1" in rendered
    assert "macro WER=0.2500 CER=0.1250" in rendered
    assert "global WER=0.2000 CER=0.1000" in rendered
    assert "median first interim=150.0 ms final=550.0 ms" in rendered
