import assert from "node:assert/strict";
import test from "node:test";

import {
  MicrophoneAudioInput,
  MicrophoneAudioInputError,
} from "./microphone-audio-input.ts";

class FakeTrack {
  listeners = new Set();
  stopCalls = 0;

  constructor(channelCount = 1, stopEmitsEnded = false) {
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
    return { channelCount: this.channelCount };
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
  disconnectCalls = 0;
  connect() {}
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
}

class FakeAudioContext {
  sampleRate = 48000;
  state = "suspended";
  closeCalls = 0;
  source = new FakeSourceNode();
  audioWorklet = { addModule: async () => {} };

  createMediaStreamSource() {
    return this.source;
  }

  async resume() {
    this.state = "running";
  }

  async close() {
    this.closeCalls += 1;
    this.state = "closed";
  }
}

function createRealPipelineHarness({ audioTracks, otherTracks = [] } = {}) {
  const audio = audioTracks ?? [new FakeTrack(1)];
  const stream = new FakeStream(audio, otherTracks);
  const context = new FakeAudioContext();
  const worklet = new FakeWorkletNode();
  const constraints = [];
  const input = new MicrophoneAudioInput({
    getUserMedia: async (options) => {
      constraints.push(options);
      return stream;
    },
    createAudioContext: () => context,
    createWorkletNode: () => worklet,
  });
  return { input, stream, context, worklet, constraints, audioTracks: audio };
}

test("microphone start requests audio only after start is called", async () => {
  const constraints = [];
  const stream = new FakeStream([new FakeTrack()]);
  let pipelineStartCalls = 0;
  const input = new MicrophoneAudioInput({
    getUserMedia: async (options) => {
      constraints.push(options);
      return stream;
    },
    createPipeline: (receivedStream) => ({
      start: async () => {
        pipelineStartCalls += 1;
        assert.strictEqual(receivedStream, stream);
        return {
          captureSampleRate: 48000,
          targetSampleRate: 16000,
          channelCount: 1,
        };
      },
      stop: async () => {},
    }),
  });

  assert.deepEqual(constraints, []);
  const info = await input.start({ onPcmChunk: () => {}, onEnded: () => {} });

  assert.deepEqual(constraints, [{ audio: true, video: false }]);
  assert.equal(pipelineStartCalls, 1);
  assert.equal(info.targetSampleRate, 16000);
});

test("microphone permission rejection becomes a controlled failure", async () => {
  const denied = new Error("raw browser permission detail");
  denied.name = "NotAllowedError";
  const input = new MicrophoneAudioInput({
    getUserMedia: async () => {
      throw denied;
    },
  });

  await assert.rejects(
    input.start({ onPcmChunk: () => {}, onEnded: () => {} }),
    (error) =>
      error instanceof MicrophoneAudioInputError &&
      error.code === "permission_denied" &&
      !error.message.includes("raw browser permission detail"),
  );
});

test("a microphone stream without audio is rejected and cleaned up", async () => {
  const nonAudioTrack = new FakeTrack();
  const harness = createRealPipelineHarness({
    audioTracks: [],
    otherTracks: [nonAudioTrack],
  });

  await assert.rejects(
    harness.input.start({ onPcmChunk: () => {}, onEnded: () => {} }),
    (error) =>
      error instanceof MicrophoneAudioInputError &&
      error.code === "no_audio_track",
  );
  assert.equal(nonAudioTrack.stopCalls, 1);
  assert.equal(harness.context.closeCalls, 0);
});

test("microphone track ended triggers shared ended handling", async () => {
  const audio = new FakeTrack(1);
  const harness = createRealPipelineHarness({ audioTracks: [audio] });
  let endedCalls = 0;
  let resolveEnded;
  const ended = new Promise((resolve) => {
    resolveEnded = resolve;
  });
  await harness.input.start({
    onPcmChunk: () => {},
    onEnded: () => {
      endedCalls += 1;
      resolveEnded();
    },
  });

  audio.emitEnded();
  await ended;

  assert.equal(endedCalls, 1);
  assert.equal(audio.stopCalls, 1);
  assert.equal(harness.context.closeCalls, 1);
});

test("microphone stop releases tracks and processing resources", async () => {
  const audio = new FakeTrack(1);
  const harness = createRealPipelineHarness({ audioTracks: [audio] });
  await harness.input.start({ onPcmChunk: () => {}, onEnded: () => {} });

  await harness.input.stop();

  assert.equal(audio.stopCalls, 1);
  assert.equal(harness.context.source.disconnectCalls, 1);
  assert.equal(harness.worklet.disconnectCalls, 1);
  assert.equal(harness.worklet.port.onmessage, null);
  assert.equal(harness.context.closeCalls, 1);
});

test("repeated microphone stop is safe even when track stop emits ended", async () => {
  const audio = new FakeTrack(1, true);
  const harness = createRealPipelineHarness({ audioTracks: [audio] });
  let endedCalls = 0;
  await harness.input.start({
    onPcmChunk: () => {},
    onEnded: () => {
      endedCalls += 1;
    },
  });

  await Promise.all([harness.input.stop(), harness.input.stop()]);
  await harness.input.stop();

  assert.equal(audio.stopCalls, 1);
  assert.equal(endedCalls, 0);
  assert.equal(harness.context.closeCalls, 1);
});

test("microphone AudioContext setup failure is sanitized and stops tracks", async () => {
  const audio = new FakeTrack(1);
  const stream = new FakeStream([audio]);
  const input = new MicrophoneAudioInput({
    getUserMedia: async () => stream,
    createAudioContext: () => {
      throw new Error("raw audio context detail");
    },
  });

  await assert.rejects(
    input.start({ onPcmChunk: () => {}, onEnded: () => {} }),
    (error) =>
      error instanceof MicrophoneAudioInputError &&
      error.code === "capture_failed" &&
      !error.message.includes("raw audio context detail"),
  );
  assert.equal(audio.stopCalls, 1);
});
