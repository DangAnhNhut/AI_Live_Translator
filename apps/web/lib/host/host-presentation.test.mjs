import assert from "node:assert/strict";
import test from "node:test";

import {
  buildHostReadyConfig,
  buildHostSplitBilingualRow,
  formatPresentationTimer,
  getHostHeaderBreadcrumb,
  getHostSupportedActions,
  shouldShowLiveWorkspace,
  shouldShowReadyCanvas,
} from "./host-presentation.ts";

const samplePendingUtterance = {
  streamId: "stream_live_01",
  utteranceId: "utt_101",
  sourceSegmentIds: ["seg_01"],
  sourceText: "Xin chào quý vị khán giả đang theo dõi.",
  sourceLanguage: "vi",
  targetLanguage: "en",
  status: "pending",
};

const sampleFinalUtterance = {
  streamId: "stream_live_01",
  utteranceId: "utt_101",
  sourceSegmentIds: ["seg_01"],
  sourceText: "Xin chào quý vị khán giả đang theo dõi.",
  sourceLanguage: "vi",
  targetLanguage: "en",
  translatedText: "Welcome to all viewers watching.",
  status: "final",
};

const sampleFailedUtterance = {
  streamId: "stream_live_01",
  utteranceId: "utt_102",
  sourceSegmentIds: ["seg_02"],
  sourceText: "Đường truyền mạng gặp sự cố.",
  sourceLanguage: "vi",
  targetLanguage: "ja",
  status: "failed",
  errorCode: "provider_error",
  errorMessage: "Service temporarily unavailable",
};

test("1. split bilingual row structure divides source VI and translation target columns", () => {
  const row = buildHostSplitBilingualRow(sampleFinalUtterance);

  assert.equal(typeof row.sourceColumn, "object");
  assert.equal(typeof row.translationColumn, "object");
  assert.equal(row.sourceColumn.label, "ORIGINAL · VI");
  assert.equal(row.translationColumn.label, "TRANSLATION · EN");
  assert.equal(row.sourceColumn.language, "vi");
  assert.equal(row.translationColumn.language, "en");
});

test("2. same utterance keeps source and translation aligned by utterance identity", () => {
  const row = buildHostSplitBilingualRow(sampleFinalUtterance);

  assert.equal(row.utteranceId, "utt_101");
  assert.equal(row.sourceColumn.text, "Xin chào quý vị khán giả đang theo dõi.");
  assert.equal(row.translationColumn.text, "Welcome to all viewers watching.");
  assert.equal(row.translationColumn.status, "final");
  assert.equal(row.translationColumn.hint, null);
});

test("3. pending translation presents source with Translating... placeholder", () => {
  const row = buildHostSplitBilingualRow(samplePendingUtterance);

  assert.equal(row.utteranceId, "utt_101");
  assert.equal(row.sourceColumn.text, "Xin chào quý vị khán giả đang theo dõi.");
  assert.equal(row.translationColumn.text, "Translating...");
  assert.equal(row.translationColumn.status, "pending");
  assert.equal(row.translationColumn.hint, null);
});

test("4. failed translation presents source with Translation unavailable and safety hint", () => {
  const row = buildHostSplitBilingualRow(sampleFailedUtterance);

  assert.equal(row.utteranceId, "utt_102");
  assert.equal(row.sourceColumn.text, "Đường truyền mạng gặp sự cố.");
  assert.equal(row.translationColumn.text, "Translation unavailable");
  assert.equal(row.translationColumn.status, "failed");
  assert.equal(
    row.translationColumn.hint,
    "Original transcript is still available.",
  );
});

test("5. Ready canvas is shown exclusively when session status is ready", () => {
  assert.equal(shouldShowReadyCanvas("ready"), true);
  assert.equal(shouldShowReadyCanvas("connecting"), false);
  assert.equal(shouldShowReadyCanvas("live"), false);
  assert.equal(shouldShowReadyCanvas("stopping"), false);
  assert.equal(shouldShowReadyCanvas("error"), false);
});

test("6. Live workspace is shown when session status transitions past ready", () => {
  assert.equal(shouldShowLiveWorkspace("ready"), false);
  assert.equal(shouldShowLiveWorkspace("connecting"), true);
  assert.equal(shouldShowLiveWorkspace("live"), true);
  assert.equal(shouldShowLiveWorkspace("stopping"), true);
  assert.equal(shouldShowLiveWorkspace("error"), true);
});

test("7. Host supported actions strictly exclude any Pause control", () => {
  const readyActions = getHostSupportedActions("ready");
  const liveActions = getHostSupportedActions("live");
  const stoppingActions = getHostSupportedActions("stopping");
  const errorActions = getHostSupportedActions("error");

  assert.equal(readyActions.hasPause, false);
  assert.equal(liveActions.hasPause, false);
  assert.equal(stoppingActions.hasPause, false);
  assert.equal(errorActions.hasPause, false);

  assert.equal(readyActions.canStart, true);
  assert.equal(readyActions.canStop, false);
  assert.equal(liveActions.canStart, false);
  assert.equal(liveActions.canStop, true);
});

test("8. unsupported fake viewer count is not rendered in Ready configuration", () => {
  const readyConfig = buildHostReadyConfig("microphone", "en");

  assert.equal("viewers" in readyConfig, false);
  assert.equal("viewerCount" in readyConfig, false);
  assert.deepEqual(Object.keys(readyConfig).sort(), [
    "audioSourceLabel",
    "sourceLanguageLabel",
    "targetLanguageLabel",
  ]);
  assert.equal(readyConfig.audioSourceLabel, "Microphone");
  assert.equal(readyConfig.sourceLanguageLabel, "Vietnamese (VI)");
  assert.equal(readyConfig.targetLanguageLabel, "English (EN)");
});

test("presentation timer and breadcrumb remain truthful and local", () => {
  assert.equal(formatPresentationTimer(0), "00:00:00");
  assert.equal(formatPresentationTimer(75), "00:01:15");
  assert.equal(formatPresentationTimer(3665), "01:01:05");

  const breadcrumb = getHostHeaderBreadcrumb("sess_live_456");
  assert.equal(breadcrumb.category, "Live Session");
  assert.equal(breadcrumb.sessionId, "sess_live_456");
  assert.equal("workspace" in breadcrumb, false);
});
