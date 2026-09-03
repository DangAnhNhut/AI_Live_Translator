import assert from "node:assert/strict";
import test from "node:test";

import { ViewerSocketClient } from "./viewer-socket.ts";

class FakeSocket {
  onopen = null;
  onmessage = null;
  onerror = null;
  onclose = null;
  closeCalls = 0;

  close() {
    this.closeCalls += 1;
    this.onclose?.({ code: 1000, wasClean: true });
  }

  open() {
    this.onopen?.({});
  }

  message(data) {
    this.onmessage?.({ data });
  }

  error() {
    this.onerror?.({});
  }

  unexpectedClose() {
    this.onclose?.({ code: 1006, wasClean: false });
  }
}

function createHarness() {
  const sockets = [];
  const statuses = [];
  const events = [];
  const translations = [];
  const scheduled = [];
  const cancelled = [];

  const client = new ViewerSocketClient({
    url: "ws://127.0.0.1:8000/ws/sessions/demo-001/viewer",
    createSocket: () => {
      const socket = new FakeSocket();
      sockets.push(socket);
      return socket;
    },
    schedule: (callback, delay) => {
      const task = { callback, delay };
      scheduled.push(task);
      return task;
    },
    cancelSchedule: (task) => cancelled.push(task),
    onStatus: (status) => statuses.push(status),
    onTranscript: (event) => events.push(event),
    onTranslation: (event) => translations.push(event),
  });

  return {
    client,
    sockets,
    statuses,
    events,
    translations,
    scheduled,
    cancelled,
  };
}

test("start connects and socket open reports live", () => {
  const harness = createHarness();

  harness.client.start();
  assert.deepEqual(harness.statuses, ["connecting"]);
  assert.equal(harness.sockets.length, 1);

  harness.sockets[0].open();
  assert.deepEqual(harness.statuses, ["connecting", "live"]);
});

test("socket messages use the public parser before emitting transcript events", () => {
  const harness = createHarness();
  harness.client.start();
  harness.sockets[0].open();

  harness.sockets[0].message(
    JSON.stringify({
      type: "transcript.interim",
      segment_id: "seg_001",
      text: "xin chào",
      language: "vi",
    }),
  );
  harness.sockets[0].message("not json");
  harness.sockets[0].message(JSON.stringify({ type: "stt.ready" }));

  assert.deepEqual(harness.events, [
    {
      type: "transcript.interim",
      segment_id: "seg_001",
      text: "xin chào",
      language: "vi",
    },
  ]);
});

test("viewer receives Translation configuration before any transcript and remains receive-only", () => {
  const harness = createHarness();
  harness.client.start();
  harness.sockets[0].open();
  const configured = {
    type: "translation.configured",
    stream_id: "stream_A",
    source_language: "vi",
    target_language: "ja",
  };

  harness.sockets[0].message(JSON.stringify(configured));

  assert.deepEqual(harness.translations, [configured]);
  assert.deepEqual(harness.events, []);
  assert.equal(typeof harness.sockets[0].send, "undefined");
});

test("viewer emits pending, final, and error Translation events through one normalized callback", () => {
  const harness = createHarness();
  harness.client.start();
  harness.sockets[0].open();
  const pending = {
    type: "translation.pending",
    stream_id: "stream_A",
    utterance_id: "utt_000001",
    source_segment_ids: ["seg_001"],
    source_text: "Xin chào.",
    source_language: "vi",
    target_language: "en",
  };
  const final = {
    ...pending,
    type: "translation.final",
    translated_text: "Hello.",
  };
  const failed = {
    ...pending,
    stream_id: "stream_B",
    type: "translation.error",
    scope: "utterance",
    code: "provider_error",
    message: "Translation failed.",
  };

  harness.sockets[0].message(JSON.stringify(pending));
  harness.sockets[0].message(JSON.stringify(final));
  harness.sockets[0].message(JSON.stringify(failed));
  harness.sockets[0].message(JSON.stringify({ type: "translation.future" }));

  assert.deepEqual(harness.translations, [pending, final, failed]);
});

test("repeated configuration snapshot is delivered safely for idempotent state reduction", () => {
  const harness = createHarness();
  harness.client.start();
  const configured = {
    type: "translation.configured",
    stream_id: "stream_A",
    source_language: "vi",
    target_language: "en",
  };

  harness.sockets[0].message(JSON.stringify(configured));
  harness.sockets[0].unexpectedClose();
  harness.scheduled[0].callback();
  harness.sockets[1].message(JSON.stringify(configured));

  assert.deepEqual(harness.translations, [configured, configured]);
});

test("unexpected close reconnects with capped exponential backoff", () => {
  const harness = createHarness();
  harness.client.start();

  harness.sockets[0].unexpectedClose();
  assert.deepEqual(harness.statuses, ["connecting", "reconnecting"]);
  assert.equal(harness.scheduled[0].delay, 1000);

  harness.scheduled[0].callback();
  assert.equal(harness.sockets.length, 2);
  harness.sockets[1].unexpectedClose();
  assert.equal(harness.scheduled[1].delay, 2000);

  harness.scheduled[1].callback();
  harness.sockets[2].unexpectedClose();
  harness.scheduled[2].callback();
  harness.sockets[3].unexpectedClose();
  harness.scheduled[3].callback();
  harness.sockets[4].unexpectedClose();
  assert.equal(harness.scheduled[4].delay, 8000);
});

test("socket error is user-safe and transitions into reconnecting on close", () => {
  const harness = createHarness();
  harness.client.start();

  harness.sockets[0].error();
  harness.sockets[0].unexpectedClose();

  assert.deepEqual(harness.statuses, [
    "connecting",
    "error",
    "reconnecting",
  ]);
});

test("stop closes the active socket without scheduling a reconnect", () => {
  const harness = createHarness();
  harness.client.start();

  harness.client.stop();

  assert.equal(harness.sockets[0].closeCalls, 1);
  assert.equal(harness.scheduled.length, 0);
  assert.deepEqual(harness.statuses, ["connecting", "disconnected"]);
});

test("stop cancels a pending reconnect and prevents its callback reconnecting", () => {
  const harness = createHarness();
  harness.client.start();
  harness.sockets[0].unexpectedClose();

  harness.client.stop();
  harness.scheduled[0].callback();

  assert.deepEqual(harness.cancelled, [harness.scheduled[0]]);
  assert.equal(harness.sockets.length, 1);
  assert.equal(harness.statuses.at(-1), "disconnected");
});
