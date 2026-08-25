# P1.2 `/ws/stt` Backend Baseline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a provider-neutral FastAPI `/ws/stt` baseline that enforces the approved P1 protocol, accepts binary PCM audio, emits normalized lifecycle/error events, and exposes a testable adapter seam without integrating a real STT provider.

**Architecture:** Keep public message parsing and connection-state rules in `app/realtime/stt_protocol.py`, and keep provider lifecycle types in `app/ai/stt.py`. The `/ws/stt` router coordinates the client WebSocket and an injected provider stream; production uses an explicit unconfigured factory that reports `provider_unavailable`, while deterministic fake streams exist only in tests. Register the new router alongside the untouched `/ws/test` router.

**Tech Stack:** Python 3.10-compatible code (observed local runtime: Python 3.10.11; the repository declares no higher minimum), FastAPI 0.141.1, Starlette 1.6.0 WebSockets/TestClient, Pydantic 2.13.4, pytest 9.1.1, standard-library `asyncio`, `enum`, `json`, and typing protocols. No new dependency.

**Spec:** `docs/superpowers/specs/2026-08-25-stt-technical-spike-design.md`

## Global Constraints

- Implement P1.2 only. P1.1 is complete; do not recreate it as an implementation task.
- The backend remains the source of truth. Web and Mobile never call STT providers directly.
- Preserve the approved public WebSocket contract exactly: JSON text controls, binary PCM audio, and normalized JSON text events.
- Accept only `pcm_s16le`, 16,000 Hz, mono, Vietnamese (`vi`); target audio chunks are approximately 100–250 ms, with no codec negotiation, resampling, remixing, or transcoding.
- All V1 protocol errors are terminal and use only `invalid_message`, `invalid_state`, `unsupported_audio`, `provider_unavailable`, `provider_error`, or `internal_error`, with `recoverable: false`.
- Do not expose provider exceptions, payloads, identifiers, credentials, endpoints, SDK types, or configuration to clients.
- Do not select a provider, install an STT SDK, add secrets/configuration, or add a production fake provider.
- Do not modify `app/realtime/test_socket.py` or change `/ws/test` behavior.
- Do not add Web, Flutter, translation, TTS, diarization, recording, persistence, authentication, billing, sharing, or other Phase 2+ behavior.
- Use TDD for every task. Run commands from `services/api` unless a step explicitly says otherwise.
- Each task commit is local only. Do not push or merge.
- Python compatibility assumption: implementation must run on the observed Python 3.10.11 runtime because no `pyproject.toml`, `.python-version`, `runtime.txt`, Docker base image, or other backend Python floor is declared. Do not use Python 3.11-only APIs or raise the minimum version as part of P1.2.

## Planned File Structure

| Path | Change | Responsibility |
|---|---|---|
| `services/api/app/realtime/stt_protocol.py` | Create | Exact control-message parsing, normalized event constructors, connection states, and valid transitions. |
| `services/api/app/ai/stt.py` | Create | Minimal provider-neutral stream protocol, transcript value type, safe exception boundary, factory dependency, and explicit unconfigured production factory. |
| `services/api/app/realtime/stt_socket.py` | Create | `/ws/stt` router, client/provider concurrency, normalized event delivery, terminal errors, and cleanup. |
| `services/api/app/main.py` | Modify | Include the new STT router without altering the existing `/ws/test` router registration. |
| `services/api/tests/test_stt_protocol.py` | Create | Unit coverage for public parsing/event shapes and all connection-state transitions. |
| `services/api/tests/fakes/stt.py` | Create | Deterministic test-only provider stream and factory controls. |
| `services/api/tests/fakes/__init__.py` | Create | Make test fakes importable. |
| `services/api/tests/test_stt_websocket.py` | Create | End-to-end WebSocket protocol, injected transcript path, failures, and cleanup. |
| `services/api/tests/test_websocket.py` | Do not modify | Existing `/ws/test` regression remains the source of truth. |
| `services/api/requirements.txt` | Do not modify | Existing dependencies are sufficient. |

---

### Task 1: Public Protocol Models and Connection State

**Files:**
- Create: `services/api/tests/test_stt_protocol.py`
- Create: `services/api/app/realtime/stt_protocol.py`

**Interfaces:**
- Consumes: Approved JSON controls and normalized event shapes from the design spec.
- Produces: `AudioConfig`, `SttStart`, `SttStop`, `ControlMessage`, `ProtocolViolation`, `ConnectionState`, `SttStateMachine`, `parse_control_message(text: str) -> ControlMessage`, `ready_event() -> dict[str, object]`, `transcript_event(kind, segment_id, text, language) -> dict[str, object]`, `error_event(code, message) -> dict[str, object]`, and `closed_event() -> dict[str, object]`.

- [ ] **Step 1: Write the failing protocol and state tests**

Create `tests/test_stt_protocol.py` with exact contract values and explicit invalid transitions:

```python
import pytest

from app.realtime.stt_protocol import (
    ConnectionState,
    ProtocolViolation,
    SttStart,
    SttStateMachine,
    closed_event,
    error_event,
    parse_control_message,
    ready_event,
    transcript_event,
)


VALID_START = """{
  "type": "stt.start",
  "audio": {
    "encoding": "pcm_s16le",
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "language": "vi"
}"""


def test_parse_valid_start_contract():
    message = parse_control_message(VALID_START)

    assert isinstance(message, SttStart)
    assert message.type == "stt.start"
    assert message.audio.encoding == "pcm_s16le"
    assert message.audio.sample_rate_hz == 16000
    assert message.audio.channels == 1
    assert message.language == "vi"


@pytest.mark.parametrize(
    ("payload", "code"),
    [
        ("not-json", "invalid_message"),
        ("[]", "invalid_message"),
        ('{"type":"unknown"}', "invalid_message"),
        ('{"type":"stt.start","audio":{},"language":"vi"}', "unsupported_audio"),
        (
            '{"type":"stt.start","audio":{"encoding":"opus",'
            '"sample_rate_hz":16000,"channels":1},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":48000,"channels":1},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":16000,"channels":2},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":16000,"channels":1},"language":"en"}',
            "invalid_message",
        ),
        ('{"type":"stt.stop","extra":true}', "invalid_message"),
    ],
)
def test_parse_rejects_invalid_control_messages(payload, code):
    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(payload)

    assert error.value.code == code
    assert error.value.recoverable is False


def test_normalized_event_shapes_are_provider_neutral():
    assert ready_event() == {"type": "stt.ready"}
    assert transcript_event("interim", "seg_001", "xin chào", "vi") == {
        "type": "transcript.interim",
        "segment_id": "seg_001",
        "text": "xin chào",
        "language": "vi",
    }
    assert transcript_event("final", "seg_001", "Xin chào.", "vi") == {
        "type": "transcript.final",
        "segment_id": "seg_001",
        "text": "Xin chào.",
        "language": "vi",
    }
    assert error_event("invalid_state", "Invalid state.") == {
        "type": "stt.error",
        "code": "invalid_state",
        "message": "Invalid state.",
        "recoverable": False,
    }
    assert closed_event() == {"type": "stt.closed"}


def test_state_machine_accepts_normal_lifecycle():
    state = SttStateMachine()

    state.begin_start()
    assert state.state is ConnectionState.STARTING
    state.mark_ready()
    assert state.state is ConnectionState.STREAMING
    state.require_audio_allowed()
    state.begin_stop()
    assert state.state is ConnectionState.STOPPING
    state.mark_closed()
    assert state.state is ConnectionState.CLOSED


@pytest.mark.parametrize(
    ("setup", "action"),
    [
        ((), "audio"),
        (("begin_start",), "audio"),
        (("begin_start",), "begin_start"),
        (("begin_start", "mark_ready"), "begin_start"),
        ((), "begin_stop"),
        (("begin_start",), "begin_stop"),
        (("begin_start", "mark_ready", "begin_stop"), "audio"),
    ],
)
def test_state_machine_rejects_invalid_transitions(setup, action):
    state = SttStateMachine()
    for method_name in setup:
        getattr(state, method_name)()

    with pytest.raises(ProtocolViolation) as error:
        getattr(state, "require_audio_allowed" if action == "audio" else action)()

    assert error.value.code == "invalid_state"
    assert error.value.recoverable is False


def test_error_transition_is_terminal():
    state = SttStateMachine()

    state.mark_error()
    assert state.state is ConnectionState.ERROR
    state.mark_closed()
    assert state.state is ConnectionState.CLOSED
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python -m pytest tests/test_stt_protocol.py -q`

Expected: collection fails with `ModuleNotFoundError: No module named 'app.realtime.stt_protocol'`.

- [ ] **Step 3: Implement the minimal protocol and state module**

Create `app/realtime/stt_protocol.py`:

```python
import json
from enum import Enum
from typing import Literal, TypeAlias

from pydantic import BaseModel, ConfigDict, ValidationError


ErrorCode: TypeAlias = Literal[
    "invalid_message",
    "invalid_state",
    "unsupported_audio",
    "provider_unavailable",
    "provider_error",
    "internal_error",
]
TranscriptKind: TypeAlias = Literal["interim", "final"]


class AudioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    encoding: Literal["pcm_s16le"]
    sample_rate_hz: Literal[16000]
    channels: Literal[1]


class SttStart(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stt.start"]
    audio: AudioConfig
    language: Literal["vi"]


class SttStop(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stt.stop"]


ControlMessage: TypeAlias = SttStart | SttStop


class ProtocolViolation(Exception):
    def __init__(self, code: ErrorCode, message: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.recoverable = False


def parse_control_message(text: str) -> ControlMessage:
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ProtocolViolation("invalid_message", "Control message must be valid JSON.") from exc

    if not isinstance(payload, dict):
        raise ProtocolViolation("invalid_message", "Control message must be a JSON object.")

    message_type = payload.get("type")
    if message_type == "stt.stop":
        try:
            return SttStop.model_validate(payload)
        except ValidationError as exc:
            raise ProtocolViolation("invalid_message", "Invalid stt.stop message.") from exc

    if message_type != "stt.start":
        raise ProtocolViolation("invalid_message", "Unknown control message type.")

    if set(payload) != {"type", "audio", "language"} or payload.get("language") != "vi":
        raise ProtocolViolation("invalid_message", "Invalid stt.start message.")

    try:
        return SttStart.model_validate(payload)
    except ValidationError as exc:
        raise ProtocolViolation("unsupported_audio", "Unsupported audio declaration.") from exc


def ready_event() -> dict[str, object]:
    return {"type": "stt.ready"}


def transcript_event(
    kind: TranscriptKind,
    segment_id: str,
    text: str,
    language: Literal["vi"] = "vi",
) -> dict[str, object]:
    return {
        "type": f"transcript.{kind}",
        "segment_id": segment_id,
        "text": text,
        "language": language,
    }


def error_event(code: ErrorCode, message: str) -> dict[str, object]:
    return {
        "type": "stt.error",
        "code": code,
        "message": message,
        "recoverable": False,
    }


def closed_event() -> dict[str, object]:
    return {"type": "stt.closed"}


class ConnectionState(str, Enum):
    CONNECTED = "CONNECTED"
    STARTING = "STARTING"
    STREAMING = "STREAMING"
    STOPPING = "STOPPING"
    ERROR = "ERROR"
    CLOSED = "CLOSED"


class SttStateMachine:
    def __init__(self) -> None:
        self.state = ConnectionState.CONNECTED

    def begin_start(self) -> None:
        self._transition(ConnectionState.CONNECTED, ConnectionState.STARTING)

    def mark_ready(self) -> None:
        self._transition(ConnectionState.STARTING, ConnectionState.STREAMING)

    def require_audio_allowed(self) -> None:
        if self.state is not ConnectionState.STREAMING:
            raise ProtocolViolation("invalid_state", "Binary audio is not accepted in this state.")

    def begin_stop(self) -> None:
        self._transition(ConnectionState.STREAMING, ConnectionState.STOPPING)

    def mark_error(self) -> None:
        if self.state is ConnectionState.CLOSED:
            raise ProtocolViolation("invalid_state", "Closed streams cannot enter ERROR.")
        self.state = ConnectionState.ERROR

    def mark_closed(self) -> None:
        self.state = ConnectionState.CLOSED

    def _transition(self, expected: ConnectionState, target: ConnectionState) -> None:
        if self.state is not expected:
            raise ProtocolViolation(
                "invalid_state",
                f"Cannot transition from {self.state} to {target}.",
            )
        self.state = target
```

- [ ] **Step 4: Run focused tests and verify GREEN**

Run: `python -m pytest tests/test_stt_protocol.py -q`

Expected: `20 passed`.

- [ ] **Step 5: Run backend regression tests**

Run: `python -m pytest -q`

Expected: all existing and new backend tests pass, including `test_websocket_echoes_received_text`.

- [ ] **Step 6: Commit Task 1**

```bash
git add app/realtime/stt_protocol.py tests/test_stt_protocol.py
git diff --cached --check
git commit -m "feat(api): define STT websocket protocol"
```

---

### Task 2: Minimal Provider-Neutral Stream Boundary

**Files:**
- Create: `services/api/tests/fakes/__init__.py`
- Create: `services/api/tests/fakes/stt.py`
- Create: `services/api/tests/test_stt_provider_boundary.py`
- Create: `services/api/app/ai/stt.py`

**Interfaces:**
- Consumes: `AudioConfig` and `TranscriptKind` from `app.realtime.stt_protocol`.
- Produces: immutable provider-neutral `SttTranscript`, runtime-checkable `SttProviderStream`, `SttProviderFactory`, `ProviderUnavailableError`, `ProviderStreamError`, `unconfigured_stt_provider_factory()`, and FastAPI dependency `get_stt_provider_factory()`.
- Test-only produces: `FakeSttProviderStream`, which records lifecycle calls, uses an async queue for deterministic results/failures, and never ships as production behavior.

- [ ] **Step 1: Write the failing provider-boundary tests**

Create an empty `tests/fakes/__init__.py`, then create `tests/test_stt_provider_boundary.py`:

```python
import asyncio

import pytest

from app.ai.stt import (
    ProviderUnavailableError,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
    unconfigured_stt_provider_factory,
)
from app.realtime.stt_protocol import AudioConfig
from tests.fakes.stt import FakeSttProviderStream


def test_fake_satisfies_provider_stream_protocol():
    assert isinstance(FakeSttProviderStream(), SttProviderStream)


def test_transcript_value_is_provider_neutral():
    transcript = SttTranscript(
        kind="interim",
        segment_id="seg_001",
        text="xin chào",
        language="vi",
    )

    assert transcript.kind == "interim"
    assert transcript.segment_id == "seg_001"
    assert transcript.text == "xin chào"
    assert transcript.language == "vi"


def test_default_factory_is_explicitly_unconfigured():
    with pytest.raises(ProviderUnavailableError, match="not configured"):
        unconfigured_stt_provider_factory()

    assert get_stt_provider_factory() is unconfigured_stt_provider_factory


def test_fake_records_audio_and_cleanup():
    stream = FakeSttProviderStream()
    audio = AudioConfig(
        encoding="pcm_s16le",
        sample_rate_hz=16000,
        channels=1,
    )

    async def exercise_stream():
        await stream.start(audio, "vi")
        await stream.send_audio(b"\x00\x00")
        await stream.finish_input()
        await stream.close()

    asyncio.run(exercise_stream())

    assert stream.start_calls == [(audio, "vi")]
    assert stream.audio_chunks == [b"\x00\x00"]
    assert stream.finish_calls == 1
    assert stream.close_calls == 1
```

- [ ] **Step 2: Run the focused test and verify RED**

Run: `python -m pytest tests/test_stt_provider_boundary.py -q`

Expected: collection fails because `app.ai.stt` and `tests.fakes.stt` do not exist.

- [ ] **Step 3: Implement the provider-neutral production boundary**

Create `app/ai/stt.py`:

```python
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
```

`SttTranscript.segment_id` is an adapter-boundary contract: adapter code must translate any provider-native identifier into a non-empty backend-neutral connection-local ID before constructing this value. P1.2 has no provider-native IDs and must not add provider-ID heuristics; P1.3 must satisfy this contract inside its adapter without changing the public event.

- [ ] **Step 4: Implement the deterministic fake only under tests**

Create `tests/fakes/stt.py`:

```python
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


```

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `python -m pytest tests/test_stt_provider_boundary.py -q`

Expected: `4 passed`.

- [ ] **Step 6: Run backend regression tests**

Run: `python -m pytest -q`

Expected: all backend tests pass.

- [ ] **Step 7: Commit Task 2**

```bash
git add app/ai/stt.py tests/fakes/__init__.py tests/fakes/stt.py tests/test_stt_provider_boundary.py
git diff --cached --check
git commit -m "feat(api): add provider-neutral STT stream boundary"
```

---

### Task 3: `/ws/stt` Happy Path, Normalized Transcripts, and Router Registration

**Files:**
- Create: `services/api/tests/test_stt_websocket.py`
- Create: `services/api/app/realtime/stt_socket.py`
- Modify: `services/api/app/main.py`

**Interfaces:**
- Consumes: `get_stt_provider_factory() -> SttProviderFactory`, `SttProviderStream`, `SttTranscript`, protocol parsers/event constructors, and `SttStateMachine` from Tasks 1–2.
- Produces: `router`, `websocket_stt(websocket, provider_factory)`, and `/ws/stt` behavior with dependency-overridable provider construction.

- [ ] **Step 1: Write failing happy-path and default-production tests**

Create `tests/test_stt_websocket.py`:

```python
import asyncio
import json

from fastapi.testclient import TestClient

from app.ai.stt import SttTranscript, get_stt_provider_factory
from app.main import app
from app.realtime.stt_protocol import SttStart, SttStateMachine
from app.realtime.stt_socket import _run_stream
from tests.fakes.stt import FakeSttProviderStream


VALID_START = {
    "type": "stt.start",
    "audio": {
        "encoding": "pcm_s16le",
        "sample_rate_hz": 16000,
        "channels": 1,
    },
    "language": "vi",
}


def use_stream(stream):
    app.dependency_overrides[get_stt_provider_factory] = lambda: lambda: stream


def clear_overrides():
    app.dependency_overrides.clear()


def test_unconfigured_endpoint_reports_provider_unavailable_without_raw_detail():
    clear_overrides()
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)

        error = websocket.receive_json()
        closed = websocket.receive_json()

    assert error == {
        "type": "stt.error",
        "code": "provider_unavailable",
        "message": "STT provider is unavailable.",
        "recoverable": False,
    }
    assert closed == {"type": "stt.closed"}


def test_streams_binary_audio_and_normalized_transcripts_then_closes():
    stream = FakeSttProviderStream(
        audio_events=(
            SttTranscript("interim", "seg_001", "xin chào"),
            SttTranscript("final", "seg_001", "Xin chào."),
        )
    )
    use_stream(stream)

    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}

        websocket.send_bytes(b"\x00\x00" * 1600)
        assert websocket.receive_json() == {
            "type": "transcript.interim",
            "segment_id": "seg_001",
            "text": "xin chào",
            "language": "vi",
        }

        assert websocket.receive_json() == {
            "type": "transcript.final",
            "segment_id": "seg_001",
            "text": "Xin chào.",
            "language": "vi",
        }
        assert stream.audio_chunks == [b"\x00\x00" * 1600]

        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.finish_calls == 1
    assert stream.close_calls == 1
    clear_overrides()


class ScriptedStoppingWebSocket:
    def __init__(self):
        self.incoming: asyncio.Queue[dict[str, object]] = asyncio.Queue()
        self.sent: list[dict[str, object]] = []

    async def receive(self):
        return await self.incoming.get()

    async def send_json(self, event):
        self.sent.append(event)
        if event == {"type": "stt.ready"}:
            await self.incoming.put(
                {
                    "type": "websocket.receive",
                    "text": json.dumps({"type": "stt.stop"}),
                }
            )


def test_finish_completion_does_not_starve_final_event_drain():
    final = SttTranscript("final", "seg_001", "Xin chào.")
    stream = FakeSttProviderStream(finish_events=(final,))
    websocket = ScriptedStoppingWebSocket()
    state = SttStateMachine()
    state.begin_start()
    start = SttStart.model_validate(VALID_START)

    async def exercise():
        await asyncio.wait_for(
            _run_stream(websocket, state, stream, start),
            timeout=0.5,
        )

    asyncio.run(exercise())

    assert stream.finish_completed is True
    assert stream.finish_events_drained_after_finish is True
    assert [event["type"] for event in websocket.sent] == [
        "stt.ready",
        "transcript.final",
        "stt.closed",
    ]
```

Use `addfinalizer` or a pytest fixture during implementation if needed to guarantee `app.dependency_overrides.clear()` after assertion failures; do not leave global overrides between tests.

- [ ] **Step 2: Run focused tests and verify RED**

Run: `python -m pytest tests/test_stt_websocket.py -q`

Expected: collection fails with `ModuleNotFoundError: No module named 'app.realtime.stt_socket'`; the route and deterministic STOPPING coordinator do not exist yet.

- [ ] **Step 3: Register a separate STT router without touching `/ws/test`**

Modify only the imports and router registration in `app/main.py`:

```python
from app.realtime.stt_socket import router as stt_websocket_router
from app.realtime.test_socket import router as test_websocket_router
```

Replace the existing local alias registration with these two lines, leaving all other application setup unchanged:

```python
app.include_router(health_router)
app.include_router(test_websocket_router)
app.include_router(stt_websocket_router)
```

- [ ] **Step 4: Implement the minimal concurrent WebSocket coordinator**

Create `app/realtime/stt_socket.py`. The implementation must race client input against provider startup so binary audio sent before `stt.ready` is rejected, and race client input against provider events/flush so midstream failures and audio after stop are observable.

```python
import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import suppress
from typing import Annotated

from fastapi import APIRouter, Depends, WebSocket

from app.ai.stt import (
    ProviderUnavailableError,
    SttProviderFactory,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
)
from app.realtime.stt_protocol import (
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


async def _send_transcript(websocket: WebSocket, event: SttTranscript) -> None:
    await websocket.send_json(
        transcript_event(event.kind, event.segment_id, event.text, event.language)
    )


async def _send_terminal_error(
    websocket: WebSocket,
    state: SttStateMachine,
    code: str,
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
    done, _ = await asyncio.wait({startup, incoming}, return_when=asyncio.FIRST_COMPLETED)

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
                await _send_transcript(websocket, event_task.result())
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
                raise ProtocolViolation("unsupported_audio", "Audio chunks must not be empty.")
            await stream.send_audio(chunk)
            incoming = asyncio.create_task(websocket.receive())
            continue

        control = parse_control_message(value)
        if isinstance(control, SttStart):
            state.begin_start()
        assert isinstance(control, SttStop)
        state.begin_stop()
        break

    finish_task: asyncio.Task[None] | None = asyncio.create_task(
        stream.finish_input()
    )
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
                await _send_transcript(websocket, event_task.result())
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
    provider_factory: Annotated[SttProviderFactory, Depends(get_stt_provider_factory)],
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
```

During implementation, keep `ErrorCode` as the `_send_terminal_error` code annotation instead of `str` by importing it from `stt_protocol`; this ensures the normalized taxonomy is statically constrained.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run: `python -m pytest tests/test_stt_websocket.py -q`

Expected: `3 passed`, including completion of the STOPPING drain regression's `asyncio.wait_for` call with `timeout=0.5`, without timeout or spin.

- [ ] **Step 6: Verify `/ws/test` regression immediately**

Run: `python -m pytest tests/test_websocket.py -q`

Expected: `1 passed`; text sent to `/ws/test` is echoed unchanged.

- [ ] **Step 7: Run the full backend suite**

Run: `python -m pytest -q`

Expected: all backend tests pass.

- [ ] **Step 8: Commit Task 3**

```bash
git add app/main.py app/realtime/stt_socket.py tests/test_stt_websocket.py
git diff --cached --check
git commit -m "feat(api): add STT websocket baseline"
```

---

### Task 4: Invalid Frames, Startup/Streaming Failures, and Cleanup

**Files:**
- Modify: `services/api/tests/test_stt_websocket.py`
- Modify: `services/api/app/realtime/stt_socket.py`

**Interfaces:**
- Consumes: `/ws/stt`, the test-only `FakeSttProviderStream`, normalized error events, and all state transitions from Tasks 1–3.
- Produces: integration evidence for every required invalid case, runtime validation of every normalized transcript before broadcast, safe exception mapping, final-before-closed flushing, and abrupt-disconnect cleanup.

- [ ] **Step 1: Replace global override helpers with a cleanup-safe fixture**

Add this import and fixture near the top of `tests/test_stt_websocket.py`, then update the two Task 3 tests to accept `provider_override` and call it rather than `use_stream`/`clear_overrides`:

```python
import pytest


@pytest.fixture
def provider_override():
    def install(stream):
        app.dependency_overrides[get_stt_provider_factory] = lambda: lambda: stream
        return stream

    yield install
    app.dependency_overrides.clear()
```

For the unconfigured test, accept the fixture but do not call it; the fixture teardown still guarantees a clean global app after failures.

- [ ] **Step 2: Add exact state and message regression tests**

Append to `tests/test_stt_websocket.py`:

```python
from starlette.websockets import WebSocketDisconnect


def assert_terminal_error(websocket, code):
    error = websocket.receive_json()
    assert error["type"] == "stt.error"
    assert error["code"] == code
    assert error["recoverable"] is False
    assert set(error) == {"type", "code", "message", "recoverable"}
    assert websocket.receive_json() == {"type": "stt.closed"}
    with pytest.raises(WebSocketDisconnect):
        websocket.receive_json()


@pytest.mark.parametrize(
    ("send", "code"),
    [
        (lambda ws: ws.send_bytes(b"\x00\x00"), "invalid_state"),
        (lambda ws: ws.send_text("not-json"), "invalid_message"),
        (lambda ws: ws.send_json({"type": "unknown"}), "invalid_message"),
        (lambda ws: ws.send_json({"type": "stt.stop"}), "invalid_state"),
        (
            lambda ws: ws.send_json(
                {
                    **VALID_START,
                    "audio": {**VALID_START["audio"], "encoding": "opus"},
                }
            ),
            "unsupported_audio",
        ),
    ],
)
def test_rejects_invalid_first_frame(provider_override, send, code):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        send(websocket)
        assert_terminal_error(websocket, code)

    assert stream.start_calls == []
    assert stream.close_calls == 0


def test_rejects_binary_audio_before_ready(provider_override):
    stream = provider_override(FakeSttProviderStream(block_start=True))
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        websocket.send_bytes(b"\x00\x00")
        assert_terminal_error(websocket, "invalid_state")

    assert stream.audio_chunks == []
    assert stream.close_calls == 1


def test_rejects_duplicate_start(provider_override):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json(VALID_START)
        assert_terminal_error(websocket, "invalid_state")

    assert stream.close_calls == 1


def test_rejects_audio_after_stop(provider_override):
    stream = provider_override(FakeSttProviderStream(block_finish=True))
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json({"type": "stt.stop"})
        websocket.send_bytes(b"\x00\x00")
        assert_terminal_error(websocket, "invalid_state")

    assert stream.close_calls == 1
```

- [ ] **Step 3: Run invalid-frame tests and verify their contract coverage**

Run: `python -m pytest tests/test_stt_websocket.py -q -k "invalid or before_ready or duplicate or after_stop"`

Expected: all selected cases pass against the state/concurrency coordinator from Task 3. If one fails, retain the failure output and correct only the mismatched state branch before continuing.

- [ ] **Step 4: Keep the normalized error code annotation exact**

Import `ErrorCode` from `stt_protocol` and use the exact constrained signature below; make no other production change in this step when Step 3 is green:

```python
# Type-safe error signature:
async def _send_terminal_error(
    websocket: WebSocket,
    state: SttStateMachine,
    code: ErrorCode,
    message: str,
) -> None:
```

- [ ] **Step 5: Run invalid-frame tests and verify GREEN**

Run: `python -m pytest tests/test_stt_websocket.py -q -k "invalid or before_ready or duplicate or after_stop"`

Expected: all selected cases pass; each receives exactly one normalized terminal error, then `stt.closed`, then transport closure.

- [ ] **Step 6: Add exact failing tests for provider failures, log sanitization, segment invariants, flush ordering, and disconnect cleanup**

Append to `tests/test_stt_websocket.py`:

```python
import logging

from app.ai.stt import ProviderStreamError, ProviderUnavailableError


@pytest.mark.parametrize(
    ("stream", "expected_code", "forbidden_text"),
    [
        (
            FakeSttProviderStream(
                start_error=ProviderUnavailableError("secret startup detail")
            ),
            "provider_unavailable",
            "secret startup detail",
        ),
        (
            FakeSttProviderStream(
                send_error=ProviderStreamError("secret midstream detail")
            ),
            "provider_error",
            "secret midstream detail",
        ),
    ],
)
def test_provider_failures_are_normalized(
    provider_override, stream, expected_code, forbidden_text
):
    provider_override(stream)
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        if stream.start_error is None:
            assert websocket.receive_json() == {"type": "stt.ready"}
            websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error["type"] == "stt.error"
        assert error["code"] == expected_code
        assert forbidden_text not in error["message"]
        assert error["recoverable"] is False
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.close_calls == 1


def test_unexpected_error_is_sanitized_for_client_and_logs(
    provider_override, caplog
):
    stream = provider_override(
        FakeSttProviderStream(
            send_error=RuntimeError("secret internal detail")
        )
    )
    with caplog.at_level(logging.ERROR, logger="app.realtime.stt_socket"):
        with TestClient(app).websocket_connect("/ws/stt") as websocket:
            websocket.send_json(VALID_START)
            assert websocket.receive_json() == {"type": "stt.ready"}
            websocket.send_bytes(b"\x00\x00")
            error = websocket.receive_json()
            assert error == {
                "type": "stt.error",
                "code": "internal_error",
                "message": "Internal STT error.",
                "recoverable": False,
            }
            assert websocket.receive_json() == {"type": "stt.closed"}

    assert "secret internal detail" not in error["message"]
    assert "secret internal detail" not in caplog.text
    assert "exception_type=RuntimeError" in caplog.text
    assert stream.close_calls == 1


def test_provider_event_failure_is_normalized(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            event_error=ProviderStreamError("raw event failure")
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error["code"] == "provider_error"
        assert "raw event failure" not in error["message"]
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.close_calls == 1


def test_repeated_interims_for_same_segment_are_allowed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("interim", "seg_001", "xin"),
                SttTranscript("interim", "seg_001", "xin chào"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["text"] == "xin"
        assert websocket.receive_json()["text"] == "xin chào"
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_final_after_interim_is_allowed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("interim", "seg_001", "xin chào"),
                SttTranscript("final", "seg_001", "Xin chào."),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.interim"
        assert websocket.receive_json()["type"] == "transcript.final"
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_interim_after_final_is_rejected(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("final", "seg_001", "Xin chào."),
                SttTranscript("interim", "seg_001", "invalid revision"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.final"
        assert_terminal_error(websocket, "provider_error")


def test_duplicate_final_is_rejected(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(
                SttTranscript("final", "seg_001", "Xin chào."),
                SttTranscript("final", "seg_001", "duplicate"),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        assert websocket.receive_json()["type"] == "transcript.final"
        assert_terminal_error(websocket, "provider_error")


def assert_malformed_transcript_is_provider_error(
    provider_override,
    event,
    forbidden_public_value=None,
):
    stream = provider_override(
        FakeSttProviderStream(
            audio_events=(event,)
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_bytes(b"\x00\x00")
        error = websocket.receive_json()
        assert error == {
            "type": "stt.error",
            "code": "provider_error",
            "message": "STT provider stream failed.",
            "recoverable": False,
        }
        if forbidden_public_value is not None:
            assert forbidden_public_value not in error["message"]
        assert websocket.receive_json() == {"type": "stt.closed"}


def test_unsupported_transcript_kind_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("partial", "seg_001", "invalid kind"),
        "partial",
    )


def test_non_vi_transcript_language_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "seg_001", "wrong language", language="en"),
        "en",
    )


def test_non_string_segment_id_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", 12345, "invalid segment ID"),
        "12345",
    )


def test_blank_segment_id_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "   ", "blank segment ID"),
    )


def test_non_string_transcript_text_is_rejected(provider_override):
    assert_malformed_transcript_is_provider_error(
        provider_override,
        SttTranscript("interim", "seg_001", ["secret malformed text"]),
        "secret malformed text",
    )


def test_stop_flushes_final_before_closed(provider_override):
    stream = provider_override(
        FakeSttProviderStream(
            finish_events=(
                SttTranscript("final", "seg_001", "Xin chào."),
            )
        )
    )
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.send_json({"type": "stt.stop"})
        assert websocket.receive_json()["type"] == "transcript.final"
        assert websocket.receive_json() == {"type": "stt.closed"}

    assert stream.finish_calls == 1
    assert stream.finish_completed is True
    assert stream.finish_events_drained_after_finish is True
    assert stream.close_calls == 1


def test_abrupt_client_disconnect_closes_provider(provider_override):
    stream = provider_override(FakeSttProviderStream())
    with TestClient(app).websocket_connect("/ws/stt") as websocket:
        websocket.send_json(VALID_START)
        assert websocket.receive_json() == {"type": "stt.ready"}
        websocket.close()

    assert stream.close_calls == 1
```

- [ ] **Step 7: Run failure/cleanup tests and verify RED**

Run: `python -m pytest tests/test_stt_websocket.py -q`

Expected: RED for three concrete reasons. The midstream `ProviderStreamError` and provider-event failure emit `internal_error` instead of `provider_error`; invalid segment sequences are still broadcast; and malformed dataclass values either produce unsupported public transcript fields or trigger `internal_error` rather than terminal `provider_error`. The Task 3 STOPPING regression already passes its 0.5-second timeout with completed tasks removed from the active set. The `RuntimeError("secret internal detail")` case must show sanitized `internal_error` output and sanitized logs containing only `exception_type=RuntimeError`.

- [ ] **Step 8: Add provider-error normalization and the minimal segment guard**

Import `ProviderStreamError` from `app.ai.stt`. Keep the public messages fixed and add no raw exception interpolation. Insert its specific branch between `ProviderUnavailableError` and the generic exception branch so provider `send_audio`, `finish_input`, and `anext(events)` failures use the approved category:

```python
except ProviderUnavailableError:
    await _send_terminal_error(
        websocket, state, "provider_unavailable", "STT provider is unavailable."
    )
except ProviderStreamError:
    await _send_terminal_error(
        websocket, state, "provider_error", "STT provider stream failed."
    )
except Exception as exc:
    logger.error(
        "stt.websocket.internal_error exception_type=%s",
        type(exc).__name__,
    )
    await _send_terminal_error(
        websocket, state, "internal_error", "Internal STT error."
    )
```

`SttTranscript` remains a minimal dataclass; its annotations document the adapter contract but do not enforce it at runtime. Replace Task 3's `_send_transcript` with this connection-local validation boundary so every adapter event is checked immediately before `send_json`:

```python
def _validate_transcript(
    event: SttTranscript,
    finalized_segment_ids: set[str],
) -> None:
    if event.kind not in ("interim", "final"):
        raise ProviderStreamError("Invalid normalized transcript kind")
    if not isinstance(event.segment_id, str) or not event.segment_id.strip():
        raise ProviderStreamError("Invalid normalized transcript segment_id")
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
```

Initialize the guard once per `_run_stream` connection, immediately before obtaining the provider event iterator:

```python
finalized_segment_ids: set[str] = set()
events: AsyncIterator[SttTranscript] = stream.events()
```

Use that same set at both transcript-send sites—the STREAMING loop and the STOPPING drain loop:

```python
await _send_transcript(
    websocket,
    event_task.result(),
    finalized_segment_ids,
)
```

Only validated `interim` and `final` kinds can reach `transcript_event`, so the public event type is restricted to `transcript.interim` or `transcript.final`. Only validated `vi` events can be broadcast. Repeated interim events do not add the ID and remain valid. The first final adds it. A malformed kind, ID, text, language, or any later interim/final for a finalized ID raises `ProviderStreamError`, which is normalized to terminal `provider_error` without serializing the guard message or malformed value.

Retain `finally: await stream.close()` under `suppress(Exception)` so cleanup runs once after normal stop, provider failure, protocol failure, or client disconnect. Never serialize `str(exc)` into a client event. The generic branch must call `logger.error` with the fixed message template and `type(exc).__name__` exactly as shown; do not use exception-trace logging, exception-info flags, raw provider payloads, or exception messages.

- [ ] **Step 9: Run all `/ws/stt` tests and verify GREEN**

Run: `python -m pytest tests/test_stt_websocket.py -q`

Expected: all `/ws/stt` tests pass, including the two happy-path tests from Task 3 and every invalid/failure/cleanup case.

- [ ] **Step 10: Commit Task 4**

```bash
git add app/realtime/stt_socket.py tests/test_stt_websocket.py
git diff --cached --check
git commit -m "test(api): cover STT websocket failures and cleanup"
```

---

### Task 5: Backend Regression and Scope Verification

**Files:**
- Verify only; no planned file changes.

**Interfaces:**
- Consumes: all P1.2 production/test files and the unchanged existing backend suite.
- Produces: fresh evidence that the complete backend baseline passes and remains in scope.

- [ ] **Step 1: Run the exact `/ws/test` regression**

Run: `python -m pytest tests/test_websocket.py::test_websocket_echoes_received_text -q`

Expected: `1 passed`; `/ws/test` still echoes received text.

- [ ] **Step 2: Run protocol and provider-boundary tests**

Run: `python -m pytest tests/test_stt_protocol.py tests/test_stt_provider_boundary.py -q`

Expected: all protocol, state, interface, and test-fake tests pass.

- [ ] **Step 3: Run all STT WebSocket tests**

Run: `python -m pytest tests/test_stt_websocket.py -q`

Expected: all normal lifecycle, transcript normalization, invalid transition, provider failure, flush, and disconnect-cleanup tests pass.

- [ ] **Step 4: Run the required full backend suite**

Run: `python -m pytest`

Expected: exit 0 with zero failed/error tests.

- [ ] **Step 5: Inspect formatting and complete diff**

Run from the repository root:

```bash
git diff --check
git status --short
git diff -- app/main.py app/ai/stt.py app/realtime/stt_protocol.py app/realtime/stt_socket.py tests/test_stt_protocol.py tests/test_stt_provider_boundary.py tests/test_stt_websocket.py tests/fakes/__init__.py tests/fakes/stt.py
```

Expected: `git diff --check` exits 0; status/diff contain only the planned backend files; no Web/Mobile, dependency, configuration, secret, provider SDK, or `/ws/test` implementation change appears.

- [ ] **Step 6: Verify committed task scope and history**

Run from the repository root:

```bash
git log --oneline 1b7c6cf..HEAD
git diff --name-status 1b7c6cf..HEAD
git status --short --branch
```

Expected: only the Task 1–4 local commits are listed; the cumulative diff contains only the planned P1.2 backend paths; the working tree is clean.

- [ ] **Step 7: Create no extra commit**

Task 5 is verification-only. If Step 5 shows no file change, do not create an empty commit. Report exact test counts, warnings, diff/status, and any known issue. Do not push or merge.

## Requirement-to-Task Traceability

| P1.2 requirement | Plan coverage |
|---|---|
| Python runtime compatibility | Global constraint and Task 1 use Python 3.10-compatible `class ConnectionState(str, Enum)` based on observed Python 3.10.11 and no declared higher floor. |
| Public protocol schemas and normalized events | Task 1 parsing/event tests and `stt_protocol.py`. |
| `CONNECTED → STARTING → STREAMING → STOPPING → CLOSED`, plus `ERROR` | Task 1 state-machine tests; Tasks 3–4 integration paths. |
| Binary audio before `stt.start` | Task 4 `test_rejects_invalid_first_frame` binary case. |
| Binary audio before `stt.ready` | Task 4 `test_rejects_binary_audio_before_ready`. |
| Malformed JSON | Tasks 1 and 4 invalid-message cases. |
| Unknown control message type | Tasks 1 and 4 invalid-message cases. |
| Unsupported audio declaration | Tasks 1 and 4 `unsupported_audio` cases. |
| Duplicate `stt.start` | Tasks 1 and 4 duplicate-start cases. |
| `stt.stop` before `STREAMING` | Tasks 1 and 4 early-stop cases. |
| Binary audio after `stt.stop` | Tasks 1 and 4 STOPPING-state cases. |
| Provider startup failure | Tasks 3–4 `provider_unavailable` tests. |
| Provider mid-stream failure | Task 4 send/event failure tests mapped to `provider_error`. |
| Unexpected backend failure and sanitized logging | Task 4 `RuntimeError("secret internal detail")` test requires `internal_error`, absence from client/logs, and class-only `exception_type=RuntimeError` metadata. |
| Abrupt client disconnect cleanup | Task 4 disconnect test and provider `close_calls` assertion. |
| Deterministic interim/final normalized path | Task 3 test-only fake emits both transcript kinds. |
| STOPPING cannot spin on completed finish task | Task 3's `asyncio.wait_for` regression and concrete nullable `finish_task` loop remove the task after one await while the event iterator controls drain completion. |
| Flush final transcript after `finish_input` completion and before `stt.closed` | Tasks 3–4 assert `finish_completed`, `finish_events_drained_after_finish`, and final-before-closed ordering. |
| Runtime validation before transcript broadcast | Task 4 `_validate_transcript` runs before every transcript `send_json`; dataclass annotations are documentation, not the enforcement boundary. |
| Transcript kind is exactly `interim` or `final` | Task 4 `test_unsupported_transcript_kind_is_rejected`; malformed kinds terminate as `provider_error`, so no other public transcript type can be formed. |
| Transcript language is exactly `vi` | Task 4 `test_non_vi_transcript_language_is_rejected`; malformed language terminates as `provider_error`. |
| Transcript text is a string | Task 4 `test_non_string_transcript_text_is_rejected`; raw malformed text is absent from the public error. |
| Non-empty, backend-neutral string `segment_id` | Task 2 adapter-boundary contract plus Task 4 non-string and blank-ID rejection. Provider-native IDs must be normalized inside adapter code before `SttTranscript` construction. |
| Repeated interim events reuse one segment ID | Task 4 `test_repeated_interims_for_same_segment_are_allowed`. |
| First final finalizes a segment | Task 4 `test_final_after_interim_is_allowed` and connection-local finalized-ID set. |
| No interim after final | Task 4 `test_interim_after_final_is_rejected` mapped to terminal `provider_error`. |
| No duplicate final | Task 4 `test_duplicate_final_is_rejected` mapped to terminal `provider_error`. |
| Production without a real provider | Tasks 2–3 explicit unconfigured factory and terminal `provider_unavailable`. |
| `/ws/test` remains unchanged | No edit to `test_socket.py`; Tasks 1, 3, and 5 run the existing echo regression. |
| Full backend regression | Task 5 runs `python -m pytest`. |

## P1.2 Completion Boundary

After Task 5, `/ws/stt` has a tested provider-neutral protocol and adapter seam but production deliberately responds with terminal `provider_unavailable` because no provider is configured. That explicit behavior is the correct P1.2 boundary. Selecting/configuring a real provider and replacing the unconfigured factory belongs to P1.3; microphone capture, client rendering, benchmarks, and reconnect UX remain in P1.4–P1.8.
