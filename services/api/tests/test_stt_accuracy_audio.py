import json
from collections import Counter
from pathlib import Path
import wave

import pytest


def write_wav(
    path,
    *,
    channels=1,
    sample_rate_hz=16000,
    sample_width_bytes=2,
    frames=b"\x00\x00" * 160,
):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(sample_width_bytes)
        output.setframerate(sample_rate_hz)
        output.writeframes(frames)


def test_valid_pcm_mono_16khz_16bit_wav_is_accepted(tmp_path):
    from app.benchmark.stt_accuracy_audio import load_wav_audio

    audio_path = tmp_path / "valid.wav"
    frames = b"\x01\x00" * 160
    write_wav(audio_path, frames=frames)

    audio = load_wav_audio(audio_path)

    assert audio.sample_rate_hz == 16000
    assert audio.channels == 1
    assert audio.sample_width_bytes == 2
    assert audio.frame_count == 160
    assert audio.pcm_bytes == frames


@pytest.mark.parametrize(
    ("wav_options", "expected_message"),
    (
        ({"channels": 2}, "mono"),
        ({"sample_rate_hz": 8000}, "16000 Hz"),
        ({"sample_width_bytes": 1}, "16-bit"),
    ),
)
def test_unsupported_wav_contract_is_rejected_cleanly(
    tmp_path,
    wav_options,
    expected_message,
):
    from app.benchmark.stt_accuracy_audio import (
        UnsupportedWavError,
        load_wav_audio,
    )

    audio_path = tmp_path / "unsupported.wav"
    write_wav(audio_path, **wav_options)

    with pytest.raises(UnsupportedWavError, match=expected_message):
        load_wav_audio(audio_path)


def test_manifest_loads_cases_without_requiring_unrecorded_audio(tmp_path):
    from app.benchmark.stt_accuracy_manifest import load_manifest

    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "cases": [
                    {
                        "case_id": "vi_normal_001",
                        "category": "vi_normal",
                        "reference_text": "Xin chào bạn.",
                        "audio_file": "recordings/vi_normal_001.wav",
                    }
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    manifest = load_manifest(manifest_path)

    assert manifest.schema_version == 1
    assert len(manifest.cases) == 1
    assert manifest.cases[0].case_id == "vi_normal_001"
    assert manifest.cases[0].reference_text == "Xin chào bạn."
    assert manifest.cases[0].audio_file == "recordings/vi_normal_001.wav"
    assert manifest.audio_path(manifest.cases[0]) == (
        tmp_path / "recordings" / "vi_normal_001.wav"
    )


def test_manifest_rejects_duplicate_case_ids(tmp_path):
    from app.benchmark.stt_accuracy_manifest import ManifestError, load_manifest

    case = {
        "case_id": "duplicate",
        "category": "vi_short",
        "reference_text": "Xin chào.",
        "audio_file": "recordings/duplicate.wav",
    }
    manifest_path = tmp_path / "manifest.json"
    manifest_path.write_text(
        json.dumps({"schema_version": 1, "cases": [case, case]}),
        encoding="utf-8",
    )

    with pytest.raises(ManifestError, match="Duplicate case_id: duplicate"):
        load_manifest(manifest_path)


def test_starter_manifest_has_24_cases_across_requested_categories():
    from app.benchmark.stt_accuracy_manifest import load_manifest

    manifest_path = (
        Path(__file__).resolve().parents[1]
        / "benchmarks"
        / "stt_accuracy"
        / "starter_manifest.json"
    )

    manifest = load_manifest(manifest_path)

    assert len(manifest.cases) == 24
    assert Counter(case.category for case in manifest.cases) == {
        "vi_normal": 3,
        "vi_short": 3,
        "vi_long": 3,
        "vi_numbers_dates": 3,
        "vi_proper_names": 3,
        "vi_technical_terms": 3,
        "vi_en_mixed": 3,
        "en_phrase": 3,
    }
    assert len({case.case_id for case in manifest.cases}) == 24
    assert all(
        case.audio_file == f"recordings/{case.case_id}.wav"
        for case in manifest.cases
    )
