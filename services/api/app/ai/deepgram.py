import asyncio
import json
import time
from collections.abc import AsyncIterator, Awaitable, Callable
from contextlib import suppress
from typing import Any, Literal, Protocol
from urllib.parse import urlencode

from pydantic import SecretStr
from websockets.asyncio.client import connect

from app.ai.stt import ProviderStreamError, SttTranscript
from app.benchmark.stt_benchmark import SttBenchmarkObserver
from app.realtime.stt_protocol import AudioConfig


class UpstreamWebSocket(Protocol):
    def __aiter__(self) -> AsyncIterator[str | bytes]: ...

    async def send(self, message: str | bytes) -> None: ...

    async def close(self) -> None: ...


UpstreamConnector = Callable[..., Awaitable[UpstreamWebSocket]]


async def _connect_upstream(uri: str, **kwargs: Any) -> UpstreamWebSocket:
    return await connect(uri, **kwargs)


_EVENTS_CLOSED = object()


class DeepgramSttStream:
    def __init__(
        self,
        *,
        api_key: SecretStr,
        model: str,
        language: Literal["vi"],
        endpointing_ms: int,
        connector: UpstreamConnector = _connect_upstream,
        keepalive_interval_s: float = 3.0,
        monotonic: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        benchmark_observer: SttBenchmarkObserver | None = None,
    ) -> None:
        self._api_key = api_key
        self._model = model
        self._language = language
        self._endpointing_ms = endpointing_ms
        self._connector = connector
        self._keepalive_interval_s = keepalive_interval_s
        self._monotonic = monotonic
        self._sleep = sleep
        self._benchmark_observer = benchmark_observer
        self._websocket: UpstreamWebSocket | None = None
        self._reader_task: asyncio.Task[None] | None = None
        self._keepalive_task: asyncio.Task[None] | None = None
        self._events: asyncio.Queue[
            SttTranscript | ProviderStreamError | object
        ] = asyncio.Queue()
        self._segment_number = 1
        self._closed = False
        self._finishing = False
        self._finish_started = False
        self._finish_lock = asyncio.Lock()
        self._send_lock = asyncio.Lock()
        self._last_outbound_at: float | None = None
        self._failure_reported = False

    def set_stt_benchmark_observer(
        self,
        observer: SttBenchmarkObserver,
    ) -> None:
        self._benchmark_observer = observer

    async def start(self, audio: AudioConfig, language: Literal["vi"]) -> None:
        query = urlencode(
            (
                ("model", self._model),
                ("language", self._language),
                ("encoding", "linear16"),
                ("sample_rate", audio.sample_rate_hz),
                ("channels", audio.channels),
                ("interim_results", "true"),
                ("punctuate", "true"),
                ("smart_format", "true"),
                ("endpointing", self._endpointing_ms),
            )
        )
        try:
            self._websocket = await self._connector(
                f"wss://api.deepgram.com/v1/listen?{query}",
                additional_headers={
                    "Authorization": f"Token {self._api_key.get_secret_value()}",
                },
            )
        except asyncio.CancelledError:
            raise
        except Exception:
            raise ProviderStreamError(
                "Deepgram upstream connection failed"
            ) from None
        self._last_outbound_at = self._monotonic()
        self._reader_task = asyncio.create_task(self._read_upstream())
        self._keepalive_task = asyncio.create_task(self._send_keepalives())

    async def send_audio(self, chunk: bytes) -> None:
        try:
            async with self._send_lock:
                websocket = self._websocket
                if websocket is None:
                    raise ProviderStreamError(
                        "Deepgram upstream stream failed"
                    )
                await websocket.send(chunk)
                self._last_outbound_at = self._monotonic()
        except asyncio.CancelledError:
            await self._shutdown()
            raise
        except ProviderStreamError:
            raise
        except Exception:
            await self._shutdown()
            raise ProviderStreamError("Deepgram upstream stream failed") from None

    async def finish_input(self) -> None:
        async with self._finish_lock:
            if self._finish_started or self._closed:
                return
            self._finish_started = True
            self._finishing = True
            try:
                async with self._send_lock:
                    keepalive_task = self._cancel_keepalive()
                    try:
                        websocket = self._websocket
                        if websocket is None or self._closed:
                            raise ProviderStreamError(
                                "Deepgram upstream stream failed"
                            )
                        await websocket.send('{"type":"CloseStream"}')
                    finally:
                        await self._await_keepalive(keepalive_task)
                if self._reader_task is not None:
                    await self._reader_task
            except asyncio.CancelledError:
                await self._shutdown(discard_events=True)
                raise
            except ProviderStreamError:
                await self._shutdown(discard_events=True)
                raise
            except Exception:
                await self._shutdown(discard_events=True)
                raise ProviderStreamError(
                    "Deepgram upstream stream failed"
                ) from None
            self._closed = True
            await self._close_socket()

    async def events(self) -> AsyncIterator[SttTranscript]:
        while True:
            item = await self._events.get()
            if item is _EVENTS_CLOSED:
                return
            if isinstance(item, ProviderStreamError):
                raise item
            assert isinstance(item, SttTranscript)
            yield item

    async def close(self) -> None:
        await self._shutdown()

    async def _send_keepalives(self) -> None:
        assert self._last_outbound_at is not None
        try:
            while not self._closed and not self._finishing:
                idle_for = self._monotonic() - self._last_outbound_at
                await self._sleep(
                    max(0.0, self._keepalive_interval_s - idle_for)
                )
                if self._closed or self._finishing:
                    return
                async with self._send_lock:
                    if self._closed or self._finishing:
                        return
                    idle_for = self._monotonic() - self._last_outbound_at
                    if idle_for < self._keepalive_interval_s:
                        continue
                    websocket = self._websocket
                    if websocket is None:
                        return
                    await websocket.send('{"type":"KeepAlive"}')
                    if self._benchmark_observer is not None:
                        self._benchmark_observer.record_keepalive()
                    self._last_outbound_at = self._monotonic()
        except asyncio.CancelledError:
            raise
        except Exception:
            self._closed = True
            await self._report_stream_failure()
            await self._close_socket()

    async def _read_upstream(self) -> None:
        assert self._websocket is not None
        websocket = self._websocket
        try:
            async for raw_message in websocket:
                if not isinstance(raw_message, str):
                    continue
                payload = json.loads(raw_message)
                if not isinstance(payload, dict) or payload.get("type") != "Results":
                    continue
                channel = payload.get("channel")
                if not isinstance(channel, dict):
                    continue
                alternatives = channel.get("alternatives")
                if not isinstance(alternatives, list) or not alternatives:
                    continue
                first_alternative = alternatives[0]
                if not isinstance(first_alternative, dict):
                    continue
                transcript = first_alternative.get("transcript")
                if not isinstance(transcript, str) or not transcript.strip():
                    continue
                is_final = payload.get("is_final") is True
                await self._events.put(
                    SttTranscript(
                        kind="final" if is_final else "interim",
                        segment_id=f"seg_{self._segment_number:03d}",
                        text=transcript,
                    )
                )
                if is_final:
                    self._segment_number += 1
        except asyncio.CancelledError:
            raise
        except Exception:
            self._closed = True
            await self._stop_keepalive()
            await self._close_socket()
            await self._report_stream_failure()
        else:
            if not self._finishing and not self._closed:
                self._closed = True
                await self._stop_keepalive()
                await self._close_socket()
                await self._report_stream_failure()
        finally:
            await self._events.put(_EVENTS_CLOSED)

    async def _shutdown(self, *, discard_events: bool = True) -> None:
        self._closed = True
        await self._stop_keepalive()
        reader_task = self._reader_task
        self._reader_task = None
        current_task = asyncio.current_task()
        if (
            reader_task is not None
            and reader_task is not current_task
            and not reader_task.done()
        ):
            reader_task.cancel()
        await self._close_socket()
        if reader_task is not None and reader_task is not current_task:
            with suppress(asyncio.CancelledError):
                await reader_task
        if discard_events:
            while True:
                try:
                    self._events.get_nowait()
                except asyncio.QueueEmpty:
                    break
            await self._events.put(_EVENTS_CLOSED)

    async def _stop_keepalive(self) -> None:
        await self._await_keepalive(self._cancel_keepalive())

    def _cancel_keepalive(self) -> asyncio.Task[None] | None:
        keepalive_task = self._keepalive_task
        self._keepalive_task = None
        current_task = asyncio.current_task()
        if (
            keepalive_task is not None
            and keepalive_task is not current_task
            and not keepalive_task.done()
        ):
            keepalive_task.cancel()
        return keepalive_task

    async def _await_keepalive(
        self,
        keepalive_task: asyncio.Task[None] | None,
    ) -> None:
        current_task = asyncio.current_task()
        if keepalive_task is not None and keepalive_task is not current_task:
            await asyncio.gather(keepalive_task, return_exceptions=True)

    async def _report_stream_failure(self) -> None:
        if self._failure_reported:
            return
        self._failure_reported = True
        await self._events.put(
            ProviderStreamError("Deepgram upstream stream failed")
        )

    async def _close_socket(self) -> None:
        websocket = self._websocket
        self._websocket = None
        if websocket is not None:
            with suppress(Exception):
                await websocket.close()
