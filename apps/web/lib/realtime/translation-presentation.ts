import type { TranscriptSegment } from "./transcript.ts";
import type {
  TargetLanguage,
  TranslationSessionErrorState,
  TranslationState,
  TranslationUtteranceState,
} from "./translation.ts";

export type TranslationPresentation = {
  utterances: readonly TranslationUtteranceState[];
  liveSegments: readonly TranscriptSegment[];
};

export type BilingualTranscriptBlockView = {
  sourceLabel: string;
  sourceText: string;
  translationLabel: string;
  translationText: string;
  status: TranslationUtteranceState["status"];
  secondaryHint: string | null;
};

const LANGUAGE_LABELS: Record<"vi" | TargetLanguage, string> = {
  vi: "Vietnamese",
  en: "English",
  ja: "Japanese",
  ko: "Korean",
  "zh-CN": "Chinese (Simplified)",
  th: "Thai",
  fr: "French",
  de: "German",
  es: "Spanish",
};

export function transcriptSegmentKey(
  streamId: string | undefined,
  segmentId: string,
): string {
  return `${streamId ?? ""}\u0000${segmentId}`;
}

export function buildTranslationPresentation(
  segments: readonly TranscriptSegment[],
  utterances: readonly TranslationUtteranceState[],
): TranslationPresentation {
  const claimedSegments = new Set(
    utterances.flatMap((utterance) =>
      utterance.sourceSegmentIds.map((segmentId) =>
        transcriptSegmentKey(utterance.streamId, segmentId),
      ),
    ),
  );
  return {
    utterances,
    liveSegments: segments.filter(
      (segment) =>
        segment.kind === "interim" ||
        !claimedSegments.has(
          transcriptSegmentKey(segment.streamId, segment.id),
        ),
    ),
  };
}

export function getTranslationDisplayText(
  utterance: TranslationUtteranceState,
): string {
  if (utterance.status === "pending") {
    return "Translating...";
  }
  if (utterance.status === "failed") {
    return "Translation unavailable";
  }
  return utterance.translatedText ?? "";
}

export function buildBilingualTranscriptBlockView(
  utterance: TranslationUtteranceState,
): BilingualTranscriptBlockView {
  return {
    sourceLabel: `ORIGINAL · ${utterance.sourceLanguage.toUpperCase()}`,
    sourceText: utterance.sourceText,
    translationLabel: `TRANSLATION · ${utterance.targetLanguage.toUpperCase()}`,
    translationText: getTranslationDisplayText(utterance),
    status: utterance.status,
    secondaryHint:
      utterance.status === "failed"
        ? "Original transcript is still available."
        : null,
  };
}

export function getLanguageLabel(
  language: "vi" | TargetLanguage,
): string {
  return LANGUAGE_LABELS[language];
}

export function getTranslationSessionWarning(
  errors: readonly TranslationSessionErrorState[],
  activeStreamId: string | null,
): string | null {
  const relevantError =
    activeStreamId === null
      ? errors.at(-1)
      : errors.find((error) => error.streamId === activeStreamId);
  return relevantError === undefined
    ? null
    : "Translation is unavailable. Original transcript will continue.";
}

export function shouldUseBilingualPresentation(
  translationExpected: boolean,
  state: TranslationState,
): boolean {
  return (
    translationExpected ||
    state.configurations.length > 0 ||
    state.utterances.length > 0 ||
    state.sessionErrors.length > 0
  );
}
