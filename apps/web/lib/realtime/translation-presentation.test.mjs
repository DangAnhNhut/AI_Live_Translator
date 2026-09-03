import assert from "node:assert/strict";
import test from "node:test";

import {
  buildBilingualTranscriptBlockView,
  buildTranslationPresentation,
  getLanguageLabel,
  getTranslationSessionWarning,
  getTranslationDisplayText,
  shouldUseBilingualPresentation,
} from "./translation-presentation.ts";
import { createTranslationState } from "./translation.ts";

const segments = [
  {
    id: "seg_001",
    streamId: "stream_A",
    text: "Committed source.",
    language: "vi",
    kind: "final",
  },
  {
    id: "seg_002",
    streamId: "stream_A",
    text: "Uncommitted source.",
    language: "vi",
    kind: "final",
  },
  {
    id: "seg_003",
    streamId: "stream_A",
    text: "Listening now",
    language: "vi",
    kind: "interim",
  },
];

const pending = {
  streamId: "stream_A",
  utteranceId: "utt_000001",
  sourceSegmentIds: ["seg_001"],
  sourceText: "Committed source.",
  sourceLanguage: "vi",
  targetLanguage: "en",
  status: "pending",
};

test("pending, final, and failed states expose canonical bilingual copy", () => {
  assert.deepEqual(buildBilingualTranscriptBlockView(pending), {
    sourceLabel: "ORIGINAL · VI",
    sourceText: "Committed source.",
    translationLabel: "TRANSLATION · EN",
    translationText: "Translating...",
    status: "pending",
    secondaryHint: null,
  });
  assert.deepEqual(
    buildBilingualTranscriptBlockView({
      ...pending,
      status: "final",
      translatedText: "Translated source.",
    }),
    {
      sourceLabel: "ORIGINAL · VI",
      sourceText: "Committed source.",
      translationLabel: "TRANSLATION · EN",
      translationText: "Translated source.",
      status: "final",
      secondaryHint: null,
    },
  );
  assert.deepEqual(
    buildBilingualTranscriptBlockView({
      ...pending,
      status: "failed",
      errorCode: "queue_overflow",
      errorMessage: "safe backend copy",
    }),
    {
      sourceLabel: "ORIGINAL · VI",
      sourceText: "Committed source.",
      translationLabel: "TRANSLATION · EN",
      translationText: "Translation unavailable",
      status: "failed",
      secondaryHint: "Original transcript is still available.",
    },
  );
  assert.equal(getTranslationDisplayText(pending), "Translating...");
});

test("claimed finals leave Live Speech while uncommitted final and interim remain", () => {
  const view = buildTranslationPresentation(segments, [pending]);

  assert.deepEqual(view.utterances, [pending]);
  assert.deepEqual(
    view.liveSegments.map((segment) => segment.id),
    ["seg_002", "seg_003"],
  );
  assert.equal(
    view.liveSegments.some((segment) => segment.text === pending.sourceText),
    false,
  );
});

test("segment claims are stream-scoped rather than text-matched", () => {
  const streamBCopy = {
    ...segments[0],
    streamId: "stream_B",
    text: "Committed source.",
  };
  const view = buildTranslationPresentation(
    [segments[0], streamBCopy],
    [pending],
  );

  assert.deepEqual(view.liveSegments, [streamBCopy]);
});

test("configured language pair labels are text-only and locale-aware", () => {
  assert.equal(getLanguageLabel("vi"), "Vietnamese");
  assert.equal(getLanguageLabel("en"), "English");
  assert.equal(getLanguageLabel("zh-CN"), "Chinese (Simplified)");
  assert.equal(`${getLanguageLabel("vi")} → ${getLanguageLabel("ja")}`, "Vietnamese → Japanese");
});

test("session-scoped failure shows one restrained warning while original speech remains", () => {
  const errors = [
    {
      streamId: "stream_A",
      sourceLanguage: "vi",
      targetLanguage: "en",
      code: "provider_unavailable",
      message: "Backend-safe detail.",
    },
  ];
  const view = buildTranslationPresentation(segments, []);

  assert.equal(
    getTranslationSessionWarning(errors, null),
    "Translation is unavailable. Original transcript will continue.",
  );
  assert.deepEqual(view.liveSegments, segments);
});

test("a healthy active stream is not warned by a retained prior-stream failure", () => {
  const priorErrors = [
    {
      streamId: "stream_A",
      sourceLanguage: "vi",
      targetLanguage: "en",
      code: "provider_unavailable",
      message: "Unavailable for stream A.",
    },
  ];

  assert.equal(getTranslationSessionWarning(priorErrors, "stream_A"),
    "Translation is unavailable. Original transcript will continue.");
  assert.equal(getTranslationSessionWarning(priorErrors, "stream_B"), null);
});

test("STT-only stays on source presentation until Translation is requested or observed", () => {
  const empty = createTranslationState();
  assert.equal(shouldUseBilingualPresentation(false, empty), false);
  assert.equal(shouldUseBilingualPresentation(true, empty), true);
  assert.equal(
    shouldUseBilingualPresentation(false, {
      ...empty,
      utterances: [pending],
    }),
    true,
  );
});
