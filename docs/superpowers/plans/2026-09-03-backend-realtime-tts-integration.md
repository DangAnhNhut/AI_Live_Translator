# P3.0B Backend Realtime TTS Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:test-driven-development` while executing every task and `superpowers:verification-before-completion` before reporting. Execute task-by-task in the existing approved worktree. Steps use checkbox (`- [ ]`) syntax for tracking. Do not commit, push, merge, switch branches, or create another worktree.

**Goal:** Connect the verified P3.0A TTS foundation to the Backend realtime Translation pipeline and deliver one synthesized result to the producer and the viewers captured at audio-broadcast start as serialized JSON-metadata/binary pairs.

**Architecture:** `TranslationSession` keeps its existing contract. A small `TranslationFinalTtsBridge` publishes every Translation event first and submits only `translation.final` to one stream-owned `TtsSession`. `SessionEventPublisher` remains the sole producer writer and holds its existing lock across each audio pair; `SessionHub` captures one opaque viewer snapshot and holds each viewer's existing lock across the corresponding pair. Clean Stop drains Translation before applying one five-second total TTS drain deadline.

**Tech Stack:** Python 3.11.9 environment with Python 3.10-compatible syntax, standard-library `asyncio`, FastAPI/Starlette WebSockets, Pydantic, pytest, and existing deterministic STT/Translation/TTS fakes. No dependency is added.

**Spec:** `docs/superpowers/specs/2026-09-03-backend-realtime-tts-integration-design.md`

## Global constraints

- Work in `D:\AI_Live_Translator_RealSTT` on `feature/stt-provider-benchmark`; do not rename or switch it.
- Use `D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe` for every Python command.
- Run every pytest and compileall command from `D:\AI_Live_Translator_RealSTT\services\api`. Run every Git command through `git -C 'D:\AI_Live_Translator_RealSTT'` so pathspecs remain repository-root-relative.
- Preserve all approved dirty and untracked work. Never reset, clean, stash, restore, or overwrite unrelated paths.
- Do not run `git add`, `git commit`, `git push`, or `git merge`.
- Apply strict RED -> verify the intended failure -> minimal GREEN -> focused verification -> refactor only while green.
- Do not change P3.0A identity, queue size 8, sequential worker, 10.0-second request timeout, five-second total TTS drain contract, error taxonomy, or no-retry behavior.
- TTS is triggered only by `translation.final`; it is never triggered by transcript, Translation pending, or Translation error events.
- One `(stream_id, utterance_id)` causes at most one synthesis independent of viewer count.
- Never place audio bytes or Base64 in JSON. Each successful socket receives `tts.audio` metadata immediately followed by its binary payload under one socket lock.
- No real TTS provider, provider credential/configuration, network call, Web/Mobile change, playback implementation, persistence, benchmark, or physical-device test is allowed.
- Do not modify `TranslationSession`, `TtsSession`, their P3.0A protocols/domain types, `session_viewer.py`, or client code unless an observed architecture conflict is reported to the human first.

## File map

Create:

- `services/api/app/realtime/tts_orchestration.py` — isolate normalized `translation.final` routing from `TranslationSession` and protect Translation from TTS submission faults.
- `services/api/tests/test_tts_orchestration.py` — bridge trigger/order/isolation contract.
- `services/api/tests/test_stt_tts_integration.py` — deterministic `/ws/stt` producer/viewer, lifecycle, provider-unavailable, and scaling coverage.

Modify:

- `services/api/app/realtime/session_hub.py` — binary-capable socket protocol, active TTS config snapshot, opaque viewer snapshot, and per-viewer audio-pair delivery.
- `services/api/tests/test_session_hub.py` — snapshot/config/pair ordering and failed-viewer tests.
- `services/api/app/realtime/session_event_publisher.py` — producer atomic-pair method, TTS config publication, viewer snapshot timing, and producer-pair failure state.
- `services/api/tests/test_session_event_publisher.py` — producer serialization and snapshot-at-operation-start tests.
- `services/api/app/realtime/stt_socket.py` — optional synthesizer dependency, startup events, bridge/session construction, Translation-then-TTS drain, and abort cleanup.

Regression-only inputs, with no planned edits:

- `services/api/app/ai/tts.py`
- `services/api/app/realtime/tts_protocol.py`
- `services/api/app/realtime/tts_session.py`
- `services/api/app/realtime/translation_session.py`
- `services/api/app/realtime/session_viewer.py`
- `services/api/tests/fakes/tts.py`
- `services/api/tests/test_tts_provider.py`
- `services/api/tests/test_tts_protocol.py`
- `services/api/tests/test_tts_session.py`
- `services/api/tests/test_stt_protocol.py`
- `services/api/tests/test_stt_translation_integration.py`
- `services/api/tests/test_session_viewer.py`
- `services/api/tests/test_stt_websocket.py`

---

### Task 1: SessionHub TTS configuration and fixed viewer-pair delivery

**Files:**

- Modify: `services/api/app/realtime/session_hub.py`
- Modify: `services/api/tests/test_session_hub.py`

**Interfaces:**

- Extends `JsonWebSocket` with `async send_bytes(data: bytes) -> None`.
- Produces `ViewerDeliverySnapshot`, treated as opaque outside `SessionHub`.
- Produces `snapshot_viewers(session_id)`, `deliver_audio_pair(snapshot, metadata, audio_bytes)`, `set_tts_config(...)`, and `publish_tts_config(...)` for Task 2.
- Preserves existing `broadcast`, Translation snapshot, producer ownership, viewer timeout, and failed-viewer behavior.

- [ ] **Step 1: Add RED frame-recording and TTS snapshot tests**

Extend the test socket without changing existing `sent_events` assertions:

```python
class FakeWebSocket:
    def __init__(self, *, fail=False, fail_binary=False):
        self.fail = fail
        self.fail_binary = fail_binary
        self.sent_events = []
        self.sent_frames = []

    async def send_json(self, event):
        if self.fail:
            raise RuntimeError("viewer disconnected")
        self.sent_events.append(event)
        self.sent_frames.append(("json", event))

    async def send_bytes(self, data):
        if self.fail or self.fail_binary:
            raise RuntimeError("viewer disconnected")
        self.sent_frames.append(("bytes", data))
```

Add these exact cases:

- `test_late_viewer_receives_translation_then_tts_configuration`: claim a producer, set both configs, join a viewer, and assert the two JSON frames occur once in Translation-then-TTS order.
- `test_wrong_producer_cannot_set_or_publish_tts_configuration`: assert both operations return `False` and no viewer frame is sent.
- `test_releasing_producer_clears_translation_and_tts_configuration`: release, claim a replacement, join a late viewer, and assert no stale config.
- `test_tts_config_publication_reaches_existing_and_late_viewers_once`: assert current and late viewers each receive one safe config.

- [ ] **Step 2: Add RED fixed-snapshot and pair-lock tests**

Add `test_audio_pair_uses_fixed_viewer_snapshot`:

```python
snapshot = await hub.snapshot_viewers("session-1")
await hub.join_viewer("session-1", late)
await hub.deliver_audio_pair(snapshot, metadata, b"audio")
assert existing.sent_frames == [("json", metadata), ("bytes", b"audio")]
assert late.sent_frames == []
```

Add `test_viewer_json_cannot_interleave_inside_audio_pair` using a socket whose `send_bytes` sets `binary_started` and waits on a gate. Start `deliver_audio_pair`, then start `broadcast` for a marker. Before releasing the gate, assert the marker task is pending. After release, assert frame order is metadata, bytes, marker.

Add `test_two_consecutive_audio_results_remain_paired` and assert:

```python
[
    ("json", first_metadata),
    ("bytes", b"first"),
    ("json", second_metadata),
    ("bytes", b"second"),
]
```

Add `test_failed_binary_viewer_does_not_block_healthy_pair_or_raise` and `test_stalled_viewer_pair_times_out_as_one_operation`. Assert the healthy viewer gets both frames, the failed/stalled viewer is removed, and `deliver_audio_pair` returns normally.

- [ ] **Step 3: Run Task 1 tests and verify RED**

Run from `services/api`:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_session_hub.py -q
```

Expected: failures identify absent `send_bytes`, TTS snapshot methods, `ViewerDeliverySnapshot`, and audio-pair delivery. Existing JSON tests must remain green.

- [ ] **Step 4: Implement the minimal Hub contracts**

Add:

```python
class JsonWebSocket(Protocol):
    async def send_json(self, event: dict[str, object]) -> None: ...
    async def send_bytes(self, data: bytes) -> None: ...


@dataclass(frozen=True, slots=True)
class ViewerDeliverySnapshot:
    session_id: str
    _targets: tuple[tuple[JsonWebSocket, asyncio.Lock], ...]
```

Initialize `_tts_configs` parallel to `_translation_configs`. Implement `set_tts_config` and `publish_tts_config` with the same producer-identity guard and defensive event copy used by Translation. Change `join_viewer` to capture zero, one, or two configs and send Translation before TTS under the viewer's send lock. Change `release_producer` to remove both config maps.

Implement:

```python
async def snapshot_viewers(self, session_id: str) -> ViewerDeliverySnapshot:
    async with self._session_guard(session_id):
        async with self._membership_lock:
            return ViewerDeliverySnapshot(
                session_id,
                self._viewer_targets(session_id),
            )

async def deliver_audio_pair(self, snapshot, metadata, audio_bytes):
    async def send_pair(viewer, send_lock):
        async with send_lock:
            await viewer.send_json(metadata)
            await viewer.send_bytes(audio_bytes)

    # Run one wait_for(send_pair(...), viewer_send_timeout_seconds)
    # per captured target, gather all results, and remove failed targets.
```

On cancellation, cancel and await every created pair task, conservatively remove unfinished snapshot viewers under shielded membership cleanup, then re-raise `CancelledError`. Do not leave pair tasks detached. Do not recapture membership during delivery.

- [ ] **Step 5: Verify GREEN and review Task 1**

Run the Task 1 command twice, with any refactor between runs. Require exit 0. Then run:

```powershell
git -C 'D:\AI_Live_Translator_RealSTT' diff --check -- services/api/app/realtime/session_hub.py services/api/tests/test_session_hub.py
git -C 'D:\AI_Live_Translator_RealSTT' diff -- services/api/app/realtime/session_hub.py services/api/tests/test_session_hub.py
```

Confirm existing JSON behavior remains, each viewer lock spans both frames, snapshot membership is fixed, all child tasks are awaited, and only failed viewers are removed during ordinary completion.

---

### Task 2: SessionEventPublisher atomic producer pair and TTS config publication

**Files:**

- Modify: `services/api/app/realtime/session_event_publisher.py`
- Modify: `services/api/tests/test_session_event_publisher.py`

**Interfaces:**

- Consumes Task 1 `snapshot_viewers`, `deliver_audio_pair`, and `publish_tts_config`.
- Produces `publish_audio_pair(metadata, audio_bytes)`, `publish_tts_config(event, producer_identity=...)`, read-only `producer_delivery_failed`, and `wait_for_producer_delivery_failure()`.
- Preserves the one existing `_send_lock` as the only producer send serialization mechanism.

- [ ] **Step 1: Write RED producer pair tests**

Extend `RecordingSocket` to record JSON and binary frames. Add:

- `test_audio_pair_sends_metadata_then_binary_to_producer_and_viewer`: assert exact frame equality on both sockets.
- `test_concurrent_json_waits_until_audio_pair_binary_completes`: gate producer `send_bytes`, concurrently call `publisher.publish(marker)`, assert marker waits, then assert metadata, bytes, marker order and `maximum_active_sends == 1`.
- `test_two_audio_pairs_cannot_cross`: start two pair publications and assert metadata1, bytes1, metadata2, bytes2.
- `test_audio_pair_captures_viewers_before_producer_send`: join an existing viewer, block producer metadata send after it starts, join a late viewer, release producer, and assert only the existing viewer receives the pair.
- `test_failed_producer_binary_send_is_surfaced_and_deactivates_publisher`: make `send_json` succeed and `send_bytes` raise; assert the exception, `producer_delivery_failed is True`, and a later `publish(marker)` sends nothing.
- `test_failed_producer_send_wakes_failure_waiter_once`: start `wait_for_producer_delivery_failure`, fail a producer JSON send, and assert the waiter completes, the publisher deactivates, and repeated close/failure observation is idempotent.
- `test_failed_viewer_pair_does_not_fail_producer_or_healthy_viewer`: assert the publisher returns normally and the Hub removes only the failed viewer.

- [ ] **Step 2: Write RED TTS config publisher test**

Add `test_tts_config_is_atomically_sent_and_snapshotted`. Claim a producer, join an existing viewer, call `publish_tts_config`, join a late viewer, and assert producer/current/late each receive the exact event once.

- [ ] **Step 3: Run Task 2 tests and verify RED**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_session_event_publisher.py -q
```

Expected: only new pair/config/property tests fail because the methods do not exist.

- [ ] **Step 4: Implement publisher pair serialization**

Initialize `_producer_delivery_failed = False` plus one `asyncio.Event`. Route producer exceptions from `publish`, both configuration methods, and `publish_audio_pair` through one `_mark_producer_delivery_failed()` helper that sets the property, sets the event, and deactivates the publisher before re-raising. Add:

```python
@property
def producer_delivery_failed(self) -> bool:
    return self._producer_delivery_failed

async def wait_for_producer_delivery_failure(self) -> None:
    await self._producer_delivery_failure_event.wait()

async def publish_audio_pair(self, metadata, audio_bytes):
    async with self._send_lock:
        if not self._active:
            return
        snapshot = None
        if self._session_hub is not None and self._session_id is not None:
            snapshot = await self._session_hub.snapshot_viewers(
                self._session_id
            )
        try:
            await self._producer.send_json(metadata)
            await self._producer.send_bytes(audio_bytes)
        except BaseException:
            self._mark_producer_delivery_failed()
            raise
        if snapshot is not None:
            await self._session_hub.deliver_audio_pair(
                snapshot,
                metadata,
                audio_bytes,
            )
```

Do not check `_active` between the metadata and binary sends. Once metadata begins successfully, the pair owns the producer lock through the binary attempt. Snapshot before producer send so a viewer joining during producer delivery receives neither old frame.

Add `publish_tts_config` mirroring `publish_translation_config` but calling `SessionHub.publish_tts_config` and raising `RuntimeError("TTS configuration producer is not active")` when the producer identity is stale.

- [ ] **Step 5: Verify GREEN and review Task 2**

Run the Task 2 command twice and require exit 0. Inspect the scoped diff and verify no new direct socket writer was added outside `SessionEventPublisher`, all publisher methods share `_send_lock`, every producer failure wakes the one failure event, and Hub viewer failures do not set `producer_delivery_failed`.

---

### Task 3: Isolated `translation.final` to TtsSession bridge

**Files:**

- Create: `services/api/app/realtime/tts_orchestration.py`
- Create: `services/api/tests/test_tts_orchestration.py`

**Interfaces:**

- Consumes `TtsSession`, `TranslationEventPublisher`, `TargetLanguage`, and `tts_session_error_event`.
- Produces `TranslationFinalTtsBridge.publish(event)` as a valid `TranslationEventPublisher` callback for Task 4.
- Does not modify or subclass `TranslationSession`.

- [ ] **Step 1: Write RED trigger and ordering tests**

Create a recording TTS-session stub with async `submit` and `abort`. Add:

- `test_bridge_publishes_translation_final_before_exact_tts_submission`: append `("publish", event)` in the base publisher and `("submit", kwargs)` in the stub; assert publish occurs first and submitted fields exactly equal the normalized final's `stream_id`, `utterance_id`, `source_segment_ids`, `translated_text`, and `target_language`.
- Parametrize `test_bridge_does_not_submit_non_final_translation_events` over `translation.pending` and utterance-scoped `translation.error`; assert events are published but submissions stay empty.
- `test_one_final_event_causes_one_submit`: publish one final and assert one call. Do not add text matching or another identity.
- `test_base_publication_failure_prevents_tts_submission`: make base publication raise and assert the exception propagates while submission count remains zero.

- [ ] **Step 2: Write RED bridge-fault isolation tests**

Add `test_unexpected_submit_failure_aborts_tts_emits_one_safe_session_error_and_keeps_translation_publisher_usable`. Make the first submit raise `RuntimeError("secret")`; assert:

```python
assert tts.abort_calls == 1
assert published[-1]["type"] == "tts.error"
assert published[-1]["scope"] == "session"
assert published[-1]["code"] == "internal_error"
assert "secret" not in published[-1]["message"]
```

Publish a second final and assert it is forwarded as Translation but causes neither another submit nor another TTS error. Add a second case where the safe-error publisher also raises; assert `bridge.publish` still returns after forwarding the Translation final and raw exception text is absent from captured logs. Add a cancellation case asserting `CancelledError` propagates and no session error is fabricated.

- [ ] **Step 3: Run Task 3 tests and verify RED**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_orchestration.py -q
```

Expected: collection fails because `tts_orchestration.py` and `TranslationFinalTtsBridge` do not exist.

- [ ] **Step 4: Implement the bridge**

Implement the exact constructor and method from the spec. The central branch is:

```python
async def publish(self, event: dict[str, object]) -> None:
    await self._publish_event(event)
    if not self._active or event.get("type") != "translation.final":
        return
    try:
        await self._tts_session.submit(
            stream_id=_required_str(event, "stream_id"),
            utterance_id=_required_str(event, "utterance_id"),
            source_segment_ids=_required_string_sequence(
                event, "source_segment_ids"
            ),
            translated_text=_required_str(event, "translated_text"),
            target_language=_required_target(event, self._target_language),
        )
    except asyncio.CancelledError:
        raise
    except Exception as exc:
        await self._disable_tts(type(exc).__name__)
```

`_disable_tts` flips `_active` before awaiting, aborts once, logs only the exception class, and attempts exactly one fixed session-scoped `internal_error` message. It catches non-cancellation abort/publication failures. The bridge owns no task and never calls the synthesizer.

- [ ] **Step 5: Verify GREEN and review Task 3**

Run the Task 3 command twice and require exit 0. Run scoped `git diff --check` and verify the only trigger literal is `translation.final`, the original event publishes first, and no exception message enters an event or log.

---

### Task 4: `/ws/stt` startup construction and unavailable-provider degradation

**Files:**

- Modify: `services/api/app/realtime/stt_socket.py`
- Create: `services/api/tests/test_stt_tts_integration.py`

**Interfaces:**

- Consumes Tasks 2–3 publisher/bridge APIs and P3.0A `SpeechSynthesizerFactory`, `SpeechSynthesizer`, `TtsSession`, and TTS event builders.
- Produces FastAPI dependency `get_session_speech_synthesizer_factory() -> SpeechSynthesizerFactory | None` returning `None` by default.
- Adds `_TTS_QUEUE_MAX_SIZE = 8`, `_TTS_REQUEST_TIMEOUT_SECONDS = 10.0`, and `_TTS_DRAIN_TIMEOUT_SECONDS = 5.0` as locked runtime integration constants.
- Extends internal stream functions with optional TTS session/startup inputs without changing the public WebSocket path.

- [ ] **Step 1: Write RED disabled/backward-compatibility tests**

Create a fixture overriding `get_session_hub`, `get_stt_provider_factory`, `get_session_translator_factory`, and the new synthesizer dependency. Its teardown calls `app.dependency_overrides.clear()`.

Add:

- `test_stt_only_with_tts_omitted_never_constructs_synthesizer`.
- `test_stt_only_with_tts_disabled_never_constructs_synthesizer`.
- `test_translation_only_with_tts_omitted_preserves_existing_events`.
- `test_translation_with_tts_disabled_preserves_existing_events`.

Use a forbidden synthesizer factory that increments and raises. Assert count zero, existing ready/transcript/Translation ordering, and normal `stt.closed`.

- [ ] **Step 2: Write RED enabled startup and provider-unavailable tests**

Define:

```python
def tts_start(*, session_id=None, voice=None):
    payload = {
        **VALID_START,
        "translation": {"target_language": "en"},
        "tts": {"enabled": True},
    }
    if voice is not None:
        payload["tts"]["voice"] = voice
    if session_id is not None:
        payload["session_id"] = session_id
    return payload
```

Add `test_tts_available_start_orders_ready_translation_and_tts_configuration`. Override with one `FakeSpeechSynthesizer`, assert factory count one, exact config fields including optional voice, and normal stop.

Add `test_tts_unavailable_emits_one_session_error_and_translation_continues`. Use the default `None` dependency, generate two committed translations, stop cleanly, and assert the full sequence contains one `tts.configured`, exactly one session-scoped `tts.error(provider_unavailable)`, two `translation.final`, zero utterance TTS events, and `stt.closed`.

Add `test_translation_unavailable_skips_tts_construction_and_tts_events`. Make Translation construction raise, assert the synthesizer factory count is zero, the existing Translation session error is emitted, and no TTS event appears.

- [ ] **Step 3: Run Task 4 tests and verify RED**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_stt_tts_integration.py -q
```

Expected: collection fails for the missing dependency and then enabled cases fail because the endpoint does not construct or configure TTS. Disabled cases should become green without TTS runtime behavior.

- [ ] **Step 4: Implement startup construction and event publication**

Add the dependency and constants. During endpoint setup:

1. Preserve existing Translation construction.
2. Only after Translation construction succeeds, inspect `start.tts`.
3. For enabled TTS, always create `tts.configured` from `stream_id`, Translation target, and optional voice.
4. If the factory is absent or construction raises, append one fixed session-scoped `provider_unavailable` event and leave `tts_session=None`.
5. If construction succeeds and conforms to `SpeechSynthesizer`, construct one `TtsSession` using the locked queue/request constants and `publisher.publish` plus `publisher.publish_audio_pair`.
6. Wrap the Translation publisher with `TranslationFinalTtsBridge` only when that session exists.

Generalize startup publication with one `_publish_startup_event` helper that dispatches `translation.configured` and `tts.configured` through their dedicated snapshot methods and all error events through ordinary `publish`. Preserve direct `_run_stream` fallback behavior used by existing unit tests.

Emit startup in ready, Translation, TTS-config, TTS-error order. Start `TtsSession` before `TranslationSession`, before creating the first provider-event task.

- [ ] **Step 5: Verify GREEN and run existing startup regressions**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_stt_tts_integration.py tests/test_stt_translation_integration.py tests/test_stt_websocket.py -q
```

Require zero failures. Inspect the scoped diff and confirm no factory call occurs for omitted/disabled TTS, no provider/vendor import exists, and unavailable TTS is reported only at startup.

---

### Task 5: Successful realtime fan-out and isolated utterance failures

**Files:**

- Modify: `services/api/tests/test_stt_tts_integration.py`
- Modify: `services/api/app/realtime/stt_socket.py` only when a failing integration assertion identifies missing wiring.

**Interfaces:**

- Uses one real in-process `TtsSession` and `FakeSpeechSynthesizer`; no provider or socket mock bypasses the integration path.
- Proves producer and viewer frames originate from one synthesis result.

- [ ] **Step 1: Write RED one-synthesis-many-viewers success test**

Create one STT final with `utterance_boundary=True`, a `FakeTranslator(outcomes=("Hello.",))`, and `FakeSpeechSynthesizer(outcomes=(SynthesizedAudio(b"speech", "audio/wav", 16000),))`. Connect two viewers and one producer to `demo-001`.

Assert each socket receives:

```text
translation.configured
tts.configured
transcript.final
translation.pending
translation.final
tts.pending
tts.audio JSON
binary b"speech"
```

Assert both viewers' metadata equals the producer metadata, all bytes equal `b"speech"`, metadata has no raw bytes/Base64, and `len(synthesizer.calls) == 1` with text `Hello.`, language `en`, and the configured voice.

- [ ] **Step 2: Write RED trigger exclusion and failure-isolation tests**

Add:

- `test_translation_pending_does_not_start_tts`: block the translator, receive `translation.pending`, assert zero synthesis calls, release it, then assert final triggers one call.
- `test_translation_error_never_starts_tts`: make the first Translation fail and the second succeed; assert zero synthesis for the failed utterance and one for the later final.
- `test_tts_provider_failure_emits_safe_error_and_later_utterance_succeeds`: use `TtsProviderError("secret")` then valid audio; assert first final -> pending -> safe error, second final -> pending -> metadata/binary, Translation remains valid, and secret text is absent.
- `test_tts_queue_overflow_emits_no_pending_and_stt_translation_continue`: monkeypatch `_TTS_QUEUE_MAX_SIZE=1`, gate the first synthesis, fill the one waiting slot, overflow a third unique identity, and assert one `queue_overflow`, no `tts.pending` or provider call for that identity, a later transcript/Translation event still arrives, and fresh TTS can continue after capacity returns.

- [ ] **Step 3: Run Task 5 tests and verify RED**

Run named Task 5 tests with:

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_stt_tts_integration.py -q
```

Expected: success/failure ordering or fan-out assertions fail until the bridge and pair callbacks are connected through every production path. A failure caused by incorrect test frame reads must be corrected in the test before production changes.

- [ ] **Step 4: Apply minimal wiring corrections**

Keep fixes inside `stt_socket.py` and the already-created orchestration/publisher/hub contracts. Do not change P3.0A `TtsSession`. Ensure the same synthesized bytes are passed once to `publish_audio_pair`; never loop viewers around synthesis and never synthesize in Hub/Publisher.

- [ ] **Step 5: Verify GREEN and review Task 5**

Run the full integration file twice and require exit 0. Review call counts, exact frame types, queue-overflow absence of pending, safe messages, and continuation after each utterance-scoped failure.

---

### Task 6: Clean Stop Translation-to-TTS drain and producer-pair failure

**Files:**

- Modify: `services/api/app/realtime/stt_socket.py`
- Modify: `services/api/tests/test_stt_tts_integration.py`

**Interfaces:**

- Uses existing Translation drain constant 5.0 seconds.
- Uses `_TTS_DRAIN_TIMEOUT_SECONDS = 5.0` once after Translation drain.
- Consumes `SessionEventPublisher.wait_for_producer_delivery_failure()` during active streaming and `producer_delivery_failed` after synchronous drain to prevent any frame after a truncated producer pair.

- [ ] **Step 1: Write RED clean-tail ordering test**

Use a final STT transcript without an utterance boundary so Translation retains it until clean Stop. Send `stt.stop`, then assert shutdown frames in exact order:

```text
translation.pending
translation.final
tts.pending
tts.audio metadata
binary payload
stt.closed
```

Assert the fake translator and synthesizer each have one call. This test proves TTS acceptance remains open until Translation drain has submitted the final utterance.

- [ ] **Step 2: Write RED bounded TTS-drain test**

Monkeypatch `_TTS_DRAIN_TIMEOUT_SECONDS=0.01`, block synthesis with an `asyncio.Event`, and wrap the client stop interaction in the existing TestClient lifecycle. Assert `stt.closed` arrives without audio, `cancelled_calls == 1`, `active_calls == 0`, and no `tts-*` owned task remains after endpoint cleanup. The test must not replace the 10.0-second request timeout; it proves the shorter total Stop deadline wins.

- [ ] **Step 3: Write RED producer pair-failure lifecycle test**

At the direct endpoint level, use a producer whose `send_json(tts.audio)` succeeds and whose next `send_bytes` raises while producer receive remains blocked. Assert the publisher failure waiter wakes without requiring a client receive-disconnect message, `producer_delivery_failed` becomes true, the endpoint aborts/settles TTS, closes/releases the producer, and does not send `stt.closed` or any other JSON after the orphaned metadata. This is a transport failure, not a `tts.error` provider event.

Add `test_failed_tts_startup_send_is_disconnect_without_terminal_write`. Fail the producer's awaited `tts.configured` send and assert the outer endpoint exception boundary observes `producer_delivery_failed`, selects `client_disconnect`, and does not call the direct terminal-error writer on the unusable socket.

- [ ] **Step 4: Run Task 6 tests and verify RED**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_stt_tts_integration.py -q
```

Expected: clean Stop closes before TTS drain or lacks the TTS drain, and the producer-pair failure path attempts a later frame until lifecycle wiring is added.

- [ ] **Step 5: Implement exact drain and failed-writer behavior**

When realtime processing begins, create one named task awaiting `publisher.wait_for_producer_delivery_failure()` and include it in both the active-input and STT-finish wait sets. If it completes, cancel current STT input/event work and return `client_disconnect`; endpoint cleanup then aborts Translation followed by TTS. Track and settle this waiter in the existing owned-task collection.

At each outer exception boundary, check `publisher.producer_delivery_failed` before `_send_terminal_error`. When true, set `close_reason="client_disconnect"`, skip terminal JSON, and proceed directly to no-drain cleanup. This covers failures from awaited startup/config publication before the failure waiter exists.

After STT finish/event drain:

```python
if translation_session is not None:
    await translation_session.flush_and_drain(
        timeout_seconds=_TRANSLATION_DRAIN_TIMEOUT_SECONDS,
    )
if tts_session is not None:
    await tts_session.flush_and_drain(
        timeout_seconds=_TTS_DRAIN_TIMEOUT_SECONDS,
    )
if publisher is not None and publisher.producer_delivery_failed:
    return "client_disconnect"
state.mark_closed()
await websocket.send_json(closed_event())
```

Pass `tts_session` through `_run_stream`/`_run_stream_owned`. Do not call its drain earlier and do not reset the deadline per utterance. In final cleanup, close Translation then TTS for `client_stop`; abort Translation then TTS for every other reason; close the publisher only after both have settled.

- [ ] **Step 6: Verify GREEN and review Task 6**

Run Task 6 tests plus existing Translation clean-stop and STT stop tests. Require exit 0 and confirm normal provider/queue/timeout errors still lead to `stt.closed`, while only a failed producer writer suppresses later application frames.

---

### Task 7: Unexpected disconnect, late viewer, and producer-release hardening

**Files:**

- Modify: `services/api/tests/test_stt_tts_integration.py`
- Modify: `services/api/app/realtime/stt_socket.py` only for observed cleanup gaps.
- Modify: `services/api/tests/test_session_hub.py` only for observed snapshot-release gaps.

**Interfaces:**

- Preserves current producer-identity release in the outer `finally` block.
- Requires abort order Translation then TTS and no TTS drain on disconnect.
- Requires late-viewer snapshot order Translation then TTS with no history.

- [ ] **Step 1: Write RED unexpected-disconnect abort test**

Start one synthesis behind a gate, receive `tts.pending` on producer/viewer, then close the producer without `stt.stop`. Assert:

```python
assert synthesizer.cancelled_calls == 1
assert synthesizer.active_calls == 0
assert translator.active_calls == 0
assert replacement_producer_claim_succeeds is True
```

Broadcast a marker to the still-connected viewer and assert it receives the marker directly, with no late `tts.audio` metadata or binary frame. Inspect `asyncio.all_tasks()` in the direct async form and assert no live task named with `translation-` or `tts-` remains.

- [ ] **Step 2: Write RED late-viewer and snapshot-clear tests**

Add `test_late_viewer_gets_translation_and_tts_configs_but_no_old_audio`: complete one audio result before the late viewer joins, then join it, assert it receives exactly Translation config followed by TTS config, broadcast a marker, and assert the next frame is that marker rather than old metadata/binary.

Add `test_producer_release_clears_tts_config_before_next_stt_only_producer`: stop the TTS producer, start a new STT-only producer under the same session ID, join a viewer, broadcast a marker, and assert the viewer receives only the marker.

Add `test_viewer_joining_after_audio_snapshot_receives_neither_old_half` at publisher/Hub level if Task 2 does not already cover the precise race. Gate producer metadata, join late, release, and assert neither metadata nor bytes reached late.

- [ ] **Step 3: Run Task 7 tests and verify RED**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_stt_tts_integration.py tests/test_session_hub.py tests/test_session_event_publisher.py -q
```

Expected: any missing abort, release, snapshot-clear, or fixed-membership behavior fails at its direct assertion; no timing sleep is used where an event gate can establish the race.

- [ ] **Step 4: Apply minimal cleanup hardening**

Centralize endpoint downstream cleanup in an async helper that always aborts Translation before TTS and closes the publisher last. Keep producer release in the existing outer `finally`. Do not drain on `client_disconnect`, protocol error, STT provider failure, or internal error. Preserve `SessionHub.release_producer` identity checks and clear both config maps only for the active owner.

- [ ] **Step 5: Verify GREEN and review Task 7**

Run the Task 7 command twice. Require exit 0, no live named task, no post-disconnect TTS result, no stale config, no old audio replay, and unchanged viewer receive-only behavior.

---

### Task 8: Focused, P3.0A, Translation, and full Backend verification

**Files:**

- Verify only; no planned changes.

**Interfaces:**

- Produces fresh evidence for implementation handoff and weekly internship reporting.

- [ ] **Step 1: Run the focused P3.0B suite**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_session_hub.py tests/test_session_event_publisher.py tests/test_tts_orchestration.py tests/test_stt_tts_integration.py tests/test_session_viewer.py tests/test_stt_websocket.py -q
```

Record exact passed/failed counts and warnings.

- [ ] **Step 2: Re-run the complete P3.0A contract suite**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_tts_provider.py tests/test_tts_protocol.py tests/test_tts_session.py tests/test_stt_protocol.py -q
```

Require exit 0. This proves integration did not redesign the provider-neutral result, event schemas, deduplication, queue, timeout, or lifecycle.

- [ ] **Step 3: Run Translation boundary regression**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest tests/test_translation_provider.py tests/test_translation_protocol.py tests/test_translation_session.py tests/test_stt_translation_integration.py -q
```

Require exit 0 and unchanged STT-only/Translation-only behavior.

- [ ] **Step 4: Run full Backend regression**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m pytest -q
```

Require zero failures/errors. No live provider dependency may be invoked.

- [ ] **Step 5: Compile all Backend production and test Python**

```powershell
& 'D:\AI_Live_Translator_RealSTT\services\api\.venv\Scripts\python.exe' -m compileall -q app tests
```

Require exit 0.

- [ ] **Step 6: Scan security, transport, and scope invariants**

```powershell
rg -n -i "T[B]D|T[O]DO|implement l[a]ter|similar t[o]|appropriate handl[i]ng" services/api/app/realtime/tts_orchestration.py services/api/app/realtime/session_event_publisher.py services/api/app/realtime/session_hub.py services/api/app/realtime/stt_socket.py services/api/tests/test_tts_orchestration.py services/api/tests/test_stt_tts_integration.py
rg -n "base64|data:audio|Authorization|api[_-]?key|CLOUDFLARE|GOOGLE|AZURE|ELEVEN" services/api/app/realtime/tts_orchestration.py services/api/app/realtime/session_event_publisher.py services/api/app/realtime/session_hub.py
```

Expected: no placeholder, Base64/data URL, credential, or vendor integration match. Test fixture strings used only to prove sanitization may be reported separately and must never contain a real secret.

- [ ] **Step 7: Run whitespace and exact-scope checks**

```powershell
git -C 'D:\AI_Live_Translator_RealSTT' diff --check
git -C 'D:\AI_Live_Translator_RealSTT' status --short
git -C 'D:\AI_Live_Translator_RealSTT' diff -- services/api/app/realtime/translation_session.py services/api/app/realtime/tts_session.py services/api/app/ai/tts.py services/api/app/realtime/tts_protocol.py services/api/app/realtime/session_viewer.py apps/web apps/mobile
```

Require `git diff --check` exit 0. Compare status to the captured pre-task baseline. P3.0B must introduce changes only in the eight File Map paths; pre-existing approved dirty work remains untouched. The exclusion diff may show pre-existing work, so compare content and status against the baseline rather than treating existing entries as P3.0B changes.

- [ ] **Step 8: Preserve final reporting evidence and stop**

Record:

- files created/modified;
- RED failure and GREEN result per task;
- focused/P3.0A/Translation/full Backend counts;
- exact producer/viewer frame order;
- one synthesizer call with multiple viewer deliveries;
- fixed viewer-snapshot race result;
- failed-viewer and failed-producer behavior;
- single provider-unavailable error result;
- clean Stop tail order and five-second total-drain evidence;
- unexpected-disconnect cancellation and no-task-leak evidence;
- compileall and diff-check results;
- review-recommended architecture decisions; and
- actual blockers/resources, if any.

Do not create the weekly report, start P3.0C/P3.1, stage, commit, push, or merge.

## Requirement-to-task traceability

| Requirement | Plan coverage |
|---|---|
| TTS disabled and Translation-only compatibility | Task 4 disabled/omitted factory and event-order tests; Task 8 regressions. |
| Only `translation.final` triggers TTS | Task 3 unit tests and Task 5 pending/error integration tests. |
| One final produces one synthesis independent of N viewers | Task 3 one-submit test; Task 5 two-viewer call-count test. |
| Producer receives pending and metadata/binary | Tasks 2 and 5. |
| Metadata immediately followed by binary with no JSON interleave | Tasks 1–2 gated lock tests and consecutive-pair tests. |
| `audio_id` associates the next binary payload | Tasks 1–2 exact frame assertions; Task 5 end-to-end metadata equality. |
| Viewer snapshot occurs at audio-broadcast start | Tasks 1–2 gated late-join race tests. |
| Failed viewer cannot block healthy recipients or TTS | Tasks 1–2 failure/timeout tests and Task 5 fan-out. |
| Active TTS config snapshot and deterministic late-viewer order | Tasks 1, 2, 4, and 7. |
| Producer release clears TTS snapshot | Tasks 1 and 7. |
| No historical transcript/Translation/TTS/audio replay | Task 7 config-then-marker test. |
| Unconfigured synthesizer emits one session error | Task 4 full-session sequence/count test. |
| Translation remains operational when TTS is unavailable | Task 4 two-final continuation test. |
| Queue overflow has no pending/provider call and remains isolated | Task 5 bounded-queue integration test plus P3.0A regression. |
| Provider/result failure isolation and safe messages | Task 5 controlled failure then success. |
| Translation drains before TTS stops accepting | Task 6 buffered-final clean-tail test. |
| Final TTS pair precedes `stt.closed` | Task 6 exact shutdown-frame test. |
| One total five-second TTS drain cannot block close indefinitely | Task 6 injected-short-deadline test and P3.0A lifecycle regression. |
| Failed producer pair promptly wakes stream cleanup and receives no later application frame | Tasks 2 and 6. |
| Unexpected disconnect aborts rather than drains | Task 7 gated cancellation/no-late-result test. |
| No owned task leak | Tasks 1, 6, and 7 task-set assertions. |
| No client/provider/persistence scope expansion | Global constraints and Task 8 exclusion/security scans. |

## P3.0B completion boundary

After Task 8, the Backend can accept an explicitly TTS-enabled translated STT session, synthesize each unique committed Translation at most once through an injected fake/provider-neutral implementation, and deliver ordered metadata/binary pairs to the producer and fixed current-viewer snapshots. Clean Stop and disconnect semantics are integrated and bounded.

No Web or Mobile client parses or plays the binary payload, no real synthesizer exists, and no vendor configuration is added. Those boundaries remain with P3.0C and P3.1.
