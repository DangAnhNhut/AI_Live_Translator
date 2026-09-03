import asyncio
from dataclasses import dataclass

from app.ai.tts import SynthesizedAudio
from app.realtime.stt_protocol import TargetLanguage


@dataclass(frozen=True, slots=True)
class SynthesisCall:
    text: str
    language: TargetLanguage
    voice: str | None


class FakeSpeechSynthesizer:
    def __init__(
        self,
        *,
        outcomes: tuple[SynthesizedAudio | Exception, ...] = (),
        gates: tuple[asyncio.Event | None, ...] = (),
    ) -> None:
        self._outcomes = outcomes
        self._gates = gates
        self.calls: list[SynthesisCall] = []
        self.call_started = asyncio.Event()
        self.cancelled_calls = 0
        self.active_calls = 0
        self.maximum_active_calls = 0

    async def synthesize(
        self,
        *,
        text: str,
        language: TargetLanguage,
        voice: str | None = None,
    ) -> SynthesizedAudio:
        call_index = len(self.calls)
        self.calls.append(SynthesisCall(text, language, voice))
        self.call_started.set()
        self.active_calls += 1
        self.maximum_active_calls = max(
            self.maximum_active_calls,
            self.active_calls,
        )
        try:
            if call_index < len(self._gates):
                gate = self._gates[call_index]
                if gate is not None:
                    await gate.wait()
            outcome = (
                self._outcomes[call_index]
                if call_index < len(self._outcomes)
                else SynthesizedAudio(
                    audio_bytes=f"audio:{text}".encode("utf-8"),
                    mime_type="audio/wav",
                    sample_rate_hz=16000,
                )
            )
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        except asyncio.CancelledError:
            self.cancelled_calls += 1
            raise
        finally:
            self.active_calls -= 1
