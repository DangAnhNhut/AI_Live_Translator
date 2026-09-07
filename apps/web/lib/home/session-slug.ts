import { isValidSessionId } from "../realtime/socket-url.ts";

export type ParseSessionResult =
  | { valid: true; sessionId: string }
  | { valid: false; error: string };

/**
 * Generates a URL-safe, compliant session ID using full Web Crypto UUID.
 * Format: `session-${crypto.randomUUID()}` (44 characters total).
 * Guaranteed to satisfy `/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/`.
 */
export function generateSessionId(): string {
  if (typeof globalThis.crypto?.randomUUID === "function") {
    return `session-${globalThis.crypto.randomUUID()}`;
  }

  // Fallback for minimal environments lacking crypto.randomUUID
  const randomPart = Math.random().toString(36).slice(2, 14);
  return `session-${randomPart}`;
}

/**
 * Validates a plain custom session ID entered by a host.
 * Strictly requires a plain session ID; does not parse pasted URLs.
 */
export function validateCustomSessionId(
  rawInput: string | undefined | null,
): ParseSessionResult {
  if (!rawInput || typeof rawInput !== "string") {
    return { valid: false, error: "Please enter a session ID." };
  }

  const trimmed = rawInput.trim();
  if (!trimmed) {
    return { valid: false, error: "Please enter a session ID." };
  }

  if (trimmed.length > 64) {
    return {
      valid: false,
      error: "Session ID must be 64 characters or fewer.",
    };
  }

  if (!isValidSessionId(trimmed)) {
    if (!/^[A-Za-z0-9]/.test(trimmed)) {
      return {
        valid: false,
        error: "Session ID must start with a letter or number.",
      };
    }
    if (/[^A-Za-z0-9._-]/.test(trimmed)) {
      return {
        valid: false,
        error:
          "Session IDs may only contain letters, numbers, hyphens, underscores, and periods.",
      };
    }
    return { valid: false, error: "Invalid session ID format." };
  }

  return { valid: true, sessionId: trimmed };
}

/**
 * Parses user input from the Viewer Join field, which may be:
 * - A raw session ID (e.g. "room-123")
 * - A full Viewer URL (e.g. "https://example.com/live/room-123")
 * - A full Host URL (e.g. "https://example.com/host/room-123")
 *
 * Strictly prevents open-redirect vulnerabilities by never returning an external origin
 * or full URL, only returning the validated session ID string.
 */
export function parseSessionInput(
  rawInput: string | undefined | null,
): ParseSessionResult {
  if (!rawInput || typeof rawInput !== "string") {
    return { valid: false, error: "Please enter a session ID or link." };
  }

  const trimmed = rawInput.trim();
  if (!trimmed) {
    return { valid: false, error: "Please enter a session ID or link." };
  }

  let candidate: string = trimmed;

  // Handle full URL or protocol-relative URL
  if (trimmed.includes("://") || trimmed.startsWith("//")) {
    try {
      const url = new URL(trimmed.startsWith("//") ? `https:${trimmed}` : trimmed);
      const segments = url.pathname.split("/").filter(Boolean);

      if (segments.length === 0) {
        return {
          valid: false,
          error: "The provided link does not contain a session ID.",
        };
      }

      if ((segments[0] === "live" || segments[0] === "host") && segments.length >= 2) {
        candidate = segments[1];
      } else if (segments.length === 1 && segments[0] !== "live" && segments[0] !== "host") {
        candidate = segments[0];
      } else {
        return {
          valid: false,
          error: "Unsupported link format. Use a /live/<session-id> link.",
        };
      }
    } catch {
      return { valid: false, error: "Malformed URL provided." };
    }
  } else {
    // Check if input is path-like, e.g. "live/room-123" or "/live/room-123"
    const pathMatch = trimmed.match(/^\/?(live|host)\/([^/?#]+)/i);
    if (pathMatch) {
      candidate = pathMatch[2];
    }
  }

  // Enforce boundary length
  if (candidate.length > 64) {
    return {
      valid: false,
      error: "Session ID must be 64 characters or fewer.",
    };
  }

  // Validate format against the canonical session pattern
  if (!isValidSessionId(candidate)) {
    if (!/^[A-Za-z0-9]/.test(candidate)) {
      return {
        valid: false,
        error: "Session ID must start with a letter or number.",
      };
    }
    if (/[^A-Za-z0-9._-]/.test(candidate)) {
      return {
        valid: false,
        error:
          "Session IDs may only contain letters, numbers, hyphens, underscores, and periods.",
      };
    }
    return { valid: false, error: "Invalid session ID format." };
  }

  return { valid: true, sessionId: candidate };
}
