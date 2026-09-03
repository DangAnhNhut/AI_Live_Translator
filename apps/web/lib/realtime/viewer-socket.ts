import {
  parseViewerTranscriptEvent,
  type ViewerTranscriptEvent,
} from "./transcript.ts";
import {
  parseTranslationEvent,
  type TranslationEvent,
} from "./translation.ts";
import { buildWebSocketUrl, isValidSessionId } from "./socket-url.ts";

export { isValidSessionId };

export type ViewerConnectionStatus =
  | "connecting"
  | "live"
  | "reconnecting"
  | "disconnected"
  | "error";

type SocketLike = {
  onopen: ((event: unknown) => void) | null;
  onmessage: ((event: { data: unknown }) => void) | null;
  onerror: ((event: unknown) => void) | null;
  onclose: ((event: { code?: number; wasClean?: boolean }) => void) | null;
  close: () => void;
};

type TimerHandle = ReturnType<typeof setTimeout> | object;

type ViewerSocketClientOptions = {
  url: string;
  createSocket?: (url: string) => SocketLike;
  schedule?: (callback: () => void, delay: number) => TimerHandle;
  cancelSchedule?: (handle: TimerHandle) => void;
  onStatus: (status: ViewerConnectionStatus) => void;
  onTranscript: (event: ViewerTranscriptEvent) => void;
  onTranslation?: (event: TranslationEvent) => void;
};

export function buildViewerWebSocketUrl(
  baseUrl: string | undefined,
  sessionId: string,
): string {
  if (!isValidSessionId(sessionId)) {
    throw new Error("Invalid session ID.");
  }

  return buildWebSocketUrl(baseUrl, `/ws/sessions/${sessionId}/viewer`);
}

export class ViewerSocketClient {
  private readonly options: Required<
    Pick<ViewerSocketClientOptions, "createSocket" | "schedule" | "cancelSchedule">
  > &
    Omit<
      ViewerSocketClientOptions,
      "createSocket" | "schedule" | "cancelSchedule"
    >;

  private socket: SocketLike | null = null;
  private reconnectTimer: TimerHandle | null = null;
  private retryAttempt = 0;
  private started = false;
  private stopped = true;

  constructor(options: ViewerSocketClientOptions) {
    this.options = {
      ...options,
      createSocket:
        options.createSocket ??
        ((url) => new WebSocket(url) as unknown as SocketLike),
      schedule:
        options.schedule ??
        ((callback, delay) => setTimeout(callback, delay)),
      cancelSchedule:
        options.cancelSchedule ??
        ((handle) => clearTimeout(handle as ReturnType<typeof setTimeout>)),
    };
  }

  start(): void {
    if (this.started) {
      return;
    }

    this.started = true;
    this.stopped = false;
    this.retryAttempt = 0;
    this.options.onStatus("connecting");
    this.connect();
  }

  stop(): void {
    this.stopped = true;
    this.started = false;

    if (this.reconnectTimer !== null) {
      this.options.cancelSchedule(this.reconnectTimer);
      this.reconnectTimer = null;
    }

    const socket = this.socket;
    this.socket = null;
    if (socket !== null) {
      socket.onopen = null;
      socket.onmessage = null;
      socket.onerror = null;
      socket.onclose = null;
      socket.close();
    }

    this.options.onStatus("disconnected");
  }

  private connect(): void {
    if (this.stopped) {
      return;
    }

    let socket: SocketLike;
    try {
      socket = this.options.createSocket(this.options.url);
    } catch {
      this.options.onStatus("error");
      this.scheduleReconnect();
      return;
    }

    this.socket = socket;

    socket.onopen = () => {
      if (this.socket !== socket || this.stopped) {
        return;
      }

      this.retryAttempt = 0;
      this.options.onStatus("live");
    };

    socket.onmessage = ({ data }) => {
      if (this.socket !== socket || this.stopped || typeof data !== "string") {
        return;
      }

      let decoded: unknown;
      try {
        decoded = JSON.parse(data);
      } catch {
        return;
      }

      const event = parseViewerTranscriptEvent(decoded);
      if (event !== null) {
        this.options.onTranscript(event);
        return;
      }

      const translation = parseTranslationEvent(decoded);
      if (translation !== null) {
        this.options.onTranslation?.(translation);
      }
    };

    socket.onerror = () => {
      if (this.socket === socket && !this.stopped) {
        this.options.onStatus("error");
      }
    };

    socket.onclose = () => {
      if (this.socket !== socket) {
        return;
      }

      this.socket = null;
      if (!this.stopped) {
        this.scheduleReconnect();
      }
    };
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer !== null) {
      return;
    }

    this.options.onStatus("reconnecting");
    const delay = Math.min(1000 * 2 ** this.retryAttempt, 8000);
    this.retryAttempt += 1;
    this.reconnectTimer = this.options.schedule(() => {
      this.reconnectTimer = null;
      this.connect();
    }, delay);
  }
}
