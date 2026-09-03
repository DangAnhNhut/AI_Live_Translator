export type AudioCaptureInfo = {
  captureSampleRate: number;
  targetSampleRate: 16000;
  channelCount: number | null;
};

export type AudioInputCallbacks = {
  onPcmChunk: (chunk: ArrayBuffer) => void;
  onEnded: () => void;
};

export interface AudioInput {
  start(callbacks: AudioInputCallbacks): Promise<AudioCaptureInfo>;
  stop(): Promise<void>;
}
