import assert from "node:assert/strict";
import test from "node:test";

import { MicrophoneAudioInputError } from "../audio/microphone-audio-input.ts";
import { SystemAudioInputError } from "../audio/system-audio-input.ts";
import {
  canStartHostSession,
  createHostAudioInput,
  createHostAudioSelection,
  getAudioInputErrorMessage,
  getHostStatusContent,
  getSystemAudioErrorMessage,
  lockHostAudioSelection,
  selectHostAudioSource,
  stopHostSession,
  unlockHostAudioSelection,
} from "./host-session.ts";

test("every approved host state has explicit accessible status content", () => {
  const expected = {
    ready: ["Ready", "Choose an audio source, then Start Session."],
    requesting_permission: [
      "Choose audio",
      "Complete the browser permission request for the selected source.",
    ],
    connecting: ["Connecting", "Preparing the live speech service."],
    live: ["LIVE", "The selected audio source is streaming to live captions."],
    stopping: ["Stopping", "Finishing the transcript and closing capture."],
    error: ["Session error", "The host session needs your attention."],
  };

  for (const [state, content] of Object.entries(expected)) {
    const actual = getHostStatusContent(state);
    assert.deepEqual([actual.label, actual.detail], content);
  }
});

test("capture errors become controlled messages without raw exception text", () => {
  assert.equal(
    getSystemAudioErrorMessage(
      new SystemAudioInputError("no_audio_track", "raw detail"),
    ),
    "The selected source did not provide audio. Select a tab or source with audio sharing enabled.",
  );
  assert.equal(
    getSystemAudioErrorMessage(
      new SystemAudioInputError("permission_denied", "raw detail"),
    ),
    "Audio sharing was cancelled or not allowed. Select Start Session to try again.",
  );
  assert.equal(
    getSystemAudioErrorMessage(new Error("secret browser detail")),
    "System audio capture could not start. Check the selected source and try again.",
  );
});

test("audio source selection starts empty and cannot start", () => {
  const selection = createHostAudioSelection();

  assert.deepEqual(selection, { selectedSource: null, locked: false });
  assert.equal(canStartHostSession("ready", selection), false);
});

test("microphone can be explicitly selected and permits Start while ready", () => {
  const selection = selectHostAudioSource(
    createHostAudioSelection(),
    "microphone",
  );

  assert.deepEqual(selection, {
    selectedSource: "microphone",
    locked: false,
  });
  assert.equal(canStartHostSession("ready", selection), true);
});

test("System Audio can be explicitly selected", () => {
  const selection = selectHostAudioSource(
    createHostAudioSelection(),
    "system",
  );

  assert.equal(selection.selectedSource, "system");
  assert.equal(canStartHostSession("ready", selection), true);
});

test("the correct AudioInput factory is chosen for each source", () => {
  const microphone = { source: "microphone" };
  const system = { source: "system" };
  const factories = {
    microphone: () => microphone,
    system: () => system,
  };

  assert.strictEqual(createHostAudioInput("microphone", factories), microphone);
  assert.strictEqual(createHostAudioInput("system", factories), system);
});

test("source changes are blocked while selection is locked", () => {
  const selected = selectHostAudioSource(
    createHostAudioSelection(),
    "microphone",
  );
  const locked = lockHostAudioSelection(selected);

  assert.strictEqual(selectHostAudioSource(locked, "system"), locked);
  assert.equal(canStartHostSession("live", locked), false);
});

test("Host stop cleans input before producer", async () => {
  const calls = [];
  const input = { stop: async () => calls.push("input") };
  const producer = { stop: async () => calls.push("producer") };

  await stopHostSession(input, producer);

  assert.deepEqual(calls, ["input", "producer"]);
});

test("Host stop still cleans producer if input cleanup fails", async () => {
  const calls = [];
  const input = {
    stop: async () => {
      calls.push("input");
      throw new Error("browser cleanup failure");
    },
  };
  const producer = { stop: async () => calls.push("producer") };

  await assert.doesNotReject(stopHostSession(input, producer));
  assert.deepEqual(calls, ["input", "producer"]);
});

test("unlock after Stop retains the selected source", () => {
  const selected = selectHostAudioSource(
    createHostAudioSelection(),
    "system",
  );
  const unlocked = unlockHostAudioSelection(lockHostAudioSelection(selected));

  assert.deepEqual(unlocked, { selectedSource: "system", locked: false });
  assert.equal(canStartHostSession("ready", unlocked), true);
});

test("microphone failures become controlled retryable Host errors", () => {
  const selection = selectHostAudioSource(
    createHostAudioSelection(),
    "microphone",
  );
  const message = getAudioInputErrorMessage(
    "microphone",
    new MicrophoneAudioInputError("permission_denied", "raw detail"),
  );

  assert.equal(
    message,
    "Microphone access was cancelled or not allowed. Select Start Session to try again.",
  );
  assert.equal(message.includes("raw detail"), false);
  assert.equal(canStartHostSession("error", selection), true);
});
