export type TranscriptKind = "interim" | "final";

export type TranscriptEvent = {
  type: `transcript.${TranscriptKind}`;
  stream_id?: string;
  segment_id: string;
  text: string;
  language: string;
};

export type ViewerTranscriptEvent = TranscriptEvent;

export type TranscriptSegment = {
  id: string;
  streamId?: string;
  text: string;
  language: string;
  kind: TranscriptKind;
};

export function parseTranscriptEvent(
  value: unknown,
): TranscriptEvent | null {
  if (!isRecord(value)) {
    return null;
  }

  const {
    type,
    stream_id: streamId,
    segment_id: segmentId,
    text,
    language,
  } = value;

  if (
    (type !== "transcript.interim" && type !== "transcript.final") ||
    typeof segmentId !== "string" ||
    !segmentId.trim() ||
    typeof text !== "string" ||
    typeof language !== "string" ||
    !language.trim() ||
    (streamId !== undefined &&
      (typeof streamId !== "string" || !streamId.trim()))
  ) {
    return null;
  }

  return {
    type,
    ...(typeof streamId === "string" ? { stream_id: streamId } : {}),
    segment_id: segmentId,
    text,
    language,
  };
}

export const parseViewerTranscriptEvent = parseTranscriptEvent;

export function applyTranscriptEvent(
  state: readonly TranscriptSegment[],
  event: ViewerTranscriptEvent,
): readonly TranscriptSegment[] {
  const existingIndex = state.findIndex(
    (segment) =>
      segment.id === event.segment_id &&
      (segment.streamId ?? "") === (event.stream_id ?? ""),
  );

  if (existingIndex >= 0 && state[existingIndex].kind === "final") {
    return state;
  }

  const nextSegment: TranscriptSegment = {
    id: event.segment_id,
    ...(event.stream_id === undefined ? {} : { streamId: event.stream_id }),
    text: event.text,
    language: event.language,
    kind: event.type === "transcript.final" ? "final" : "interim",
  };

  if (existingIndex < 0) {
    return [...state, nextSegment];
  }

  const existingSegment = state[existingIndex];
  if (
    existingSegment.text === nextSegment.text &&
    existingSegment.language === nextSegment.language &&
    existingSegment.kind === nextSegment.kind
  ) {
    return state;
  }

  return state.map((segment, index) =>
    index === existingIndex ? nextSegment : segment,
  );
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
