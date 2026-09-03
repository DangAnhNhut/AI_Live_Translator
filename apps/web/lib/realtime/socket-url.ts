const DEFAULT_WS_BASE_URL = "ws://127.0.0.1:8000";
const SESSION_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

export function isValidSessionId(sessionId: string): boolean {
  return SESSION_ID_PATTERN.test(sessionId);
}

export function buildWebSocketUrl(
  baseUrl: string | undefined,
  pathname: string,
): string {
  if (!pathname.startsWith("/") || pathname.includes("?") || pathname.includes("#")) {
    throw new Error("Invalid WebSocket path.");
  }

  const normalizedBaseUrl = (baseUrl?.trim() || DEFAULT_WS_BASE_URL).replace(
    /\/+$/,
    "",
  );

  let parsedBaseUrl: URL;
  try {
    parsedBaseUrl = new URL(normalizedBaseUrl);
  } catch {
    throw new Error("Invalid WebSocket base URL.");
  }

  if (
    (parsedBaseUrl.protocol !== "ws:" && parsedBaseUrl.protocol !== "wss:") ||
    parsedBaseUrl.search ||
    parsedBaseUrl.hash
  ) {
    throw new Error("Invalid WebSocket base URL.");
  }

  return `${normalizedBaseUrl}${pathname}`;
}
