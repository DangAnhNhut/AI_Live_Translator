import type { AudioInput } from "../audio/audio-input.ts";
import {
  MicrophoneAudioInputError,
} from "../audio/microphone-audio-input.ts";
import { SystemAudioInputError } from "../audio/system-audio-input.ts";

export type HostSessionState =
  | "ready"
  | "requesting_permission"
  | "connecting"
  | "live"
  | "stopping"
  | "error";

export type HostStatusContent = {
  label: string;
  detail: string;
};

export type AudioSourceType = "microphone" | "system";

export type HostAudioSelection = {
  selectedSource: AudioSourceType | null;
  locked: boolean;
};

export type HostAudioInputFactories = Record<
  AudioSourceType,
  () => AudioInput
>;

type Stoppable = {
  stop(): Promise<unknown>;
};

const HOST_STATUS_CONTENT: Record<HostSessionState, HostStatusContent> = {
  ready: {
    label: "Ready",
    detail: "Choose an audio source, then Start Session.",
  },
  requesting_permission: {
    label: "Choose audio",
    detail: "Complete the browser permission request for the selected source.",
  },
  connecting: {
    label: "Connecting",
    detail: "Preparing the live speech service.",
  },
  live: {
    label: "LIVE",
    detail: "The selected audio source is streaming to live captions.",
  },
  stopping: {
    label: "Stopping",
    detail: "Finishing the transcript and closing capture.",
  },
  error: {
    label: "Session error",
    detail: "The host session needs your attention.",
  },
};

export function getHostStatusContent(
  state: HostSessionState,
): HostStatusContent {
  return HOST_STATUS_CONTENT[state];
}

export function createHostAudioSelection(): HostAudioSelection {
  return { selectedSource: null, locked: false };
}

export function selectHostAudioSource(
  selection: HostAudioSelection,
  source: AudioSourceType,
): HostAudioSelection {
  if (selection.locked || selection.selectedSource === source) {
    return selection;
  }
  return { selectedSource: source, locked: false };
}

export function lockHostAudioSelection(
  selection: HostAudioSelection,
): HostAudioSelection {
  if (selection.locked || selection.selectedSource === null) {
    return selection;
  }
  return { ...selection, locked: true };
}

export function unlockHostAudioSelection(
  selection: HostAudioSelection,
): HostAudioSelection {
  return selection.locked ? { ...selection, locked: false } : selection;
}

export function canStartHostSession(
  state: HostSessionState,
  selection: HostAudioSelection,
): boolean {
  return (
    selection.selectedSource !== null &&
    !selection.locked &&
    (state === "ready" || state === "error")
  );
}

export function createHostAudioInput(
  source: AudioSourceType,
  factories: HostAudioInputFactories,
): AudioInput {
  return factories[source]();
}

export async function stopHostSession(
  input: Stoppable | null,
  producer: Stoppable | null,
): Promise<void> {
  try {
    await input?.stop();
  } catch {
    // Producer shutdown must still run after a browser cleanup failure.
  }
  try {
    await producer?.stop();
  } catch {
    // Both boundaries own idempotent cleanup; Host recovery still completes.
  }
}

export function getAudioInputErrorMessage(
  source: AudioSourceType,
  error: unknown,
): string {
  if (source === "microphone") {
    return getMicrophoneErrorMessage(error);
  }
  return getSystemAudioErrorMessage(error);
}

export function getSystemAudioErrorMessage(error: unknown): string {
  if (error instanceof SystemAudioInputError) {
    switch (error.code) {
      case "no_audio_track":
        return "The selected source did not provide audio. Select a tab or source with audio sharing enabled.";
      case "permission_denied":
        return "Audio sharing was cancelled or not allowed. Select Start Session to try again.";
      case "unsupported":
        return "System audio capture is not supported in this browser. Use a current desktop version of Chrome.";
      case "capture_failed":
        break;
    }
  }
  return "System audio capture could not start. Check the selected source and try again.";
}

function getMicrophoneErrorMessage(error: unknown): string {
  if (error instanceof MicrophoneAudioInputError) {
    switch (error.code) {
      case "no_audio_track":
        return "The selected microphone did not provide audio. Check browser access and try again.";
      case "permission_denied":
        return "Microphone access was cancelled or not allowed. Select Start Session to try again.";
      case "unsupported":
        return "Microphone capture is not supported in this browser. Use a current desktop browser.";
      case "capture_failed":
        break;
    }
  }
  return "Microphone capture could not start. Check browser access and try again.";
}
