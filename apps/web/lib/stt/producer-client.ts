import { buildWebSocketUrl, isValidSessionId } from "../realtime/socket-url.ts";
import {
  parseTranscriptEvent,
  type TranscriptEvent,
} from "../realtime/transcript.ts";
import {
  parseTranslationEvent,
  type TargetLanguage,
  type TranslationEvent,
} from "../realtime/translation.ts";

export type ProducerConnectionStatus =
  | "connecting"
  | "live"
  | "stopping"
  | "disconnected"
  | "error";

type ProducerState =
  | "idle"
  | "connecting"
  | "live"
  | "stopping"
  | "closed"
  | "error";

type ProducerSocket = {
  readyState: number;
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onclose: ((event: { code?: number; wasClean?: boolean }) => void) | null;
  send: (data: string | ArrayBuffer) => void;
  close: () => void;
};

type TimerHandle = number | object;

type SttProducerClientOptions = {
  url: string;
  sessionId: string;
  translation?: { targetLanguage: TargetLanguage };
  createSocket?: (url: string) => ProducerSocket;
  schedule?: (callback: () => void, delay: number) => TimerHandle;
  cancelSchedule?: (handle: TimerHandle) => void;
  onStatus: (status: ProducerConnectionStatus) => void;
  onTranscript: (event: TranscriptEvent) => void;
  onTranslation?: (event: TranslationEvent) => void;
  onError: (message: string) => void;
};

type ProducerDiagnostics = {
  chunksSent: number;
  pcmBytesSent: number;
};

const SOCKET_OPEN = 1;
const SOCKET_CLOSED = 3;
const CONNECT_TIMEOUT_MS = 10000;
const STOP_TIMEOUT_MS = 8000;

export function buildProducerWebSocketUrl(
  baseUrl: string | undefined,
): string {
  return buildWebSocketUrl(baseUrl, "/ws/stt");
}

export class SttProducerClient {
  private readonly options: Required<
    Pick<
      SttProducerClientOptions,
      "createSocket" | "schedule" | "cancelSchedule"
    >
  > &
    Omit<
      SttProducerClientOptions,
      "createSocket" | "schedule" | "cancelSchedule"
    >;

  private socket: ProducerSocket | null = null;
  private state: ProducerState = "idle";
  private timer: TimerHandle | null = null;
  private startPromise: Promise<void> | null = null;
  private resolveStart: (() => void) | null = null;
  private rejectStart: ((reason: Error) => void) | null = null;
  private stopPromise: Promise<void> | null = null;
  private resolveStop: (() => void) | null = null;
  private chunksSent = 0;
  private pcmBytesSent = 0;

  constructor(options: SttProducerClientOptions) {
    if (!isValidSessionId(options.sessionId)) {
      throw new Error("Invalid session ID.");
    }

    this.options = {
      ...options,
      createSocket:
        options.createSocket ??
        ((url) => new WebSocket(url) as unknown as ProducerSocket),
      schedule:
        options.schedule ??
        ((callback, delay) => window.setTimeout(callback, delay)),
      cancelSchedule:
        options.cancelSchedule ??
        ((handle) =>
          window.clearTimeout(handle as ReturnType<typeof window.setTimeout>)),
    };
  }

  start(): Promise<void> {
    if (this.startPromise !== null) {
      return this.startPromise;
    }
    if (this.state !== "idle") {
      return Promise.reject(new Error("The speech session cannot be restarted."));
    }

    this.state = "connecting";
    this.options.onStatus("connecting");
    this.startPromise = new Promise<void>((resolve, reject) => {
      this.resolveStart = resolve;
      this.rejectStart = reject;
    });

    let socket: ProducerSocket;
    try {
      socket = this.options.createSocket(this.options.url);
    } catch {
      this.failUnexpected("The speech connection could not be opened.");
      return this.startPromise;
    }

    this.socket = socket;
    socket.onopen = () => this.handleOpen(socket);
    socket.onmessage = ({ data }) => this.handleMessage(socket, data);
    socket.onerror = () => {
      if (this.socket === socket && this.state !== "closed") {
        this.failUnexpected("The speech connection encountered an error.");
      }
    };
    socket.onclose = () => {
      if (this.socket === socket && this.state !== "closed") {
        this.failUnexpected(
          "The speech connection ended unexpectedly. Start the session again.",
        );
      }
    };
    this.setTimer(() => {
      this.failUnexpected("The speech service did not become ready in time.");
    }, CONNECT_TIMEOUT_MS);

    return this.startPromise;
  }

  sendPcmChunk(chunk: ArrayBuffer): boolean {
    const socket = this.socket;
    if (
      this.state !== "live" ||
      socket === null ||
      socket.readyState !== SOCKET_OPEN ||
      chunk.byteLength === 0
    ) {
      return false;
    }

    try {
      socket.send(chunk);
      this.chunksSent += 1;
      this.pcmBytesSent += chunk.byteLength;
      return true;
    } catch {
      this.failUnexpected("The speech connection could not send audio.");
      return false;
    }
  }

  stop(): Promise<void> {
    if (this.stopPromise !== null) {
      return this.stopPromise;
    }

    if (this.state === "idle" || this.state === "closed") {
      return Promise.resolve();
    }

    if (this.state !== "live") {
      if (this.state === "connecting") {
        this.rejectPendingStart(
          new Error("The speech session was stopped before it became ready."),
        );
      }
      this.finishSocket(this.state !== "error");
      return Promise.resolve();
    }

    this.state = "stopping";
    this.options.onStatus("stopping");
    this.stopPromise = new Promise<void>((resolve) => {
      this.resolveStop = resolve;
    });

    try {
      this.socket?.send(JSON.stringify({ type: "stt.stop" }));
    } catch {
      this.finishStop();
      return this.stopPromise;
    }

    this.setTimer(() => this.finishStop(), STOP_TIMEOUT_MS);
    return this.stopPromise;
  }

  getDiagnostics(): ProducerDiagnostics {
    return {
      chunksSent: this.chunksSent,
      pcmBytesSent: this.pcmBytesSent,
    };
  }

  private handleOpen(socket: ProducerSocket): void {
    if (this.socket !== socket || this.state !== "connecting") {
      return;
    }

    try {
      socket.send(
        JSON.stringify({
          type: "stt.start",
          session_id: this.options.sessionId,
          audio: {
            encoding: "pcm_s16le",
            sample_rate_hz: 16000,
            channels: 1,
          },
          language: "vi",
          ...(this.options.translation === undefined
            ? {}
            : {
                translation: {
                  target_language: this.options.translation.targetLanguage,
                },
              }),
        }),
      );
    } catch {
      this.failUnexpected("The speech session could not be started.");
    }
  }

  private handleMessage(socket: ProducerSocket, data: unknown): void {
    if (this.socket !== socket || typeof data !== "string") {
      return;
    }

    let message: unknown;
    try {
      message = JSON.parse(data);
    } catch {
      return;
    }

    const transcript = parseTranscriptEvent(message);
    if (transcript !== null) {
      if (this.state === "live" || this.state === "stopping") {
        this.options.onTranscript(transcript);
      }
      return;
    }

    const translation = parseTranslationEvent(message);
    if (translation !== null) {
      if (this.state === "live" || this.state === "stopping") {
        this.options.onTranslation?.(translation);
      }
      return;
    }

    if (!isRecord(message)) {
      return;
    }

    if (message.type === "stt.ready" && this.state === "connecting") {
      this.clearTimer();
      this.state = "live";
      this.resolveStart?.();
      this.resolveStart = null;
      this.rejectStart = null;
      this.options.onStatus("live");
      return;
    }

    if (message.type === "stt.error") {
      this.handleServerError();
      return;
    }

    if (message.type === "stt.closed") {
      if (this.state === "stopping") {
        this.finishStop();
      } else if (this.state === "error") {
        this.finishSocket(false);
      } else if (this.state !== "closed") {
        this.failUnexpected(
          "The speech connection ended unexpectedly. Start the session again.",
        );
      }
    }
  }

  private handleServerError(): void {
    if (this.state === "closed" || this.state === "error") {
      return;
    }

    this.clearTimer();
    this.state = "error";
    this.rejectPendingStart(new Error("The speech service reported an error."));
    this.options.onStatus("error");
    this.options.onError(
      "The speech service could not continue this session. Start again.",
    );
    this.setTimer(() => this.finishSocket(false), STOP_TIMEOUT_MS);
  }

  private failUnexpected(message: string): void {
    if (this.state === "closed" || this.state === "error") {
      return;
    }

    this.clearTimer();
    this.state = "error";
    this.rejectPendingStart(new Error(message));
    this.options.onStatus("error");
    this.options.onError(message);
    this.finishSocket(false);
  }

  private finishStop(): void {
    if (this.state === "closed") {
      return;
    }
    this.finishSocket(true);
    this.resolveStop?.();
    this.resolveStop = null;
  }

  private finishSocket(reportDisconnected: boolean): void {
    this.clearTimer();
    const socket = this.socket;
    this.socket = null;
    if (socket !== null) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      if (socket.readyState !== SOCKET_CLOSED) {
        socket.close();
      }
    }
    this.state = "closed";
    if (reportDisconnected) {
      this.options.onStatus("disconnected");
    }
  }

  private rejectPendingStart(error: Error): void {
    this.rejectStart?.(error);
    this.resolveStart = null;
    this.rejectStart = null;
  }

  private setTimer(callback: () => void, delay: number): void {
    this.clearTimer();
    this.timer = this.options.schedule(() => {
      this.timer = null;
      callback();
    }, delay);
  }

  private clearTimer(): void {
    if (this.timer !== null) {
      this.options.cancelSchedule(this.timer);
      this.timer = null;
    }
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
