import json
import logging

from app.core.config import Settings


class SequenceClock:
    def __init__(self, *values: float) -> None:
        self._values = iter(values)
        self.calls = 0

    def __call__(self) -> float:
        self.calls += 1
        return next(self._values)


def benchmark_payloads(lines: list[str]) -> list[dict[str, object]]:
    prefix = "STT_BENCHMARK "
    assert all(line.startswith(prefix) for line in lines)
    return [json.loads(line.removeprefix(prefix)) for line in lines]


def test_benchmark_configuration_defaults_off_and_parses_environment(monkeypatch):
    monkeypatch.delenv("STT_BENCHMARK", raising=False)
    assert Settings(_env_file=None).stt_benchmark is False

    monkeypatch.setenv("STT_BENCHMARK", "true")
    assert Settings(_env_file=None).stt_benchmark is True

    monkeypatch.setenv("STT_BENCHMARK", "false")
    assert Settings(_env_file=None).stt_benchmark is False


def test_disabled_benchmark_does_not_touch_clock_or_sink():
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    clock = SequenceClock()
    lines: list[str] = []

    recorder = create_stt_benchmark_recorder(
        enabled=False,
        monotonic=clock,
        sink=lines.append,
    )

    assert recorder is None
    assert clock.calls == 0
    assert lines == []


def test_default_runtime_sink_emits_jsonl_when_root_logging_is_warning(
    monkeypatch,
    capsys,
):
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    root_logger = logging.getLogger()
    benchmark_logger = logging.getLogger("app.benchmark.stt_benchmark")
    monkeypatch.setattr(root_logger, "level", logging.WARNING)
    monkeypatch.setattr(benchmark_logger, "level", logging.NOTSET)
    monkeypatch.setattr(benchmark_logger, "propagate", True)

    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=SequenceClock(1.0, 1.25),
    )
    assert recorder is not None
    recorder.finish("client_disconnect")

    captured = capsys.readouterr()
    lines = captured.out.splitlines()
    assert captured.err == ""
    assert len(lines) == 2
    payloads = benchmark_payloads(lines)
    assert [payload["event"] for payload in payloads] == [
        "session_open",
        "session_summary",
    ]


def test_session_summary_has_first_milestones_counters_and_deterministic_metrics():
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    clock = SequenceClock(
        100.0,
        100.1,
        100.2,
        100.3,
        100.4,
        100.7,
        100.8,
        101.0,
    )
    lines: list[str] = []
    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=clock,
        sink=lines.append,
    )
    assert recorder is not None

    recorder.record_audio_chunk(b"\x00\x00")
    recorder.record_audio_chunk(b"\x00\x00\x00\x00")
    recorder.record_transcript("interim", "seg_001")
    recorder.record_transcript("interim", "seg_001")
    recorder.record_transcript("final", "seg_001")
    recorder.record_transcript("final", "seg_002")
    recorder.record_keepalive()
    recorder.record_keepalive()
    recorder.record_provider_error()
    recorder.record_provider_error()
    recorder.finish("client_stop")
    recorder.finish("internal_error")

    payloads = benchmark_payloads(lines)
    assert [payload["event"] for payload in payloads] == [
        "session_open",
        "first_audio",
        "first_interim",
        "first_final",
        "session_summary",
    ]
    assert all(payload["category"] == "stt_benchmark" for payload in payloads)
    assert all(payload["source"] == "backend" for payload in payloads)

    summary = payloads[-1]
    assert summary["session_opened_at_monotonic_s"] == 100.0
    assert summary["audio_chunk_count"] == 2
    assert summary["audio_byte_count"] == 6
    assert summary["interim_count"] == 2
    assert summary["final_count"] == 2
    assert summary["keepalive_count"] == 2
    assert summary["provider_error_count"] == 2
    assert summary["session_duration_ms"] == 1000.0
    assert summary["first_audio_to_first_interim_ms"] == 200.0
    assert summary["first_audio_to_first_final_ms"] == 600.0
    assert summary["first_interim_to_first_final_ms"] == 400.0
    assert summary["close_reason"] == "client_stop"
    assert clock.calls == 8


def test_summary_uses_null_for_metrics_whose_milestones_never_occurred():
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    lines: list[str] = []
    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=SequenceClock(5.0, 5.25),
        sink=lines.append,
    )
    assert recorder is not None

    recorder.finish("client_disconnect")

    summary = benchmark_payloads(lines)[-1]
    assert summary["first_audio_to_first_interim_ms"] is None
    assert summary["first_audio_to_first_final_ms"] is None
    assert summary["first_interim_to_first_final_ms"] is None
    assert summary["session_duration_ms"] == 250.0


def test_records_never_contain_transcript_audio_or_secret_fields():
    from app.benchmark.stt_benchmark import create_stt_benchmark_recorder

    lines: list[str] = []
    recorder = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=SequenceClock(1.0, 1.1, 1.2, 1.3, 1.4),
        sink=lines.append,
    )
    assert recorder is not None

    recorder.record_audio_chunk(b"\x00\x00\x00\x00")
    recorder.record_transcript("interim", "seg_001")
    recorder.record_transcript("final", "seg_001")
    recorder.record_provider_error()
    recorder.finish("provider_error")

    rendered = "\n".join(lines)
    assert "xin chao secret transcript" not in rendered
    assert "Authorization" not in rendered
    assert "test-deepgram-key" not in rendered
    assert "raw_audio" not in rendered
    assert "audio_bytes" not in rendered
    assert "exception" not in rendered
    assert "header" not in rendered
    assert "auth" not in rendered.lower()
