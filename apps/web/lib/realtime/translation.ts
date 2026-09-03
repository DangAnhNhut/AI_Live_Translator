export const APPROVED_TARGET_LANGUAGES = [
  "en",
  "ja",
  "ko",
  "zh-CN",
  "th",
  "fr",
  "de",
  "es",
] as const;

export type TargetLanguage = (typeof APPROVED_TARGET_LANGUAGES)[number];
export type TranslationErrorCode =
  | "provider_unavailable"
  | "provider_error"
  | "queue_overflow"
  | "request_timeout"
  | "internal_error";

export type TranslationConfiguredEvent = {
  type: "translation.configured";
  stream_id: string;
  source_language: "vi";
  target_language: TargetLanguage;
};

type TranslationUtteranceFields = {
  stream_id: string;
  utterance_id: string;
  source_segment_ids: string[];
  source_text: string;
  source_language: "vi";
  target_language: TargetLanguage;
};

export type TranslationPendingEvent = TranslationUtteranceFields & {
  type: "translation.pending";
};

export type TranslationFinalEvent = TranslationUtteranceFields & {
  type: "translation.final";
  translated_text: string;
};

export type TranslationUtteranceErrorEvent = TranslationUtteranceFields & {
  type: "translation.error";
  scope: "utterance";
  code: TranslationErrorCode;
  message: string;
};

export type TranslationSessionErrorEvent = {
  type: "translation.error";
  scope: "session";
  stream_id: string;
  source_language: "vi";
  target_language: TargetLanguage;
  code: TranslationErrorCode;
  message: string;
};

export type TranslationEvent =
  | TranslationConfiguredEvent
  | TranslationPendingEvent
  | TranslationFinalEvent
  | TranslationUtteranceErrorEvent
  | TranslationSessionErrorEvent;

export type TranslationConfiguration = {
  streamId: string;
  sourceLanguage: "vi";
  targetLanguage: TargetLanguage;
};

export type TranslationUtteranceState = {
  streamId: string;
  utteranceId: string;
  sourceSegmentIds: string[];
  sourceText: string;
  sourceLanguage: "vi";
  targetLanguage: TargetLanguage;
  status: "pending" | "final" | "failed";
  translatedText?: string;
  errorCode?: TranslationErrorCode;
  errorMessage?: string;
};

export type TranslationSessionErrorState = {
  streamId: string;
  sourceLanguage: "vi";
  targetLanguage: TargetLanguage;
  code: TranslationErrorCode;
  message: string;
};

export type TranslationState = {
  configurations: readonly TranslationConfiguration[];
  utterances: readonly TranslationUtteranceState[];
  sessionErrors: readonly TranslationSessionErrorState[];
};

const TRANSLATION_ERROR_CODES: readonly TranslationErrorCode[] = [
  "provider_unavailable",
  "provider_error",
  "queue_overflow",
  "request_timeout",
  "internal_error",
];

export function createTranslationState(): TranslationState {
  return { configurations: [], utterances: [], sessionErrors: [] };
}

export function translationUtteranceKey(
  streamId: string,
  utteranceId: string,
): string {
  return `${streamId}\u0000${utteranceId}`;
}

export function getActiveTranslationConfiguration(
  state: TranslationState,
): TranslationConfiguration | null {
  return state.configurations.at(-1) ?? null;
}

export function parseTranslationEvent(value: unknown): TranslationEvent | null {
  if (!isRecord(value) || typeof value.type !== "string") {
    return null;
  }

  if (value.type === "translation.configured") {
    return parseConfigured(value);
  }
  if (value.type === "translation.pending") {
    const fields = parseUtteranceFields(value);
    return fields === null ? null : { type: value.type, ...fields };
  }
  if (value.type === "translation.final") {
    const fields = parseUtteranceFields(value);
    return fields === null || !isNonEmptyString(value.translated_text)
      ? null
      : {
          type: value.type,
          ...fields,
          translated_text: value.translated_text,
        };
  }
  if (value.type !== "translation.error") {
    return null;
  }

  const commonError = parseErrorFields(value);
  if (commonError === null) {
    return null;
  }
  if (value.scope === "session") {
    const configuration = parseConfiguredFields(value);
    return configuration === null
      ? null
      : {
          type: value.type,
          scope: value.scope,
          ...configuration,
          ...commonError,
        };
  }
  if (value.scope === "utterance") {
    const fields = parseUtteranceFields(value);
    return fields === null
      ? null
      : {
          type: value.type,
          scope: value.scope,
          ...fields,
          ...commonError,
        };
  }
  return null;
}

export function applyTranslationEvent(
  state: TranslationState,
  event: TranslationEvent,
): TranslationState {
  const activeState = deactivateTranslationConfiguration(
    state,
    event.stream_id,
  );
  if (event.type === "translation.configured") {
    return applyConfiguration(activeState, event);
  }
  if (event.type === "translation.error" && event.scope === "session") {
    return applySessionError(activeState, event);
  }
  return applyUtterance(activeState, event);
}

export function deactivateTranslationConfiguration(
  state: TranslationState,
  observedStreamId?: string,
): TranslationState {
  if (observedStreamId !== undefined) {
    const activeStreamId =
      getActiveTranslationConfiguration(state)?.streamId ??
      state.sessionErrors.at(-1)?.streamId ??
      null;
    if (activeStreamId === null || activeStreamId === observedStreamId) {
      return state;
    }
  }
  if (state.configurations.length === 0 && state.sessionErrors.length === 0) {
    return state;
  }
  return { ...state, configurations: [], sessionErrors: [] };
}

function applyConfiguration(
  state: TranslationState,
  event: TranslationConfiguredEvent,
): TranslationState {
  const configuration: TranslationConfiguration = {
    streamId: event.stream_id,
    sourceLanguage: event.source_language,
    targetLanguage: event.target_language,
  };
  const index = state.configurations.findIndex(
    (item) => item.streamId === configuration.streamId,
  );
  if (index >= 0 && shallowEqual(state.configurations[index], configuration)) {
    return state;
  }
  const configurations =
    index < 0
      ? [...state.configurations, configuration]
      : state.configurations.map((item, itemIndex) =>
          itemIndex === index ? configuration : item,
        );
  return { ...state, configurations };
}

function applySessionError(
  state: TranslationState,
  event: TranslationSessionErrorEvent,
): TranslationState {
  const error: TranslationSessionErrorState = {
    streamId: event.stream_id,
    sourceLanguage: event.source_language,
    targetLanguage: event.target_language,
    code: event.code,
    message: event.message,
  };
  const index = state.sessionErrors.findIndex(
    (item) => item.streamId === error.streamId && item.code === error.code,
  );
  if (index >= 0 && shallowEqual(state.sessionErrors[index], error)) {
    return state;
  }
  const sessionErrors =
    index < 0
      ? [...state.sessionErrors, error]
      : state.sessionErrors.map((item, itemIndex) =>
          itemIndex === index ? error : item,
        );
  return { ...state, sessionErrors };
}

function applyUtterance(
  state: TranslationState,
  event:
    | TranslationPendingEvent
    | TranslationFinalEvent
    | TranslationUtteranceErrorEvent,
): TranslationState {
  const key = translationUtteranceKey(event.stream_id, event.utterance_id);
  const index = state.utterances.findIndex(
    (item) => translationUtteranceKey(item.streamId, item.utteranceId) === key,
  );
  const existing = index < 0 ? null : state.utterances[index];

  if (existing?.status === "final") {
    return state;
  }
  if (event.type === "translation.pending" && existing !== null) {
    return state;
  }
  if (
    event.type === "translation.error" &&
    existing?.status === "failed" &&
    existing.errorCode === event.code &&
    existing.errorMessage === event.message
  ) {
    return state;
  }

  const base = {
    streamId: event.stream_id,
    utteranceId: event.utterance_id,
    sourceSegmentIds: [...event.source_segment_ids],
    sourceText: event.source_text,
    sourceLanguage: event.source_language,
    targetLanguage: event.target_language,
  };
  const utterance: TranslationUtteranceState =
    event.type === "translation.final"
      ? {
          ...base,
          status: "final",
          translatedText: event.translated_text,
        }
      : event.type === "translation.error"
        ? {
            ...base,
            status: "failed",
            errorCode: event.code,
            errorMessage: event.message,
          }
        : { ...base, status: "pending" };

  const utterances =
    index < 0
      ? [...state.utterances, utterance]
      : state.utterances.map((item, itemIndex) =>
          itemIndex === index ? utterance : item,
        );
  return { ...state, utterances };
}

function parseConfigured(value: Record<string, unknown>): TranslationConfiguredEvent | null {
  const fields = parseConfiguredFields(value);
  return fields === null
    ? null
    : { type: "translation.configured", ...fields };
}

function parseConfiguredFields(value: Record<string, unknown>): Omit<TranslationConfiguredEvent, "type"> | null {
  if (
    !isNonEmptyString(value.stream_id) ||
    value.source_language !== "vi" ||
    !isTargetLanguage(value.target_language)
  ) {
    return null;
  }
  return {
    stream_id: value.stream_id,
    source_language: value.source_language,
    target_language: value.target_language,
  };
}

function parseUtteranceFields(value: Record<string, unknown>): TranslationUtteranceFields | null {
  const configuration = parseConfiguredFields(value);
  if (
    configuration === null ||
    !isNonEmptyString(value.utterance_id) ||
    !Array.isArray(value.source_segment_ids) ||
    value.source_segment_ids.length === 0 ||
    !value.source_segment_ids.every(isNonEmptyString) ||
    !isNonEmptyString(value.source_text)
  ) {
    return null;
  }
  return {
    ...configuration,
    utterance_id: value.utterance_id,
    source_segment_ids: [...value.source_segment_ids],
    source_text: value.source_text,
  };
}

function parseErrorFields(value: Record<string, unknown>): Pick<TranslationSessionErrorEvent, "code" | "message"> | null {
  if (!isTranslationErrorCode(value.code) || !isNonEmptyString(value.message)) {
    return null;
  }
  return { code: value.code, message: value.message };
}

function isTargetLanguage(value: unknown): value is TargetLanguage {
  return APPROVED_TARGET_LANGUAGES.some((language) => language === value);
}

function isTranslationErrorCode(value: unknown): value is TranslationErrorCode {
  return TRANSLATION_ERROR_CODES.some((code) => code === value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shallowEqual(
  left: Record<string, unknown>,
  right: Record<string, unknown>,
): boolean {
  const keys = Object.keys(left);
  return (
    keys.length === Object.keys(right).length &&
    keys.every((key) => left[key] === right[key])
  );
}
