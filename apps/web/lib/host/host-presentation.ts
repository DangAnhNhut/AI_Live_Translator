import type { HostSessionState } from "./host-session.ts";
import type { TranslationUtteranceState, TargetLanguage } from "../realtime/translation.ts";
import {
  buildBilingualTranscriptBlockView,
  getLanguageLabel,
  type BilingualTranscriptBlockView,
} from "../realtime/translation-presentation.ts";

export interface HostSplitBilingualRowView {
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

export interface HostReadyConfigurationSummary {
  audioSourceLabel: string;
  sourceLanguageLabel: string;
  targetLanguageLabel: string;
  // Note: viewers presence/count is strictly omitted as telemetry does not exist.
}

export function shouldShowReadyCanvas(status: HostSessionState): boolean {
  return status === "ready";
}

export function shouldShowLiveWorkspace(status: HostSessionState): boolean {
  return status !== "ready";
}

export function getHostSupportedActions(status: HostSessionState): {
  canStart: boolean;
  canStop: boolean;
  hasPause: boolean;
} {
  return {
    canStart: status === "ready" || status === "error",
    canStop: status === "live" || status === "connecting",
    hasPause: false, // Strict architectural guardrail: Pause control is forbidden
  };
}

export function formatPresentationTimer(elapsedSeconds: number): string {
  const safeSeconds = Math.max(0, Math.floor(elapsedSeconds));
  const hours = Math.floor(safeSeconds / 3600);
  const minutes = Math.floor((safeSeconds % 3600) / 60);
  const seconds = safeSeconds % 60;
  return `${hours.toString().padStart(2, "0")}:${minutes.toString().padStart(2, "0")}:${seconds.toString().padStart(2, "0")}`;
}

export function getHostHeaderBreadcrumb(sessionId: string): {
  category: string;
  sessionId: string;
} {
  return {
    category: "Live Session",
    sessionId,
  };
}

export function buildHostReadyConfig(
  audioSourceName: string | null,
  targetLanguage: TargetLanguage,
): HostReadyConfigurationSummary {
  return {
    audioSourceLabel: audioSourceName
      ? audioSourceName === "microphone"
        ? "Microphone"
        : "System Audio"
      : "Not selected",
    sourceLanguageLabel: "Vietnamese (VI)",
    targetLanguageLabel: `${getLanguageLabel(targetLanguage)} (${targetLanguage.toUpperCase()})`,
  };
}

export function buildHostSplitBilingualRow(
  utterance: TranslationUtteranceState,
): HostSplitBilingualRowView {
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
