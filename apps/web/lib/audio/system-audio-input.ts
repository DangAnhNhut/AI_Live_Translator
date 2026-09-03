import type {
  AudioCaptureInfo,
  AudioInput,
  AudioInputCallbacks,
} from "./audio-input.ts";
import {
  MediaStreamPcmPipeline,
  MediaStreamPcmPipelineError,
  type AudioContextLike,
  type MediaStreamLike,
  type MediaStreamPcmPipelineLike,
  type WorkletNodeLike,
} from "./media-stream-pcm-pipeline.ts";

export type SystemAudioInputErrorCode =
  | "unsupported"
  | "permission_denied"
  | "no_audio_track"
  | "capture_failed";

export class SystemAudioInputError extends Error {
  readonly code: SystemAudioInputErrorCode;

  constructor(code: SystemAudioInputErrorCode, message: string) {
    super(message);
    this.name = "SystemAudioInputError";
    this.code = code;
  }
}

type SystemAudioInputDependencies = {
  getDisplayMedia: (
    options: DisplayMediaStreamOptions,
  ) => Promise<MediaStreamLike>;
  createAudioContext: () => AudioContextLike;
  createWorkletNode: (context: AudioContextLike) => WorkletNodeLike;
  createPipeline: (stream: MediaStreamLike) => MediaStreamPcmPipelineLike;
};

export class SystemAudioInput implements AudioInput {
  private readonly getDisplayMedia: SystemAudioInputDependencies["getDisplayMedia"];
  private readonly createPipeline: SystemAudioInputDependencies["createPipeline"];
  private pipeline: MediaStreamPcmPipelineLike | null = null;
  private startInProgress = false;
  private stopRequested = false;

  constructor(dependencies?: Partial<SystemAudioInputDependencies>) {
    this.getDisplayMedia =
      dependencies?.getDisplayMedia ?? defaultGetDisplayMedia;
    this.createPipeline =
      dependencies?.createPipeline ??
      ((stream) =>
        new MediaStreamPcmPipeline(stream, {
          createAudioContext: dependencies?.createAudioContext,
          createWorkletNode: dependencies?.createWorkletNode,
        }));
  }

  async start(callbacks: AudioInputCallbacks): Promise<AudioCaptureInfo> {
    if (this.startInProgress || this.pipeline !== null) {
      throw new SystemAudioInputError(
        "capture_failed",
        "System audio capture is already active.",
      );
    }

    this.startInProgress = true;
    this.stopRequested = false;
    let stream: MediaStreamLike | null = null;

    try {
      stream = await this.getDisplayMedia({ video: true, audio: true });
      if (this.stopRequested) {
        stopStreamTracks(stream);
        stream = null;
        throw new SystemAudioInputError(
          "capture_failed",
          "System audio capture was stopped before it started.",
        );
      }

      const pipeline = this.createPipeline(stream);
      this.pipeline = pipeline;
      const info = await pipeline.start(callbacks);
      if (this.stopRequested) {
        await pipeline.stop();
        throw new SystemAudioInputError(
          "capture_failed",
          "System audio capture was stopped before it started.",
        );
      }
      this.startInProgress = false;
      return info;
    } catch (error) {
      if (this.pipeline !== null) {
        await this.pipeline.stop();
      } else if (stream !== null) {
        stopStreamTracks(stream);
      }
      this.startInProgress = false;
      throw normalizeSystemAudioError(error);
    }
  }

  stop(): Promise<void> {
    if (this.startInProgress) {
      this.stopRequested = true;
    }
    return this.pipeline?.stop() ?? Promise.resolve();
  }
}

async function defaultGetDisplayMedia(
  options: DisplayMediaStreamOptions,
): Promise<MediaStreamLike> {
  if (
    typeof navigator === "undefined" ||
    navigator.mediaDevices?.getDisplayMedia === undefined
  ) {
    throw new SystemAudioInputError(
      "unsupported",
      "System audio capture is not supported in this browser.",
    );
  }
  const stream = await navigator.mediaDevices.getDisplayMedia(options);
  return stream as unknown as MediaStreamLike;
}

function stopStreamTracks(stream: MediaStreamLike): void {
  for (const track of stream.getTracks()) {
    track.stop();
  }
}

function normalizeSystemAudioError(error: unknown): SystemAudioInputError {
  if (error instanceof SystemAudioInputError) {
    return error;
  }
  if (
    error instanceof MediaStreamPcmPipelineError &&
    error.code === "no_audio_track"
  ) {
    return new SystemAudioInputError(
      "no_audio_track",
      "The selected source did not provide audio.",
    );
  }
  if (isNamedError(error, "NotAllowedError")) {
    return new SystemAudioInputError(
      "permission_denied",
      "System audio sharing was cancelled or not allowed.",
    );
  }
  return new SystemAudioInputError(
    "capture_failed",
    "System audio capture could not be started.",
  );
}

function isNamedError(value: unknown, name: string): boolean {
  return (
    typeof value === "object" &&
    value !== null &&
    "name" in value &&
    value.name === name
  );
}
