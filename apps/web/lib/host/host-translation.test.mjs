import assert from "node:assert/strict";
import test from "node:test";

import {
  HOST_SOURCE_LANGUAGE,
  HOST_TARGET_LANGUAGE_OPTIONS,
  createHostTranslationSelection,
  lockHostTranslationSelection,
  selectHostTargetLanguage,
  unlockHostTranslationSelection,
} from "./host-translation.ts";

test("Host source is read-only Vietnamese and target defaults to English", () => {
  assert.deepEqual(HOST_SOURCE_LANGUAGE, {
    code: "vi",
    label: "Vietnamese",
    readOnly: true,
  });
  assert.deepEqual(createHostTranslationSelection(), {
    targetLanguage: "en",
    locked: false,
  });
});

test("Host selector contains exactly the eight approved text/code choices", () => {
  assert.deepEqual(HOST_TARGET_LANGUAGE_OPTIONS, [
    { code: "en", label: "English" },
    { code: "ja", label: "Japanese" },
    { code: "ko", label: "Korean" },
    { code: "zh-CN", label: "Chinese (Simplified)" },
    { code: "th", label: "Thai" },
    { code: "fr", label: "French" },
    { code: "de", label: "German" },
    { code: "es", label: "Spanish" },
  ]);
  assert.equal(
    HOST_TARGET_LANGUAGE_OPTIONS.some(({ label }) => /[🇦-🇿]/u.test(label)),
    false,
  );
});

test("target changes before Start, locks for an active stream, and re-enables after closure", () => {
  const selected = selectHostTargetLanguage(
    createHostTranslationSelection(),
    "ja",
  );
  const locked = lockHostTranslationSelection(selected);

  assert.deepEqual(locked, { targetLanguage: "ja", locked: true });
  assert.strictEqual(selectHostTargetLanguage(locked, "fr"), locked);
  assert.deepEqual(unlockHostTranslationSelection(locked), {
    targetLanguage: "ja",
    locked: false,
  });
});

