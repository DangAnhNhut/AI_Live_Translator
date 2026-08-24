"use client";

import { useEffect, useRef, useState } from "react";

type BackendStatus = "checking" | "online" | "offline";
type WebSocketStatus =
  | "disconnected"
  | "connecting"
  | "connected";

interface HealthResponse {
  status: string;
  service: string;
}

const API_BASE_URL =
  process.env.NEXT_PUBLIC_API_BASE_URL ??
  "http://127.0.0.1:8000";

const WS_BASE_URL =
  process.env.NEXT_PUBLIC_WS_URL ??
  "ws://127.0.0.1:8000";

async function fetchBackendHealth(): Promise<HealthResponse> {
  const response = await fetch(`${API_BASE_URL}/health`);

  if (!response.ok) {
    throw new Error(`HTTP ${response.status}`);
  }

  return response.json();
}

export default function LiveTestPage() {
  const [backendStatus, setBackendStatus] =
    useState<BackendStatus>("checking");

  const [health, setHealth] =
    useState<HealthResponse | null>(null);

  const [webSocketStatus, setWebSocketStatus] =
    useState<WebSocketStatus>("disconnected");

  const [message, setMessage] = useState("");

  const [receivedMessages, setReceivedMessages] =
    useState<string[]>([]);

  const socketRef = useRef<WebSocket | null>(null);

  const checkBackend = async () => {
    setBackendStatus("checking");

    try {
      const data = await fetchBackendHealth();

      setHealth(data);
      setBackendStatus("online");
    } catch {
      setHealth(null);
      setBackendStatus("offline");
    }
  };

  const connectWebSocket = () => {
    const existingSocket = socketRef.current;

    if (
      existingSocket &&
      (
        existingSocket.readyState === WebSocket.OPEN ||
        existingSocket.readyState === WebSocket.CONNECTING
      )
    ) {
      return;
    }

    setWebSocketStatus("connecting");

    const socket = new WebSocket(
      `${WS_BASE_URL}/ws/test`,
    );

    socketRef.current = socket;

    socket.onopen = () => {
      setWebSocketStatus("connected");
    };

    socket.onmessage = (event) => {
      setReceivedMessages((current) => [
        ...current,
        String(event.data),
      ]);
    };

    socket.onerror = () => {
      setWebSocketStatus("disconnected");
    };

    socket.onclose = () => {
      setWebSocketStatus("disconnected");

      if (socketRef.current === socket) {
        socketRef.current = null;
      }
    };
  };

  const disconnectWebSocket = () => {
    const socket = socketRef.current;

    if (!socket) {
      return;
    }

    socket.close();
    socketRef.current = null;

    setWebSocketStatus("disconnected");
  };

  const sendMessage = () => {
    const socket = socketRef.current;
    const normalizedMessage = message.trim();

    if (
      !socket ||
      socket.readyState !== WebSocket.OPEN ||
      !normalizedMessage
    ) {
      return;
    }

    socket.send(normalizedMessage);
    setMessage("");
  };

  useEffect(() => {
    let cancelled = false;

    const loadInitialHealth = async () => {
      try {
        const data = await fetchBackendHealth();

        if (!cancelled) {
          setHealth(data);
          setBackendStatus("online");
        }
      } catch {
        if (!cancelled) {
          setHealth(null);
          setBackendStatus("offline");
        }
      }
    };

    void loadInitialHealth();

    return () => {
      cancelled = true;

      const socket = socketRef.current;

      if (socket) {
        socket.close();
      }
    };
  }, []);

  const websocketConnected =
    webSocketStatus === "connected";

  return (
    <main className="min-h-screen bg-gray-50 p-8 text-gray-900">
      <div className="mx-auto max-w-3xl">
        <h1 className="text-3xl font-bold">
          AI Live Translator
        </h1>

        <p className="mt-2 text-gray-600">
          Realtime Technical Test
        </p>

        <section className="mt-8 rounded-xl border bg-white p-6">
          <h2 className="text-xl font-semibold">
            Backend Connection
          </h2>

          <div className="mt-4 flex items-center gap-3">
            <span
              className={`h-3 w-3 rounded-full ${
                backendStatus === "online"
                  ? "bg-green-500"
                  : backendStatus === "offline"
                    ? "bg-red-500"
                    : "bg-yellow-500"
              }`}
            />

            <span className="font-medium">
              {backendStatus === "checking" && "Checking..."}
              {backendStatus === "online" && "Backend Online"}
              {backendStatus === "offline" && "Backend Offline"}
            </span>
          </div>

          {health && (
            <div className="mt-4 rounded-lg bg-gray-100 p-4 font-mono text-sm">
              <div>status: {health.status}</div>
              <div>service: {health.service}</div>
            </div>
          )}

          <button
            type="button"
            onClick={() => void checkBackend()}
            className="mt-6 rounded-lg bg-black px-4 py-2 text-white"
          >
            Check Backend
          </button>
        </section>

        <section className="mt-6 rounded-xl border bg-white p-6">
          <h2 className="text-xl font-semibold">
            WebSocket Connection
          </h2>

          <div className="mt-4 flex items-center gap-3">
            <span
              className={`h-3 w-3 rounded-full ${
                webSocketStatus === "connected"
                  ? "bg-green-500"
                  : webSocketStatus === "connecting"
                    ? "bg-yellow-500"
                    : "bg-red-500"
              }`}
            />

            <span className="font-medium">
              {webSocketStatus === "connected" &&
                "Connected"}

              {webSocketStatus === "connecting" &&
                "Connecting..."}

              {webSocketStatus === "disconnected" &&
                "Disconnected"}
            </span>
          </div>

          <div className="mt-6 flex gap-3">
            <button
              type="button"
              onClick={connectWebSocket}
              disabled={
                webSocketStatus !== "disconnected"
              }
              className="rounded-lg bg-black px-4 py-2 text-white disabled:cursor-not-allowed disabled:opacity-40"
            >
              Connect
            </button>

            <button
              type="button"
              onClick={disconnectWebSocket}
              disabled={
                webSocketStatus === "disconnected"
              }
              className="rounded-lg border px-4 py-2 disabled:cursor-not-allowed disabled:opacity-40"
            >
              Disconnect
            </button>
          </div>

          <div className="mt-6 flex gap-3">
            <input
              type="text"
              value={message}
              onChange={(event) =>
                setMessage(event.target.value)
              }
              onKeyDown={(event) => {
                if (event.key === "Enter") {
                  sendMessage();
                }
              }}
              placeholder="Enter message"
              className="flex-1 rounded-lg border px-4 py-2 outline-none focus:ring-2 focus:ring-black"
            />

            <button
              type="button"
              onClick={sendMessage}
              disabled={
                !websocketConnected ||
                !message.trim()
              }
              className="rounded-lg bg-black px-4 py-2 text-white disabled:cursor-not-allowed disabled:opacity-40"
            >
              Send
            </button>
          </div>

          <div className="mt-6">
            <h3 className="font-semibold">
              Received Messages
            </h3>

            <div className="mt-3 min-h-32 rounded-lg bg-gray-100 p-4">
              {receivedMessages.length === 0 ? (
                <p className="text-sm text-gray-500">
                  No messages received yet.
                </p>
              ) : (
                <ul className="space-y-2">
                  {receivedMessages.map(
                    (receivedMessage, index) => (
                      <li
                        key={`${index}-${receivedMessage}`}
                        className="rounded bg-white px-3 py-2 font-mono text-sm"
                      >
                        {receivedMessage}
                      </li>
                    ),
                  )}
                </ul>
              )}
            </div>
          </div>
        </section>
      </div>
    </main>
  );
}