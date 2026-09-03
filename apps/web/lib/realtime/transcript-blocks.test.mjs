import assert from "node:assert/strict";
import test from "node:test";

import { applyTranscriptEvent } from "./transcript.ts";
import {
  groupTranscriptSegments,
  normalizeTranscriptWhitespace,
} from "./transcript-blocks.ts";

function finalSegment(id, text) {
  return { id, text, language: "vi", kind: "final" };
}

function interimSegment(id, text) {
  return { id, text, language: "vi", kind: "interim" };
}

test("one final segment produces one presentation block", () => {
  const blocks = groupTranscriptSegments([finalSegment("seg_001", "Xin chào.")]);

  assert.deepEqual(blocks, [
    {
      id: "final:seg_001",
      segmentIds: ["seg_001"],
      text: "Xin chào.",
      language: "vi",
      kind: "final",
    },
  ]);
});

test("two short final segments combine with normalized whitespace", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "  Xin   chào "),
    finalSegment("seg_002", " mọi người.  "),
  ]);

  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].text, "Xin chào mọi người.");
  assert.deepEqual(blocks[0].segmentIds, ["seg_001", "seg_002"]);
});

test("multiple tiny finals remain in one readable block", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "Một"),
    finalSegment("seg_002", "hai"),
    finalSegment("seg_003", "ba."),
  ]);

  assert.deepEqual(blocks.map((block) => block.text), ["Một hai ba."]);
});

test("a tiny punctuated sentence does not create its own block", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "Bạn có đồng ý không?"),
    finalSegment("seg_002", "Có."),
    finalSegment(
      "seg_003",
      "Nhưng sau đó chúng ta tiếp tục nói về vấn đề này.",
    ),
  ]);

  assert.equal(blocks.length, 1);
  assert.equal(
    blocks[0].text,
    "Bạn có đồng ý không? Có. Nhưng sau đó chúng ta tiếp tục nói về vấn đề này.",
  );
});

test("punctuation at 100 characters creates a natural boundary", () => {
  const sentence = `${"A".repeat(99)}.`;
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", sentence),
    finalSegment("seg_002", "Next thought"),
  ]);

  assert.deepEqual(blocks.map((block) => block.text), [sentence, "Next thought"]);
});

test("220 characters creates a boundary without punctuation", () => {
  const first = "B".repeat(120);
  const second = "C".repeat(99);
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", first),
    finalSegment("seg_002", second),
    finalSegment("seg_003", "After boundary"),
  ]);

  assert.deepEqual(blocks.map((block) => block.text), [
    `${first} ${second}`,
    "After boundary",
  ]);
});

test("four finalized segments create a safety boundary", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "one"),
    finalSegment("seg_002", "two"),
    finalSegment("seg_003", "three"),
    finalSegment("seg_004", "four"),
    finalSegment("seg_005", "five"),
  ]);

  assert.deepEqual(blocks.map((block) => block.segmentIds), [
    ["seg_001", "seg_002", "seg_003", "seg_004"],
    ["seg_005"],
  ]);
});

test("final ordering is preserved and every segment belongs to exactly one block", () => {
  const raw = Array.from({ length: 9 }, (_, index) =>
    finalSegment(`seg_${index + 1}`, `text-${index + 1}`),
  );
  const blocks = groupTranscriptSegments(raw);

  assert.deepEqual(
    blocks.flatMap((block) => block.segmentIds),
    raw.map((segment) => segment.id),
  );
  assert.equal(
    new Set(blocks.flatMap((block) => block.segmentIds)).size,
    raw.length,
  );
});

test("final grouping preserves all normalized content without loss or duplication", () => {
  const raw = [
    finalSegment("seg_001", "  First   part"),
    finalSegment("seg_002", "ends here."),
    finalSegment("seg_003", "Third part"),
    finalSegment("seg_004", "continues"),
    finalSegment("seg_005", "and ends!"),
  ];
  const blocks = groupTranscriptSegments(raw);
  const rawText = normalizeTranscriptWhitespace(
    raw.map((segment) => segment.text).join(" "),
  );
  const blockText = normalizeTranscriptWhitespace(
    blocks
      .filter((block) => block.kind === "final")
      .map((block) => block.text)
      .join(" "),
  );

  assert.equal(blockText, rawText);
});

test("one active interim block is presented at the end", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "Final text"),
    interimSegment("seg_002", "current revision"),
  ]);

  assert.deepEqual(blocks.at(-1), {
    id: "interim:seg_002",
    segmentIds: ["seg_002"],
    text: "current revision",
    language: "vi",
    kind: "interim",
  });
  assert.equal(blocks.filter((block) => block.kind === "interim").length, 1);
});

test("an interim revision replaces presentation text instead of duplicating it", () => {
  const firstRaw = applyTranscriptEvent([], {
    type: "transcript.interim",
    segment_id: "seg_001",
    text: "xin chào",
    language: "vi",
  });
  const revisedRaw = applyTranscriptEvent(firstRaw, {
    type: "transcript.interim",
    segment_id: "seg_001",
    text: "xin chào mọi người",
    language: "vi",
  });
  const blocks = groupTranscriptSegments(revisedRaw);

  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].text, "xin chào mọi người");
  assert.deepEqual(blocks[0].segmentIds, ["seg_001"]);
});

test("interim to final transition recomputes deterministic final grouping", () => {
  const firstFinal = applyTranscriptEvent([], {
    type: "transcript.final",
    segment_id: "seg_001",
    text: "Xin chào",
    language: "vi",
  });
  const withInterim = applyTranscriptEvent(firstFinal, {
    type: "transcript.interim",
    segment_id: "seg_002",
    text: "mọi người",
    language: "vi",
  });
  const finalized = applyTranscriptEvent(withInterim, {
    type: "transcript.final",
    segment_id: "seg_002",
    text: "mọi người.",
    language: "vi",
  });

  assert.deepEqual(groupTranscriptSegments(finalized), [
    {
      id: "final:seg_001",
      segmentIds: ["seg_001", "seg_002"],
      text: "Xin chào mọi người.",
      language: "vi",
      kind: "final",
    },
  ]);
});

test("empty final and interim text do not create presentation blocks", () => {
  const blocks = groupTranscriptSegments([
    finalSegment("seg_001", "  \n "),
    interimSegment("seg_002", "\t"),
  ]);

  assert.deepEqual(blocks, []);
});

test("a later empty interim clears an older active interim presentation", () => {
  const blocks = groupTranscriptSegments([
    interimSegment("seg_001", "stale interim"),
    interimSegment("seg_002", "   "),
  ]);

  assert.deepEqual(blocks, []);
});

test("presentation grouping and block identities remain stream-scoped", () => {
  const blocks = groupTranscriptSegments([
    { ...finalSegment("seg_001", "Stream A."), streamId: "stream_A" },
    { ...finalSegment("seg_001", "Stream B."), streamId: "stream_B" },
  ]);

  assert.equal(blocks.length, 2);
  assert.notEqual(blocks[0].id, blocks[1].id);
  assert.deepEqual(
    blocks.map((block) => block.streamId),
    ["stream_A", "stream_B"],
  );
});
