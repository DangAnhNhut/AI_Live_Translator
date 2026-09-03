import assert from "node:assert/strict";
import test from "node:test";

import {
  SystemAudioInput,
  SystemAudioInputError,
} from "./system-audio-input.ts";

class FakeTrack {
  listeners = new Set();
  stopCalls = 0;

  constructor(kind, channelCount = undefined, stopEmitsEnded = false) {
    this.kind = kind;
    this.channelCount = channelCount;
    this.stopEmitsEnded = stopEmitsEnded;
  }

  addEventListener(type, listener) {
    if (type === "ended") this.listeners.add(listener);
  }

  removeEventListener(type, listener) {
    if (type === "ended") this.listeners.delete(listener);
  }

  getSettings() {
    return this.channelCount === undefined
      ? {}
      : { channelCount: this.channelCount };
  }

  stop() {
    this.stopCalls += 1;
    if (this.stopEmitsEnded) this.emitEnded();
  }

  emitEnded() {
    for (const listener of [...this.listeners]) listener({ type: "ended" });
  }
}

class FakeStream {
  constructor(audioTracks, otherTracks = []) {
    this.audioTracks = audioTracks;
    this.tracks = [...audioTracks, ...otherTracks];
  }

  getAudioTracks() {
    return this.audioTracks;
  }

  getTracks() {
    return this.tracks;
  }
}

class FakeSourceNode {
  connectCalls = [];
  disconnectCalls = 0;

  connect(node) {
    this.connectCalls.push(node);
    return node;
  }

  disconnect() {
    this.disconnectCalls += 1;
  }
}

class FakeWorkletNode {
  disconnectCalls = 0;
  port = {
    onmessage: null,
  };

  disconnect() {
    this.disconnectCalls += 1;
  }

  emitChannels(channels) {
    this.port.onmessage?.({ data: { channels } });
  }
}

class FakeAudioContext {
  state = "suspended";
  resumeCalls = 0;
  closeCalls = 0;
  addedModules = [];
  source = new FakeSourceNode();
  audioWorklet = {
    addModule: async (url) => {
      this.addedModules.push(url);
    },
  };

  constructor(sampleRate = 48000) {
    this.sampleRate = sampleRate;
  }

  createMediaStreamSource(stream) {
    this.createdFrom = stream;
    return this.source;
  }

  async resume() {
    this.resumeCalls += 1;
    this.state = "running";
  }

  async close() {
    this.closeCalls += 1;
    this.state = "closed";
  }
}

function createHarness({
  audioTracks = [new FakeTrack("audio", 2)],
  otherTracks = [new FakeTrack("video")],
  sampleRate = 48000,
} = {}) {
  const stream = new FakeStream(audioTracks, otherTracks);
  const context = new FakeAudioContext(sampleRate);
  const worklet = new FakeWorkletNode();
  const constraints = [];
  let contextFactoryCalls = 0;
  const input = new SystemAudioInput({
    getDisplayMedia: async (options) => {
      constraints.push(options);
      return stream;
    },
    createAudioContext: () => {
      contextFactoryCalls += 1;
      return context;
    },
    createWorkletNode: () => worklet,
  });

  return {
    input,
    stream,
    context,
    worklet,
    constraints,
    get contextFactoryCalls() {
      return contextFactoryCalls;
    },
  };
}

test("audio-enabled display capture emits bounded PCM and reports capture metadata", async () => {
  const harness = createHarness();
  const chunks = [];
  const capture = await harness.input.start({
    onPcmChunk: (chunk) => chunks.push(chunk),
    onEnded: () => assert.fail("capture must not end during startup"),
  });

  assert.deepEqual(harness.constraints, [{ video: true, audio: true }]);
  assert.deepEqual(capture, {
    captureSampleRate: 48000,
    targetSampleRate: 16000,
    channelCount: 2,
  });
  assert.deepEqual(harness.context.addedModules, [
    "/worklets/pcm-capture-processor.js",
  ]);
  assert.equal(harness.context.resumeCalls, 1);
  assert.deepEqual(harness.context.source.connectCalls, [harness.worklet]);

  harness.worklet.emitChannels([
    new Float32Array(960).fill(1),
    new Float32Array(960).fill(-1),
  ]);

  assert.equal(chunks.length, 1);
  assert.equal(chunks[0] instanceof ArrayBuffer, true);
  assert.equal(chunks[0].byteLength, 640);
  assert.equal(new Uint8Array(chunks[0]).every((byte) => byte === 0), true);

  await harness.input.stop();
});

test("a selected source without audio fails safely and stops every track", async () => {
  const video = new FakeTrack("video");
  const harness = createHarness({ audioTracks: [], otherTracks: [video] });

  await assert.rejects(
    harness.input.start({ onPcmChunk: () => {}, onEnded: () => {} }),
    (error) =>
      error instanceof SystemAudioInputError && error.code === "no_audio_track",
  );

  assert.equal(video.stopCalls, 1);
  assert.equal(harness.contextFactoryCalls, 0);
});

test("native track ended flushes once, cleans resources, and notifies once", async () => {
  const audio = new FakeTrack("audio", 2);
  const video = new FakeTrack("video");
  const harness = createHarness({ audioTracks: [audio], otherTracks: [video] });
  const chunks = [];
  let endedCalls = 0;
  let resolveEnded;
  const ended = new Promise((resolve) => {
    resolveEnded = resolve;
  });
  await harness.input.start({
    onPcmChunk: (chunk) => chunks.push(chunk),
    onEnded: () => {
      endedCalls += 1;
      resolveEnded();
    },
  });
  harness.worklet.emitChannels([
    new Float32Array(300).fill(0.25),
    new Float32Array(300).fill(0.25),
  ]);

  audio.emitEnded();
  await ended;
  video.emitEnded();
  await Promise.resolve();

  assert.equal(endedCalls, 1);
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].byteLength, 200);
  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);
  assert.equal(harness.worklet.port.onmessage, null);
  assert.equal(harness.context.closeCalls, 1);
});

test("repeated deliberate stop is idempotent and cannot race track ended", async () => {
  const audio = new FakeTrack("audio", 2, true);
  const video = new FakeTrack("video", undefined, true);
  const harness = createHarness({ audioTracks: [audio], otherTracks: [video] });
  const chunks = [];
  let endedCalls = 0;
  await harness.input.start({
    onPcmChunk: (chunk) => chunks.push(chunk),
    onEnded: () => {
      endedCalls += 1;
    },
  });
  harness.worklet.emitChannels([
    new Float32Array(300).fill(0.5),
    new Float32Array(300).fill(0.5),
  ]);

  await Promise.all([harness.input.stop(), harness.input.stop()]);

  assert.equal(endedCalls, 0);
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].byteLength, 200);
  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(harness.context.closeCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);

  await harness.input.stop();
  assert.equal(harness.context.closeCalls, 1);
});

test("stop while the share picker is pending rejects and cleans a late stream", async () => {
  const audio = new FakeTrack("audio", 2);
  const video = new FakeTrack("video");
  const stream = new FakeStream([audio], [video]);
  let resolveDisplayMedia;
  const pendingDisplayMedia = new Promise((resolve) => {
    resolveDisplayMedia = resolve;
  });
  let contextFactoryCalls = 0;
  const input = new SystemAudioInput({
    getDisplayMedia: () => pendingDisplayMedia,
    createAudioContext: () => {
      contextFactoryCalls += 1;
      return new FakeAudioContext();
    },
    createWorkletNode: () => new FakeWorkletNode(),
  });
  const started = input.start({ onPcmChunk: () => {}, onEnded: () => {} });

  await input.stop();
  resolveDisplayMedia(stream);

  await assert.rejects(
    started,
    (error) =>
      error instanceof SystemAudioInputError && error.code === "capture_failed",
  );
  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(contextFactoryCalls, 0);
});

test("a browser AudioContext close failure cannot abort the remaining cleanup", async () => {
  const audio = new FakeTrack("audio", 2);
  const video = new FakeTrack("video");
  const harness = createHarness({ audioTracks: [audio], otherTracks: [video] });
  await harness.input.start({ onPcmChunk: () => {}, onEnded: () => {} });
  harness.context.close = async () => {
    harness.context.closeCalls += 1;
    throw new Error("browser close failure");
  };

  await assert.doesNotReject(harness.input.stop());

  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);
  assert.equal(harness.worklet.port.onmessage, null);
  assert.equal(harness.context.closeCalls, 1);
  await assert.doesNotReject(harness.input.stop());
});
