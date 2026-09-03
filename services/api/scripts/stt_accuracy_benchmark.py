"""CLI for provider-neutral offline STT accuracy benchmarks."""

import argparse
import asyncio
from pathlib import Path

from app.ai.stt import get_stt_provider_factory
from app.benchmark.stt_accuracy import AccuracyCaseResult
from app.benchmark.stt_accuracy_manifest import (
    BenchmarkCase,
    ManifestError,
    load_manifest,
    select_cases,
)
from app.benchmark.stt_accuracy_report import (
    ReportPaths,
    aggregate_results,
    write_reports,
)
from app.benchmark.stt_accuracy_runner import run_benchmark_case
from app.core.config import settings


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Stream a reusable WAV/reference dataset through the configured "
            "Deepgram adapter and write accuracy reports."
        )
    )
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument(
        "--category",
        dest="categories",
        action="append",
        help="Limit to a category; may be repeated.",
    )
    parser.add_argument(
        "--case-id",
        dest="case_ids",
        action="append",
        help="Limit to a case ID; may be repeated.",
    )
    return parser


async def run_selected_cases(
    cases: tuple[BenchmarkCase, ...],
    *,
    manifest_path: Path,
    output_dir: Path,
) -> tuple[tuple[AccuracyCaseResult, ...], ReportPaths]:
    provider_factory = get_stt_provider_factory()
    results: list[AccuracyCaseResult] = []
    for index, case in enumerate(cases, start=1):
        print(f"[{index}/{len(cases)}] {case.case_id}", flush=True)
        result = await run_benchmark_case(
            case,
            manifest_path.parent / Path(case.audio_file),
            provider_factory=provider_factory,
            provider="deepgram",
            model=settings.deepgram_model,
            configured_language=settings.deepgram_language,
        )
        results.append(result)
        status = "ok" if result.provider_error is None else "failed"
        print(f"  {status}", flush=True)
    frozen_results = tuple(results)
    paths = write_reports(output_dir, frozen_results)
    print(format_terminal_summary(aggregate_results(frozen_results)), flush=True)
    print(f"JSON: {paths.json_path}", flush=True)
    print(f"CSV: {paths.csv_path}", flush=True)
    return frozen_results, paths


def format_terminal_summary(summary: dict[str, object]) -> str:
    overall = summary["overall"]
    assert isinstance(overall, dict)
    first_interim = overall["first_interim_ms"]
    final = overall["final_ms"]
    assert isinstance(first_interim, dict)
    assert isinstance(final, dict)
    return "\n".join(
        (
            "STT accuracy summary",
            (
                f"cases={overall['case_count']} "
                f"successful={overall['successful_cases']} "
                f"failed={overall['failed_cases']}"
            ),
            (
                "macro "
                f"WER={_format_rate(overall['macro_wer'])} "
                f"CER={_format_rate(overall['macro_cer'])}"
            ),
            (
                "global "
                f"WER={_format_rate(overall['global_wer'])} "
                f"CER={_format_rate(overall['global_cer'])}"
            ),
            (
                "median first interim="
                f"{_format_latency(first_interim['median'])} "
                f"final={_format_latency(final['median'])}"
            ),
        )
    )


def _format_rate(value: object) -> str:
    return "n/a" if value is None else f"{float(value):.4f}"


def _format_latency(value: object) -> str:
    return "n/a" if value is None else f"{float(value):.1f} ms"


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    if settings.stt_provider != "deepgram":
        parser.error("STT_PROVIDER must be deepgram for D2.1")
    api_key = settings.deepgram_api_key
    if api_key is None or not api_key.get_secret_value().strip():
        parser.error("DEEPGRAM_API_KEY must be configured in the environment")
    try:
        manifest = load_manifest(args.manifest)
    except ManifestError as error:
        parser.error(str(error))
    cases = select_cases(
        manifest,
        categories=set(args.categories or ()),
        case_ids=set(args.case_ids or ()),
    )
    if not cases:
        parser.error("No benchmark cases matched the requested filters")
    asyncio.run(
        run_selected_cases(
            cases,
            manifest_path=manifest.path,
            output_dir=args.output_dir,
        )
    )


if __name__ == "__main__":
    main()
