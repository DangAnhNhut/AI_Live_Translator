import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Annotated
from uuid import uuid4

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
from app.ai.translation import (
    TranslationProviderUnavailable,
    TranslatorFactory,
    get_translator_factory,
)
from app.benchmark.stt_benchmark import (
    SttBenchmarkCloseReason,
    SttBenchmarkFactory,
    SttBenchmarkObserver,
    attach_stt_benchmark_observer,
    get_stt_benchmark_factory,
)
from app.core.config import settings
from app.realtime.session_event_publisher import SessionEventPublisher
from app.realtime.session_hub import SessionHub, get_session_hub
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
from app.realtime.stt_transcript_trace import (
    SttTranscriptTraceFactory,
    SttTranscriptTraceRecorder,
    attach_stt_transcript_trace,
    get_stt_transcript_trace_factory,
)
from app.realtime.translation_protocol import (
    translation_configured_event,
    translation_session_error_event,
)
from app.realtime.translation_session import TranslationSession


router = APIRouter()
logger = logging.getLogger(__name__)
_TRANSLATION_DRAIN_TIMEOUT_SECONDS = 5.0


def get_session_translator_factory() -> TranslatorFactory:
    return get_translator_factory()


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
    if not isinstance(event.utterance_boundary, bool):
        raise ProviderStreamError(
            "Invalid normalized transcript utterance boundary"
        )
    if event.segment_id in finalized_segment_ids:
        raise ProviderStreamError("Normalized transcript segment is already final")
    if event.kind == "final":
        finalized_segment_ids.add(event.segment_id)


async def _send_transcript(
    websocket: WebSocket,
    event: SttTranscript,
    finalized_segment_ids: set[str],
    benchmark: SttBenchmarkObserver | None = None,
    transcript_trace: SttTranscriptTraceRecorder | None = None,
    session_hub: SessionHub | None = None,
    session_id: str | None = None,
    stream_id: str | None = None,
    publisher: SessionEventPublisher | None = None,
    translation_session: TranslationSession | None = None,
) -> None:
    _validate_transcript(event, finalized_segment_ids)
    if benchmark is not None:
        benchmark.record_transcript(event.kind, event.segment_id)
    normalized_event = transcript_event(
        event.kind,
        event.segment_id,
        event.text,
        event.language,
        stream_id=stream_id,
    )
    if publisher is None:
        await websocket.send_json(normalized_event)
    else:
        await publisher.publish(normalized_event)
    if transcript_trace is not None:
        transcript_trace.record_websocket_transcript_sent(
            segment_id=event.segment_id,
            kind=event.kind,
            text=event.text,
            language=event.language,
        )
    if (
        publisher is None
        and session_hub is not None
        and session_id is not None
    ):
        await session_hub.broadcast(session_id, normalized_event)
    if translation_session is not None and event.kind == "final":
        await translation_session.accept_transcript(event)


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
    transcript_trace: SttTranscriptTraceRecorder | None = None,
    session_hub: SessionHub | None = None,
    stream_id: str | None = None,
    publisher: SessionEventPublisher | None = None,
    translation_session: TranslationSession | None = None,
    translation_startup_event: dict[str, object] | None = None,
    producer_identity: object | None = None,
) -> SttBenchmarkCloseReason:
    stream_id = stream_id or f"stream_{uuid4().hex}"
    owned_tasks: set[asyncio.Task] = set()
    event_tasks: set[asyncio.Task] = set()
    try:
        close_reason = await _run_stream_owned(
            websocket,
            state,
            stream,
            start,
            benchmark,
            transcript_trace,
            session_hub,
            owned_tasks,
            event_tasks,
            stream_id,
            publisher,
            translation_session,
            translation_startup_event,
            producer_identity,
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
    transcript_trace: SttTranscriptTraceRecorder | None,
    session_hub: SessionHub | None,
    owned_tasks: set[asyncio.Task],
    event_tasks: set[asyncio.Task],
    stream_id: str,
    publisher: SessionEventPublisher | None,
    translation_session: TranslationSession | None,
    translation_startup_event: dict[str, object] | None,
    producer_identity: object | None,
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
    await websocket.send_json(ready_event(stream_id=stream_id))
    if translation_startup_event is not None:
        is_configured = (
            translation_startup_event["type"] == "translation.configured"
        )
        if is_configured and publisher is not None:
            assert producer_identity is not None
            await publisher.publish_translation_config(
                translation_startup_event,
                producer_identity=producer_identity,
            )
        elif publisher is None:
            await websocket.send_json(translation_startup_event)
            if (
                is_configured
                and session_hub is not None
                and start.session_id is not None
                and producer_identity is not None
            ):
                await session_hub.publish_translation_config(
                    start.session_id,
                    producer_identity,
                    translation_startup_event,
                )
            elif session_hub is not None and start.session_id is not None:
                await session_hub.broadcast(
                    start.session_id,
                    translation_startup_event,
                )
        else:
            await publisher.publish(translation_startup_event)
    if translation_session is not None:
        await translation_session.start()

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
                    transcript_trace,
                    session_hub,
                    start.session_id,
                    stream_id,
                    publisher,
                    translation_session,
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
                    transcript_trace,
                    session_hub,
                    start.session_id,
                    stream_id,
                    publisher,
                    translation_session,
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
    if translation_session is not None:
        await translation_session.flush_and_drain(
            timeout_seconds=_TRANSLATION_DRAIN_TIMEOUT_SECONDS,
        )
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
    transcript_trace_factory: Annotated[
        SttTranscriptTraceFactory, Depends(get_stt_transcript_trace_factory)
    ],
    session_hub: Annotated[SessionHub, Depends(get_session_hub)],
    translator_factory: Annotated[
        TranslatorFactory | None,
        Depends(get_session_translator_factory),
    ] = None,
) -> None:
    await websocket.accept()
    state = SttStateMachine()
    stream: SttProviderStream | None = None
    benchmark = benchmark_factory()
    transcript_trace = transcript_trace_factory()
    close_reason: SttBenchmarkCloseReason = "internal_error"
    producer_identity = object()
    claimed_session_id: str | None = None
    publisher: SessionEventPublisher | None = None
    translation_session: TranslationSession | None = None

    async def stop_translation_delivery() -> None:
        if translation_session is not None:
            await translation_session.abort()
        if publisher is not None:
            await publisher.close()

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
        if start.session_id is not None:
            claimed = await session_hub.claim_producer(
                start.session_id,
                producer_identity,
            )
            if not claimed:
                raise ProtocolViolation(
                    "session_producer_conflict",
                    "Session already has an active producer.",
                )
            claimed_session_id = start.session_id

        stream_id = f"stream_{uuid4().hex}"
        publisher = SessionEventPublisher(
            producer=websocket,
            session_hub=session_hub,
            session_id=start.session_id,
        )
        translation_startup_event: dict[str, object] | None = None
        if start.translation is not None:
            active_translator_factory = (
                translator_factory or get_session_translator_factory()
            )
            try:
                translator = active_translator_factory()
            except TranslationProviderUnavailable:
                translation_startup_event = translation_session_error_event(
                    stream_id=stream_id,
                    source_language=start.language,
                    target_language=start.translation.target_language,
                    code="provider_unavailable",
                    message="Translation provider is unavailable.",
                )
            except Exception as exc:
                logger.error(
                    "translation.provider.initialization_failed exception_type=%s",
                    type(exc).__name__,
                )
                translation_startup_event = translation_session_error_event(
                    stream_id=stream_id,
                    source_language=start.language,
                    target_language=start.translation.target_language,
                    code="provider_unavailable",
                    message="Translation provider is unavailable.",
                )
            else:
                translation_session = TranslationSession(
                    translator=translator,
                    stream_id=stream_id,
                    source_language=start.language,
                    target_language=start.translation.target_language,
                    publish_event=publisher.publish,
                    queue_max_size=settings.translation_queue_max_size,
                    request_timeout_seconds=(
                        settings.translation_request_timeout_seconds
                    ),
                )
                translation_startup_event = translation_configured_event(
                    stream_id=stream_id,
                    source_language=start.language,
                    target_language=start.translation.target_language,
                )

        stream = provider_factory()
        attach_stt_benchmark_observer(stream, benchmark)
        attach_stt_transcript_trace(stream, transcript_trace)
        close_reason = await _run_stream(
            websocket,
            state,
            stream,
            start,
            benchmark,
            transcript_trace,
            session_hub,
            stream_id,
            publisher,
            translation_session,
            translation_startup_event,
            producer_identity,
        )
    except ProtocolViolation as exc:
        close_reason = "protocol_error"
        await stop_translation_delivery()
        await _send_terminal_error(websocket, state, exc.code, exc.message)
    except ProviderUnavailableError:
        close_reason = "provider_unavailable"
        await stop_translation_delivery()
        await _send_terminal_error(
            websocket, state, "provider_unavailable", "STT provider is unavailable."
        )
    except ProviderStreamError:
        close_reason = "provider_error"
        await stop_translation_delivery()
        if benchmark is not None:
            benchmark.record_provider_error()
        await _send_terminal_error(
            websocket, state, "provider_error", "STT provider stream failed."
        )
    except Exception as exc:
        close_reason = "internal_error"
        await stop_translation_delivery()
        logger.error(
            "stt.websocket.internal_error exception_type=%s",
            type(exc).__name__,
        )
        await _send_terminal_error(
            websocket, state, "internal_error", "Internal STT error."
        )
    finally:
        try:
            if translation_session is not None:
                if close_reason == "client_stop":
                    await translation_session.close()
                else:
                    await translation_session.abort()
            if publisher is not None:
                await publisher.close()
            if stream is not None:
                with suppress(Exception):
                    await stream.close()
            state.mark_closed()
            await _close_websocket(websocket)
            if benchmark is not None:
                benchmark.finish(close_reason)
        finally:
            if claimed_session_id is not None:
                await session_hub.release_producer(
                    claimed_session_id,
                    producer_identity,
                )
