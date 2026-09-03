import type {
  TranscriptKind,
  TranscriptSegment,
} from "./transcript.ts";

export const MIN_SENTENCE_BOUNDARY_CHARS = 100;
export const MAX_BLOCK_CHARS = 220;
export const MAX_FINAL_SEGMENTS_PER_BLOCK = 4;

export type TranscriptBlock = {
  id: string;
  streamId?: string;
  segmentIds: string[];
  text: string;
  kind: TranscriptKind;
  language?: string;
};

type PendingFinalBlock = {
  firstSegmentId: string;
  streamId?: string;
  segmentIds: string[];
  text: string;
  language: string;
};

const NATURAL_BOUNDARY = /[.?!…]$/u;

export function normalizeTranscriptWhitespace(text: string): string {
  return text.trim().replace(/\s+/gu, " ");
}

export function groupTranscriptSegments(
  segments: readonly TranscriptSegment[],
): readonly TranscriptBlock[] {
  const finalBlocks: TranscriptBlock[] = [];
  let pendingFinal: PendingFinalBlock | null = null;
  let activeInterim: TranscriptBlock | null = null;

  const commitPendingFinal = () => {
    if (pendingFinal === null) {
      return;
    }
    finalBlocks.push({
      id: blockId("final", pendingFinal.streamId, pendingFinal.firstSegmentId),
      ...(pendingFinal.streamId === undefined
        ? {}
        : { streamId: pendingFinal.streamId }),
      segmentIds: pendingFinal.segmentIds,
      text: pendingFinal.text,
      language: pendingFinal.language,
      kind: "final",
    });
    pendingFinal = null;
  };

  for (const segment of segments) {
    const text = normalizeTranscriptWhitespace(segment.text);

    if (segment.kind === "interim") {
      commitPendingFinal();
      activeInterim = text
          ? {
            id: blockId("interim", segment.streamId, segment.id),
            ...(segment.streamId === undefined
              ? {}
              : { streamId: segment.streamId }),
            segmentIds: [segment.id],
            text,
            language: segment.language,
            kind: "interim",
          }
        : null;
      continue;
    }

    if (!text) {
      continue;
    }

    if (
      pendingFinal !== null &&
      (pendingFinal.streamId ?? "") !== (segment.streamId ?? "")
    ) {
      commitPendingFinal();
    }

    if (pendingFinal === null) {
      pendingFinal = {
        firstSegmentId: segment.id,
        ...(segment.streamId === undefined
          ? {}
          : { streamId: segment.streamId }),
        segmentIds: [segment.id],
        text,
        language: segment.language,
      };
    } else {
      pendingFinal.segmentIds.push(segment.id);
      pendingFinal.text = `${pendingFinal.text} ${text}`;
    }

    const reachesNaturalBoundary =
      pendingFinal.text.length >= MIN_SENTENCE_BOUNDARY_CHARS &&
      NATURAL_BOUNDARY.test(pendingFinal.text);
    const reachesMaximumSize = pendingFinal.text.length >= MAX_BLOCK_CHARS;
    const reachesSegmentLimit =
      pendingFinal.segmentIds.length >= MAX_FINAL_SEGMENTS_PER_BLOCK;

    if (
      reachesNaturalBoundary ||
      reachesMaximumSize ||
      reachesSegmentLimit
    ) {
      commitPendingFinal();
    }
  }

  commitPendingFinal();
  return activeInterim === null
    ? finalBlocks
    : [...finalBlocks, activeInterim];
}

function blockId(
  kind: TranscriptKind,
  streamId: string | undefined,
  segmentId: string,
): string {
  return streamId === undefined
    ? `${kind}:${segmentId}`
    : `${kind}:${streamId}:${segmentId}`;
}
