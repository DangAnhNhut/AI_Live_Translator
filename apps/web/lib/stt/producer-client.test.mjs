import assert from "node:assert/strict";
import test from "node:test";

import {
  buildProducerWebSocketUrl,
  SttProducerClient,
} from "./producer-client.ts";

class FakeSocket {
  onopen = null;
  onmessage = null;
  onerror = null;
  onclose = null;
  readyState = 0;
  sent = [];
  closeCalls = 0;

  send(data) {
    this.sent.push(data);
  }

  close() {
    this.closeCalls += 1;
    this.readyState = 3;
  }

  open() {
    this.readyState = 1;
    this.onopen?.({});
  }

  message(value) {
    this.onmessage?.({ data: value });
  }

  unexpectedClose() {
    this.readyState = 3;
    this.onclose?.({ code: 1006, wasClean: false });
  }
}

function createHarness(options = {}) {
  const sockets = [];
  const statuses = [];
  const transcripts = [];
  const errors = [];
  const translations = [];
  const scheduled = [];
  const cancelled = [];
  const client = new SttProducerClient({
    url: "ws://127.0.0.1:8000/ws/stt",
    sessionId: "demo-001",
    translation: options.translation,
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
    onTranscript: (event) => transcripts.push(event),
    onTranslation: (event) => translations.push(event),
    onError: (message) => errors.push(message),
  });

  return {
    client,
    sockets,
    statuses,
    transcripts,
    errors,
    translations,
    scheduled,
    cancelled,
  };
}

async function startReady(harness) {
  const started = harness.client.start();
  const socket = harness.sockets[0];
  socket.open();
  socket.message(JSON.stringify({ type: "stt.ready" }));
  await started;
  return socket;
}

test("producer URL uses the shared WebSocket base contract", () => {
  assert.equal(
    buildProducerWebSocketUrl("wss://api.example.com/"),
    "wss://api.example.com/ws/stt",
  );
  assert.equal(
    buildProducerWebSocketUrl(undefined),
    "ws://127.0.0.1:8000/ws/stt",
  );
  assert.throws(
    () => buildProducerWebSocketUrl("https://api.example.com"),
    /WebSocket base URL/,
  );
});

test("open sends the exact start contract and waits for stt.ready", async () => {
  const harness = createHarness();
  let resolved = false;
  const started = harness.client.start().then(() => {
    resolved = true;
  });
  const socket = harness.sockets[0];

  assert.deepEqual(harness.statuses, ["connecting"]);
  socket.open();
  assert.deepEqual(JSON.parse(socket.sent[0]), {
    type: "stt.start",
    session_id: "demo-001",
    audio: {
      encoding: "pcm_s16le",
      sample_rate_hz: 16000,
      channels: 1,
    },
    language: "vi",
  });
  assert.equal(resolved, false);

  socket.message(JSON.stringify({ type: "stt.ready" }));
  await started;
  assert.equal(resolved, true);
  assert.deepEqual(harness.statuses, ["connecting", "live"]);
});

test("open includes optional Translation target while STT-only remains omittable", () => {
  const harness = createHarness({
    translation: { targetLanguage: "en" },
  });
  harness.client.start();
  const socket = harness.sockets[0];
  socket.open();

  assert.deepEqual(JSON.parse(socket.sent[0]).translation, {
    target_language: "en",
  });

  const sttOnly = createHarness();
  sttOnly.client.start();
  sttOnly.sockets[0].open();
  assert.equal("translation" in JSON.parse(sttOnly.sockets[0].sent[0]), false);
});

test("binary PCM is rejected before ready and sent as ArrayBuffer after ready", async () => {
  const harness = createHarness();
  const started = harness.client.start();
  const socket = harness.sockets[0];
  socket.open();
  const pcm = Uint8Array.from([0, 128, 255, 127]).buffer;

  assert.equal(harness.client.sendPcmChunk(pcm), false);
  assert.equal(socket.sent.length, 1);

  socket.message(JSON.stringify({ type: "stt.ready" }));
  await started;
  assert.equal(harness.client.sendPcmChunk(pcm), true);
  assert.equal(socket.sent[1], pcm);
  assert.deepEqual(harness.client.getDiagnostics(), {
    chunksSent: 1,
    pcmBytesSent: 4,
  });
});

test("producer emits normalized interim and final transcripts only", async () => {
  const harness = createHarness();
  const socket = await startReady(harness);
  const interim = {
    type: "transcript.interim",
    segment_id: "seg_001",
    text: "xin chao",
    language: "vi",
  };
  const final = { ...interim, type: "transcript.final", text: "Xin chao." };

  socket.message(JSON.stringify(interim));
  socket.message("not-json");
  socket.message(JSON.stringify({ type: "unknown" }));
  socket.message(JSON.stringify(final));

  assert.deepEqual(harness.transcripts, [interim, final]);
});

test("producer emits normalized Translation events without turning Translation errors into STT errors", async () => {
  const harness = createHarness({ translation: { targetLanguage: "en" } });
  const socket = await startReady(harness);
  const configured = {
    type: "translation.configured",
    stream_id: "stream_A",
    source_language: "vi",
    target_language: "en",
  };
  const sessionError = {
    type: "translation.error",
    scope: "session",
    stream_id: "stream_A",
    source_language: "vi",
    target_language: "en",
    code: "provider_unavailable",
    message: "Translation is unavailable.",
  };

  socket.message(JSON.stringify(configured));
  socket.message(JSON.stringify(sessionError));
  socket.message(
    JSON.stringify({
      type: "transcript.final",
      stream_id: "stream_A",
      segment_id: "seg_001",
      text: "Original continues.",
      language: "vi",
    }),
  );

  assert.deepEqual(harness.translations, [configured, sessionError]);
  assert.equal(harness.transcripts.at(-1).text, "Original continues.");
  assert.deepEqual(harness.errors, []);
  assert.equal(harness.statuses.at(-1), "live");
});

test("queue overflow stays an utterance Translation event", async () => {
  const harness = createHarness({ translation: { targetLanguage: "en" } });
  const socket = await startReady(harness);
  const overflow = {
    type: "translation.error",
    scope: "utterance",
    stream_id: "stream_A",
    utterance_id: "utt_000001",
    source_segment_ids: ["seg_001"],
    source_text: "Original remains.",
    source_language: "vi",
    target_language: "en",
    code: "queue_overflow",
    message: "Translation queue is full.",
  };

  socket.message(JSON.stringify(overflow));

  assert.deepEqual(harness.translations, [overflow]);
  assert.equal(harness.statuses.at(-1), "live");
  assert.deepEqual(harness.errors, []);
});

test("stop sends one control message, drains a final, then closes on stt.closed", async () => {
  const harness = createHarness();
  const socket = await startReady(harness);

  const firstStop = harness.client.stop();
  const secondStop = harness.client.stop();
  assert.deepEqual(harness.statuses, ["connecting", "live", "stopping"]);
  assert.deepEqual(
    socket.sent.filter((message) => typeof message === "string").map(JSON.parse),
    [
      {
        type: "stt.start",
        session_id: "demo-001",
        audio: {
          encoding: "pcm_s16le",
          sample_rate_hz: 16000,
          channels: 1,
        },
        language: "vi",
      },
      { type: "stt.stop" },
    ],
  );

  socket.message(
    JSON.stringify({
      type: "transcript.final",
      segment_id: "seg_001",
      text: "Final after stop.",
      language: "vi",
    }),
  );
  socket.message(JSON.stringify({ type: "stt.closed" }));
  await Promise.all([firstStop, secondStop]);

  assert.equal(harness.transcripts.at(-1).text, "Final after stop.");
  assert.equal(socket.closeCalls, 1);
  assert.equal(harness.statuses.at(-1), "disconnected");

  await harness.client.stop();
  assert.equal(socket.closeCalls, 1);
});

test("clean Stop leaves delivery margin beyond the Backend drain deadline", async () => {
  const harness = createHarness();
  await startReady(harness);

  const stopped = harness.client.stop();
  const stopDeadline = harness.scheduled.at(-1);

  assert.ok(stopDeadline.delay > 5000);

  harness.sockets[0].message(JSON.stringify({ type: "stt.closed" }));
  await stopped;
});

test("stop before ready closes directly without sending stt.stop", async () => {
  const harness = createHarness();
  const started = harness.client.start();
  const socket = harness.sockets[0];
  socket.open();

  await harness.client.stop();

  assert.equal(socket.closeCalls, 1);
  assert.equal(
    socket.sent.filter((message) => message === JSON.stringify({ type: "stt.stop" })).length,
    0,
  );
  await assert.rejects(started, /stopped before it became ready/i);
});

test("unexpected close reports a sanitized error and never reconnects", async () => {
  const harness = createHarness();
  const socket = await startReady(harness);

  socket.unexpectedClose();

  assert.equal(harness.statuses.at(-1), "error");
  assert.deepEqual(harness.errors, [
    "The speech connection ended unexpectedly. Start the session again.",
  ]);
  assert.equal(harness.sockets.length, 1);
  assert.equal(harness.scheduled.length, 1);
});
