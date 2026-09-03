import asyncio
from dataclasses import dataclass
from typing import Literal

from app.ai.translation import TranslationResult


@dataclass(frozen=True, slots=True)
class TranslationCall:
    text: str
    source_language: str
    target_language: str


class FakeTranslator:
    def __init__(
        self,
        *,
        outcomes: tuple[str | Exception, ...] = (),
        gates: tuple[asyncio.Event | None, ...] = (),
    ) -> None:
        self._outcomes = outcomes
        self._gates = gates
        self.calls: list[TranslationCall] = []
        self.call_started = asyncio.Event()
        self.cancelled_calls = 0
        self.active_calls = 0
        self.maximum_active_calls = 0

    async def translate(
        self,
        *,
        text: str,
        source_language: Literal["vi"],
        target_language: str,
    ) -> TranslationResult:
        call_index = len(self.calls)
        self.calls.append(
            TranslationCall(text, source_language, target_language)
        )
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
            outcome: str | Exception
            if call_index < len(self._outcomes):
                outcome = self._outcomes[call_index]
            else:
                outcome = f"translated:{text}"
            if isinstance(outcome, Exception):
                raise outcome
            return TranslationResult(translated_text=outcome)
        except asyncio.CancelledError:
            self.cancelled_calls += 1
            raise
        finally:
            self.active_calls -= 1
