import type { AudioCaptureInfo, AudioInputCallbacks } from "./audio-input.ts";
import {
  downmixToMono,
  float32ToPcm16Le,
  PcmChunkAccumulator,
} from "./pcm.ts";
import { StreamingLinearResampler } from "./streaming-resampler.ts";

export type MediaTrackLike = {
  stop: () => void;
  addEventListener: (type: "ended", listener: (event: unknown) => void) => void;
  removeEventListener: (
    type: "ended",
    listener: (event: unknown) => void,
  ) => void;
  getSettings?: () => { channelCount?: number };
};

export type MediaStreamLike = {
  getAudioTracks: () => MediaTrackLike[];
  getTracks: () => MediaTrackLike[];
};

type WorkletPortLike = {
  onmessage: ((event: { data: unknown }) => void) | null;
};

export type WorkletNodeLike = {
  port: WorkletPortLike;
  disconnect: () => void;
};

type SourceNodeLike = {
  connect: (node: WorkletNodeLike) => unknown;
  disconnect: () => void;
};

export type AudioContextLike = {
  sampleRate: number;
  state: string;
  audioWorklet: { addModule: (url: string) => Promise<void> };
  createMediaStreamSource: (stream: MediaStreamLike) => SourceNodeLike;
  resume: () => Promise<void>;
  close: () => Promise<void>;
};

export type MediaStreamPcmPipelineDependencies = {
  createAudioContext: () => AudioContextLike;
  createWorkletNode: (context: AudioContextLike) => WorkletNodeLike;
};

export interface MediaStreamPcmPipelineLike {
  start(callbacks: AudioInputCallbacks): Promise<AudioCaptureInfo>;
  stop(): Promise<void>;
}

export type MediaStreamPcmPipelineErrorCode =
  | "no_audio_track"
  | "setup_failed";

export class MediaStreamPcmPipelineError extends Error {
  readonly code: MediaStreamPcmPipelineErrorCode;

  constructor(code: MediaStreamPcmPipelineErrorCode, message: string) {
    super(message);
    this.name = "MediaStreamPcmPipelineError";
    this.code = code;
  }
}

const TARGET_SAMPLE_RATE = 16000 as const;
const PCM_BYTES_PER_SAMPLE = 2;
const PCM_CHUNK_DURATION_MS = 20;
const PCM_CHUNK_SIZE_BYTES =
  (TARGET_SAMPLE_RATE * PCM_BYTES_PER_SAMPLE * PCM_CHUNK_DURATION_MS) / 1000;
const WORKLET_MODULE_URL = "/worklets/pcm-capture-processor.js";

export class MediaStreamPcmPipeline implements MediaStreamPcmPipelineLike {
  private readonly stream: MediaStreamLike;
  private readonly dependencies: MediaStreamPcmPipelineDependencies;
  private callbacks: AudioInputCallbacks | null = null;
  private tracks: MediaTrackLike[] = [];
  private context: AudioContextLike | null = null;
  private sourceNode: SourceNodeLike | null = null;
  private workletNode: WorkletNodeLike | null = null;
  private resampler: StreamingLinearResampler | null = null;
  private chunkAccumulator: PcmChunkAccumulator | null = null;
  private cleanupPromise: Promise<void> | null = null;
  private processing = false;
  private active = false;
  private started = false;
  private endedNotified = false;
  private readonly handleTrackEnded = () => {
    if (this.cleanupPromise === null && this.active) {
      void this.beginCleanup(true, true);
    }
  };

  constructor(
    stream: MediaStreamLike,
    dependencies?: Partial<MediaStreamPcmPipelineDependencies>,
  ) {
    this.stream = stream;
    this.dependencies = {
      createAudioContext:
        dependencies?.createAudioContext ?? defaultCreateAudioContext,
      createWorkletNode:
        dependencies?.createWorkletNode ?? defaultCreateWorkletNode,
    };
  }

  async start(callbacks: AudioInputCallbacks): Promise<AudioCaptureInfo> {
    if (this.started) {
      throw new MediaStreamPcmPipelineError(
        "setup_failed",
        "The media stream PCM pipeline cannot be restarted.",
      );
    }
    this.started = true;
    this.callbacks = callbacks;
    this.tracks = this.stream.getTracks();
    const audioTracks = this.stream.getAudioTracks();
    if (audioTracks.length === 0) {
      for (const track of this.tracks) {
        track.stop();
      }
      this.tracks = [];
      throw new MediaStreamPcmPipelineError(
        "no_audio_track",
        "The acquired media stream did not provide audio.",
      );
    }

    for (const track of this.tracks) {
      track.addEventListener("ended", this.handleTrackEnded);
    }
    this.active = true;

    try {
      const context = this.dependencies.createAudioContext();
      this.context = context;
      await context.audioWorklet.addModule(WORKLET_MODULE_URL);
      this.throwIfStoppedDuringSetup();

      const sourceNode = context.createMediaStreamSource(this.stream);
      const workletNode = this.dependencies.createWorkletNode(context);
      this.sourceNode = sourceNode;
      this.workletNode = workletNode;
      this.resampler = new StreamingLinearResampler(
        context.sampleRate,
        TARGET_SAMPLE_RATE,
      );
      this.chunkAccumulator = new PcmChunkAccumulator(PCM_CHUNK_SIZE_BYTES);
      workletNode.port.onmessage = ({ data }) => this.handleWorkletMessage(data);
      sourceNode.connect(workletNode);
      this.processing = true;

      if (context.state === "suspended") {
        await context.resume();
      }
      this.throwIfStoppedDuringSetup();

      const channelCount = audioTracks[0].getSettings?.().channelCount;
      return {
        captureSampleRate: context.sampleRate,
        targetSampleRate: TARGET_SAMPLE_RATE,
        channelCount:
          typeof channelCount === "number" && channelCount > 0
            ? channelCount
            : null,
      };
    } catch (error) {
      await this.beginCleanup(false, false);
      if (error instanceof MediaStreamPcmPipelineError) {
        throw error;
      }
      throw new MediaStreamPcmPipelineError(
        "setup_failed",
        "The media stream PCM pipeline could not be started.",
      );
    }
  }

  stop(): Promise<void> {
    if (!this.active) {
      return this.cleanupPromise ?? Promise.resolve();
    }
    return this.beginCleanup(false, true);
  }

  private throwIfStoppedDuringSetup(): void {
    if (!this.active) {
      throw new MediaStreamPcmPipelineError(
        "setup_failed",
        "The media stream PCM pipeline stopped during setup.",
      );
    }
  }

  private handleWorkletMessage(value: unknown): void {
    if (!this.processing || this.resampler === null) {
      return;
    }
    const channels = parseChannelBlock(value);
    if (channels === null) {
      return;
    }

    let mono: Float32Array;
    try {
      mono = downmixToMono(channels);
    } catch {
      return;
    }
    const resampled = this.resampler.process(mono);
    const chunks = this.chunkAccumulator?.push(float32ToPcm16Le(resampled)) ?? [];
    for (const chunk of chunks) {
      this.callbacks?.onPcmChunk(chunk);
    }
  }

  private beginCleanup(
    notifyEnded: boolean,
    flushBufferedPcm: boolean,
  ): Promise<void> {
    if (this.cleanupPromise !== null) {
      return this.cleanupPromise;
    }
    this.cleanupPromise = this.cleanup(notifyEnded, flushBufferedPcm);
    return this.cleanupPromise;
  }

  private async cleanup(
    notifyEnded: boolean,
    flushBufferedPcm: boolean,
  ): Promise<void> {
    this.processing = false;
    this.active = false;
    if (this.workletNode !== null) {
      this.workletNode.port.onmessage = null;
    }
    for (const track of this.tracks) {
      track.removeEventListener("ended", this.handleTrackEnded);
    }

    if (flushBufferedPcm) {
      const remainder = this.chunkAccumulator?.flush() ?? null;
      if (remainder !== null) {
        this.callbacks?.onPcmChunk(remainder);
      }
    }

    this.sourceNode?.disconnect();
    this.workletNode?.disconnect();
    for (const track of this.tracks) {
      track.stop();
    }

    if (this.context !== null && this.context.state !== "closed") {
      try {
        await this.context.close();
      } catch {
        // Tracks and nodes are already detached; finish local cleanup.
      }
    }

    this.resampler?.reset();
    this.chunkAccumulator?.reset();
    this.tracks = [];
    this.context = null;
    this.sourceNode = null;
    this.workletNode = null;
    this.resampler = null;
    this.chunkAccumulator = null;

    if (notifyEnded && !this.endedNotified) {
      this.endedNotified = true;
      this.callbacks?.onEnded();
    }
  }
}

function defaultCreateAudioContext(): AudioContextLike {
  if (typeof AudioContext === "undefined") {
    throw new MediaStreamPcmPipelineError(
      "setup_failed",
      "Web Audio is not supported in this browser.",
    );
  }
  return new AudioContext() as unknown as AudioContextLike;
}

function defaultCreateWorkletNode(context: AudioContextLike): WorkletNodeLike {
  if (typeof AudioWorkletNode === "undefined") {
    throw new MediaStreamPcmPipelineError(
      "setup_failed",
      "AudioWorklet is not supported in this browser.",
    );
  }
  return new AudioWorkletNode(
    context as unknown as AudioContext,
    "pcm-capture-processor",
    {
      numberOfInputs: 1,
      numberOfOutputs: 0,
      channelCountMode: "max",
    },
  ) as unknown as WorkletNodeLike;
}

function parseChannelBlock(value: unknown): readonly Float32Array[] | null {
  if (
    typeof value !== "object" ||
    value === null ||
    !("channels" in value) ||
    !Array.isArray(value.channels) ||
    value.channels.length === 0 ||
    !value.channels.every((channel) => channel instanceof Float32Array)
  ) {
    return null;
  }
  return value.channels;
}
