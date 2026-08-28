import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket
from starlette.websockets import WebSocketDisconnect, WebSocketState
from uvicorn.protocols.utils import ClientDisconnected

from app.ai.stt import (
    ProviderStreamError,
    ProviderUnavailableError,
    SttProviderFactory,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
)
from app.benchmark.stt_benchmark import (
    SttBenchmarkCloseReason,
    SttBenchmarkFactory,
    SttBenchmarkObserver,
    attach_stt_benchmark_observer,
    get_stt_benchmark_factory,
)
from app.realtime.stt_protocol import (
    ErrorCode,
    ProtocolViolation,
    SttStart,
    SttStateMachine,
    SttStop,
    closed_event,
    error_event,
    parse_control_message,
    ready_event,
    transcript_event,
)


router = APIRouter()
logger = logging.getLogger(__name__)


async def _cancel(
    task: asyncio.Task[object] | None,
    *,
    allow_stop_iteration: bool = False,
) -> None:
    if task is None:
        return
    if not task.done():
        task.cancel()
    result = (await asyncio.gather(task, return_exceptions=True))[0]
    if isinstance(result, asyncio.CancelledError):
        return
    if isinstance(result, StopAsyncIteration):
        if not allow_stop_iteration:
            raise result
        return
    if isinstance(result, BaseException):
        raise result


async def _close_websocket(websocket: WebSocket) -> None:
    if (
        getattr(websocket, "application_state", None)
        is WebSocketState.DISCONNECTED
    ):
        return
    try:
        await websocket.close()
    except (ClientDisconnected, WebSocketDisconnect):
        pass


def _is_disconnect(message: dict[str, object]) -> bool:
    return message["type"] == "websocket.disconnect"


def _client_value(message: dict[str, object]) -> tuple[str, str | bytes]:
    if message["type"] != "websocket.receive":
        raise ProtocolViolation("invalid_message", "Unsupported WebSocket message.")
    if message.get("bytes") is not None:
        return "bytes", message["bytes"]
    if message.get("text") is not None:
        return "text", message["text"]
    raise ProtocolViolation("invalid_message", "Empty WebSocket message.")


def _validate_transcript(
    event: SttTranscript,
    finalized_segment_ids: set[str],
) -> None:
    if event.kind not in ("interim", "final"):
        raise ProviderStreamError("Invalid normalized transcript kind")
    if not isinstance(event.segment_id, str) or not event.segment_id.strip():
        raise ProviderStreamError("Invalid normalized transcript segment ID")
    if not isinstance(event.text, str):
        raise ProviderStreamError("Invalid normalized transcript text")
    if event.language != "vi":
        raise ProviderStreamError("Invalid normalized transcript language")
    if event.segment_id in finalized_segment_ids:
        raise ProviderStreamError("Normalized transcript segment is already final")
    if event.kind == "final":
        finalized_segment_ids.add(event.segment_id)


async def _send_transcript(
    websocket: WebSocket,
    event: SttTranscript,
    finalized_segment_ids: set[str],
    benchmark: SttBenchmarkObserver | None = None,
) -> None:
    _validate_transcript(event, finalized_segment_ids)
    if benchmark is not None:
        benchmark.record_transcript(event.kind, event.segment_id)
    await websocket.send_json(
        transcript_event(event.kind, event.segment_id, event.text, event.language)
    )


async def _send_terminal_error(
    websocket: WebSocket,
    state: SttStateMachine,
    code: ErrorCode,
    message: str,
) -> None:
    state.mark_error()
    with suppress(RuntimeError):
        await websocket.send_json(error_event(code, message))
        await websocket.send_json(closed_event())


async def _run_stream(
    websocket: WebSocket,
    state: SttStateMachine,
    stream: SttProviderStream,
    start: SttStart,
    benchmark: SttBenchmarkObserver | None = None,
) -> SttBenchmarkCloseReason:
    owned_tasks: set[asyncio.Task] = set()
    event_tasks: set[asyncio.Task] = set()
    try:
        close_reason = await _run_stream_owned(
            websocket,
            state,
            stream,
            start,
            benchmark,
            owned_tasks,
            event_tasks,
        )
    except BaseException:
        await _cleanup_stream_tasks(owned_tasks, event_tasks)
        raise

    cleanup_error = await _cleanup_stream_tasks(owned_tasks, event_tasks)
    if cleanup_error is not None:
        raise cleanup_error
    return close_reason


async def _cleanup_stream_tasks(
    owned_tasks: set[asyncio.Task],
    event_tasks: set[asyncio.Task],
) -> BaseException | None:
    for task in owned_tasks:
        if not task.done():
            task.cancel()

    first_error: BaseException | None = None
    tasks = tuple(owned_tasks)
    results = await asyncio.gather(*tasks, return_exceptions=True)
    for task, result in zip(tasks, results):
        if isinstance(result, asyncio.CancelledError):
            continue
        if isinstance(result, StopAsyncIteration):
            if task not in event_tasks and first_error is None:
                first_error = result
            continue
        if isinstance(result, BaseException):
            if first_error is None:
                first_error = result
    owned_tasks.clear()
    event_tasks.clear()
    return first_error


async def _run_stream_owned(
    websocket: WebSocket,
    state: SttStateMachine,
    stream: SttProviderStream,
    start: SttStart,
    benchmark: SttBenchmarkObserver | None,
    owned_tasks: set[asyncio.Task],
    event_tasks: set[asyncio.Task],
) -> SttBenchmarkCloseReason:
    startup = asyncio.create_task(stream.start(start.audio, start.language))
    owned_tasks.add(startup)
    incoming = asyncio.create_task(websocket.receive())
    owned_tasks.add(incoming)
    done, _ = await asyncio.wait(
        {startup, incoming}, return_when=asyncio.FIRST_COMPLETED
    )

    if incoming in done:
        try:
            message = incoming.result()
        finally:
            owned_tasks.discard(incoming)
        if _is_disconnect(message):
            await _cancel(startup)
            owned_tasks.discard(startup)
            return "client_disconnect"
        kind, value = _client_value(message)
        await _cancel(startup)
        owned_tasks.discard(startup)
        if kind == "bytes":
            state.require_audio_allowed()
        control = parse_control_message(value)
        if isinstance(control, SttStart):
            state.begin_start()
        state.begin_stop()

    await _cancel(incoming)
    owned_tasks.discard(incoming)
    try:
        await startup
    finally:
        owned_tasks.discard(startup)
    state.mark_ready()
    await websocket.send_json(ready_event())

    finalized_segment_ids: set[str] = set()
    events: AsyncIterator[SttTranscript] = stream.events()
    event_task: asyncio.Task[SttTranscript] | None = asyncio.create_task(anext(events))
    owned_tasks.add(event_task)
    event_tasks.add(event_task)
    incoming = asyncio.create_task(websocket.receive())
    owned_tasks.add(incoming)

    while True:
        active = {incoming}
        if event_task is not None:
            active.add(event_task)
        done, _ = await asyncio.wait(active, return_when=asyncio.FIRST_COMPLETED)

        if event_task is not None and event_task in done:
            try:
                try:
                    event = event_task.result()
                finally:
                    owned_tasks.discard(event_task)
                    event_tasks.discard(event_task)
                await _send_transcript(
                    websocket,
                    event,
                    finalized_segment_ids,
                    benchmark,
                )
                event_task = asyncio.create_task(anext(events))
                owned_tasks.add(event_task)
                event_tasks.add(event_task)
            except StopAsyncIteration:
                event_task = None
            continue

        try:
            message = incoming.result()
        finally:
            owned_tasks.discard(incoming)
        if _is_disconnect(message):
            await _cancel(event_task, allow_stop_iteration=True)
            owned_tasks.discard(event_task)
            event_tasks.discard(event_task)
            return "client_disconnect"
        kind, value = _client_value(message)
        if kind == "bytes":
            state.require_audio_allowed()
            chunk = value
            if not chunk:
                raise ProtocolViolation(
                    "unsupported_audio", "Audio chunks must not be empty."
                )
            if benchmark is not None:
                benchmark.record_audio_chunk(chunk)
            await stream.send_audio(chunk)
            incoming = asyncio.create_task(websocket.receive())
            owned_tasks.add(incoming)
            continue

        control = parse_control_message(value)
        if isinstance(control, SttStart):
            state.begin_start()
        assert isinstance(control, SttStop)
        state.begin_stop()
        break

    finish_task: asyncio.Task[None] | None = asyncio.create_task(stream.finish_input())
    owned_tasks.add(finish_task)
    incoming = asyncio.create_task(websocket.receive())
    owned_tasks.add(incoming)
    while finish_task is not None or event_task is not None:
        active = {incoming}
        if finish_task is not None:
            active.add(finish_task)
        if event_task is not None:
            active.add(event_task)
        done, _ = await asyncio.wait(active, return_when=asyncio.FIRST_COMPLETED)

        if incoming in done:
            try:
                message = incoming.result()
            finally:
                owned_tasks.discard(incoming)
            if _is_disconnect(message):
                await _cancel(finish_task)
                owned_tasks.discard(finish_task)
                await _cancel(event_task, allow_stop_iteration=True)
                owned_tasks.discard(event_task)
                event_tasks.discard(event_task)
                return "client_disconnect"
            kind, value = _client_value(message)
            if kind == "bytes":
                state.require_audio_allowed()
            parse_control_message(value)
            state.begin_stop()

        if event_task is not None and event_task in done:
            try:
                try:
                    event = event_task.result()
                finally:
                    owned_tasks.discard(event_task)
                    event_tasks.discard(event_task)
                await _send_transcript(
                    websocket,
                    event,
                    finalized_segment_ids,
                    benchmark,
                )
                event_task = asyncio.create_task(anext(events))
                owned_tasks.add(event_task)
                event_tasks.add(event_task)
            except StopAsyncIteration:
                event_task = None

        if finish_task is not None and finish_task in done:
            try:
                await finish_task
            finally:
                owned_tasks.discard(finish_task)
            finish_task = None

    await _cancel(incoming)
    owned_tasks.discard(incoming)
    state.mark_closed()
    await websocket.send_json(closed_event())
    return "client_stop"


@router.websocket("/ws/stt")
async def websocket_stt(
    websocket: WebSocket,
    provider_factory: Annotated[
        SttProviderFactory, Depends(get_stt_provider_factory)
    ],
    benchmark_factory: Annotated[
        SttBenchmarkFactory, Depends(get_stt_benchmark_factory)
    ],
) -> None:
    await websocket.accept()
    state = SttStateMachine()
    stream: SttProviderStream | None = None
    benchmark = benchmark_factory()
    close_reason: SttBenchmarkCloseReason = "internal_error"

    try:
        first = await websocket.receive()
        if _is_disconnect(first):
            close_reason = "client_disconnect"
            return
        kind, value = _client_value(first)
        if kind == "bytes":
            state.require_audio_allowed()
        start = parse_control_message(value)
        if not isinstance(start, SttStart):
            state.begin_stop()
        state.begin_start()
        stream = provider_factory()
        attach_stt_benchmark_observer(stream, benchmark)
        close_reason = await _run_stream(websocket, state, stream, start, benchmark)
    except ProtocolViolation as exc:
        close_reason = "protocol_error"
        await _send_terminal_error(websocket, state, exc.code, exc.message)
    except ProviderUnavailableError:
        close_reason = "provider_unavailable"
        await _send_terminal_error(
            websocket, state, "provider_unavailable", "STT provider is unavailable."
        )
    except ProviderStreamError:
        close_reason = "provider_error"
        if benchmark is not None:
            benchmark.record_provider_error()
        await _send_terminal_error(
            websocket, state, "provider_error", "STT provider stream failed."
        )
    except Exception as exc:
        close_reason = "internal_error"
        logger.error(
            "stt.websocket.internal_error exception_type=%s",
            type(exc).__name__,
        )
        await _send_terminal_error(
            websocket, state, "internal_error", "Internal STT error."
        )
    finally:
        if stream is not None:
            with suppress(Exception):
                await stream.close()
        state.mark_closed()
        await _close_websocket(websocket)
        if benchmark is not None:
            benchmark.finish(close_reason)
