# P3.0B Backend Realtime TTS Integration Design

**Date:** 2026-09-03

**Status:** Proposed for human review

**Scope:** Backend realtime orchestration and metadata-plus-binary delivery only

## 1. Context

P2 established the verified realtime path from Deepgram transcript events through a bounded `TranslationSession` to normalized Translation events delivered to one producer and the current `SessionHub` viewers. P3.0A added a provider-neutral `SpeechSynthesizer`, immutable `SynthesizedAudio`, normalized TTS event builders, and a bounded sequential `TtsSession` without connecting them to `/ws/stt`.

P3.0B connects those completed building blocks. A committed `translation.final` becomes the sole TTS input. One backend synthesis result is delivered to the producer and every viewer that was eligible when that audio broadcast began. JSON metadata and raw audio remain separate WebSocket frames, with per-socket serialization making them one indivisible application-level outbound pair.

## 2. Goals

P3.0B will deterministically establish:

- one `TtsSession` per TTS-enabled producer stream when a synthesizer is available;
- `translation.final` as the only TTS trigger;
- one synthesis independent of viewer count;
- normalized `tts.configured`, `tts.pending`, `tts.audio`, and `tts.error` delivery;
- raw binary WebSocket audio immediately after its `tts.audio` metadata on every successful recipient socket;
- a viewer snapshot taken at the start of each audio broadcast;
- active Translation and TTS configuration snapshots for late viewers, with no event or audio replay;
- isolated failed-viewer handling;
- a single startup error when TTS is requested but unavailable;
- clean Stop ordering from STT finalization through Translation drain and then bounded TTS drain;
- prompt abort and snapshot cleanup on unexpected producer disconnect; and
- deterministic Backend tests using only the existing fakes and dependency seams.

## 3. Non-goals

P3.0B does not:

- choose or implement a real TTS provider;
- add provider credentials, vendor models, language mapping, billing, or network calls;
- add Web or Mobile playback, buffering, mute controls, or UI;
- change the P3.0A TTS domain, identity, queue, retry, timeout, or error contracts;
- put audio bytes or Base64 in JSON;
- add a custom binary header;
- persist, cache, record, or replay synthesized audio;
- alter transcript or Translation history semantics;
- synthesize per viewer;
- change Web or Mobile `stt.closed` timeouts; or
- run P1.5E Android System Audio validation.

P3.0C owns client playback and client Stop-timeout alignment. P3.1 owns real-provider selection and validation.

## 4. Current verified architecture

The current `/ws/stt` endpoint owns the provider stream, optional `TranslationSession`, one `SessionEventPublisher`, producer identity, and cleanup lifecycle. `SessionEventPublisher.publish` holds one producer send lock, sends JSON to the producer, then asks `SessionHub` to broadcast the same event. `SessionHub` snapshots viewers under membership protection, serializes sends per viewer, applies a bounded viewer-send timeout, and removes failed viewers without surfacing them as producer failures.

`TranslationSession` receives final transcripts, aggregates them into committed utterances, emits `translation.pending`, and then emits either `translation.final` or `translation.error`. Its publisher callback is the correct downstream seam: an event has already become a normalized committed Translation result before any TTS submission occurs.

Clean Stop currently finishes Deepgram input and trailing events, drains Translation with one five-second limit, then sends `stt.closed`. Unexpected disconnect returns without draining and the endpoint's `finally` path aborts Translation before releasing the producer and its Translation snapshot.

## 5. P3.0A dependencies

P3.0B consumes these contracts unchanged:

```python
class SpeechSynthesizer(Protocol):
    async def synthesize(
        self,
        *,
        text: str,
        language: TargetLanguage,
        voice: str | None = None,
    ) -> SynthesizedAudio: ...


@dataclass(frozen=True, slots=True)
class SynthesizedAudio:
    audio_bytes: bytes
    mime_type: str
    sample_rate_hz: int | None = None
```

`TtsSession` retains its `(stream_id, utterance_id)` deduplication, `asyncio.Queue(maxsize=8)`, one sequential worker, 10.0-second per-request timeout, permanent no-retry policy, safe error taxonomy, and caller-supplied total drain deadline. P3.0B passes exactly `timeout_seconds=5.0` once during clean Stop.

The existing `stt.start` rule remains unchanged: `tts.enabled=true` requires a valid Translation configuration; omitted TTS and `enabled=false` preserve existing behavior.

## 6. Realtime TTS data flow

```text
Deepgram transcript.final
  -> TranslationUtteranceAggregator
  -> TranslationSession
  -> SessionEventPublisher publishes translation.final
  -> TranslationFinalTtsBridge submits that normalized final once
  -> TtsSession bounded queue and sequential worker
  -> SessionEventPublisher publishes tts.pending
  -> SpeechSynthesizer.synthesize once
  -> SynthesizedAudio
  -> SessionEventPublisher.publish_audio_pair(metadata, bytes)
       -> snapshot current viewers
       -> producer: JSON metadata, then binary bytes
       -> each snapshotted viewer: JSON metadata, then binary bytes
```

The bridge sits after successful Translation event publication and before TTS submission. This preserves `translation.final -> tts.pending` while leaving `TranslationSession` unchanged.

## 7. `translation.final` trigger contract

`TranslationFinalTtsBridge` wraps the publisher callback supplied to `TranslationSession` only when an operational `TtsSession` exists:

```python
class TranslationFinalTtsBridge:
    def __init__(
        self,
        *,
        publish_event: TranslationEventPublisher,
        tts_session: TtsSession,
        stream_id: str,
        target_language: TargetLanguage,
    ) -> None: ...

    async def publish(self, event: dict[str, object]) -> None: ...
```

`publish` first awaits the original event publisher. It submits only when `event["type"] == "translation.final"`, using the event's exact `stream_id`, `utterance_id`, `source_segment_ids`, `translated_text`, and `target_language`. It does not inspect or match text to establish identity.

`transcript.interim`, `transcript.final`, `translation.pending`, and `translation.error` never call `TtsSession.submit`. One normalized final reaches the bridge once; P3.0A deduplication provides the second at-most-one defense if a duplicate identity is ever delivered.

An unexpected bridge/submission exception is isolated from Translation. The bridge disables further submissions, aborts TTS, attempts one safe session-scoped `tts.error` with `internal_error`, and never exposes exception text. Failure to publish that notification is swallowed after safe exception-class logging so it cannot make `TranslationSession` fail. `asyncio.CancelledError` still propagates for lifecycle cancellation.

## 8. Producer event flow

With operational Translation and TTS, startup order is:

```text
stt.ready
-> translation.configured
-> tts.configured
```

Successful utterance order is:

```text
transcript.final
-> translation.pending
-> translation.final
-> tts.pending
-> tts.audio JSON metadata
-> binary audio frame
```

TTS provider/result failure order is:

```text
translation.final
-> tts.pending
-> tts.error
```

Queue overflow has no fake pending event:

```text
translation.final
-> tts.error(code="queue_overflow")
```

Unrelated realtime events may occur between Translation and TTS operations because the subsystems are asynchronous. No event may occur between a given socket's `tts.audio` metadata and its paired binary frame.

## 9. Viewer event flow

Every current eligible viewer receives the same normalized TTS lifecycle events as the producer. `tts.pending` and `tts.error` use ordinary serialized JSON broadcast. Successful audio uses the dedicated pair operation.

For every viewer in the audio broadcast snapshot:

```text
tts.audio JSON metadata(audio_id=X)
-> binary audio bytes for X
```

All viewers remain receive-only. No viewer message can request provider work in P3.0B, and no viewer count or join/leave event is passed to `TtsSession` or `SpeechSynthesizer`.

## 10. SessionHub TTS configuration snapshot

`SessionHub` adds a producer-owned `_tts_configs` map parallel to `_translation_configs` and exposes:

```python
async def set_tts_config(
    self,
    session_id: str,
    producer_identity: object,
    event: dict[str, object],
) -> bool: ...

async def publish_tts_config(
    self,
    session_id: str,
    producer_identity: object,
    event: dict[str, object],
) -> bool: ...
```

Only the current producer may set or publish the snapshot. `publish_tts_config` stores a defensive copy and broadcasts that same safe event to current viewers. `join_viewer` captures both active configuration objects while holding membership protection and sends them in deterministic order: `translation.configured` first, then `tts.configured`.

`release_producer` clears both snapshots in the same producer-identity-checked operation. A later STT-only or Translation-only producer cannot inherit stale TTS state.

## 11. Metadata and binary frame contract

P3.0A's `tts.audio` schema remains metadata-only:

```json
{
  "type": "tts.audio",
  "stream_id": "stream_123",
  "utterance_id": "utt_000001",
  "audio_id": "audio_000001",
  "target_language": "en",
  "mime_type": "audio/wav",
  "byte_length": 6,
  "sample_rate_hz": 16000
}
```

The next application data frame on that same successfully delivered WebSocket is the exact raw byte sequence passed with the metadata. No Base64, data URL, byte list, provider response, or authorization value enters JSON.

The existing WebSocket protocol type gains `send_bytes(data: bytes)`. No alternate socket writer or transport envelope is introduced.

## 12. Atomic outbound-pair serialization

`SessionEventPublisher` adds:

```python
async def publish_audio_pair(
    self,
    metadata: dict[str, object],
    audio_bytes: bytes,
) -> None: ...

@property
def producer_delivery_failed(self) -> bool: ...

async def wait_for_producer_delivery_failure(self) -> None: ...
```

The method acquires the existing `_send_lock` once and keeps it across viewer snapshot capture, producer `send_json(metadata)`, producer `send_bytes(audio_bytes)`, and dispatch to the fixed viewer snapshot. Every realtime transcript, Translation, and TTS JSON or audio publication uses the same lock, so no producer frame can interleave within the pair. `stt.ready` is sent before downstream sessions start. Terminal STT error/closed frames remain endpoint lifecycle writes only after downstream work has settled; they are suppressed when publisher failure marks the producer transport unusable. No new unsynchronized writer is added.

`SessionHub.deliver_audio_pair` acquires each existing viewer send lock once around both sends. Ordinary broadcasts and other audio pairs use that same per-viewer lock, so no viewer frame can interleave. Different viewers may be served concurrently because ordering is socket-local.

Atomicity here is application-level serialization, not a transactional network guarantee. If a socket closes, a send is cancelled, or its binary send fails after metadata was accepted, that socket has a truncated transport operation. Any producer send failure sets `producer_delivery_failed=True`, signals the publisher's one awaitable failure event, deactivates the publisher, and re-raises to the immediate caller. The stream loop owns a task waiting on that event while realtime work is active. A pair failure can therefore end the stream as `client_disconnect` even though `TtsSession` correctly catches the callback exception inside its worker. A failed viewer is removed. The failed producer writer is not deliberately used for a later application event, while healthy recipients remain unaffected.

## 13. `audio_id` association

`audio_id` is generated by the one `TtsSession` in successful synthesis order and appears only in metadata. P3.0C associates the immediately following binary frame on that socket with this ID. The binary payload has no custom prefix or duplicated ID.

Two consecutive results therefore appear as:

```text
JSON tts.audio(audio_000001)
binary bytes for audio_000001
JSON tts.audio(audio_000002)
binary bytes for audio_000002
```

Text, MIME guessing, byte hashing, and audio-content matching are forbidden identity mechanisms.

## 14. Viewer snapshot semantics

At the beginning of `SessionEventPublisher.publish_audio_pair`, after acquiring the publisher lock and before sending producer metadata, the publisher asks `SessionHub` for one opaque `ViewerDeliverySnapshot`:

```python
async def snapshot_viewers(
    self,
    session_id: str,
) -> ViewerDeliverySnapshot: ...

async def deliver_audio_pair(
    self,
    snapshot: ViewerDeliverySnapshot,
    metadata: dict[str, object],
    audio_bytes: bytes,
) -> None: ...
```

The snapshot contains the session ID plus the exact viewer/socket-lock targets eligible at that instant. `deliver_audio_pair` never resnapshots. A viewer joining while producer delivery is in progress is absent and receives neither half of the old audio result. A viewer leaving or failing after capture is handled as a failed snapshot target without affecting other targets.

This two-step Hub API is intentionally narrow: the snapshot is opaque outside `SessionHub`, is used immediately by `SessionEventPublisher`, and is not stored as audio history.

## 15. Failed-viewer isolation

Each viewer pair is wrapped by the existing `viewer_send_timeout_seconds` as one operation. Failure or timeout on either JSON metadata or binary payload marks that viewer failed. `SessionHub` removes failed viewers after all snapshot sends settle and does not raise their failures to `SessionEventPublisher`.

Consequently one failed viewer cannot prevent producer delivery, healthy-viewer delivery, later synthesis, STT, Translation, or producer ownership. Queueing and provider cost are completely independent of viewer delivery outcomes.

## 16. Provider-unavailable behavior

P3.0B adds a dependency seam without selecting a provider:

```python
def get_session_speech_synthesizer_factory(
) -> SpeechSynthesizerFactory | None:
    return None
```

Tests override this dependency with `FakeSpeechSynthesizer`. No environment setting or credential is added.

When `tts.enabled=true`, Translation initialized successfully, and the dependency is absent or factory construction raises, startup emits exactly:

```text
stt.ready
-> translation.configured
-> tts.configured
-> tts.error(scope="session", code="provider_unavailable")
```

No `TtsSession` is created, so later `translation.final` events cannot repeatedly emit unavailable errors or invoke a provider. STT and Translation continue normally. Current viewers receive the startup error once. Late viewers receive active Translation/TTS configuration snapshots but no replay of the earlier error.

If Translation itself cannot initialize, the existing session-scoped Translation error remains authoritative. TTS construction is skipped and no `tts.configured` or TTS provider error is emitted because the required downstream input pipeline never became operational.

## 17. One synthesis to many viewers

The scaling invariant is structural:

```text
one translation.final
-> one TranslationFinalTtsBridge.submit call
-> one TtsSession work identity
-> at most one SpeechSynthesizer.synthesize call
-> one SynthesizedAudio
-> one producer pair plus N viewer pair deliveries
```

`SessionHub` receives completed bytes, never text to synthesize. Joining, leaving, failing, or adding 100 viewers changes only fan-out, never TTS call count.

## 18. Clean Stop lifecycle

Normal producer Stop is locked as:

```text
stt.stop
-> reject further client audio
-> stream.finish_input
-> trailing transcript.final publication
-> TranslationSession.flush_and_drain(timeout_seconds=5.0)
-> trailing translation.final/error publication
-> every completed translation.final is submitted while TTS still accepts
-> TtsSession.flush_and_drain(timeout_seconds=5.0), called once
-> trailing tts.pending/audio+binary/error completed inside the TTS budget
-> stt.closed
-> close TranslationSession and TtsSession in endpoint cleanup
-> transport and producer cleanup
```

The TTS drain call cannot begin until the Translation drain call has returned. TTS acceptance therefore stays open throughout Translation's drain, including its buffered final utterance. Whether Translation drain succeeds or reaches its bound, it is no longer capable of emitting a later final before TTS acceptance closes.

`stt.closed` is sent after the TTS drain returns while producer delivery remains healthy; the endpoint's existing `finally` lifecycle then closes both drained downstream sessions. A TTS timeout or provider error does not convert the successful STT stop into `stt.error`. If the producer's metadata/binary pair itself was truncated by a transport failure or cancellation, either the active stream-loop failure waiter or the post-drain failure check selects disconnect cleanup. The endpoint does not send `stt.closed` through that failed writer, so no JSON frame can follow orphaned metadata.

## 19. Deadline interaction

The Translation total drain retains its existing 5.0-second bound. The TTS provider call retains its 10.0-second per-request bound. P3.0B applies one independent 5.0-second total TTS drain deadline after Translation drain. The TTS deadline is never multiplied by queue length and may cancel a provider request before its ten-second request timeout.

The complete server-side Stop duration includes Deepgram finalization plus sequential Translation and TTS drain windows. It can therefore exceed the clients' current approximately eight-second local wait. P3.0B does not change clients. P3.0C must increase and test each client `stt.closed` wait so it exceeds the complete enabled-TTS server lifecycle with a safety margin; retaining the current eight-second value is explicitly disallowed when TTS playback is enabled.

## 20. Unexpected disconnect

Unexpected producer disconnect performs no drain:

```text
detect producer disconnect
-> abort Translation
-> abort TTS
-> settle their owned tasks
-> close SessionEventPublisher and STT stream
-> release producer identity
-> clear Translation and TTS snapshots
```

Translation is aborted first so it cannot emit and submit a new final after TTS abort begins. TTS then cancels current synthesis/publication and discards queued work. No historical audio-completion guarantee applies. The final release remains in the endpoint's `finally` block so errors and WebSocket close failures cannot leave stale ownership.

A producer-send failure signalled by `SessionEventPublisher` follows this same no-drain path. `_run_stream_owned` monitors the publisher failure waiter alongside producer receive and STT events. During the synchronous clean-drain section it checks `producer_delivery_failed` immediately after TTS settles. If a startup or other awaited publisher call raises directly, the endpoint exception boundary performs the same property check before considering a terminal STT error. All three paths classify the broken transport as `client_disconnect` and suppress later application frames.

## 21. TTS failure isolation

The existing `TtsSession` maps provider unavailable, provider error, request timeout, invalid audio, queue overflow, and internal synthesis failures to safe `tts.error` events. It continues to later unique utterances where the P3.0A contract permits.

These errors do not raise an STT error, hide `translation.final`, stop Translation, or close the producer. Queue overflow emits no `tts.pending` because no provider call begins. No automatic retry is added.

A producer WebSocket write failure is a transport failure, not a provider failure. It deactivates the publisher, is surfaced through the publisher/TTS delivery path, and causes endpoint cleanup without another application frame on that socket. Viewer write failures remain isolated and never fail `TtsSession`.

## 22. Task and resource ownership

- The `/ws/stt` endpoint owns the STT stream, `TranslationSession`, `TtsSession`, bridge, publisher, producer identity, and their shutdown order.
- `TranslationSession` owns Translation aggregation, inactivity, queue, and worker tasks.
- `TtsSession` owns TTS queue, worker, provider request, drain, and cleanup tasks.
- `SessionEventPublisher` owns the producer serialization lock and creates no detached long-lived task.
- `SessionHub` owns viewer membership, configuration snapshots, session locks, and per-viewer send locks. Pair-send coroutines are bounded, awaited, and removed with failed viewers.
- `TranslationFinalTtsBridge` owns no background task and performs no synthesis itself.

The stream loop owns and cancels one publisher-failure waiter whenever TTS-enabled realtime work is active. Every endpoint exit settles downstream sessions before publisher closure and producer release. No P3.0B operation leaves a synthesis, drain, publisher-failure waiter, pair-send, or viewer-send task detached.

## 23. Late-viewer behavior

A late viewer joins the existing receive-only endpoint. If a producer is active, it receives configuration snapshots in this order:

```text
translation.configured, when active
-> tts.configured, when active
-> future realtime events only
```

It receives no earlier transcript, Translation event, `tts.pending`, `tts.error`, `tts.audio`, or binary payload. Joining after an audio snapshot cannot add it to that snapshot. No audio-history data structure or replay API is introduced.

## 24. Backward compatibility

- STT-only start, with TTS omitted or explicitly disabled, never invokes either AI downstream factory because Translation is absent.
- Translation-only start, with TTS omitted or disabled, uses the existing Translation publisher and event order without constructing a synthesizer.
- TTS-enabled behavior is opt-in and valid only with Translation.
- Existing JSON-only clients never receive binary audio unless they explicitly send `tts.enabled=true`.
- Existing transcript and Translation event schemas, identity rules, producer exclusivity, and viewer receive-only behavior remain unchanged.
- `SessionHub.broadcast` and `SessionEventPublisher.publish` keep their existing JSON behavior.

## 25. Security and secrets

- The default TTS factory seam is unconfigured and uses no environment variable.
- Tests use `FakeSpeechSynthesizer` only and make no network request.
- Audio metadata contains only protocol fields already approved in P3.0A.
- Raw audio appears only in process memory and binary WebSocket frames.
- Tokens, authorization headers, account IDs, provider responses, exception messages, and SDK objects are never serialized.
- Logs record only safe event context and exception class names; they do not log text, audio bytes, or raw exception details.

## 26. Testing strategy

All new tests use pytest, `asyncio.run`, `asyncio.Event` gates, FastAPI `TestClient`, existing fake STT/Translation/TTS providers, and recording sockets with distinct JSON/binary frame capture.

Publisher tests prove one producer lock covers the pair, concurrent JSON cannot interleave, consecutive results stay paired, the viewer snapshot is captured before producer send, and every producer send failure sets the property and wakes the failure waiter. Hub tests prove per-viewer pair locking, snapshot immutability, failed/stalled viewer isolation, TTS configuration storage/order/clear, and no replay.

Bridge tests prove only `translation.final` submits, exact identity/content forwarding, publication-before-submission, one submission, and isolation of unexpected TTS submission failure.

Socket integration tests prove disabled compatibility, available/unavailable startup ordering, one synthesis with multiple viewers, producer/viewer metadata-plus-binary equality, provider and queue failure isolation, Translation-before-TTS clean Stop, final-tail preservation, bounded TTS drain, unexpected-disconnect abort, late-viewer snapshots without old audio, snapshot cleanup, and no owned task leak.

Final verification runs the focused new/modified tests, all P3.0A tests, Translation integration regression, the full Backend suite, `compileall`, forbidden-pattern scans, `git diff --check`, and exact scope inspection. No service or real provider is started.

## 27. Exact P3.0B scope

Expected production changes are limited to:

- `services/api/app/realtime/session_hub.py`;
- `services/api/app/realtime/session_event_publisher.py`;
- `services/api/app/realtime/tts_orchestration.py` as a small Translation-final bridge;
- `services/api/app/realtime/stt_socket.py`.

Expected deterministic test changes are limited to:

- `services/api/tests/test_session_hub.py`;
- `services/api/tests/test_session_event_publisher.py`;
- `services/api/tests/test_tts_orchestration.py`;
- `services/api/tests/test_stt_tts_integration.py`.

P3.0A production contracts and tests remain regression inputs, not redesign targets. `session_viewer.py`, `TranslationSession`, Web, and Mobile require no production change for this milestone.

## 28. P3.0C handoff

P3.0C consumes the ordered metadata/binary contract and must:

- associate the binary frame immediately following `tts.audio` with that event's `audio_id`;
- validate byte length and supported MIME handling;
- preserve playback order;
- implement enable/disable, buffering, mute, and cleanup behavior;
- keep viewers receive-only;
- handle a truncated pair as transport failure rather than attaching later JSON/binary data to the old `audio_id`; and
- replace the current approximately eight-second local Stop wait with a tested value exceeding the complete TTS-enabled Backend Stop lifecycle plus safety margin.

No part of that client behavior is implemented in P3.0B.

## 29. P3.1 provider handoff

P3.1 selects and implements one real adapter behind `SpeechSynthesizer`, adds server-only provider configuration and canonical language/voice mapping, validates one bounded provider request, and then performs separately approved Web and Mobile E2E checkpoints.

Provider choice, credentials, cost, quality, latency benchmarking, and vendor-specific fields are not P3.0B concerns.

## 30. Risks and leader-review candidates

### Review recommended

- **Metadata JSON plus immediate binary frame:** confirm that application-level serialized pairing, without a custom binary header, is the preferred protocol for P3.0C.
- **One synthesis to many viewers:** confirm backend synthesis and completed-audio fan-out as the cost/scaling boundary.
- **Viewer snapshot timing:** confirm snapshot-at-publish-start behavior, especially that a viewer joining during producer delivery receives neither half of that old audio.
- **Clean Stop chain:** review the explicit Deepgram finalization, Translation drain, then TTS drain ordering.
- **Client timeout implication:** acknowledge that the current approximately eight-second client wait cannot remain the TTS-enabled contract and is a P3.0C change.
- **Provider deferral:** confirm that production provider choice and provider-specific mapping remain isolated in P3.1.
- **Transport failure boundary:** confirm that atomicity prevents application interleaving but cannot make two WebSocket sends transactional across a broken connection; failed sockets are removed or closed rather than reused.

These are review-worthy architecture decisions, not impediments to deterministic P3.0B implementation.

### Actual blocker or resource needed

None. P3.0B can be implemented and verified entirely with current repository dependencies and fakes. Real-provider credentials, billing, physical devices, browser playback, and stakeholder selection of a production voice are not required for this checkpoint.

## 31. Implementation evidence to preserve

The P3.0B completion report must preserve:

- exact files created and modified;
- RED and GREEN test names and counts by task;
- the final event and binary-frame order;
- proof that concurrent JSON cannot interleave inside a pair;
- one-synthesis-many-viewers call-count evidence;
- viewer snapshot, failure-isolation, and late-viewer results;
- provider-unavailable single-error evidence;
- clean Stop Translation-to-TTS drain ordering and timeout result;
- unexpected-disconnect cancellation and task-leak results;
- focused, P3.0A, Translation, and full Backend regression totals;
- `compileall` and `git diff --check` results;
- safe screenshots or filtered logs if later client work produces them;
- the review-recommended decisions above; and
- any actual external resource need discovered during implementation.

This evidence is sufficient to extract a weekly internship progress report without creating that report during P3.0B.
