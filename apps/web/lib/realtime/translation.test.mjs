import assert from "node:assert/strict";
import test from "node:test";

import {
  APPROVED_TARGET_LANGUAGES,
  applyTranslationEvent,
  createTranslationState,
  deactivateTranslationConfiguration,
  getActiveTranslationConfiguration,
  parseTranslationEvent,
  translationUtteranceKey,
} from "./translation.ts";

const configured = {
  type: "translation.configured",
  stream_id: "stream_A",
  source_language: "vi",
  target_language: "en",
};

const pending = {
  type: "translation.pending",
  stream_id: "stream_A",
  utterance_id: "utt_000001",
  source_segment_ids: ["seg_001", "seg_002"],
  source_text: "Xin chào mọi người.",
  source_language: "vi",
  target_language: "en",
};

const final = {
  ...pending,
  type: "translation.final",
  translated_text: "Hello everyone.",
};

const utteranceError = {
  ...pending,
  type: "translation.error",
  scope: "utterance",
  code: "provider_error",
  message: "Translation is temporarily unavailable.",
};

const sessionError = {
  type: "translation.error",
  scope: "session",
  stream_id: "stream_A",
  source_language: "vi",
  target_language: "en",
  code: "provider_unavailable",
  message: "Translation is unavailable.",
};

test("parses every normalized Translation event shape", () => {
  assert.deepEqual(parseTranslationEvent(configured), configured);
  assert.deepEqual(parseTranslationEvent(pending), pending);
  assert.deepEqual(parseTranslationEvent(final), final);
  assert.deepEqual(parseTranslationEvent(utteranceError), utteranceError);
  assert.deepEqual(parseTranslationEvent(sessionError), sessionError);
});

test("rejects malformed Translation events and safely ignores unknown events", () => {
  const malformed = [
    null,
    [],
    { ...configured, stream_id: "" },
    { ...configured, target_language: "xx" },
    { ...pending, utterance_id: 1 },
    { ...pending, source_segment_ids: [] },
    { ...pending, source_segment_ids: ["seg_001", ""] },
    { ...final, translated_text: 42 },
    { ...final, translated_text: "" },
    { ...final, translated_text: "   " },
    { ...utteranceError, code: "raw_provider_exception" },
    { ...sessionError, message: null },
  ];

  for (const event of malformed) {
    assert.equal(parseTranslationEvent(event), null);
  }
  assert.equal(parseTranslationEvent({ type: "translation.future" }), null);
  assert.equal(parseTranslationEvent({ type: "stt.ready" }), null);
});

test("a malformed blank final cannot lock out a later valid final", () => {
  const pendingState = applyTranslationEvent(createTranslationState(), pending);
  assert.equal(
    parseTranslationEvent({ ...final, translated_text: "  " }),
    null,
  );

  const corrected = parseTranslationEvent(final);
  assert.notEqual(corrected, null);
  const finalState = applyTranslationEvent(pendingState, corrected);
  assert.equal(finalState.utterances[0].translatedText, "Hello everyone.");
});

test("the target-language domain contains exactly the eight approved choices", () => {
  assert.deepEqual(APPROVED_TARGET_LANGUAGES, [
    "en",
    "ja",
    "ko",
    "zh-CN",
    "th",
    "fr",
    "de",
    "es",
  ]);
});

test("pending creates one utterance and final updates it in place", () => {
  const pendingState = applyTranslationEvent(createTranslationState(), pending);
  const finalState = applyTranslationEvent(pendingState, final);

  assert.equal(pendingState.utterances.length, 1);
  assert.equal(pendingState.utterances[0].status, "pending");
  assert.equal(finalState.utterances.length, 1);
  assert.equal(finalState.utterances[0].status, "final");
  assert.equal(finalState.utterances[0].translatedText, "Hello everyone.");
  assert.deepEqual(finalState.utterances[0].sourceSegmentIds, [
    "seg_001",
    "seg_002",
  ]);
});

test("utterance error updates pending in place without hiding source metadata", () => {
  const state = applyTranslationEvent(
    applyTranslationEvent(createTranslationState(), pending),
    utteranceError,
  );

  assert.equal(state.utterances.length, 1);
  assert.equal(state.utterances[0].status, "failed");
  assert.equal(state.utterances[0].sourceText, pending.source_text);
  assert.equal(state.utterances[0].errorCode, "provider_error");
});

test("duplicate events are idempotent and stale pending or error cannot downgrade final", () => {
  const oncePending = applyTranslationEvent(createTranslationState(), pending);
  assert.strictEqual(applyTranslationEvent(oncePending, pending), oncePending);

  const onceFinal = applyTranslationEvent(oncePending, final);
  assert.strictEqual(applyTranslationEvent(onceFinal, final), onceFinal);
  assert.strictEqual(applyTranslationEvent(onceFinal, pending), onceFinal);
  assert.strictEqual(applyTranslationEvent(onceFinal, utteranceError), onceFinal);

  const onceFailed = applyTranslationEvent(oncePending, utteranceError);
  assert.strictEqual(
    applyTranslationEvent(onceFailed, utteranceError),
    onceFailed,
  );
  assert.strictEqual(applyTranslationEvent(onceFailed, pending), onceFailed);
});

test("same utterance ID in different streams remains distinct", () => {
  const state = applyTranslationEvent(
    applyTranslationEvent(createTranslationState(), pending),
    { ...pending, stream_id: "stream_B", source_text: "Stream B source." },
  );

  assert.equal(state.utterances.length, 2);
  assert.notEqual(
    translationUtteranceKey("stream_A", "utt_000001"),
    translationUtteranceKey("stream_B", "utt_000001"),
  );
});

test("configuration and session errors are idempotent", () => {
  const configuredOnce = applyTranslationEvent(createTranslationState(), configured);
  assert.strictEqual(
    applyTranslationEvent(configuredOnce, configured),
    configuredOnce,
  );
  assert.deepEqual(getActiveTranslationConfiguration(configuredOnce), {
    streamId: "stream_A",
    sourceLanguage: "vi",
    targetLanguage: "en",
  });

  const errorOnce = applyTranslationEvent(configuredOnce, sessionError);
  assert.strictEqual(applyTranslationEvent(errorOnce, sessionError), errorOnce);
  assert.equal(errorOnce.sessionErrors.length, 1);
});

test("closing a Host stream clears active configuration and warning but preserves utterances", () => {
  const active = applyTranslationEvent(
    applyTranslationEvent(
      applyTranslationEvent(createTranslationState(), configured),
      pending,
    ),
    sessionError,
  );
  const closed = deactivateTranslationConfiguration(active);

  assert.deepEqual(closed.configurations, []);
  assert.deepEqual(closed.sessionErrors, []);
  assert.deepEqual(closed.utterances, active.utterances);
});

test("a new source-only stream clears stale Translation activity without clearing history", () => {
  const active = applyTranslationEvent(
    applyTranslationEvent(
      applyTranslationEvent(createTranslationState(), configured),
      pending,
    ),
    sessionError,
  );

  assert.strictEqual(
    deactivateTranslationConfiguration(active, "stream_A"),
    active,
  );

  const nextStream = deactivateTranslationConfiguration(active, "stream_B");
  assert.deepEqual(nextStream.configurations, []);
  assert.deepEqual(nextStream.sessionErrors, []);
  assert.deepEqual(nextStream.utterances, active.utterances);
});

test("a new stream session error replaces stale configuration and remains active", () => {
  const streamA = applyTranslationEvent(createTranslationState(), configured);
  const streamBError = {
    ...sessionError,
    stream_id: "stream_B",
    target_language: "ja",
  };

  const streamB = applyTranslationEvent(streamA, streamBError);

  assert.deepEqual(streamB.configurations, []);
  assert.deepEqual(streamB.sessionErrors, [
    {
      streamId: "stream_B",
      sourceLanguage: "vi",
      targetLanguage: "ja",
      code: "provider_unavailable",
      message: "Translation is unavailable.",
    },
  ]);
});
