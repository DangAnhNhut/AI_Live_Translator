import type { TranslationConfiguration, TranslationUtteranceState } from "./translation.ts";
import type { ViewerConnectionStatus } from "./viewer-socket.ts";
import {
  buildBilingualTranscriptBlockView,
  type BilingualTranscriptBlockView,
} from "./translation-presentation.ts";

export interface ViewerStatusPresentation {
  label: string;
  dotColor: string;
  badgeClass: string;
  isPulsing: boolean;
  detail: string;
}

export interface ViewerSupportedActions {
  canSelectAudio: false;
  canStart: false;
  canStop: false;
  canPause: false;
  canMutateTarget: false;
  hasTTS: false;
  hasViewerCount: false;
  isReceiveOnly: true;
}

export interface ViewerSplitBilingualRowView {
  utteranceId: string;
  sourceColumn: {
    label: string;
    language: string;
    text: string;
  };
  translationColumn: {
    label: string;
    language: string;
    text: string;
    status: TranslationUtteranceState["status"];
    hint: string | null;
  };
}

export function getViewerStatusPresentation(
  status: ViewerConnectionStatus,
): ViewerStatusPresentation {
  switch (status) {
    case "live":
      return {
        label: "LIVE",
        dotColor: "bg-emerald-500",
        badgeClass: "bg-emerald-50 text-emerald-700 border-emerald-200",
        isPulsing: true,
        detail: "Captions arriving in real time",
      };
    case "connecting":
      return {
        label: "Connecting",
        dotColor: "bg-amber-400",
        badgeClass: "bg-amber-50 text-amber-700 border-amber-200",
        isPulsing: true,
        detail: "Opening live stream...",
      };
    case "reconnecting":
      return {
        label: "Reconnecting",
        dotColor: "bg-amber-500",
        badgeClass: "bg-amber-50 text-amber-800 border-amber-200",
        isPulsing: true,
        detail: "Connection interrupted. Retrying automatically...",
      };
    case "disconnected":
      return {
        label: "Disconnected",
        dotColor: "bg-slate-400",
        badgeClass: "bg-slate-100 text-slate-700 border-slate-200",
        isPulsing: false,
        detail: "Stream disconnected",
      };
    case "error":
      return {
        label: "Connection Error",
        dotColor: "bg-rose-500",
        badgeClass: "bg-rose-50 text-rose-700 border-rose-200",
        isPulsing: false,
        detail: "Could not connect to live caption feed",
      };
  }
}

export function formatViewerLanguageRoute(
  activeConfig: TranslationConfiguration | null,
): string {
  if (!activeConfig) {
    return "VI → —";
  }
  return `VI → ${activeConfig.targetLanguage.toUpperCase()}`;
}

export function getViewerSessionBreadcrumb(sessionId: string): {
  category: string;
  sessionId: string;
} {
  return {
    category: "Live Session",
    sessionId,
  };
}

export function getViewerSupportedActions(): ViewerSupportedActions {
  return {
    canSelectAudio: false,
    canStart: false,
    canStop: false,
    canPause: false,
    canMutateTarget: false,
    hasTTS: false,
    hasViewerCount: false,
    isReceiveOnly: true,
  };
}

export function shouldShowNonBlockingReconnectBanner(
  status: ViewerConnectionStatus,
): boolean {
  return status === "reconnecting";
}

export function shouldPreserveTranscriptOnStatus(
  status: ViewerConnectionStatus,
): boolean {
  // Transcripts received stay visible across all runtime network states
  return (
    status === "live" ||
    status === "connecting" ||
    status === "reconnecting" ||
    status === "disconnected" ||
    status === "error"
  );
}

export function buildViewerSplitBilingualRow(
  utterance: TranslationUtteranceState,
): ViewerSplitBilingualRowView {
  const blockView: BilingualTranscriptBlockView = buildBilingualTranscriptBlockView(utterance);
  return {
    utteranceId: utterance.utteranceId,
    sourceColumn: {
      label: blockView.sourceLabel,
      language: utterance.sourceLanguage,
      text: blockView.sourceText,
    },
    translationColumn: {
      label: blockView.translationLabel,
      language: utterance.targetLanguage,
      text: blockView.translationText,
      status: blockView.status,
      hint: blockView.secondaryHint,
    },
  };
}

export interface ViewerTranscriptLabels {
  streamBadgeLabel: string;
  sourceBadgeLabel: string;
}

export function getViewerTranscriptLabels(): ViewerTranscriptLabels {
  return {
    streamBadgeLabel: "LIVE CAPTIONS",
    sourceBadgeLabel: "Live Source",
  };
}
