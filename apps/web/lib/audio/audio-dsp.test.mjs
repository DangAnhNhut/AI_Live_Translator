import assert from "node:assert/strict";
import test from "node:test";

import {
  downmixToMono,
  float32ToPcm16Le,
  PcmChunkAccumulator,
} from "./pcm.ts";
import { StreamingLinearResampler } from "./streaming-resampler.ts";

function assertSamplesClose(actual, expected, tolerance = 1e-6) {
  assert.equal(actual.length, expected.length);
  for (let index = 0; index < actual.length; index += 1) {
    assert.ok(
      Math.abs(actual[index] - expected[index]) <= tolerance,
      `sample ${index}: expected ${expected[index]}, received ${actual[index]}`,
    );
  }
}

test("downmix averages every active channel into mono", () => {
  assertSamplesClose(
    downmixToMono([
      new Float32Array([1, 0]),
      new Float32Array([0, 1]),
    ]),
    new Float32Array([0.5, 0.5]),
  );
  assertSamplesClose(
    downmixToMono([
      new Float32Array([1, 0]),
      new Float32Array([0, 1]),
      new Float32Array([0.5, 0.5]),
    ]),
    new Float32Array([0.5, 0.5]),
  );
});

test("PCM16 conversion clamps boundaries and writes signed little-endian", () => {
  const encoded = float32ToPcm16Le(
    new Float32Array([-2, -1, -0.5, 0, 0.5, 1, 2]),
  );
  const view = new DataView(encoded);

  assert.deepEqual(
    Array.from({ length: 7 }, (_, index) => view.getInt16(index * 2, true)),
    [-32768, -32768, -16384, 0, 16383, 32767, 32767],
  );
  assert.deepEqual(Array.from(new Uint8Array(encoded).slice(2, 6)), [0, 128, 0, 192]);
});

test("identity resampling preserves every expected sample", () => {
  const input = new Float32Array([-1, -0.25, 0, 0.25, 1]);
  const resampler = new StreamingLinearResampler(16000, 16000);

  assertSamplesClose(resampler.process(input), input);
});

test("48000 to 16000 resampling produces a continuous one-third-rate signal", () => {
  const input = Float32Array.from({ length: 480 }, (_, index) => index / 480);
  const expected = Float32Array.from(
    { length: 160 },
    (_, index) => input[index * 3],
  );
  const resampler = new StreamingLinearResampler(48000, 16000);

  assertSamplesClose(resampler.process(input), expected);
});

test("44100 to 16000 resampling supports a non-integer ratio", () => {
  const input = Float32Array.from({ length: 441 }, (_, index) => index);
  const resampler = new StreamingLinearResampler(44100, 16000);
  const output = resampler.process(input);

  assert.equal(output.length, 160);
  assert.ok(Math.abs(output[1] - 2.75625) < 1e-5);
  assert.ok(Math.abs(output[159] - 438.24375) < 1e-4);
});

test("split input produces the same stream as one continuous input", () => {
  const input = Float32Array.from(
    { length: 1000 },
    (_, index) => Math.sin(index / 23),
  );
  const wholeResampler = new StreamingLinearResampler(44100, 16000);
  const splitResampler = new StreamingLinearResampler(44100, 16000);
  const whole = wholeResampler.process(input);
  const first = splitResampler.process(input.slice(0, 333));
  const second = splitResampler.process(input.slice(333));
  const split = new Float32Array(first.length + second.length);
  split.set(first);
  split.set(second, first.length);

  assertSamplesClose(split, whole);
});

test("reset removes fractional and boundary state", () => {
  const prefix = Float32Array.from({ length: 37 }, (_, index) => index / 37);
  const input = Float32Array.from({ length: 200 }, (_, index) => index / 200);
  const reused = new StreamingLinearResampler(44100, 16000);
  const fresh = new StreamingLinearResampler(44100, 16000);

  reused.process(prefix);
  reused.reset();

  assertSamplesClose(reused.process(input), fresh.process(input));
});

test("PCM accumulator emits bounded chunks and flushes the remainder once", () => {
  const accumulator = new PcmChunkAccumulator(8);

  assert.deepEqual(accumulator.push(Uint8Array.from([1, 2, 3, 4, 5]).buffer), []);
  const emitted = accumulator.push(Uint8Array.from([6, 7, 8, 9, 10]).buffer);

  assert.equal(emitted.length, 1);
  assert.deepEqual(Array.from(new Uint8Array(emitted[0])), [1, 2, 3, 4, 5, 6, 7, 8]);
  assert.deepEqual(Array.from(new Uint8Array(accumulator.flush())), [9, 10]);
  assert.equal(accumulator.flush(), null);
});
