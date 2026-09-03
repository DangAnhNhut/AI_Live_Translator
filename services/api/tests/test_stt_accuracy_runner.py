import asyncio
import wave

from app.ai.stt import ProviderStreamError, SttTranscript
from app.benchmark.stt_accuracy_manifest import BenchmarkCase


class FakeProviderStream:
    def __init__(self, events, *, event_error=None):
        self._events = events
        self._event_error = event_error
        self.started_with = None
        self.audio_chunks = []
        self.finish_calls = 0
        self.close_calls = 0

    async def start(self, audio, language):
        self.started_with = (audio, language)

    async def send_audio(self, chunk):
        self.audio_chunks.append(chunk)

    async def finish_input(self):
        self.finish_calls += 1

    async def events(self):
        for event in self._events:
            await asyncio.sleep(0)
            yield event
        if self._event_error is not None:
            raise self._event_error

    async def close(self):
        self.close_calls += 1


def write_valid_wav(path, frame_count=3200):
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(16000)
        output.writeframes(b"\x01\x00" * frame_count)


def benchmark_case():
    return BenchmarkCase(
        case_id="vi_normal_001",
        category="vi_normal",
        reference_text="Xin chào bạn",
        audio_file="recordings/vi_normal_001.wav",
    )


def test_multiple_final_segments_are_preserved_in_provider_order(tmp_path):
    from app.benchmark.stt_accuracy_runner import run_benchmark_case

    audio_path = tmp_path / "case.wav"
    write_valid_wav(audio_path)
    stream = FakeProviderStream(
        (
            SttTranscript("interim", "seg_001", ""),
            SttTranscript("interim", "seg_001", "xin"),
            SttTranscript("interim", "seg_001", "xin chào"),
            SttTranscript("final", "seg_001", "Xin chào"),
            SttTranscript("interim", "seg_002", "bạn ơi"),
            SttTranscript("final", "seg_002", "bạn"),
        )
    )

    result = asyncio.run(
        run_benchmark_case(
            benchmark_case(),
            audio_path,
            provider_factory=lambda: stream,
            provider="deepgram",
            model="nova-3",
            configured_language="vi",
            pace_audio=False,
        )
    )

    assert result.raw_hypothesis == "Xin chào bạn"
    assert result.provider_error is None
    assert result.wer == 0.0
    assert result.first_interim_ms is not None
    assert result.final_ms is not None
    assert stream.started_with[0].model_dump() == {
        "encoding": "pcm_s16le",
        "sample_rate_hz": 16000,
        "channels": 1,
    }
    assert stream.started_with[1] == "vi"
    assert stream.finish_calls == 1
    assert stream.close_calls == 1


def test_realtime_pacing_uses_audio_duration_and_fixed_size_chunks(tmp_path):
    from app.benchmark.stt_accuracy_runner import run_benchmark_case

    audio_path = tmp_path / "case.wav"
    write_valid_wav(audio_path, frame_count=2400)
    stream = FakeProviderStream(
        (SttTranscript("final", "seg_001", "Xin chào bạn"),)
    )
    delays = []

    async def record_sleep(delay):
        delays.append(delay)
        await asyncio.sleep(0)

    asyncio.run(
        run_benchmark_case(
            benchmark_case(),
            audio_path,
            provider_factory=lambda: stream,
            provider="deepgram",
            model="nova-3",
            configured_language="vi",
            sleep=record_sleep,
        )
    )

    assert [len(chunk) for chunk in stream.audio_chunks] == [3200, 1600]
    assert delays == [0.1, 0.05]


def test_provider_error_is_explicit_and_does_not_score_empty_success(tmp_path):
    from app.benchmark.stt_accuracy_runner import run_benchmark_case

    audio_path = tmp_path / "case.wav"
    write_valid_wav(audio_path)
    stream = FakeProviderStream(
        (SttTranscript("interim", "seg_001", "xin"),),
        event_error=ProviderStreamError("Deepgram upstream stream failed"),
    )

    result = asyncio.run(
        run_benchmark_case(
            benchmark_case(),
            audio_path,
            provider_factory=lambda: stream,
            provider="deepgram",
            model="nova-3",
            configured_language="vi",
            pace_audio=False,
        )
    )

    assert result.raw_hypothesis == ""
    assert result.wer is None
    assert result.cer is None
    assert result.word_edits is None
    assert result.character_edits is None
    assert result.provider_error == "Deepgram upstream stream failed"
    assert stream.close_calls == 1


def test_no_usable_final_transcript_is_an_explicit_failure(tmp_path):
    from app.benchmark.stt_accuracy_runner import run_benchmark_case

    audio_path = tmp_path / "case.wav"
    write_valid_wav(audio_path)
    stream = FakeProviderStream(
        (
            SttTranscript("interim", "seg_001", "xin"),
            SttTranscript("final", "seg_001", "   "),
        )
    )

    result = asyncio.run(
        run_benchmark_case(
            benchmark_case(),
            audio_path,
            provider_factory=lambda: stream,
            provider="deepgram",
            model="nova-3",
            configured_language="vi",
            pace_audio=False,
        )
    )

    assert result.raw_hypothesis == ""
    assert result.provider_error == "no_usable_final_transcript"
    assert result.wer is None
    assert result.final_ms is None
