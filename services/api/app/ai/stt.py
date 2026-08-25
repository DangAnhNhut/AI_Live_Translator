from collections.abc import AsyncIterator, Callable
from dataclasses import dataclass
from typing import Literal, Protocol, runtime_checkable

from app.realtime.stt_protocol import AudioConfig, TranscriptKind


@dataclass(frozen=True, slots=True)
class SttTranscript:
    """Normalized adapter output; segment_id is backend-neutral, never raw provider ID."""

    kind: TranscriptKind
    segment_id: str
    text: str
    language: Literal["vi"] = "vi"


class ProviderUnavailableError(Exception):
    pass


class ProviderStreamError(Exception):
    pass


@runtime_checkable
class SttProviderStream(Protocol):
    async def start(self, audio: AudioConfig, language: Literal["vi"]) -> None:
        raise NotImplementedError

    async def send_audio(self, chunk: bytes) -> None:
        raise NotImplementedError

    async def finish_input(self) -> None:
        raise NotImplementedError

    def events(self) -> AsyncIterator[SttTranscript]:
        raise NotImplementedError

    async def close(self) -> None:
        raise NotImplementedError


SttProviderFactory = Callable[[], SttProviderStream]


def unconfigured_stt_provider_factory() -> SttProviderStream:
    raise ProviderUnavailableError("STT provider is not configured")


def get_stt_provider_factory() -> SttProviderFactory:
    return unconfigured_stt_provider_factory
