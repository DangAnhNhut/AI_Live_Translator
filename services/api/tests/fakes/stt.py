import asyncio
from collections.abc import AsyncIterator, Sequence
from typing import Literal

from app.ai.stt import SttTranscript
from app.realtime.stt_protocol import AudioConfig


_FINISH_COMPLETE = object()


class FakeSttProviderStream:
    def __init__(
        self,
        *,
        start_error: Exception | None = None,
        send_error: Exception | None = None,
        finish_error: Exception | None = None,
        block_start: bool = False,
        block_finish: bool = False,
        audio_events: Sequence[SttTranscript] = (),
        finish_events: Sequence[SttTranscript] = (),
        event_error: Exception | None = None,
    ) -> None:
        self.start_error = start_error
        self.send_error = send_error
        self.finish_error = finish_error
        self.audio_events = audio_events
        self.finish_events = finish_events
        self.event_error = event_error
        self.start_gate = asyncio.Event()
        self.finish_gate = asyncio.Event()
        if not block_start:
            self.start_gate.set()
        if not block_finish:
            self.finish_gate.set()
        self.start_calls: list[tuple[AudioConfig, Literal["vi"]]] = []
        self.audio_chunks: list[bytes] = []
        self.finish_calls = 0
        self.close_calls = 0
        self.finish_completed = False
        self.finish_events_drained_after_finish = False
        self._events: asyncio.Queue[SttTranscript | Exception | object] = asyncio.Queue()

    async def start(self, audio: AudioConfig, language: Literal["vi"]) -> None:
        self.start_calls.append((audio, language))
        await self.start_gate.wait()
        if self.start_error:
            raise self.start_error

    async def send_audio(self, chunk: bytes) -> None:
        if self.send_error:
            raise self.send_error
        self.audio_chunks.append(chunk)
        for event in self.audio_events:
            await self._events.put(event)
        if self.event_error:
            await self._events.put(self.event_error)

    async def finish_input(self) -> None:
        self.finish_calls += 1
        await self.finish_gate.wait()
        if self.finish_error:
            raise self.finish_error
        self.finish_completed = True
        await self._events.put(_FINISH_COMPLETE)

    async def events(self) -> AsyncIterator[SttTranscript]:
        while True:
            item = await self._events.get()
            if item is _FINISH_COMPLETE:
                await asyncio.sleep(0)
                for event in self.finish_events:
                    yield event
                self.finish_events_drained_after_finish = True
                return
            if isinstance(item, Exception):
                raise item
            assert isinstance(item, SttTranscript)
            yield item

    async def close(self) -> None:
        self.close_calls += 1
