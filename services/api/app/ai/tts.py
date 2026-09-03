from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from app.realtime.stt_protocol import TargetLanguage


class TtsProviderUnavailable(Exception):
    pass


class TtsProviderError(Exception):
    pass


class InvalidSynthesizedAudio(ValueError):
    pass


@dataclass(frozen=True, slots=True)
class SynthesizedAudio:
    audio_bytes: bytes
    mime_type: str
    sample_rate_hz: int | None = None

    def __post_init__(self) -> None:
        if not isinstance(self.audio_bytes, bytes) or not self.audio_bytes:
            raise InvalidSynthesizedAudio(
                "audio_bytes must be non-empty bytes"
            )
        if not isinstance(self.mime_type, str) or not self.mime_type.strip():
            raise InvalidSynthesizedAudio("mime_type must be non-empty")
        if self.sample_rate_hz is not None and (
            isinstance(self.sample_rate_hz, bool)
            or not isinstance(self.sample_rate_hz, int)
            or self.sample_rate_hz <= 0
        ):
            raise InvalidSynthesizedAudio(
                "sample_rate_hz must be a positive integer or None"
            )


@runtime_checkable
class SpeechSynthesizer(Protocol):
    async def synthesize(
        self,
        *,
        text: str,
        language: TargetLanguage,
        voice: str | None = None,
    ) -> SynthesizedAudio:
        raise NotImplementedError


SpeechSynthesizerFactory = Callable[[], SpeechSynthesizer]
