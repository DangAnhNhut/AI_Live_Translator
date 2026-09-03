import assert from "node:assert/strict";
import test from "node:test";

import {
  applyTranscriptEvent,
  parseTranscriptEvent,
  parseViewerTranscriptEvent,
} from "./transcript.ts";
import { buildWebSocketUrl } from "./socket-url.ts";
import {
  buildViewerWebSocketUrl,
  isValidSessionId,
} from "./viewer-socket.ts";

const interim = {
  type: "transcript.interim",
  segment_id: "seg_001",
  text: "xin chào",
  language: "vi",
};

test("first interim creates one interim segment", () => {
  assert.deepEqual(applyTranscriptEvent([], interim), [
    {
      id: "seg_001",
      text: "xin chào",
      language: "vi",
      kind: "interim",
    },
  ]);
});

test("a later interim replaces text for the same segment", () => {
  const firstState = applyTranscriptEvent([], interim);
  const nextState = applyTranscriptEvent(firstState, {
    ...interim,
    text: "xin chào mọi người",
  });

  assert.equal(nextState.length, 1);
  assert.equal(nextState[0].text, "xin chào mọi người");
  assert.equal(nextState[0].kind, "interim");
});

test("a final replaces and locks an existing interim segment", () => {
  const firstState = applyTranscriptEvent([], interim);
  const finalState = applyTranscriptEvent(firstState, {
    ...interim,
    type: "transcript.final",
    text: "Xin chào mọi người.",
  });

  assert.deepEqual(finalState, [
    {
      id: "seg_001",
      text: "Xin chào mọi người.",
      language: "vi",
      kind: "final",
    },
  ]);

  assert.strictEqual(
    applyTranscriptEvent(finalState, {
      ...interim,
      text: "must not regress",
    }),
    finalState,
  );
});

test("a different segment appends in arrival order", () => {
  const firstState = applyTranscriptEvent([], {
    ...interim,
    type: "transcript.final",
  });
  const nextState = applyTranscriptEvent(firstState, {
    type: "transcript.final",
    segment_id: "seg_002",
    text: "Hẹn gặp lại.",
    language: "vi",
  });

  assert.deepEqual(
    nextState.map((segment) => segment.id),
    ["seg_001", "seg_002"],
  );
});

test("the same segment ID in different streams remains distinct", () => {
  const first = applyTranscriptEvent([], {
    ...interim,
    stream_id: "stream_A",
  });
  const next = applyTranscriptEvent(first, {
    ...interim,
    stream_id: "stream_B",
    text: "other stream",
  });

  assert.equal(next.length, 2);
  assert.deepEqual(
    next.map((segment) => segment.streamId),
    ["stream_A", "stream_B"],
  );
});

test("parser retains an optional normalized stream identity", () => {
  const streamed = { ...interim, stream_id: "stream_A" };

  assert.deepEqual(parseTranscriptEvent(streamed), streamed);
  assert.equal(parseTranscriptEvent({ ...streamed, stream_id: "" }), null);
});

test("a repeated final cannot duplicate or rewrite finalized content", () => {
  const finalState = applyTranscriptEvent([], {
    ...interim,
    type: "transcript.final",
    text: "Canonical final.",
  });

  const repeatedState = applyTranscriptEvent(finalState, {
    ...interim,
    type: "transcript.final",
    text: "Conflicting repeated final.",
  });

  assert.strictEqual(repeatedState, finalState);
  assert.equal(repeatedState.length, 1);
  assert.equal(repeatedState[0].text, "Canonical final.");
});

test("parser accepts the exact normalized viewer transcript contract", () => {
  assert.deepEqual(parseTranscriptEvent(interim), interim);
  assert.deepEqual(parseViewerTranscriptEvent(interim), interim);
});

test("parser ignores malformed and unknown viewer messages", () => {
  const invalidMessages = [
    null,
    [],
    "not an object",
    { type: "transcript.interim", segment_id: "seg_001" },
    { ...interim, segment_id: "" },
    { ...interim, text: 42 },
    { ...interim, language: null },
    { ...interim, type: "stt.ready" },
  ];

  for (const message of invalidMessages) {
    assert.equal(parseViewerTranscriptEvent(message), null);
  }
});

test("session validation matches the backend identifier constraints", () => {
  assert.equal(isValidSessionId("demo-001"), true);
  assert.equal(isValidSessionId("A.b_c-9"), true);
  assert.equal(isValidSessionId("a".repeat(64)), true);
  assert.equal(isValidSessionId(""), false);
  assert.equal(isValidSessionId("-starts-wrong"), false);
  assert.equal(isValidSessionId("contains space"), false);
  assert.equal(isValidSessionId("a".repeat(65)), false);
});

test("viewer URL uses an env base, trims trailing slashes, and has a local fallback", () => {
  assert.equal(
    buildWebSocketUrl("wss://api.example.com/", "/ws/stt"),
    "wss://api.example.com/ws/stt",
  );
  assert.equal(
    buildViewerWebSocketUrl("wss://api.example.com/", "demo-001"),
    "wss://api.example.com/ws/sessions/demo-001/viewer",
  );
  assert.equal(
    buildViewerWebSocketUrl(undefined, "demo-001"),
    "ws://127.0.0.1:8000/ws/sessions/demo-001/viewer",
  );
  assert.throws(
    () => buildViewerWebSocketUrl("https://api.example.com", "demo-001"),
    /WebSocket base URL/,
  );
  assert.throws(
    () => buildViewerWebSocketUrl(undefined, "invalid session"),
    /session ID/,
  );
});
