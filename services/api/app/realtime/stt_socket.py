import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket

from app.ai.stt import (
    ProviderStreamError,
    ProviderUnavailableError,
    SttProviderFactory,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
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


async def _cancel(task: asyncio.Task[object] | None) -> None:
    if task is None or task.done():
        return
    task.cancel()
    with suppress(asyncio.CancelledError):
        await task


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
) -> None:
    _validate_transcript(event, finalized_segment_ids)
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
) -> None:
    startup = asyncio.create_task(stream.start(start.audio, start.language))
    incoming = asyncio.create_task(websocket.receive())
    done, _ = await asyncio.wait(
        {startup, incoming}, return_when=asyncio.FIRST_COMPLETED
    )

    if incoming in done:
        message = incoming.result()
        if _is_disconnect(message):
            await _cancel(startup)
            return
        kind, value = _client_value(message)
        await _cancel(startup)
        if kind == "bytes":
            state.require_audio_allowed()
        control = parse_control_message(value)
        if isinstance(control, SttStart):
            state.begin_start()
        state.begin_stop()

    await _cancel(incoming)
    await startup
    state.mark_ready()
    await websocket.send_json(ready_event())

    finalized_segment_ids: set[str] = set()
    events: AsyncIterator[SttTranscript] = stream.events()
    event_task: asyncio.Task[SttTranscript] | None = asyncio.create_task(anext(events))
    incoming = asyncio.create_task(websocket.receive())

    while True:
        active = {incoming}
        if event_task is not None:
            active.add(event_task)
        done, _ = await asyncio.wait(active, return_when=asyncio.FIRST_COMPLETED)

        if event_task is not None and event_task in done:
            try:
                await _send_transcript(
                    websocket, event_task.result(), finalized_segment_ids
                )
                event_task = asyncio.create_task(anext(events))
            except StopAsyncIteration:
                event_task = None
            continue

        message = incoming.result()
        if _is_disconnect(message):
            await _cancel(event_task)
            return
        kind, value = _client_value(message)
        if kind == "bytes":
            state.require_audio_allowed()
            chunk = value
            if not chunk:
                raise ProtocolViolation(
                    "unsupported_audio", "Audio chunks must not be empty."
                )
            await stream.send_audio(chunk)
            incoming = asyncio.create_task(websocket.receive())
            continue

        control = parse_control_message(value)
        if isinstance(control, SttStart):
            state.begin_start()
        assert isinstance(control, SttStop)
        state.begin_stop()
        break

    finish_task: asyncio.Task[None] | None = asyncio.create_task(stream.finish_input())
    incoming = asyncio.create_task(websocket.receive())
    while finish_task is not None or event_task is not None:
        active = {incoming}
        if finish_task is not None:
            active.add(finish_task)
        if event_task is not None:
            active.add(event_task)
        done, _ = await asyncio.wait(active, return_when=asyncio.FIRST_COMPLETED)

        if incoming in done:
            message = incoming.result()
            if _is_disconnect(message):
                await _cancel(finish_task)
                await _cancel(event_task)
                return
            kind, value = _client_value(message)
            if kind == "bytes":
                state.require_audio_allowed()
            parse_control_message(value)
            state.begin_stop()

        if event_task is not None and event_task in done:
            try:
                await _send_transcript(
                    websocket, event_task.result(), finalized_segment_ids
                )
                event_task = asyncio.create_task(anext(events))
            except StopAsyncIteration:
                event_task = None

        if finish_task is not None and finish_task in done:
            await finish_task
            finish_task = None

    await _cancel(incoming)
    state.mark_closed()
    await websocket.send_json(closed_event())


@router.websocket("/ws/stt")
async def websocket_stt(
    websocket: WebSocket,
    provider_factory: Annotated[
        SttProviderFactory, Depends(get_stt_provider_factory)
    ],
) -> None:
    await websocket.accept()
    state = SttStateMachine()
    stream: SttProviderStream | None = None

    try:
        first = await websocket.receive()
        if _is_disconnect(first):
            return
        kind, value = _client_value(first)
        if kind == "bytes":
            state.require_audio_allowed()
        start = parse_control_message(value)
        if not isinstance(start, SttStart):
            state.begin_stop()
        state.begin_start()
        stream = provider_factory()
        await _run_stream(websocket, state, stream, start)
    except ProtocolViolation as exc:
        await _send_terminal_error(websocket, state, exc.code, exc.message)
    except ProviderUnavailableError:
        await _send_terminal_error(
            websocket, state, "provider_unavailable", "STT provider is unavailable."
        )
    except ProviderStreamError:
        await _send_terminal_error(
            websocket, state, "provider_error", "STT provider failed."
        )
    except Exception as exc:
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
        with suppress(RuntimeError):
            await websocket.close()
