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

export type MicrophoneAudioInputErrorCode =
  | "unsupported"
  | "permission_denied"
  | "no_audio_track"
  | "capture_failed";

export class MicrophoneAudioInputError extends Error {
  readonly code: MicrophoneAudioInputErrorCode;

  constructor(code: MicrophoneAudioInputErrorCode, message: string) {
    super(message);
    this.name = "MicrophoneAudioInputError";
    this.code = code;
  }
}

type MicrophoneAudioInputDependencies = {
  getUserMedia: (options: MediaStreamConstraints) => Promise<MediaStreamLike>;
  createAudioContext: () => AudioContextLike;
  createWorkletNode: (context: AudioContextLike) => WorkletNodeLike;
  createPipeline: (stream: MediaStreamLike) => MediaStreamPcmPipelineLike;
};

export class MicrophoneAudioInput implements AudioInput {
  private readonly getUserMedia: MicrophoneAudioInputDependencies["getUserMedia"];
  private readonly createPipeline: MicrophoneAudioInputDependencies["createPipeline"];
  private pipeline: MediaStreamPcmPipelineLike | null = null;
  private startInProgress = false;
  private stopRequested = false;

  constructor(dependencies?: Partial<MicrophoneAudioInputDependencies>) {
    this.getUserMedia = dependencies?.getUserMedia ?? defaultGetUserMedia;
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
      throw new MicrophoneAudioInputError(
        "capture_failed",
        "Microphone capture is already active.",
      );
    }

    this.startInProgress = true;
    this.stopRequested = false;
    let stream: MediaStreamLike | null = null;

    try {
      stream = await this.getUserMedia({ audio: true, video: false });
      if (this.stopRequested) {
        stopStreamTracks(stream);
        stream = null;
        throw new MicrophoneAudioInputError(
          "capture_failed",
          "Microphone capture was stopped before it started.",
        );
      }

      const pipeline = this.createPipeline(stream);
      this.pipeline = pipeline;
      const info = await pipeline.start(callbacks);
      if (this.stopRequested) {
        await pipeline.stop();
        throw new MicrophoneAudioInputError(
          "capture_failed",
          "Microphone capture was stopped before it started.",
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
      throw normalizeMicrophoneError(error);
    }
  }

  stop(): Promise<void> {
    if (this.startInProgress) {
      this.stopRequested = true;
    }
    return this.pipeline?.stop() ?? Promise.resolve();
  }
}

async function defaultGetUserMedia(
  options: MediaStreamConstraints,
): Promise<MediaStreamLike> {
  if (
    typeof navigator === "undefined" ||
    navigator.mediaDevices?.getUserMedia === undefined
  ) {
    throw new MicrophoneAudioInputError(
      "unsupported",
      "Microphone capture is not supported in this browser.",
    );
  }
  const stream = await navigator.mediaDevices.getUserMedia(options);
  return stream as unknown as MediaStreamLike;
}

function stopStreamTracks(stream: MediaStreamLike): void {
  for (const track of stream.getTracks()) {
    track.stop();
  }
}

function normalizeMicrophoneError(error: unknown): MicrophoneAudioInputError {
  if (error instanceof MicrophoneAudioInputError) {
    return error;
  }
  if (
    error instanceof MediaStreamPcmPipelineError &&
    error.code === "no_audio_track"
  ) {
    return new MicrophoneAudioInputError(
      "no_audio_track",
      "The selected microphone did not provide audio.",
    );
  }
  if (isNamedError(error, "NotAllowedError")) {
    return new MicrophoneAudioInputError(
      "permission_denied",
      "Microphone access was cancelled or not allowed.",
    );
  }
  return new MicrophoneAudioInputError(
    "capture_failed",
    "Microphone capture could not be started.",
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
