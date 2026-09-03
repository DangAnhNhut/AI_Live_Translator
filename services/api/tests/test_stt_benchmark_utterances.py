import asyncio
import json

from app.ai.stt import SttTranscript
from app.benchmark.stt_benchmark import create_stt_benchmark_recorder
from app.realtime.stt_protocol import SttStart, SttStateMachine
from app.realtime.stt_socket import _run_stream
from tests.fakes.stt import FakeSttProviderStream


class ManualClock:
    def __init__(self, value: float = 0.0) -> None:
        self.value = value
        self.calls = 0

    def __call__(self) -> float:
        self.calls += 1
        return self.value

    def set(self, value: float) -> None:
        self.value = value


def pcm(sample: int, *, samples: int = 1600) -> bytes:
    return sample.to_bytes(2, byteorder="little", signed=True) * samples


def payloads(lines: list[str], event: str | None = None) -> list[dict[str, object]]:
    decoded = [
        json.loads(line.removeprefix("STT_BENCHMARK ")) for line in lines
    ]
    if event is None:
        return decoded
    return [payload for payload in decoded if payload["event"] == event]


def recorder(clock: ManualClock, lines: list[str], **kwargs):
    result = create_stt_benchmark_recorder(
        enabled=True,
        monotonic=clock,
        sink=lines.append,
        **kwargs,
    )
    assert result is not None
    return result


def test_disabled_benchmark_does_no_rms_work_or_output():
    clock = ManualClock()
    lines: list[str] = []
    rms_calls = 0

    def rms_spy(_pcm: bytes) -> float:
        nonlocal rms_calls
        rms_calls += 1
        return 2000.0

    result = create_stt_benchmark_recorder(
        enabled=False,
        monotonic=clock,
        sink=lines.append,
        rms_calculator=rms_spy,
    )

    assert result is None
    assert rms_calls == 0
    assert clock.calls == 0
    assert lines == []


def test_silence_then_speech_detects_one_onset_and_continuous_speech_does_not_duplicate():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    for timestamp in (0.5, 0.6, 0.7):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(2000))

    onsets = payloads(lines, "utterance_onset")
    assert [item["backend_utterance_id"] for item in onsets] == [1]


def test_short_hesitation_does_not_split_but_sufficient_silence_creates_next_onset():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(0.5)
    benchmark.record_audio_chunk(pcm(2000))
    for timestamp in (0.6, 0.7):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(0.8)
    benchmark.record_audio_chunk(pcm(2000))
    for timestamp in (0.9, 1.0, 1.1, 1.2):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(1.3)
    benchmark.record_audio_chunk(pcm(2000))

    onsets = payloads(lines, "utterance_onset")
    assert [item["backend_utterance_id"] for item in onsets] == [1, 2]


def test_no_pcm_pause_gap_rearms_without_creating_fake_audio_event():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(0.5)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.0)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.2)
    benchmark.record_transcript("final", "seg_after_pause")

    assert len(payloads(lines, "first_audio")) == 1
    onsets = payloads(lines, "utterance_onset")
    assert [item["backend_utterance_id"] for item in onsets] == [1, 2]
    assert payloads(lines, "utterance_complete")[0][
        "backend_utterance_id"
    ] == 2


def test_first_interim_is_captured_once_and_final_emits_complete_metrics():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(1.0)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.02)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.10)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.62)
    benchmark.record_transcript("interim", "seg_001")
    clock.set(2.0)
    benchmark.record_transcript("interim", "seg_001")
    clock.set(3.10)
    benchmark.record_transcript("final", "seg_001")

    first_interims = payloads(lines, "utterance_first_interim")
    assert len(first_interims) == 1
    assert first_interims[0] == {
        **{
            key: first_interims[0][key]
            for key in ("category", "source", "event", "session_id")
        },
        "backend_utterance_id": 1,
        "speech_to_first_interim_ms": 620.0,
    }
    complete = payloads(lines, "utterance_complete")
    assert len(complete) == 1
    assert complete[0]["backend_utterance_id"] == 1
    assert complete[0]["speech_to_first_interim_ms"] == 620.0
    assert complete[0]["speech_to_first_final_ms"] == 2100.0
    assert complete[0]["interim_to_final_ms"] == 1480.0
    assert complete[0]["audio_chunk_count"] == 3
    assert complete[0]["audio_byte_count"] == len(pcm(2000)) * 3
    assert complete[0]["max_audio_chunk_gap_ms"] == 80.0


def test_final_only_result_is_safe_and_orphan_final_does_not_corrupt_next_utterance():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    clock.set(0.1)
    benchmark.record_transcript("final", "orphan")
    for timestamp in (0.2, 0.3, 0.4, 0.5):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(1.0)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.5)
    benchmark.record_transcript("final", "seg_001")

    complete = payloads(lines, "utterance_complete")
    assert len(complete) == 1
    assert complete[0]["backend_utterance_id"] == 1
    assert complete[0]["speech_to_first_interim_ms"] is None
    assert complete[0]["speech_to_first_final_ms"] == 500.0
    assert complete[0]["interim_to_final_ms"] is None


def test_audio_gap_summary_and_per_utterance_max_are_deterministic():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    for timestamp in (1.0, 1.05, 1.15, 1.35):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.5)
    benchmark.record_transcript("final", "seg_001")
    clock.set(1.75)
    benchmark.record_audio_chunk(pcm(0))
    clock.set(3.0)
    benchmark.finish("client_stop")

    summary = payloads(lines, "session_summary")[0]
    assert summary["audio_chunk_gap_ms"] == {
        "count": 8,
        "min": 50.0,
        "median": 100.0,
        "p95": 600.0,
        "max": 600.0,
    }
    assert payloads(lines, "utterance_complete")[0][
        "max_audio_chunk_gap_ms"
    ] == 200.0


def test_reconnect_uses_a_fresh_recorder_and_cannot_attach_to_stale_utterance():
    first_clock = ManualClock()
    first_lines: list[str] = []
    first = recorder(first_clock, first_lines)
    for timestamp in (0.1, 0.2, 0.3, 0.4):
        first_clock.set(timestamp)
        first.record_audio_chunk(pcm(0))
    first_clock.set(0.5)
    first.record_audio_chunk(pcm(2000))
    first_clock.set(0.6)
    first.finish("client_disconnect")

    second_clock = ManualClock(10.0)
    second_lines: list[str] = []
    second = recorder(second_clock, second_lines)
    for timestamp in (10.1, 10.2, 10.3, 10.4):
        second_clock.set(timestamp)
        second.record_audio_chunk(pcm(0))
    second_clock.set(10.5)
    second.record_audio_chunk(pcm(2000))
    second_clock.set(11.0)
    second.record_transcript("final", "seg_001")

    complete = payloads(second_lines, "utterance_complete")
    assert len(complete) == 1
    assert complete[0]["backend_utterance_id"] == 1
    assert complete[0]["speech_to_first_final_ms"] == 500.0


def test_stop_with_incomplete_utterance_is_bounded_and_summary_is_exactly_once():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines, max_pending_utterances=2)

    for timestamp in (0.1, 0.2, 0.3, 0.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(0.5)
    benchmark.record_audio_chunk(pcm(2000))
    clock.set(0.5)
    benchmark.finish("client_stop")
    clock.set(0.6)
    benchmark.finish("internal_error")

    summaries = payloads(lines, "session_summary")
    assert len(summaries) == 1
    assert summaries[0]["backend_utterance_count"] == 1
    assert summaries[0]["speech_to_first_interim_ms"]["count"] == 0
    assert summaries[0]["speech_to_first_final_ms"]["count"] == 0


def test_summary_percentiles_use_bounded_nearest_rank_samples():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines, max_completed_samples=4)

    clock.set(0.0)
    benchmark.record_audio_chunk(pcm(2000))
    for gap in (0.01, 0.02, 0.03, 0.04, 0.10):
        clock.set(clock.value + gap)
        benchmark.record_audio_chunk(pcm(2000))
    clock.set(1.0)
    benchmark.finish("client_stop")

    stats = payloads(lines, "session_summary")[0]["audio_chunk_gap_ms"]
    assert stats == {
        "count": 4,
        "min": 20.0,
        "median": 35.0,
        "p95": 100.0,
        "max": 100.0,
    }


def test_utterance_summary_statistics_are_deterministic():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    timings = (
        (1.0, 0.1, 0.4),
        (3.0, 0.2, 0.6),
        (5.0, 0.3, 0.8),
        (7.0, 0.4, 1.0),
    )
    for index, (onset, interim_delay, final_delay) in enumerate(timings, 1):
        for timestamp in (onset - 0.7, onset - 0.6, onset - 0.5, onset - 0.4):
            clock.set(timestamp)
            benchmark.record_audio_chunk(pcm(0))
        clock.set(onset)
        benchmark.record_audio_chunk(pcm(2000))
        clock.set(onset + interim_delay)
        benchmark.record_transcript("interim", f"seg_{index}")
        clock.set(onset + final_delay)
        benchmark.record_transcript("final", f"seg_{index}")
    clock.set(9.0)
    benchmark.finish("client_stop")

    summary = payloads(lines, "session_summary")[0]
    assert summary["backend_utterance_count"] == 4
    assert summary["speech_to_first_interim_ms"] == {
        "count": 4,
        "min": 100.0,
        "median": 250.0,
        "p95": 400.0,
        "max": 400.0,
    }
    assert summary["speech_to_first_final_ms"] == {
        "count": 4,
        "min": 400.0,
        "median": 700.0,
        "p95": 1000.0,
        "max": 1000.0,
    }
    assert summary["interim_to_final_ms"] == {
        "count": 4,
        "min": 300.0,
        "median": 450.0,
        "p95": 600.0,
        "max": 600.0,
    }


def test_evicted_segment_result_is_not_reassigned_to_a_newer_utterance():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines, max_pending_utterances=2)

    for index, onset in enumerate((1.0, 2.0, 3.0), 1):
        for timestamp in (onset - 0.4, onset - 0.3, onset - 0.2, onset - 0.1):
            clock.set(timestamp)
            benchmark.record_audio_chunk(pcm(0))
        clock.set(onset)
        benchmark.record_audio_chunk(pcm(2000))
        if index < 3:
            clock.set(onset + 0.1)
            benchmark.record_transcript("interim", f"seg_{index}")

    clock.set(3.2)
    benchmark.record_transcript("final", "seg_1")

    assert payloads(lines, "utterance_complete") == []

    clock.set(3.3)
    benchmark.record_transcript("final", "seg_2")
    clock.set(3.4)
    benchmark.record_transcript("final", "seg_3")
    assert [
        item["backend_utterance_id"]
        for item in payloads(lines, "utterance_complete")
    ] == [2, 3]


def test_delayed_result_is_not_confidently_attached_after_new_onset():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for onset in (1.0, 2.0):
        for timestamp in (onset - 0.4, onset - 0.3, onset - 0.2, onset - 0.1):
            clock.set(timestamp)
            benchmark.record_audio_chunk(pcm(0))
        clock.set(onset)
        benchmark.record_audio_chunk(pcm(2000))

    clock.set(2.1)
    benchmark.record_transcript("interim", "delayed_segment")
    clock.set(2.2)
    benchmark.record_transcript("final", "delayed_segment")

    assert payloads(lines, "utterance_first_interim") == []
    assert payloads(lines, "utterance_complete") == []

    clock.set(2.3)
    benchmark.record_transcript("interim", "current_segment")
    clock.set(2.4)
    benchmark.record_transcript("final", "current_segment")

    complete = payloads(lines, "utterance_complete")
    assert len(complete) == 1
    assert complete[0]["backend_utterance_id"] == 2
    assert complete[0]["speech_to_first_interim_ms"] == 300.0
    assert complete[0]["speech_to_first_final_ms"] == 400.0


def test_explicit_silence_keeps_delayed_result_ambiguous_after_long_gap():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)

    for timestamp in (0.6, 0.7, 0.8, 0.9):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(1.0)
    benchmark.record_audio_chunk(pcm(2000))
    for timestamp in (1.1, 1.2, 1.3, 1.4):
        clock.set(timestamp)
        benchmark.record_audio_chunk(pcm(0))
    clock.set(2.0)
    benchmark.record_audio_chunk(pcm(2000))

    clock.set(2.1)
    benchmark.record_transcript("final", "delayed_segment")
    assert payloads(lines, "utterance_complete") == []

    clock.set(2.2)
    benchmark.record_transcript("final", "current_segment")
    complete = payloads(lines, "utterance_complete")
    assert len(complete) == 1
    assert complete[0]["backend_utterance_id"] == 2
    assert complete[0]["speech_to_first_final_ms"] == 200.0


class IdentityBenchmarkObserver:
    def __init__(self) -> None:
        self.audio_chunks: list[bytes] = []

    def record_audio_chunk(self, chunk: bytes) -> None:
        self.audio_chunks.append(chunk)

    def record_transcript(self, kind: str, segment_id: str) -> None:
        return None

    def record_keepalive(self) -> None:
        return None

    def record_provider_error(self) -> None:
        return None

    def finish(self, close_reason: str) -> None:
        return None


class AudioThenStopWebSocket:
    def __init__(self, chunk: bytes) -> None:
        self._incoming: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self._chunk = chunk
        self.sent: list[dict[str, object]] = []

    async def receive(self):
        return await self._incoming.get()

    async def send_json(self, event):
        self.sent.append(event)
        if event.get("type") == "stt.ready":
            await self._incoming.put(
                {"type": "websocket.receive", "bytes": self._chunk}
            )
            await self._incoming.put(
                {
                    "type": "websocket.receive",
                    "text": json.dumps({"type": "stt.stop"}),
                }
            )


def test_benchmark_observes_same_binary_pcm_object_sent_to_provider():
    chunk = pcm(1234)
    websocket = AudioThenStopWebSocket(chunk)
    stream = FakeSttProviderStream()
    benchmark = IdentityBenchmarkObserver()
    state = SttStateMachine()
    state.begin_start()
    start = SttStart.model_validate(
        {
            "type": "stt.start",
            "audio": {
                "encoding": "pcm_s16le",
                "sample_rate_hz": 16000,
                "channels": 1,
            },
            "language": "vi",
        }
    )

    close_reason = asyncio.run(
        _run_stream(websocket, state, stream, start, benchmark)
    )

    assert close_reason == "client_stop"
    assert benchmark.audio_chunks == [chunk]
    assert stream.audio_chunks == [chunk]
    assert benchmark.audio_chunks[0] is stream.audio_chunks[0]


def test_benchmark_json_never_contains_transcript_pcm_provider_payload_or_secrets():
    clock = ManualClock()
    lines: list[str] = []
    benchmark = recorder(clock, lines)
    sensitive_segment = "Authorization-test-deepgram-key-raw-json"
    sensitive_pcm = b"raw-secret-pcm" * 300

    clock.set(0.1)
    benchmark.record_audio_chunk(sensitive_pcm)
    clock.set(0.2)
    benchmark.record_transcript("interim", sensitive_segment)
    clock.set(0.3)
    benchmark.record_transcript("final", sensitive_segment)
    clock.set(0.4)
    benchmark.record_provider_error()
    clock.set(0.5)
    benchmark.finish("provider_error")

    rendered = "\n".join(lines)
    assert sensitive_segment not in rendered
    assert "raw-secret-pcm" not in rendered
    assert "Authorization" not in rendered
    assert "test-deepgram-key" not in rendered
    assert "transcript" not in rendered.lower()
    assert "raw_json" not in rendered.lower()
    assert "exception" not in rendered.lower()
