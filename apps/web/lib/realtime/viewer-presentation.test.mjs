import assert from "node:assert/strict";
import test from "node:test";

import {
  buildViewerSplitBilingualRow,
  formatViewerLanguageRoute,
  getViewerSessionBreadcrumb,
  getViewerStatusPresentation,
  getViewerSupportedActions,
  getViewerTranscriptLabels,
  shouldPreserveTranscriptOnStatus,
  shouldShowNonBlockingReconnectBanner,
} from "./viewer-presentation.ts";

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

test("1. connection status mapping returns truthful presentation for all states", () => {
  const live = getViewerStatusPresentation("live");
  assert.equal(live.label, "LIVE");
  assert.equal(live.isPulsing, true);

  const connecting = getViewerStatusPresentation("connecting");
  assert.equal(connecting.label, "Connecting");
  assert.equal(connecting.isPulsing, true);

  const reconnecting = getViewerStatusPresentation("reconnecting");
  assert.equal(reconnecting.label, "Reconnecting");
  assert.equal(reconnecting.isPulsing, true);

  const disconnected = getViewerStatusPresentation("disconnected");
  assert.equal(disconnected.label, "Disconnected");
  assert.equal(disconnected.isPulsing, false);

  const error = getViewerStatusPresentation("error");
  assert.equal(error.label, "Connection Error");
  assert.equal(error.isPulsing, false);
});

test("2. real sessionId presentation formats breadcrumb without fabricated meeting title", () => {
  const breadcrumb = getViewerSessionBreadcrumb("sess_audit_987");
  assert.equal(breadcrumb.category, "Live Session");
  assert.equal(breadcrumb.sessionId, "sess_audit_987");
  // Ensure no fabricated title is attached
  assert.equal("title" in breadcrumb, false);
  assert.equal("meetingName" in breadcrumb, false);
});

test("3. language route formatting shows active target or neutral placeholder when unconfigured", () => {
  const activeEn = formatViewerLanguageRoute({
    sourceLanguage: "vi",
    targetLanguage: "en",
    model: "gemini-2.5-flash",
  });
  assert.equal(activeEn, "VI → EN");

  const activeJa = formatViewerLanguageRoute({
    sourceLanguage: "vi",
    targetLanguage: "ja",
    model: "gemini-2.5-flash",
  });
  assert.equal(activeJa, "VI → JA");

  const unconfigured = formatViewerLanguageRoute(null);
  assert.equal(unconfigured, "VI → —");
});

test("4. unsupported fake viewer count and presence telemetry are strictly absent", () => {
  const actions = getViewerSupportedActions();
  assert.equal(actions.hasViewerCount, false);
  assert.equal("viewerCount" in actions, false);
  assert.equal("presence" in actions, false);
});

test("5. Start, Stop, and Pause controls are strictly forbidden in Viewer", () => {
  const actions = getViewerSupportedActions();
  assert.equal(actions.canStart, false);
  assert.equal(actions.canStop, false);
  assert.equal(actions.canPause, false);
});

test("6. audio-source controls are strictly absent from Viewer", () => {
  const actions = getViewerSupportedActions();
  assert.equal(actions.canSelectAudio, false);
  assert.equal("microphone" in actions, false);
  assert.equal("systemAudio" in actions, false);
});

test("7. Viewer remains strictly receive-only and cannot mutate translation target", () => {
  const actions = getViewerSupportedActions();
  assert.equal(actions.isReceiveOnly, true);
  assert.equal(actions.canMutateTarget, false);
});

test("8. split bilingual compatibility preserves utterance identity across pending, final, and failed states", () => {
  // Final row
  const finalRow = buildViewerSplitBilingualRow(sampleFinalUtterance);
  assert.equal(finalRow.utteranceId, "utt_101");
  assert.equal(finalRow.sourceColumn.label, "ORIGINAL · VI");
  assert.equal(finalRow.translationColumn.label, "TRANSLATION · EN");
  assert.equal(finalRow.sourceColumn.text, "Xin chào quý vị khán giả đang theo dõi.");
  assert.equal(finalRow.translationColumn.text, "Welcome to all viewers watching.");
  assert.equal(finalRow.translationColumn.status, "final");

  // Pending row
  const pendingRow = buildViewerSplitBilingualRow(samplePendingUtterance);
  assert.equal(pendingRow.utteranceId, "utt_101");
  assert.equal(pendingRow.translationColumn.text, "Translating...");
  assert.equal(pendingRow.translationColumn.status, "pending");

  // Failed row preserves source text and shows graceful unavailable hint
  const failedRow = buildViewerSplitBilingualRow(sampleFailedUtterance);
  assert.equal(failedRow.utteranceId, "utt_102");
  assert.equal(failedRow.sourceColumn.text, "Đường truyền mạng gặp sự cố.");
  assert.equal(failedRow.translationColumn.text, "Translation unavailable");
  assert.equal(failedRow.translationColumn.hint, "Original transcript is still available.");
  assert.equal(failedRow.translationColumn.status, "failed");
});

test("9. reconnect presentation preserves transcript visibility and activates non-blocking banner", () => {
  assert.equal(shouldShowNonBlockingReconnectBanner("reconnecting"), true);
  assert.equal(shouldShowNonBlockingReconnectBanner("live"), false);
  assert.equal(shouldShowNonBlockingReconnectBanner("connecting"), false);
  assert.equal(shouldShowNonBlockingReconnectBanner("error"), false);

  assert.equal(shouldPreserveTranscriptOnStatus("reconnecting"), true);
  assert.equal(shouldPreserveTranscriptOnStatus("error"), true);
  assert.equal(shouldPreserveTranscriptOnStatus("disconnected"), true);
  assert.equal(shouldPreserveTranscriptOnStatus("live"), true);
});

test("10. unsupported TTS/voice playback controls are absent from Viewer", () => {
  const actions = getViewerSupportedActions();
  assert.equal(actions.hasTTS, false);
  assert.equal("ttsPlayback" in actions, false);
  assert.equal("muteAudio" in actions, false);
  assert.equal("audioVolume" in actions, false);
});

test("11. Viewer toolbar label is LIVE CAPTIONS and not AUDIO STREAM", () => {
  const labels = getViewerTranscriptLabels();
  assert.equal(labels.streamBadgeLabel, "LIVE CAPTIONS");
  assert.notEqual(labels.streamBadgeLabel, "AUDIO STREAM");
});

test("12. Viewer source badge is Live Source and strictly not Audio In", () => {
  const labels = getViewerTranscriptLabels();
  assert.equal(labels.sourceBadgeLabel, "Live Source");
  assert.notEqual(labels.sourceBadgeLabel, "Audio In");
});
