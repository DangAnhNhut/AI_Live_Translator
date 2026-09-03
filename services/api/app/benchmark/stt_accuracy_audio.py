"""Strict WAV loading for offline STT accuracy benchmarks."""

from dataclasses import dataclass
from pathlib import Path
import wave


EXPECTED_CHANNELS = 1
EXPECTED_SAMPLE_RATE_HZ = 16000
EXPECTED_SAMPLE_WIDTH_BYTES = 2


class UnsupportedWavError(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class WavAudio:
    pcm_bytes: bytes
    frame_count: int
    sample_rate_hz: int
    channels: int
    sample_width_bytes: int

    @property
    def bytes_per_second(self) -> int:
        return self.sample_rate_hz * self.channels * self.sample_width_bytes


def load_wav_audio(path: Path) -> WavAudio:
    try:
        with wave.open(str(path), "rb") as source:
            channels = source.getnchannels()
            sample_rate_hz = source.getframerate()
            sample_width_bytes = source.getsampwidth()
            compression = source.getcomptype()
            frame_count = source.getnframes()
            if compression != "NONE":
                raise UnsupportedWavError("WAV must use uncompressed PCM")
            if channels != EXPECTED_CHANNELS:
                raise UnsupportedWavError("WAV must be mono (1 channel)")
            if sample_rate_hz != EXPECTED_SAMPLE_RATE_HZ:
                raise UnsupportedWavError("WAV sample rate must be 16000 Hz")
            if sample_width_bytes != EXPECTED_SAMPLE_WIDTH_BYTES:
                raise UnsupportedWavError("WAV sample width must be signed 16-bit")
            pcm_bytes = source.readframes(frame_count)
    except wave.Error as error:
        raise UnsupportedWavError(f"Invalid WAV file: {error}") from error

    return WavAudio(
        pcm_bytes=pcm_bytes,
        frame_count=frame_count,
        sample_rate_hz=sample_rate_hz,
        channels=channels,
        sample_width_bytes=sample_width_bytes,
    )
