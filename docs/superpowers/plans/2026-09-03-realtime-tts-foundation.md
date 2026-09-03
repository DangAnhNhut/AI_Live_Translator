# P3.0A Realtime TTS Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` while executing each task. Execute inline unless the human reviewer explicitly authorizes delegation. Steps use checkbox (`- [ ]`) syntax for tracking. Do not commit, push, merge, switch branches, or create a worktree.

**Goal:** Build and deterministically test the provider-neutral TTS domain, protocol, and bounded sequential session foundation without realtime socket integration, client playback, or a real provider.

**Architecture:** A committed Translation result will eventually be submitted once to a backend `TtsSession`. P3.0A supplies a bounded eight-item queue and one sequential worker around a provider-neutral `SpeechSynthesizer`; each provider call has a 10-second limit while the complete clean-stop TTS drain has one separate 5-second deadline. JSON lifecycle events use one callback while validated `tts.audio` metadata and raw bytes cross a second callback together. This plan defines that foundation only and leaves WebSocket fan-out to P3.0B.

**Tech Stack:** Python 3.11.9 environment with Python 3.10-compatible syntax, standard-library `asyncio`, dataclasses and typing protocols, Pydantic 2.13.4, and pytest 9.1.1. No dependency is added.

**Spec:** `docs/superpowers/specs/2026-09-03-realtime-tts-foundation-design.md`

## Global constraints

- Work from `D:\AI_Live_Translator_RealSTT` on the existing `feature/stt-provider-benchmark` branch; do not rename or switch it.
- Use `D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe` for every Python command.
- Preserve all approved dirty and untracked work. Never reset, clean, stash, restore, or overwrite unrelated paths.
- Do not run `git add`, `git commit`, `git push`, or `git merge` during this milestone.
- P3.0A may touch only the nine paths listed in the File Map below.
- Do not modify `/ws/stt` runtime construction, `SessionEventPublisher`, `SessionHub`, Web, Mobile, provider configuration, or dependencies.
- Do not call Deepgram, Cloudflare, Google, a TTS provider, a browser, or an Android device.
- Preserve STT-only and Translation-only behavior when `tts` is omitted or disabled.
- Lock configuration semantics explicitly: omitted `tts` preserves current behavior, `tts.enabled=false` is inert, and `tts.enabled=true` requires Translation configuration.
- Audio bytes must never appear in JSON or Base64.
- One unique `(stream_id, utterance_id)` causes at most one synthesis request.
- Queue size defaults to 8; per-request synthesis timeout defaults to 10.0 seconds; each session has one worker.
- The future clean-stop integration must call `TtsSession.flush_and_drain(timeout_seconds=5.0)` once. That value is one total deadline across the current request, queued requests, publications, cancellation, and TTS task release; it is never applied once per queue item.

## File map

Create:

- `services/api/app/ai/tts.py` — immutable synthesized-audio domain, provider-neutral errors, protocol, and factory type.
- `services/api/app/realtime/tts_protocol.py` — exact TTS event constructors and error-code alias.
- `services/api/app/realtime/tts_session.py` — validation, deduplication, bounded queue, sequential synthesis, event mapping, and lifecycle.
- `services/api/tests/fakes/tts.py` — deterministic fake, recorded calls, controlled outcomes/gates, and concurrency/cancellation counters.
- `services/api/tests/test_tts_provider.py` — domain and fake contract tests.
- `services/api/tests/test_tts_protocol.py` — exact normalized event-schema tests.
- `services/api/tests/test_tts_session.py` — ordering, cost, backpressure, failure, and lifecycle tests.

Modify:

- `services/api/app/realtime/stt_protocol.py` — parse optional `TtsConfig`; no runtime provider construction.
- `services/api/tests/test_stt_protocol.py` — TTS start validation and backward-compatibility tests.

No other file is in P3.0A implementation scope.

---

### Task 1: Provider-neutral TTS domain and deterministic fake

**Files:**

- Create: `services/api/app/ai/tts.py`
- Create: `services/api/tests/fakes/tts.py`
- Create: `services/api/tests/test_tts_provider.py`

**Interfaces:**

- Consumes: `TargetLanguage` from `app.realtime.stt_protocol`.
- Produces: `SynthesizedAudio`, `InvalidSynthesizedAudio`, `TtsProviderUnavailable`, `TtsProviderError`, `SpeechSynthesizer`, and `SpeechSynthesizerFactory` in `app.ai.tts`.
- Produces for Tasks 3–4: `FakeSpeechSynthesizer`, `SynthesisCall`, recorded `calls`, `call_started`, `cancelled_calls`, `active_calls`, and `maximum_active_calls`.

- [ ] **Step 1: Write RED domain validation tests**

Create `services/api/tests/test_tts_provider.py` with these concrete assertions:

```python
import asyncio
from dataclasses import FrozenInstanceError

import pytest

from app.ai.tts import (
    InvalidSynthesizedAudio,
    SynthesizedAudio,
    TtsProviderError,
)
from tests.fakes.tts import FakeSpeechSynthesizer


def test_synthesized_audio_is_provider_neutral_immutable_and_valid():
    result = SynthesizedAudio(
        audio_bytes=b"audio",
        mime_type="audio/mpeg",
        sample_rate_hz=24000,
    )
    assert result.audio_bytes == b"audio"
    assert result.mime_type == "audio/mpeg"
    assert result.sample_rate_hz == 24000
    with pytest.raises(FrozenInstanceError):
        result.mime_type = "audio/wav"


@pytest.mark.parametrize(
    "kwargs",
    (
        {"audio_bytes": b"", "mime_type": "audio/mpeg"},
        {"audio_bytes": bytearray(b"audio"), "mime_type": "audio/mpeg"},
        {"audio_bytes": b"audio", "mime_type": "   "},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": 0},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": True},
    ),
)
def test_synthesized_audio_rejects_invalid_provider_neutral_data(kwargs):
    with pytest.raises(InvalidSynthesizedAudio):
        SynthesizedAudio(**kwargs)
```

- [ ] **Step 2: Write RED fake behavior tests**

Append tests that define exact fake behavior:

```python
def test_fake_synthesizer_records_successful_call():
    async def exercise():
        expected = SynthesizedAudio(b"speech", "audio/wav", 16000)
        fake = FakeSpeechSynthesizer(outcomes=(expected,))
        result = await fake.synthesize(
            text="Hello.", language="en", voice="voice-a"
        )
        return fake, result

    fake, result = asyncio.run(exercise())
    assert result.audio_bytes == b"speech"
    assert fake.calls[0].text == "Hello."
    assert fake.calls[0].language == "en"
    assert fake.calls[0].voice == "voice-a"
    assert fake.maximum_active_calls == 1


def test_fake_synthesizer_raises_controlled_provider_failure():
    async def exercise():
        fake = FakeSpeechSynthesizer(
            outcomes=(TtsProviderError("controlled detail"),)
        )
        with pytest.raises(TtsProviderError):
            await fake.synthesize(text="Hello.", language="en")
        return fake

    fake = asyncio.run(exercise())
    assert len(fake.calls) == 1
    assert fake.active_calls == 0


def test_fake_synthesizer_gate_supports_hang_and_cancellation():
    async def exercise():
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        task = asyncio.create_task(
            fake.synthesize(text="Hello.", language="en")
        )
        await fake.call_started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        return fake

    fake = asyncio.run(exercise())
    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
```

- [ ] **Step 3: Run Task 1 tests and verify RED**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_provider.py -q
```

Expected: collection fails because `app.ai.tts` and `tests.fakes.tts` do not exist. Confirm the failure is missing P3.0A symbols, not an environment or unrelated-suite failure.

- [ ] **Step 4: Implement the minimal provider-neutral domain**

Create `services/api/app/ai/tts.py` with the exact public surface:

```python
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
            raise InvalidSynthesizedAudio("audio_bytes must be non-empty bytes")
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
```

- [ ] **Step 5: Implement the deterministic fake**

Create `services/api/tests/fakes/tts.py`:

```python
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
            self.maximum_active_calls, self.active_calls
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
```

- [ ] **Step 6: Verify GREEN, then refactor and re-run**

Run the Task 1 command again. Expected: all tests in `test_tts_provider.py` pass. Review names, imports, immutability, and exception messages; remove duplication without expanding the interface. Run the same command once more after any refactor and require exit 0.

- [ ] **Step 7: Review Task 1 diff without committing**

Run from the repository root:

```powershell
git diff --check -- services/api/app/ai/tts.py services/api/tests/fakes/tts.py services/api/tests/test_tts_provider.py
git diff -- services/api/app/ai/tts.py services/api/tests/fakes/tts.py services/api/tests/test_tts_provider.py
```

Expected: only the three Task 1 files appear and no secret, provider adapter, dependency, or network code exists. Do not stage or commit.

---

### Task 2: Optional start configuration and exact TTS event schemas

**Files:**

- Create: `services/api/app/realtime/tts_protocol.py`
- Create: `services/api/tests/test_tts_protocol.py`
- Modify: `services/api/app/realtime/stt_protocol.py`
- Modify: `services/api/tests/test_stt_protocol.py`

**Interfaces:**

- Consumes: `TargetLanguage` from `app.realtime.stt_protocol`.
- Produces: `TtsConfig(enabled: bool, voice: str | None)`, `SttStart.tts`, `TtsErrorCode`, and four event constructors.
- Produces for Task 3: `tts_pending_event`, `tts_audio_event`, and `tts_utterance_error_event` with the exact argument names shown below.

- [ ] **Step 1: Write RED start-contract tests**

Append these cases to `services/api/tests/test_stt_protocol.py`:

```python
def test_parse_valid_start_with_disabled_tts_preserves_stt_only_contract():
    payload = json.loads(VALID_START)
    payload["tts"] = {"enabled": False}
    message = parse_control_message(json.dumps(payload))
    assert message.tts is not None
    assert message.tts.enabled is False
    assert message.tts.voice is None
    assert message.translation is None


def test_parse_valid_start_with_translation_and_enabled_tts():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = {"enabled": True, "voice": "voice-a"}
    message = parse_control_message(json.dumps(payload))
    assert message.translation.target_language == "en"
    assert message.tts.enabled is True
    assert message.tts.voice == "voice-a"


def test_translation_only_start_keeps_tts_omitted():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    message = parse_control_message(json.dumps(payload))
    assert message.translation.target_language == "en"
    assert message.tts is None


def test_parse_valid_translation_start_with_explicit_tts_disabled():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = {"enabled": False}
    message = parse_control_message(json.dumps(payload))
    assert message.translation.target_language == "en"
    assert message.tts.enabled is False
    assert message.tts.voice is None


@pytest.mark.parametrize(
    "tts",
    (
        None,
        {},
        {"enabled": 1},
        {"enabled": "true"},
        {"enabled": True, "voice": "   "},
        {"enabled": True, "voice": "v" * 129},
        {"enabled": True, "provider": "vendor"},
    ),
)
def test_parse_rejects_invalid_tts_configuration(tts):
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = tts
    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))
    assert error.value.code == "invalid_message"


def test_enabled_tts_requires_translation_configuration():
    payload = json.loads(VALID_START)
    payload["tts"] = {"enabled": True}
    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))
    assert error.value.code == "invalid_message"
```

Also add `assert message.tts is None` to the existing `test_parse_valid_start_contract` and `test_parse_valid_start_with_translation_target` cases. Together with the new tests, Task 2 must prove all six matrix rows: STT only; STT with disabled TTS; Translation only; Translation with disabled TTS; Translation with enabled TTS; and invalid enabled TTS without Translation. Retain every other existing assertion and the all-eight-target Translation parametrization.

- [ ] **Step 2: Write RED normalized-event tests**

Create `services/api/tests/test_tts_protocol.py` with exact equality assertions:

```python
from app.realtime.tts_protocol import (
    tts_audio_event,
    tts_configured_event,
    tts_pending_event,
    tts_session_error_event,
    tts_utterance_error_event,
)


def test_tts_configured_omits_absent_voice_and_includes_selected_voice():
    assert tts_configured_event(
        stream_id="stream_123", target_language="en"
    ) == {
        "type": "tts.configured",
        "stream_id": "stream_123",
        "target_language": "en",
    }
    assert tts_configured_event(
        stream_id="stream_123", target_language="en", voice="voice-a"
    )["voice"] == "voice-a"


def test_tts_pending_uses_translation_identity():
    assert tts_pending_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        target_language="en",
    ) == {
        "type": "tts.pending",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "target_language": "en",
    }


def test_tts_audio_is_metadata_only_and_omits_unknown_sample_rate():
    event = tts_audio_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        audio_id="audio_000001",
        target_language="en",
        mime_type="audio/mpeg",
        byte_length=6,
        sample_rate_hz=None,
    )
    assert event == {
        "type": "tts.audio",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "audio_id": "audio_000001",
        "target_language": "en",
        "mime_type": "audio/mpeg",
        "byte_length": 6,
    }
    assert "audio_bytes" not in event
    assert "audio" not in event
    assert "base64" not in event


def test_tts_audio_includes_known_sample_rate():
    event = tts_audio_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        audio_id="audio_000001",
        target_language="en",
        mime_type="audio/wav",
        byte_length=6,
        sample_rate_hz=16000,
    )
    assert event["sample_rate_hz"] == 16000


def test_tts_error_schemas_keep_session_and_utterance_scopes_distinct():
    utterance = tts_utterance_error_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        target_language="en",
        code="provider_error",
        message="Speech synthesis failed for this passage.",
    )
    session = tts_session_error_event(
        stream_id="stream_123",
        target_language="en",
        code="provider_unavailable",
        message="Speech synthesis is unavailable.",
    )
    assert utterance["scope"] == "utterance"
    assert utterance["utterance_id"] == "utt_000001"
    assert session["scope"] == "session"
    assert "utterance_id" not in session
```

- [ ] **Step 3: Run Task 2 tests and verify RED**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_protocol.py tests/test_stt_protocol.py -q
```

Expected: RED because `tts_protocol.py`, `TtsConfig`, `SttStart.tts`, and the `tts` allowed field do not exist.

- [ ] **Step 4: Implement strict optional TTS start parsing**

Modify `stt_protocol.py` with `field_validator` and `model_validator` from Pydantic, then add:

```python
class TtsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = Field(strict=True)
    voice: str | None = Field(default=None, min_length=1, max_length=128)

    @field_validator("voice")
    @classmethod
    def reject_blank_voice(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("voice must not be blank")
        return value
```

Add `tts: TtsConfig | None = None` to `SttStart` and validate the feature dependency:

```python
@model_validator(mode="after")
def require_translation_for_enabled_tts(self) -> "SttStart":
    if self.tts is not None and self.tts.enabled and self.translation is None:
        raise ValueError("enabled TTS requires translation")
    return self
```

Change `allowed_fields` to include `"tts"`, reject explicit `tts: null` in the existing pre-validation condition, and classify validation errors rooted at `tts` or the model-level dependency as `invalid_message`:

```python
if any(
    not error["loc"]
    or error["loc"][:1]
    in (("session_id",), ("translation",), ("tts",))
    for error in exc.errors()
):
    raise ProtocolViolation(
        "invalid_message", "Invalid stt.start message."
    ) from exc
```

Do not import or construct a synthesizer in `stt_protocol.py` or `stt_socket.py`.

- [ ] **Step 5: Implement exact event constructors**

Create `services/api/app/realtime/tts_protocol.py` with:

```python
from typing import Literal, TypeAlias

from app.realtime.stt_protocol import TargetLanguage


TtsErrorCode: TypeAlias = Literal[
    "provider_unavailable",
    "provider_error",
    "queue_overflow",
    "request_timeout",
    "invalid_audio",
    "internal_error",
]


def tts_configured_event(
    *,
    stream_id: str,
    target_language: TargetLanguage,
    voice: str | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "type": "tts.configured",
        "stream_id": stream_id,
        "target_language": target_language,
    }
    if voice is not None:
        event["voice"] = voice
    return event


def tts_pending_event(
    *,
    stream_id: str,
    utterance_id: str,
    target_language: TargetLanguage,
) -> dict[str, object]:
    return {
        "type": "tts.pending",
        "stream_id": stream_id,
        "utterance_id": utterance_id,
        "target_language": target_language,
    }


def tts_audio_event(
    *,
    stream_id: str,
    utterance_id: str,
    audio_id: str,
    target_language: TargetLanguage,
    mime_type: str,
    byte_length: int,
    sample_rate_hz: int | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "type": "tts.audio",
        "stream_id": stream_id,
        "utterance_id": utterance_id,
        "audio_id": audio_id,
        "target_language": target_language,
        "mime_type": mime_type,
        "byte_length": byte_length,
    }
    if sample_rate_hz is not None:
        event["sample_rate_hz"] = sample_rate_hz
    return event


def tts_utterance_error_event(
    *,
    stream_id: str,
    utterance_id: str,
    target_language: TargetLanguage,
    code: TtsErrorCode,
    message: str,
) -> dict[str, object]:
    event = tts_pending_event(
        stream_id=stream_id,
        utterance_id=utterance_id,
        target_language=target_language,
    )
    event.update(
        {
            "type": "tts.error",
            "scope": "utterance",
            "code": code,
            "message": message,
        }
    )
    return event


def tts_session_error_event(
    *,
    stream_id: str,
    target_language: TargetLanguage,
    code: TtsErrorCode,
    message: str,
) -> dict[str, object]:
    return {
        "type": "tts.error",
        "scope": "session",
        "stream_id": stream_id,
        "target_language": target_language,
        "code": code,
        "message": message,
    }
```

The constructors must remain pure provider-neutral dictionary builders; do not add audio bytes or provider fields.

- [ ] **Step 6: Verify GREEN, then refactor and re-run**

Run the Task 2 command. Expected: all new TTS protocol tests and all existing/new STT protocol tests pass. Confirm every existing translation target remains accepted. Refactor only duplicated event-dictionary construction, preserving exact equality; rerun the same command and require exit 0.

- [ ] **Step 7: Review Task 2 diff without committing**

Run scoped `git diff --check` and `git diff` for the four Task 2 paths. Expected: only parsing and pure event-schema code changed; `stt_socket.py`, provider configuration, and clients remain untouched. Do not stage or commit.

---

### Task 3: Bounded sequential TtsSession, deduplication, and isolated outcomes

**Files:**

- Create: `services/api/app/realtime/tts_session.py`
- Create: `services/api/tests/test_tts_session.py`
- Modify: `services/api/tests/fakes/tts.py` only if the RED tests expose a missing deterministic observation primitive already specified in Task 1.

**Interfaces:**

- Consumes: all Task 1 domain symbols, Task 2 event constructors, `TargetLanguage`, and the Task 1 fake.
- Produces: `TtsEventPublisher`, `TtsAudioPublisher`, and `TtsSession` with the exact constructor, `start`, `submit`, `flush_and_drain`, `abort`, and `close` signatures in the spec.
- Produces for Task 4: observable behavior through public methods and fake counters; tests must not depend on private queue internals.

- [ ] **Step 1: Create test helpers and write RED happy-path/ordering tests**

Start `services/api/tests/test_tts_session.py` with a recorded output stream and a session factory:

```python
import asyncio
from collections.abc import Callable

from app.ai.tts import (
    InvalidSynthesizedAudio,
    SynthesizedAudio,
    TtsProviderError,
    TtsProviderUnavailable,
)
from app.realtime.tts_session import TtsSession
from tests.fakes.tts import FakeSpeechSynthesizer


async def wait_until(predicate: Callable[[], bool], turns: int = 1000):
    for _ in range(turns):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition was not reached")


def make_session(*, synthesizer, outputs, queue_max_size=8, timeout=1.0):
    async def publish_event(event):
        outputs.append(("json", event))

    async def publish_audio(event, audio_bytes):
        outputs.append(("audio", event, audio_bytes))

    return TtsSession(
        synthesizer=synthesizer,
        stream_id="stream_123",
        target_language="en",
        publish_event=publish_event,
        publish_audio=publish_audio,
        voice="voice-a",
        queue_max_size=queue_max_size,
        request_timeout_seconds=timeout,
    )


async def submit(session, utterance_id, text):
    await session.submit(
        stream_id="stream_123",
        utterance_id=utterance_id,
        source_segment_ids=(f"seg_{utterance_id[-1]}",),
        translated_text=text,
        target_language="en",
    )
```

Add exact success and ordering cases:

```python
def test_unique_utterance_emits_pending_then_metadata_and_raw_bytes():
    async def exercise():
        outputs = []
        result = SynthesizedAudio(b"speech", "audio/wav", 16000)
        fake = FakeSpeechSynthesizer(outcomes=(result,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "Hello.")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())
    assert outputs[0][0] == "json"
    assert outputs[0][1]["type"] == "tts.pending"
    assert outputs[1][0] == "audio"
    assert outputs[1][1]["type"] == "tts.audio"
    assert outputs[1][1]["audio_id"] == "audio_000001"
    assert outputs[1][1]["byte_length"] == 6
    assert outputs[1][2] == b"speech"
    assert len(fake.calls) == 1
    assert fake.calls[0].voice == "voice-a"


def test_two_utterances_synthesize_sequentially_in_submission_order():
    async def exercise():
        outputs = []
        first_gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(
            outcomes=(
                SynthesizedAudio(b"one", "audio/wav", 16000),
                SynthesizedAudio(b"two", "audio/wav", 16000),
            ),
            gates=(first_gate, None),
        )
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        await wait_until(lambda: len(fake.calls) == 1)
        assert fake.maximum_active_calls == 1
        first_gate.set()
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())
    assert [call.text for call in fake.calls] == ["One", "Two"]
    assert fake.maximum_active_calls == 1
    assert [
        item[1]["utterance_id"] for item in outputs
    ] == ["utt_000001", "utt_000001", "utt_000002", "utt_000002"]
```

- [ ] **Step 2: Write RED cost, backpressure, and failure tests**

Add named tests with these exact outcomes:

```python
def test_duplicate_identity_is_permanently_ignored_after_success():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "First")
        await submit(session, "utt_000001", "Changed duplicate")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())
    assert len(fake.calls) == 1
    assert fake.calls[0].text == "First"
    assert [item[1]["type"] for item in outputs] == [
        "tts.pending", "tts.audio"
    ]
```

Add this explicit overflow/freshness test:

```python
def test_queue_overflow_drops_identity_permanently_and_later_unique_continues():
    async def exercise():
        outputs = []
        first_gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(
            outcomes=(
                SynthesizedAudio(b"one", "audio/wav", 16000),
                SynthesizedAudio(b"two", "audio/wav", 16000),
                SynthesizedAudio(b"four", "audio/wav", 16000),
            ),
            gates=(first_gate, None, None),
        )
        session = make_session(
            synthesizer=fake,
            outputs=outputs,
            queue_max_size=1,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await wait_until(lambda: len(fake.calls) == 1)
        await submit(session, "utt_000002", "Two")
        await submit(session, "utt_000003", "Dropped")
        await submit(session, "utt_000003", "Duplicate dropped")

        overflow_events = [
            item[1] for item in outputs
            if item[0] == "json"
            and item[1].get("code") == "queue_overflow"
        ]
        assert len(overflow_events) == 1
        assert overflow_events[0]["utterance_id"] == "utt_000003"
        assert [call.text for call in fake.calls] == ["One"]

        first_gate.set()
        await wait_until(lambda: len(fake.calls) == 2)
        await wait_until(
            lambda: any(
                item[0] == "audio"
                and item[1]["utterance_id"] == "utt_000002"
                for item in outputs
            )
        )
        await submit(session, "utt_000004", "Four")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())
    assert [call.text for call in fake.calls] == ["One", "Two", "Four"]
    assert all(call.text != "Dropped" for call in fake.calls)
    assert all(call.text != "Duplicate dropped" for call in fake.calls)
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000004"
        for item in outputs
    )
```

This test locks that the overflowed Translation remains unaffected but its TTS audio is intentionally dropped, the overflow identity and its duplicate cause zero provider calls, one controlled error is emitted, and the active session accepts later fresh work after capacity returns.

Create a parametrized `test_provider_failure_is_safe_and_worker_continues` for `TtsProviderUnavailable("secret")`, `TtsProviderError("secret")`, and `RuntimeError("secret")`. For each, assert the first utterance emits pending plus `provider_unavailable`, `provider_error`, or `internal_error`; assert `"secret"` is absent from the public message; then assert the second utterance reaches `tts.audio`.

Create `test_provider_timeout_cancels_request_and_worker_continues` with a blocked first gate and `timeout=0.01`; assert `cancelled_calls == 1`, the first terminal code is `request_timeout`, and the second utterance reaches audio. While the session is still accepting, resubmit the timed-out identity and assert its call count remains one.

Create `test_duplicate_after_provider_failure_does_not_retry` with a controlled `TtsProviderError` for the first identity. Wait for its `tts.error`, submit the same identity again, then submit a new valid identity. Assert the failed identity appears exactly once in `fake.calls`, produces no audio, and the later unique identity reaches `tts.audio`.

Create `test_invalid_provider_result_emits_invalid_audio_and_continues` using a small synthesizer stub whose first return is `object()` and whose second return is valid `SynthesizedAudio`; assert no bytes are published for the first identity, its code is `invalid_audio`, and the second identity reaches audio. Also use a stub that raises `InvalidSynthesizedAudio` to represent empty provider output rejected during result construction and assert the same public code.

- [ ] **Step 3: Write RED submission-contract tests**

Add a parametrized test that submits one mismatch at a time: wrong stream, wrong target, blank utterance ID, blank translated text, and empty source IDs. Assert `ValueError`, zero fake calls, and zero events. Add a test that calls `submit` before `start` and after successful drain; assert `RuntimeError` both times.

- [ ] **Step 4: Run Task 3 tests and verify RED**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_session.py -q
```

Expected: RED because `TtsSession` does not exist. After the first skeleton is added, preserve RED until pending/audio output, deduplication, bounded overflow, timeout, invalid-result mapping, and failure continuation all match the assertions.

- [ ] **Step 5: Implement the queue item, constructor, start, and submission boundary**

Create `tts_session.py` with these exact aliases, defaults, state, and work item:

```python
import asyncio
from collections.abc import Awaitable, Callable, Sequence
from dataclasses import dataclass

from app.ai.tts import SpeechSynthesizer
from app.realtime.stt_protocol import TargetLanguage

TtsEventPublisher = Callable[[dict[str, object]], Awaitable[None]]
TtsAudioPublisher = Callable[
    [dict[str, object], bytes], Awaitable[None]
]


@dataclass(frozen=True, slots=True)
class _TtsWorkItem:
    stream_id: str
    utterance_id: str
    source_segment_ids: tuple[str, ...]
    translated_text: str
    target_language: TargetLanguage
```

The constructor validates queue size, timeout, stream ID, and optional non-blank voice. Initialize `asyncio.Queue(maxsize=queue_max_size)`, `_seen_identities: set[tuple[str, str]]`, `_worker_task`, `_cleanup_tasks`, `_accepting=False`, `_closed=False`, `_publisher_failed=False`, and `_next_audio_number=1`.

Implement `start` exactly like the established Translation lifecycle: reject after close, return if a worker already exists, set accepting, and create `asyncio.create_task(self._run_worker(), name=f"tts-worker:{self._stream_id}")`.

In `submit`, validate all fields before altering state. Form `identity = (stream_id, utterance_id)`. If already seen, return without publishing. Add the key before `put_nowait`. On `QueueFull`, await `_publish_utterance_error(..., code="queue_overflow")`; do not remove the identity and do not call the provider. That utterance's Translation state remains valid, but its speech is intentionally dropped. A duplicate cannot retry it; later unique submissions can enter after capacity returns.

- [ ] **Step 6: Implement one worker and exact outcome mapping**

Define safe fixed messages:

```python
_ERROR_MESSAGES = {
    "provider_unavailable": "Speech synthesis is unavailable.",
    "provider_error": "Speech synthesis failed for this passage.",
    "queue_overflow": "Speech synthesis queue is full.",
    "request_timeout": "Speech synthesis request timed out.",
    "invalid_audio": "Speech synthesis returned invalid audio.",
    "internal_error": "Speech synthesis failed for this passage.",
}
```

`_run_worker` must call `queue.get`, await `_synthesize_item`, and call `queue.task_done` in `finally`. It must never create a second synthesis task for another item while the current item is active.

`_synthesize_item` performs this order:

1. publish `tts_pending_event`;
2. call `await asyncio.wait_for(self._synthesizer.synthesize(text=item.translated_text, language=item.target_language, voice=self._voice), timeout=self._request_timeout_seconds)`;
3. map `asyncio.TimeoutError`, `TtsProviderUnavailable`, `TtsProviderError`, `InvalidSynthesizedAudio`, and unexpected exceptions to the exact codes above while re-raising `asyncio.CancelledError`;
4. defensively reject any result that is not `SynthesizedAudio` as `invalid_audio`;
5. assign `audio_id = f"audio_{self._next_audio_number:06d}"` and increment only for a valid result; and
6. call `publish_audio(tts_audio_event(..., byte_length=len(result.audio_bytes), sample_rate_hz=result.sample_rate_hz), result.audio_bytes)` exactly once.

After any utterance error, return to `_run_worker`; do not close the session. If a publishing callback raises, set `_publisher_failed`, stop acceptance, discard queued items with balanced task accounting, and terminate the worker. Do not pass exception text into an event.

- [ ] **Step 7: Add the minimum lifecycle needed by Task 3 tests**

Implement the first `flush_and_drain` with its final signature: reject non-positive timeouts, reject use before start, set `_accepting=False`, await `asyncio.wait_for(self._queue.join(), timeout_seconds)`, return `True` on completion, and call `abort` then return `False` on timeout or publisher failure. Implement `abort` and `close` so every Task 3 test settles its worker: `abort` sets closed/not accepting, cancels the worker, discards the queue, awaits the cancelled task with `asyncio.gather(..., return_exceptions=True)`, clears its reference, and returns safely when repeated. `close` delegates to `abort`. Task 4 replaces the direct `wait_for(queue.join())` path with explicitly owned drain/cancellation tasks and locks repeated-call/no-leak behavior.

- [ ] **Step 8: Verify GREEN, then refactor and re-run**

Run the Task 3 command. Expected: all session core tests pass with `maximum_active_calls == 1`, exact event order, one provider call per unique identity, safe errors, and no raw bytes in the JSON callback. Extract only helpers that reduce duplication without changing callback signatures or state semantics. Rerun the same command and require exit 0.

- [ ] **Step 9: Review Task 3 diff without committing**

Run scoped `git diff --check` and `git diff` for `tts_session.py`, `test_tts_session.py`, and `tests/fakes/tts.py`. Confirm no network, socket, SessionHub, provider-selection, Web, or Mobile code appears. Do not stage or commit.

---

### Task 4: Drain, abort, close, idempotency, and task ownership

**Files:**

- Modify: `services/api/app/realtime/tts_session.py`
- Modify: `services/api/tests/test_tts_session.py`

**Interfaces:**

- Consumes: Task 3's exact constructor, callbacks, worker, queue, and submission semantics.
- Produces: final `flush_and_drain(*, timeout_seconds: float) -> bool`, prompt/idempotent `abort() -> None`, and idempotent `close() -> None` with no owned task left after cooperative cancellation. P3.0B is contractually required to invoke clean-stop drain once with `timeout_seconds=5.0`.

- [ ] **Step 1: Write RED successful-drain and total-deadline tests**

Add:

```python
def test_flush_and_drain_completes_all_accepted_work():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        first = await session.flush_and_drain(timeout_seconds=1.0)
        second = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return first, second, outputs

    first, second, outputs = asyncio.run(exercise())
    assert first is True
    assert second is True
    assert [item[1]["type"] for item in outputs] == [
        "tts.pending", "tts.audio", "tts.pending", "tts.audio"
    ]


def test_total_drain_deadline_bounds_multiple_slow_queued_requests():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate, gate, gate))
        session = make_session(
            synthesizer=fake,
            outputs=outputs,
            timeout=1.0,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        await submit(session, "utt_000003", "Three")
        await fake.call_started.wait()
        drained = await asyncio.wait_for(
            session.flush_and_drain(timeout_seconds=0.01),
            timeout=0.2,
        )
        await session.close()
        return drained, fake

    drained, fake = asyncio.run(exercise())
    assert drained is False
    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
    assert [call.text for call in fake.calls] == ["One"]
```

The injected one-second request timeout represents the production 10-second per-request limit; the injected 0.01-second drain value represents the production 5-second total clean-stop deadline. The external 0.2-second guard proves that three slow queued requests do not receive three independent drain windows. The total deadline cancels the current call and discards the other two before their provider calls begin.

Add validation cases asserting `timeout_seconds <= 0` raises `ValueError`, drain before start raises `RuntimeError`, and drain after close returns `False`.

- [ ] **Step 2: Write RED abort/close/no-leak tests**

Add:

```python
def test_abort_and_close_are_idempotent_and_leave_no_owned_tasks():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await fake.call_started.wait()
        await session.abort()
        await session.abort()
        await session.close()
        await session.close()
        owned = [
            task for task in asyncio.all_tasks()
            if task is not asyncio.current_task()
            and task.get_name().startswith("tts-")
            and not task.done()
        ]
        return fake, owned

    fake, owned = asyncio.run(exercise())
    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
    assert owned == []
```

Add `test_abort_discards_queued_work_without_queue_join_hanging`: block the first call, queue a second, abort, then wrap a direct repeated `close` in `asyncio.wait_for(..., 0.1)` and assert only the first provider call started.

Add `test_publisher_failure_makes_drain_false_and_stops_later_work` twice through parametrization: once raising from pending publication and once from the audio callback. Assert `flush_and_drain` is `False`, the later queued item never starts, and close leaves no named TTS task.

- [ ] **Step 3: Run Task 4 tests and verify RED**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_session.py -q
```

Expected: the new drain/repeated-call/publication-failure assertions fail against Task 3's minimum cleanup. In particular, the multiple-slow-request case must fail if the implementation resets a timeout for each queued item instead of enforcing one total deadline. Confirm failures are confined to lifecycle semantics.

- [ ] **Step 4: Implement bounded drain and centralized cancellation**

Implement `flush_and_drain` using one named `tts-drain:<stream_id>` task around `queue.join()`. Set `_accepting=False` before creating it. Apply `timeout_seconds` once around the whole drain task; never wrap each queue item in a fresh drain timeout. On expiry, cancel the drain task, call the centralized abort path, cancel the current provider request, discard remaining queued work, settle owned tasks, and return `False`. If the queue completes and `_publisher_failed` is false, record a successful drain result and return `True`; repeated drain before close returns `True` without creating more work. P3.0A tests use shortened values, while P3.0B must pass exactly 5.0 seconds for the production clean-stop call.

Centralize `_begin_abort`, `_cancel_and_track`, `_cleanup_task_done`, `_consume_task_result`, and `_discard_queued_items` using the established TranslationSession pattern. Every discarded queue item calls `task_done`. Keep references to worker, drain, and cleanup tasks until their result is consumed.

`abort` must call `_begin_abort` and await all tracked cancellation tasks. Because `SpeechSynthesizer` adapters are contractually cancellation-cooperative, do not leave a detached provider task. `close` calls `abort` and remains idempotent.

- [ ] **Step 5: Verify GREEN, then refactor and re-run**

Run the Task 4 command. Expected: every core and lifecycle test passes, including successful repeated drain, the total deadline across multiple slow queued requests, provider-request timeout as a separate case, cancellation, balanced queue accounting, callback failure, repeated abort/close, and the `asyncio.all_tasks` leak assertion. Refactor only duplicated cancellation/result-consumption code. Rerun and require exit 0.

- [ ] **Step 6: Review Task 4 diff without committing**

Run scoped `git diff --check` and inspect the complete `tts_session.py`/test diff. Confirm all created tasks have one owner and one settle path, every queue removal balances unfinished-work accounting, and `close` creates no event after abort. Do not stage or commit.

---

### Task 5: Focused regression, full Backend regression, and scope verification

**Files:**

- Verify only; no planned file changes.

**Interfaces:**

- Consumes: all P3.0A files and the unchanged Backend suite.
- Produces: fresh evidence that P3.0A contracts pass, legacy clients remain compatible, and no later-milestone implementation entered the diff.

- [ ] **Step 1: Run the focused P3.0A suite**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_provider.py tests/test_tts_protocol.py tests/test_tts_session.py tests/test_stt_protocol.py -q
```

Expected: exit 0 with zero failures. This is the final GREEN run for the provider boundary, fake, start contract, event schemas, queue, ordering, deduplication, errors, and lifecycle.

- [ ] **Step 2: Run Translation regression at the downstream boundary**

Run:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_translation_provider.py tests/test_translation_protocol.py tests/test_translation_session.py tests/test_stt_translation_integration.py -q
```

Expected: exit 0. Existing Translation identity, event order, clean Stop, and STT-only/Translation-only behavior remain unchanged.

- [ ] **Step 3: Run the full Backend suite**

Run:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest -q
```

Expected: exit 0 with zero failed/error tests and no real-provider request. The tests must use fakes and dependency overrides only.

- [ ] **Step 4: Compile Backend Python sources**

Run from the repository root:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m compileall -q services/api/app services/api/tests
```

Expected: exit 0 with no syntax error.

- [ ] **Step 5: Scan for forbidden placeholders and binary-in-JSON mistakes**

Run:

```powershell
rg -n -i "T[B]D|T[O]DO|implement l[a]ter|similar t[o]|appropriate handl[i]ng" services/api/app/ai/tts.py services/api/app/realtime/tts_protocol.py services/api/app/realtime/tts_session.py services/api/tests/fakes/tts.py services/api/tests/test_tts_provider.py services/api/tests/test_tts_protocol.py services/api/tests/test_tts_session.py
rg -n "base64|data:audio|Authorization|api[_-]?key|audio_bytes.*tts\.audio" services/api/app/ai/tts.py services/api/app/realtime/tts_protocol.py services/api/app/realtime/tts_session.py
```

Expected: both commands find no production placeholder, Base64/data URL, authorization, key, or raw-byte-in-event construction. `audio_bytes` is permitted only in `SynthesizedAudio` and as the second `TtsAudioPublisher` callback argument.

- [ ] **Step 6: Verify exact file scope and whitespace**

Run from the repository root:

```powershell
git diff --check -- services/api/app/ai/tts.py services/api/app/realtime/tts_protocol.py services/api/app/realtime/tts_session.py services/api/app/realtime/stt_protocol.py services/api/tests/fakes/tts.py services/api/tests/test_tts_provider.py services/api/tests/test_tts_protocol.py services/api/tests/test_tts_session.py services/api/tests/test_stt_protocol.py
git status --short
```

Expected: diff check exits 0. Compare status with the preserved pre-task status and verify that P3.0A introduced changes only in the nine allowed paths. Existing unrelated dirty/untracked entries remain untouched.

- [ ] **Step 7: Inspect exclusions and stop without committing**

Run:

```powershell
git diff -- services/api/app/realtime/stt_socket.py services/api/app/realtime/session_event_publisher.py services/api/app/realtime/session_hub.py apps/web apps/mobile services/api/requirements.txt services/api/app/core/config.py
```

Expected: no P3.0A diff appears in any excluded path. Confirm no provider adapter/factory selection, WebSocket binary send, viewer snapshot change, playback UI, audio persistence, real-provider configuration, dependency, or client change was introduced. Do not stage, commit, push, or merge.

## Requirement-to-task traceability

| P3.0A requirement | Plan coverage |
|---|---|
| Provider-neutral abstraction and immutable result | Task 1 domain tests and `app/ai/tts.py`. |
| Non-empty bytes, MIME, optional sample rate | Task 1 parametrized validation. |
| Controlled provider errors and no provider leakage | Tasks 1 and 3 exception mapping and safe-message assertions. |
| Deterministic fake, call capture, failure, hang, cancellation | Task 1 fake and tests. |
| Complete six-row Translation/TTS start matrix | Task 2 has explicit valid tests for both omitted states, both disabled-TTS states, and enabled Translation+TTS, plus a RED/GREEN invalid enabled-TTS-without-Translation test. |
| TTS requires Translation target text | Task 2 model-level dependency rejects enabled TTS without Translation as `invalid_message` before startup. |
| STT-only and Translation-only compatibility | Existing protocol tests retained plus Task 2 explicit assertions; Task 5 Translation regression. |
| Exact configured/pending/audio/error events | Task 2 exact dictionary equality tests. |
| `audio_id`, byte length, optional sample rate | Task 2 metadata tests; Task 3 stream-local sequence assertions. |
| No raw/Base64 audio in JSON | Task 2 absence assertions and Task 5 scan. |
| Metadata-plus-binary callback boundary | Task 3 recorded `publish_audio(event, bytes)` assertions. |
| Identity `(stream_id, utterance_id)` | Task 3 submission validation and deduplication tests. |
| At-most-one call and duplicate ignore | Task 3 duplicate success, duplicate-after-overflow, duplicate-after-provider-failure, and duplicate-after-timeout assertions. |
| Bounded queue size 8 and intentional overflow drop | Task 3 blocked-worker test proves one `queue_overflow`, zero calls for the dropped identity and its duplicate, unchanged Translation ownership, and acceptance of a later unique utterance. |
| One sequential worker and output ordering | Task 3 gated two-utterance test and maximum concurrency assertion. |
| 10-second per-request bound | Task 3 constructor/default plus injected provider-timeout test and continuation assertion. |
| Provider/result failure isolation | Task 3 parametrized failure and invalid-result continuation tests. |
| 5-second total clean-stop TTS drain deadline | Global contract and Task 4 multiple-slow-request test prove one shared deadline wins over the longer per-request timeout and cancels/discards remaining work. |
| Abort/close idempotency and no task leak | Task 4 repeated calls and named-task inspection. |
| Future Translation-then-TTS clean Stop support | Task 4 final lifecycle API; design spec section 20. No socket edit. |
| Unexpected-disconnect abort support | Task 4 abort contract; no integration edit. |
| Late-viewer configuration without audio replay | Design spec section 22 and P3.0B boundary; no storage or Hub edit. |
| No persistence, clients, or real provider | Global constraints, File Map, and Task 5 exclusion diff. |

## P3.0A completion boundary

After Task 5, the Backend has deterministic provider-neutral TTS domain, protocol, fake, and session building blocks. The only existing protocol change is optional `stt.start.tts` parsing; omission and `enabled=false` make no runtime change. `/ws/stt` does not construct or feed a `TtsSession`, no binary audio is sent, no client plays audio, and no production provider exists. Those boundaries remain reserved for P3.0B, P3.0C, and P3.1 respectively.
