"""Manifest model and loader for reusable STT accuracy datasets."""

from dataclasses import dataclass
import json
from pathlib import Path


class ManifestError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class BenchmarkCase:
    case_id: str
    category: str
    reference_text: str
    audio_file: str


@dataclass(frozen=True, slots=True)
class BenchmarkManifest:
    path: Path
    schema_version: int
    cases: tuple[BenchmarkCase, ...]

    def audio_path(self, case: BenchmarkCase) -> Path:
        return self.path.parent / Path(case.audio_file)


def load_manifest(path: Path) -> BenchmarkManifest:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"Unable to read benchmark manifest: {error}") from error
    if not isinstance(payload, dict):
        raise ManifestError("Benchmark manifest must be a JSON object")
    schema_version = payload.get("schema_version")
    if schema_version != 1:
        raise ManifestError("Benchmark manifest schema_version must be 1")
    raw_cases = payload.get("cases")
    if not isinstance(raw_cases, list):
        raise ManifestError("Benchmark manifest cases must be a list")

    cases: list[BenchmarkCase] = []
    seen_case_ids: set[str] = set()
    for index, raw_case in enumerate(raw_cases):
        if not isinstance(raw_case, dict):
            raise ManifestError(f"Case at index {index} must be an object")
        values: dict[str, str] = {}
        for field in ("case_id", "category", "reference_text", "audio_file"):
            value = raw_case.get(field)
            if not isinstance(value, str) or not value.strip():
                raise ManifestError(
                    f"Case at index {index} requires non-empty {field}"
                )
            values[field] = value.strip()
        case_id = values["case_id"]
        if case_id in seen_case_ids:
            raise ManifestError(f"Duplicate case_id: {case_id}")
        seen_case_ids.add(case_id)
        cases.append(BenchmarkCase(**values))

    return BenchmarkManifest(
        path=path,
        schema_version=schema_version,
        cases=tuple(cases),
    )


def select_cases(
    manifest: BenchmarkManifest,
    *,
    categories: set[str] | None = None,
    case_ids: set[str] | None = None,
) -> tuple[BenchmarkCase, ...]:
    return tuple(
        case
        for case in manifest.cases
        if (not categories or case.category in categories)
        and (not case_ids or case.case_id in case_ids)
    )
