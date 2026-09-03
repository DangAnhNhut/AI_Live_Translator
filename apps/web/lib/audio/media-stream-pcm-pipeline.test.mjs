import assert from "node:assert/strict";
import test from "node:test";

import {
  MediaStreamPcmPipeline,
  MediaStreamPcmPipelineError,
} from "./media-stream-pcm-pipeline.ts";

class FakeTrack {
  listeners = new Set();
  stopCalls = 0;

  constructor(channelCount = undefined, stopEmitsEnded = false) {
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
  port = { onmessage: null };

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

function createHarness({ audioTracks, otherTracks = [] } = {}) {
  const audio = audioTracks ?? [new FakeTrack(2)];
  const stream = new FakeStream(audio, otherTracks);
  const context = new FakeAudioContext();
  const worklet = new FakeWorkletNode();
  const pipeline = new MediaStreamPcmPipeline(stream, {
    createAudioContext: () => context,
    createWorkletNode: () => worklet,
  });
  return { pipeline, stream, context, worklet, audioTracks: audio, otherTracks };
}

test("an acquired media stream reaches the shared PCM pipeline", async () => {
  const harness = createHarness();
  const chunks = [];
  const info = await harness.pipeline.start({
    onPcmChunk: (chunk) => chunks.push(chunk),
    onEnded: () => assert.fail("capture must remain active"),
  });

  assert.deepEqual(info, {
    captureSampleRate: 48000,
    targetSampleRate: 16000,
    channelCount: 2,
  });
  assert.deepEqual(harness.context.addedModules, [
    "/worklets/pcm-capture-processor.js",
  ]);
  assert.deepEqual(harness.context.source.connectCalls, [harness.worklet]);

  harness.worklet.emitChannels([
    new Float32Array(960).fill(1),
    new Float32Array(960).fill(-1),
  ]);

  assert.equal(chunks.length, 1);
  assert.equal(chunks[0] instanceof ArrayBuffer, true);
  assert.equal(chunks[0].byteLength, 640);
  assert.equal(new Uint8Array(chunks[0]).every((byte) => byte === 0), true);
  await harness.pipeline.stop();
});

test("a media stream without audio is rejected and every track is stopped", async () => {
  const video = new FakeTrack();
  const harness = createHarness({ audioTracks: [], otherTracks: [video] });

  await assert.rejects(
    harness.pipeline.start({ onPcmChunk: () => {}, onEnded: () => {} }),
    (error) =>
      error instanceof MediaStreamPcmPipelineError &&
      error.code === "no_audio_track",
  );
  assert.equal(video.stopCalls, 1);
});

test("an audio track ending flushes once and notifies after shared cleanup", async () => {
  const audio = new FakeTrack(1);
  const video = new FakeTrack();
  const harness = createHarness({ audioTracks: [audio], otherTracks: [video] });
  const chunks = [];
  let endedCalls = 0;
  let resolveEnded;
  const ended = new Promise((resolve) => {
    resolveEnded = resolve;
  });
  await harness.pipeline.start({
    onPcmChunk: (chunk) => chunks.push(chunk),
    onEnded: () => {
      endedCalls += 1;
      resolveEnded();
    },
  });
  harness.worklet.emitChannels([new Float32Array(300).fill(0.25)]);

  audio.emitEnded();
  await ended;
  video.emitEnded();

  assert.equal(endedCalls, 1);
  assert.equal(chunks.length, 1);
  assert.equal(chunks[0].byteLength, 200);
  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(harness.context.closeCalls, 1);
});

test("shared pipeline stop is idempotent and detaches every resource", async () => {
  const audio = new FakeTrack(2, true);
  const video = new FakeTrack(undefined, true);
  const harness = createHarness({ audioTracks: [audio], otherTracks: [video] });
  let endedCalls = 0;
  await harness.pipeline.start({
    onPcmChunk: () => {},
    onEnded: () => {
      endedCalls += 1;
    },
  });

  await Promise.all([harness.pipeline.stop(), harness.pipeline.stop()]);
  await harness.pipeline.stop();

  assert.equal(endedCalls, 0);
  assert.equal(audio.stopCalls, 1);
  assert.equal(video.stopCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);
  assert.equal(harness.worklet.port.onmessage, null);
  assert.equal(harness.context.closeCalls, 1);
});

test("an AudioContext close rejection cannot abort shared cleanup", async () => {
  const harness = createHarness();
  harness.context.close = async () => {
    harness.context.closeCalls += 1;
    throw new Error("browser close failure");
  };
  await harness.pipeline.start({ onPcmChunk: () => {}, onEnded: () => {} });

  await assert.doesNotReject(harness.pipeline.stop());
  await assert.doesNotReject(harness.pipeline.stop());

  assert.equal(harness.audioTracks[0].stopCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);
  assert.equal(harness.context.closeCalls, 1);
});
