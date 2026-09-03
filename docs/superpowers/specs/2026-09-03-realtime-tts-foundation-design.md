# P3.0A Realtime TTS Foundation Design

**Date:** 2026-09-03
**Status:** Approved architecture documented for implementation planning
**Scope:** P3.0A provider-neutral TTS contracts and deterministic backend foundation only

## 1. Context

P2.0 and P2.1 established and verified the current realtime pipeline:

```text
Audio
  -> Deepgram Nova-3 STT
  -> transcript.final
  -> TranslationUtteranceAggregator
  -> TranslationSession
  -> translation.pending / translation.final
  -> SessionEventPublisher
  -> producer and session viewers
```

Translation is backend-owned, provider-neutral, bounded, sequential, and isolated from STT failures. The Web and Mobile clients consume normalized events and never call the Translation provider directly. Clean Stop drains accepted Translation work before `stt.closed`; an unexpected producer disconnect aborts Translation.

P3 adds synthesized speech after a committed `translation.final`. Synthesis is backend-owned so one translated utterance causes no more than one provider request regardless of viewer count. The resulting audio can then be broadcast to the producer and every current viewer. Client-side or per-viewer provider calls are forbidden.

P3 is deliberately split into four checkpoints. This document locks only the P3.0A foundation required before realtime transport or playback is introduced.

## 2. Goals

P3.0A will define and deterministically test:

- provider-neutral `SpeechSynthesizer` and `SynthesizedAudio` contracts;
- provider-neutral domain and public error categories;
- a deterministic, network-free `FakeSpeechSynthesizer`;
- the optional `stt.start.tts` configuration contract;
- exact `tts.configured`, `tts.pending`, `tts.audio`, and `tts.error` JSON schemas;
- a metadata-plus-binary publishing seam without WebSocket framing;
- an independent `TtsSession` with bounded input, one sequential worker, per-request timeout, deduplication, failure isolation, and explicit lifecycle operations; and
- the contracts that P3.0B must use for realtime integration, shutdown, viewer snapshots, and non-replay.

The cost invariant is:

```text
one unique committed (stream_id, utterance_id)
  -> at most one SpeechSynthesizer.synthesize call
  -> at most one synthesized audio result
  -> broadcast of that single result to all current recipients
```

## 3. Explicit non-goals

P3.0A does not:

- choose, configure, call, or benchmark a real TTS provider;
- integrate `TtsSession` into `/ws/stt`;
- modify `SessionEventPublisher`, `SessionHub`, WebSocket routing, or viewer delivery;
- send any binary WebSocket frame;
- add Web or Mobile playback, controls, buffering, mute behavior, or UI;
- synthesize source-language speech or infer a language from text;
- define a voice catalog, gender, persona, marketplace, or provider mapping;
- persist, cache, record, replay, or archive synthesized audio;
- add concurrency within a single TTS session;
- change existing STT-only or Translation-only behavior; or
- run P1.5E Android System Audio validation.

P3.0B owns Backend realtime integration. P3.0C owns client playback. P3.1 owns real-provider selection and validation.

## 4. Existing architecture being extended

The design follows these repository conventions:

- `app.ai.translation` defines an immutable provider result, provider-neutral exceptions, a runtime-checkable `Protocol`, and a callable factory type.
- `TranslationSession` accepts explicit dependencies, owns an `asyncio.Queue(maxsize=8)`, starts one named worker, uses `asyncio.wait_for` for a 10-second provider timeout, publishes normalized errors, and exposes `start`, `flush_and_drain`, `abort`, and `close`. The current socket separately applies `_TRANSLATION_DRAIN_TIMEOUT_SECONDS = 5.0`, establishing that a per-request timeout and a total clean-stop drain deadline are distinct limits.
- `translation_protocol` uses typed literal aliases and small functions returning `dict[str, object]`.
- `stt_protocol` uses Pydantic models with `extra="forbid"` and explicitly permits optional feature configuration in `stt.start`.
- `SessionEventPublisher` serializes producer delivery and mirrors the same normalized event to `SessionHub` viewers.
- `SessionHub` stores only active configuration snapshots. It does not replay transcript or Translation history.
- deterministic fakes record calls, expose concurrency counters, accept controlled outcomes, and use `asyncio.Event` gates to test ordering, timeouts, and cancellation without a network.

TTS will use these patterns without changing their established Translation behavior in P3.0A.

## 5. Component architecture

```text
committed translation.final
          |
          v
TtsSession.submit(translation identity and translated content)
          |
          v
bounded asyncio.Queue(maxsize=8)
          |
          v
one sequential TTS worker
          |
          +--> tts.pending through TtsEventPublisher
          |
          v
SpeechSynthesizer.synthesize
          |
          +--> tts.error through TtsEventPublisher
          |
          v
SynthesizedAudio
          |
          v
TtsAudioPublisher(tts.audio metadata, raw bytes)
```

P3.0A creates the domain, protocol, fake, and session components. `TtsEventPublisher` and `TtsAudioPublisher` are callback types, not WebSocket implementations. This keeps `TtsSession` independent of FastAPI and lets P3.0B connect it to a transport that atomically serializes metadata and binary delivery.

## 6. SpeechSynthesizer abstraction

`services/api/app/ai/tts.py` will define:

```python
from collections.abc import Callable
from typing import Protocol, runtime_checkable

from app.realtime.stt_protocol import TargetLanguage


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

The interface contains only translated text, the canonical product target language, and an optional opaque voice string. Provider endpoints, models, account identifiers, SDK objects, request IDs, credentials, and provider-specific language values are excluded. A future adapter performs its own language and voice mapping internally.

Provider adapters must propagate `asyncio.CancelledError` so timeout, abort, and close can stop owned work.

## 7. SynthesizedAudio contract

The exact immutable result is:

```python
@dataclass(frozen=True, slots=True)
class SynthesizedAudio:
    audio_bytes: bytes
    mime_type: str
    sample_rate_hz: int | None = None
```

Construction validates all invariants:

- `audio_bytes` is a `bytes` value and is non-empty;
- `mime_type` is a non-empty, non-whitespace string;
- `sample_rate_hz` is either `None` or a positive integer, with booleans rejected; and
- no vendor response, request identifier, authorization value, or provider metadata is retained.

Invalid construction raises the provider-neutral `InvalidSynthesizedAudio` exception, a `ValueError` subtype. `sample_rate_hz=None` supports encoded formats whose adapter cannot provide a meaningful sample rate. P3.0A adds no duration, channel count, codec negotiation, or file name because the realtime transport does not require those fields.

## 8. Provider-neutral error taxonomy

The domain exceptions in `app.ai.tts` are:

| Exception | Meaning |
|---|---|
| `TtsProviderUnavailable` | No synthesizer can be constructed or the configured provider is unavailable. |
| `TtsProviderError` | A configured provider failed to synthesize the requested utterance. |
| `InvalidSynthesizedAudio` | The synthesized result violates the provider-neutral audio contract. |

The public `TtsErrorCode` values are:

| Code | Trigger | Session behavior |
|---|---|---|
| `provider_unavailable` | `TtsProviderUnavailable` during startup or synthesis | Emit safe error; STT and Translation remain alive. |
| `provider_error` | `TtsProviderError` | Emit utterance error; worker continues. |
| `queue_overflow` | A unique submission cannot enter the bounded queue | Emit utterance error; no provider call; worker continues. |
| `request_timeout` | Synthesis exceeds the configured request timeout | Cancel the request, emit utterance error, and continue. |
| `invalid_audio` | Result type or content violates `SynthesizedAudio` | Emit utterance error; discard bytes; continue. |
| `internal_error` | Any other synthesizer/session exception | Emit a safe utterance error and continue when publication remains usable. |

Public messages are fixed safe strings. Raw exception text, response bodies, headers, account IDs, tokens, provider names, and provider implementation details never enter protocol events. Logging may include the exception class name but not raw exception messages or payloads.

## 9. TTS identity and input model

TTS reuses Translation identity:

```text
(stream_id, utterance_id)
```

There is no TTS utterance ID and no text-based matching. A submission is created only from a committed `translation.final` and carries:

- `stream_id`;
- `utterance_id`;
- `source_segment_ids` as an immutable tuple internally;
- `translated_text`; and
- `target_language` copied from `translation.final.target_language`.

`TtsSession` is constructed for one `stream_id` and one `target_language`. `submit` still receives both values from the normalized Translation event and rejects a mismatch with `ValueError`; this makes accidental cross-stream or cross-language routing visible at the internal boundary. It also rejects blank `utterance_id`, blank translated text, and an empty source-segment list as programming-contract violations. These violations are not provider errors and must not produce a provider call.

The `source_segment_ids` relationship remains owned by the committed Translation event. TTS events use the shared `(stream_id, utterance_id)` to refer to that Translation record and do not duplicate source text or segment lists.

## 10. TTS start configuration

`stt.start` gains one optional field:

```json
{
  "type": "stt.start",
  "audio": {
    "encoding": "pcm_s16le",
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "language": "vi",
  "translation": {
    "target_language": "en"
  },
  "tts": {
    "enabled": true
  }
}
```

The exact Pydantic configuration model is:

```python
class TtsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool
    voice: str | None = Field(default=None, min_length=1, max_length=128)
```

Additional validation rejects a voice containing only whitespace. Voice is an opaque provider-neutral value; P3.0A defines no catalog.

Configuration rules are deterministic:

- omitted `tts` preserves all existing STT-only and Translation-only behavior;
- `{"enabled": false}` is accepted and creates no TTS session or TTS event;
- a voice may remain present while disabled but is inert;
- `{"enabled": true}` requires a non-null valid `translation` configuration in the same `stt.start` message;
- the TTS language is exactly `translation.target_language` and remains one of `en`, `ja`, `ko`, `zh-CN`, `th`, `fr`, `de`, or `es`;
- `tts: null`, missing `enabled`, non-boolean `enabled`, blank/oversized voice, and unknown fields are `invalid_message`; and
- P3.0A parses and validates this contract but does not construct a synthesizer from `/ws/stt`.

The complete start-validation matrix is locked as follows:

| Translation | TTS | Result | Runtime meaning |
|---|---|---|---|
| omitted | omitted | Valid | Existing STT-only session. |
| omitted | `enabled=false` | Valid | Existing STT-only session; TTS is explicitly inert. |
| configured | omitted | Valid | Existing Translation-only session. |
| configured | `enabled=false` | Valid | Translation runs; TTS is explicitly inert. |
| configured | `enabled=true` | Valid | Translation supplies committed target text to TTS. |
| omitted | `enabled=true` | Invalid `stt.start` | Rejected as `invalid_message` before STT or provider startup. |

There is no fallback path that synthesizes source text, creates an idle TTS session, or waits for an input that cannot exist. Enabled TTS always depends on enabled Translation in the same validated start message.

## 11. TTS protocol events

`services/api/app/realtime/tts_protocol.py` defines event constructors and these exact schemas.

### 11.1 `tts.configured`

Without a voice:

```json
{
  "type": "tts.configured",
  "stream_id": "stream_123",
  "target_language": "en"
}
```

With a voice, the event adds `"voice": "voice-name"`. A `voice` key is absent when the value is `None`; JSON `null` is not emitted.

### 11.2 `tts.pending`

```json
{
  "type": "tts.pending",
  "stream_id": "stream_123",
  "utterance_id": "utt_000001",
  "target_language": "en"
}
```

The worker emits this event immediately before its one synthesis call for the utterance. Queue-overflow and duplicate submissions do not emit `tts.pending` because no provider call begins.

### 11.3 `tts.audio`

```json
{
  "type": "tts.audio",
  "stream_id": "stream_123",
  "utterance_id": "utt_000001",
  "audio_id": "audio_000001",
  "target_language": "en",
  "mime_type": "audio/mpeg",
  "byte_length": 4182,
  "sample_rate_hz": 24000
}
```

`audio_id` is backend-assigned, non-empty, and unique within `stream_id`. `TtsSession` generates deterministic stream-local IDs in successful-output order using `audio_000001`, `audio_000002`, and so on. `sample_rate_hz` is omitted when `SynthesizedAudio.sample_rate_hz` is `None`. `byte_length` must equal `len(audio_bytes)` and be positive. No audio bytes, Base64 string, data URL, provider identifier, or raw response is present in the JSON object.

### 11.4 `tts.error`

Utterance-scoped errors are:

```json
{
  "type": "tts.error",
  "scope": "utterance",
  "stream_id": "stream_123",
  "utterance_id": "utt_000001",
  "target_language": "en",
  "code": "provider_error",
  "message": "Speech synthesis failed for this passage."
}
```

Session-scoped startup errors are:

```json
{
  "type": "tts.error",
  "scope": "session",
  "stream_id": "stream_123",
  "target_language": "en",
  "code": "provider_unavailable",
  "message": "Speech synthesis is unavailable."
}
```

Session-scoped errors have no fabricated `utterance_id`. P3.0A defines and tests both constructors; P3.0B decides when startup construction produces the session-scoped form.

## 12. Metadata and binary-audio boundary

Audio bytes are never placed in JSON. `TtsSession` receives two publishing dependencies:

```python
TtsEventPublisher = Callable[[dict[str, object]], Awaitable[None]]
TtsAudioPublisher = Callable[
    [dict[str, object], bytes],
    Awaitable[None],
]
```

`publish_event` carries `tts.pending` and `tts.error`. `publish_audio` receives one validated `tts.audio` metadata object together with the exact raw bytes. This single callback invocation is the handoff boundary: it prevents the session from independently publishing metadata and bytes in a way that could be interleaved.

P3.0B must implement `publish_audio` so each recipient receives the JSON metadata frame immediately followed by its binary payload under the recipient's serialized send ordering. The same synthesized byte sequence is fanned out; synthesis is not repeated per recipient. P3.0A tests the callback pair in memory and performs no WebSocket send.

## 13. TtsSession responsibilities and interface

`services/api/app/realtime/tts_session.py` will expose:

```python
class TtsSession:
    def __init__(
        self,
        *,
        synthesizer: SpeechSynthesizer,
        stream_id: str,
        target_language: TargetLanguage,
        publish_event: TtsEventPublisher,
        publish_audio: TtsAudioPublisher,
        voice: str | None = None,
        queue_max_size: int = 8,
        request_timeout_seconds: float = 10.0,
    ) -> None: ...

    async def start(self) -> None: ...

    async def submit(
        self,
        *,
        stream_id: str,
        utterance_id: str,
        source_segment_ids: Sequence[str],
        translated_text: str,
        target_language: TargetLanguage,
    ) -> None: ...

    async def flush_and_drain(
        self,
        *,
        timeout_seconds: float,
    ) -> bool: ...

    async def abort(self) -> None: ...

    async def close(self) -> None: ...
```

The session owns validation, permanent deduplication, the bounded queue, one worker, safe event mapping, stream-local audio ID generation, provider timeout, and all created tasks. It does not know about FastAPI, WebSockets, viewers, provider credentials, or playback.

`start` is idempotent until close. `submit` is valid only after start and while accepting. `queue_max_size < 1`, non-positive request/drain timeouts, invalid constructor voice, and identity/content mismatches raise `ValueError` or `RuntimeError` before provider work.

## 14. Queue and backpressure

The default queue size is **8**, matching `TranslationSession`.

Eight provides a finite cost and memory bound while allowing a short burst of translated utterances to wait behind one synthesis. A larger default would increase delayed speech and shutdown time; an unbounded queue is forbidden. A smaller default would diverge from the established realtime subsystem without evidence that TTS needs a different burst allowance.

`submit` uses `put_nowait`. It does not wait for queue capacity. If the queue is full, the unique identity is marked consumed, a safe utterance-scoped `tts.error` with `queue_overflow` is published, and no provider call is made. The translated text remains valid and visible, but synthesized speech for that utterance is intentionally dropped.

This is an explicit realtime freshness, cost, ordering, and idempotency policy. An overflowed utterance is not queued later and is not automatically retried: late speech for an older utterance could play after newer speech and would weaken the one-request cost bound. The worker and session remain usable. Work already accepted finishes within lifecycle bounds, and a later unique utterance can be accepted when capacity is available. STT, Translation, the producer socket, and viewers remain active throughout.

## 15. Sequential ordering invariant

Each `TtsSession` owns exactly one synthesis worker and performs at most one active `synthesize` call. For accepted unique submissions A then B:

```text
tts.pending(A)
-> tts.audio(A) or tts.error(A)
-> tts.pending(B)
-> tts.audio(B) or tts.error(B)
```

An earlier provider failure does not block later work, but its terminal `tts.error` is emitted before the later utterance starts. Consequently utterance N cannot produce playable audio after utterance N+1 because of provider concurrency races. P3.0A introduces no session-local parallelism or result reordering buffer.

## 16. Duplicate and idempotency behavior

`TtsSession` keeps a set of seen `(stream_id, utterance_id)` keys. The key is inserted synchronously before the first queue insertion attempt.

Every later submission with that key is a silent idempotent no-op:

- it emits no second `tts.pending`, `tts.audio`, or `tts.error`;
- it never calls the provider;
- it does not compare or replace text, language, voice, or source segment IDs; and
- it remains ignored even if the first attempt overflowed, timed out, failed, or produced invalid audio.

There is no automatic TTS retry in P3.0A. In particular, duplicate events after queue overflow, provider failure, provider timeout, or invalid audio cannot create a hidden second request. This permanent first-submission rule gives a direct at-most-one provider-call guarantee and prevents duplicate normalized events from multiplying cost. An explicit user-requested replay/retry flow would require a separate future identity and ordering design and is outside P3.0A.

## 17. Provider request timeout and total drain deadline

Two independent limits are locked:

| Limit | Value | Scope |
|---|---:|---|
| Per synthesis provider request timeout | **10.0 seconds** | Bounds one `SpeechSynthesizer.synthesize` call during normal streaming or drain. |
| Total clean-stop TTS drain deadline | **5.0 seconds** | Bounds the complete `TtsSession.flush_and_drain` operation across the current request, all queued items, output publication, cancellation, and task release. |

The 10-second request limit matches Translation's established provider-call default. The 5-second total drain deadline matches the current socket's total Translation drain convention and protects the interactive Stop lifecycle. The total deadline is not reset for each queue item and does not become `queue length × request timeout`. Therefore an eight-item queue can never make clean Stop wait up to 80 seconds.

The worker wraps each `synthesize` await in `asyncio.wait_for`. Timeout cancels the provider coroutine, publishes `request_timeout`, and proceeds to the next accepted item. Provider adapters are required to release request resources when cancelled.

During clean Stop, `flush_and_drain(timeout_seconds=5.0)` gives all currently accepted work one shared wall-clock budget. Results completed inside that budget are published in order. At expiry, the session cancels the current request, discards queued items, settles all TTS-owned tasks, returns `False`, and allows the enclosing `stt.closed` lifecycle to continue. The clean-stop deadline may therefore cancel a request before its individual 10-second request timeout; this is intentional because the shorter total lifecycle bound wins during Stop.

## 18. Error isolation and publication failure

All TTS work is downstream of a successful Translation. A TTS failure never reverses or hides `translation.final`, and it never terminates STT, Translation, the producer WebSocket, or the viewer session.

Provider and result failures produce one safe terminal TTS outcome for that utterance and the worker continues. Queue overflow affects only the rejected identity. No partial or invalid audio bytes are published.

If a supplied publisher callback itself raises, `TtsSession` marks TTS delivery failed, stops accepting new work, discards queued TTS items, cancels its worker, and makes `flush_and_drain` return `False`. It does not recursively attempt to publish `tts.error` through a failed callback. P3.0B owns transport-level handling; this TTS-local failure must not be reclassified as an STT or Translation provider failure.

## 19. Lifecycle semantics

### `start`

- Creates exactly one named worker, `tts-worker:<stream_id>`.
- Becomes accepting before returning.
- A repeated call is a no-op.
- A call after close raises `RuntimeError`.

### `submit`

- Requires a started, accepting session.
- Validates the committed Translation fields.
- Permanently reserves the identity before `put_nowait`.
- Returns after acceptance, duplicate ignore, or overflow publication; it never waits for synthesis.

### `flush_and_drain`

- Requires a positive caller-supplied timeout and a started session.
- Stops accepting new work before waiting.
- Uses the caller's value as one total wall-clock deadline for the entire drain, not once per queue item. P3.0B must pass exactly `5.0` seconds for clean Stop; deterministic P3.0A tests inject shorter values.
- Attempts to let every accepted queued and in-flight item reach `tts.audio` or `tts.error` publication within that shared deadline.
- Returns `True` only when all accepted work and publications complete successfully.
- On deadline or publisher failure, begins abort, discards queued work, cancels in-flight work, settles TTS-owned tasks, and returns `False` without extending the deadline per discarded item.
- A call after close returns `False`; a repeated call before close over an already drained queue returns the same successful outcome.

### `abort`

- Stops acceptance immediately.
- Cancels the current provider/publisher await and the worker.
- Discards queued work with balanced `queue.task_done` accounting.
- Publishes no cancellation errors because delivery may already be unavailable.
- Awaits cancellation of all session-owned tasks; adapters must propagate cancellation.
- Is idempotent.

### `close`

- Calls the abort/settle path and releases all owned tasks.
- Is safe after a successful drain, a failed drain, or an earlier abort.
- Is idempotent.
- Leaves no session-owned worker, provider, drain, or cleanup task running once cooperative dependency cancellation completes.

## 20. Future clean Stop integration contract

P3.0B must implement normal Stop in this order:

```text
stt.stop
-> stop accepting client audio
-> Deepgram finish_input and trailing transcript.final
-> TranslationSession.flush_and_drain
-> submit each emitted translation.final to TtsSession
-> no more TTS submissions after Translation drain completes
-> TtsSession.flush_and_drain(timeout_seconds=5.0), one TOTAL deadline
-> trailing tts.audio or tts.error completed within that deadline
-> TtsSession.close
-> stt.closed
-> socket/resource cleanup
```

The socket stays open while bounded Translation and TTS drains run. A final translated utterance is not discarded merely because synthesis is in flight: it receives an opportunity to complete inside the shared five-second TTS window. If that total deadline expires, TTS cancels the current synthesis, drops remaining queued synthesis work, releases its worker/tasks, and `stt.closed` continues. STT and Translation success are not rewritten as failures. P3.0C must align future client Stop timeouts with the complete server-side Stop chain.

## 21. Unexpected disconnect behavior

P3.0B must handle an unexpected producer disconnect as:

```text
unexpected disconnect
-> abort Translation
-> abort TTS
-> close publisher/provider resources
-> release producer ownership
```

No TTS drain or audio-delivery guarantee applies when the producer transport disappears. Abort must promptly cancel synthesis and discard pending audio work. Viewers receive no late TTS output from the abandoned producer stream.

## 22. Late viewers and non-replay

P3.0B will extend the active session snapshot so a late viewer can receive current `translation.configured` and, when enabled, `tts.configured`. Snapshot publication remains owned by the active producer identity and is cleared when that producer releases the session.

A late viewer receives only configuration plus future realtime events. It does not receive historical `tts.pending`, `tts.audio`, binary audio, `tts.error`, transcript, or Translation replay. P3.0A creates no audio history collection and no replay API.

## 23. Security and secrets

- Provider credentials remain backend-only and outside all P3.0A contracts.
- Events and exceptions expose fixed provider-neutral messages only.
- Raw response bodies, request/response headers, authorization values, account IDs, provider request IDs, and SDK objects are never serialized.
- `SynthesizedAudio` holds only validated bytes and safe media metadata.
- The fake uses generated deterministic bytes and no environment credentials.
- Tests make no Deepgram, Cloudflare, Google, TTS, browser, WebSocket-provider, or device request.

## 24. Testing strategy

All P3.0A tests are deterministic pytest tests using `asyncio.run`, recorded callbacks, and `asyncio.Event` gates consistent with existing Translation tests.

Domain tests cover immutable valid audio, rejection of empty/wrong-type bytes, blank MIME types, invalid sample rates, protocol conformance, deterministic fake success, captured text/language/voice, call counts, controlled exceptions, blocking gates, concurrency counters, and cancellation.

Protocol tests cover all six rows of the locked Translation/TTS validation matrix; all eight canonical target languages through Translation; voice validation; extra-field rejection; STT-only and Translation-only compatibility; exact configured/pending/audio/error schemas; omission of optional fields; deterministic audio IDs; byte length; and the absence of audio bytes, Base64, data URLs, and provider fields from metadata.

Session tests cover successful pending-to-audio publication, a bounded queue, intentional overflow drop, zero calls for an overflowed identity and its duplicates, later unique work after overflow, one worker, maximum provider concurrency of one, submission/output order, permanent duplicate ignore, exactly one call per unique identity, provider request timeout, absence of automatic retry after provider failure/timeout, unavailable/provider/internal failures, invalid/empty results, continuation after an utterance failure, successful drain, the separate total drain deadline, multiple queued slow requests unable to extend that total deadline, prompt abort, idempotent abort/close, balanced queue accounting, publisher failure, and no owned task after close.

The focused verification command defined in the implementation plan uses the mandated Backend interpreter and runs only the new TTS files plus the modified STT protocol tests. Final verification also runs the full Backend suite, `compileall`, scoped `git diff --check`, and a scope inspection. No live service is started.

## 25. P3.0A exact scope

P3.0A implementation may create:

- `services/api/app/ai/tts.py`;
- `services/api/app/realtime/tts_protocol.py`;
- `services/api/app/realtime/tts_session.py`;
- `services/api/tests/fakes/tts.py`;
- `services/api/tests/test_tts_provider.py`;
- `services/api/tests/test_tts_protocol.py`; and
- `services/api/tests/test_tts_session.py`.

It may modify only these existing files:

- `services/api/app/realtime/stt_protocol.py`, to parse the optional TTS start configuration; and
- `services/api/tests/test_stt_protocol.py`, to prove validation and backward compatibility.

No settings field is added in P3.0A. `TtsSession` exposes queue and timeout constructor parameters with locked defaults; P3.0B may connect them to backend settings when it adds runtime construction.

## 26. P3.0B handoff boundary

P3.0B consumes the completed P3.0A interfaces and is responsible for:

- constructing one `TtsSession` per enabled producer stream;
- feeding only committed `translation.final` values into `submit`;
- extending `SessionEventPublisher` and `SessionHub` for TTS configuration and metadata-plus-binary fan-out;
- serializing each recipient's `tts.audio` JSON metadata immediately before its binary frame;
- broadcasting one synthesis result rather than calling the provider per viewer;
- integrating Translation-then-TTS bounded clean Stop;
- passing exactly `timeout_seconds=5.0` as the one total TTS clean-stop drain deadline, independently of the 10-second per-request timeout;
- aborting both downstream sessions on unexpected disconnect; and
- applying active TTS configuration snapshots without historical audio replay.

P3.0A does not edit any of those integration points.

## 27. P3.0C handoff boundary

P3.0C owns Web and Mobile parsing of TTS metadata, association of the next binary payload by `audio_id`, ordered playback, enable/disable controls, mute behavior, buffering, cleanup, and client Stop timeout alignment. It must preserve receive-only Viewer behavior and all existing STT/Translation presentation semantics.

P3.0A does not modify `apps/web` or `apps/mobile` and does not define their final playback UI.

## 28. P3.1 provider boundary

P3.1 evaluates and selects a real synthesizer, implements its adapter behind `SpeechSynthesizer`, adds server-only provider configuration and canonical-language/voice mapping, runs one bounded provider smoke, and performs separately approved Web and Mobile real-provider E2E checkpoints.

P3.0A contains no vendor selection, dependency, credential, billing change, network call, or provider adapter.
