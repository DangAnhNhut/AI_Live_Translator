import assert from "node:assert/strict";
import test from "node:test";

import { isValidSessionId } from "../realtime/socket-url.ts";
import {
  generateSessionId,
  parseSessionInput,
  validateCustomSessionId,
} from "./session-slug.ts";

test("1. generated ID uses full UUID format and satisfies existing validation", () => {
  for (let i = 0; i < 20; i++) {
    const id = generateSessionId();
    assert.equal(typeof id, "string");
    // "session-" (8) + UUID (36) = 44 characters
    assert.equal(id.length, 44);
    assert.ok(id.length <= 64, `id length ${id.length} exceeds 64`);
    assert.match(
      id,
      /^session-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/,
    );
    assert.ok(
      isValidSessionId(id),
      `generated ID "${id}" does not satisfy isValidSessionId`,
    );
  }
});

test("2. generated IDs use safe URL characters and no spaces/symbols", () => {
  for (let i = 0; i < 10; i++) {
    const id = generateSessionId();
    assert.match(id, /^[A-Za-z0-9._-]+$/);
    assert.doesNotMatch(id, /[\s/?#&%=]/);
  }
});

test("3. plain session ID parsing", () => {
  const result = parseSessionInput("room-123");
  assert.deepEqual(result, {
    valid: true,
    sessionId: "room-123",
  });
});

test("4. surrounding whitespace trimming", () => {
  const result = parseSessionInput("   audit-session-001 \t\n ");
  assert.deepEqual(result, {
    valid: true,
    sessionId: "audit-session-001",
  });
});

test("5. Viewer URL parsing extracts sessionId", () => {
  const result = parseSessionInput("https://example.com/live/room-123");
  assert.deepEqual(result, {
    valid: true,
    sessionId: "room-123",
  });

  const trailingSlash = parseSessionInput(
    "http://localhost:3000/live/conference-456/",
  );
  assert.deepEqual(trailingSlash, {
    valid: true,
    sessionId: "conference-456",
  });
});

test("6. Host URL parsing extracts sessionId", () => {
  const result = parseSessionInput("https://example.com/host/host-session-789");
  assert.deepEqual(result, {
    valid: true,
    sessionId: "host-session-789",
  });
});

test("7. external-origin Viewer URL extracts ID only and never includes origin", () => {
  const result = parseSessionInput(
    "https://evil.example.com:8443/live/room-safe-999?query=1#hash",
  );
  assert.deepEqual(result, {
    valid: true,
    sessionId: "room-safe-999",
  });
  assert.ok(
    !result.sessionId.includes("evil") &&
      !result.sessionId.includes("http") &&
      !result.sessionId.includes("://"),
  );
});

test("8. malformed URL/input rejected", () => {
  const malformedProtocol = parseSessionInput("http://");
  assert.equal(malformedProtocol.valid, false);
  assert.ok(malformedProtocol.error);

  const rootOnly = parseSessionInput("https://example.com/");
  assert.equal(rootOnly.valid, false);
  assert.ok(rootOnly.error);

  const emptyPath = parseSessionInput("https://example.com/live/");
  assert.equal(emptyPath.valid, false);
  assert.ok(emptyPath.error);
});

test("9. invalid characters rejected in parseSessionInput", () => {
  const withSpaces = parseSessionInput("room 123");
  assert.equal(withSpaces.valid, false);
  assert.ok(withSpaces.error);

  const withSymbols = parseSessionInput("room@123!");
  assert.equal(withSymbols.valid, false);
  assert.ok(withSymbols.error);

  const startsWithHyphen = parseSessionInput("-invalid-start");
  assert.equal(startsWithHyphen.valid, false);
  assert.ok(startsWithHyphen.error);
});

test("10. empty input rejected in parseSessionInput", () => {
  const empty = parseSessionInput("");
  assert.equal(empty.valid, false);
  assert.ok(empty.error);

  const spacesOnly = parseSessionInput("    ");
  assert.equal(spacesOnly.valid, false);
  assert.ok(spacesOnly.error);
});

test("11. over-length ID rejected in parseSessionInput", () => {
  const over64 = "a".repeat(65);
  const result = parseSessionInput(over64);
  assert.equal(result.valid, false);
  assert.ok(result.error);

  const maxValid = "a".repeat(64);
  const maxResult = parseSessionInput(maxValid);
  assert.equal(maxResult.valid, true);
  assert.equal(maxResult.sessionId, maxValid);
});

test("12. parsing never returns an external URL or protocol scheme", () => {
  const inputs = [
    "https://example.com/live/my-room",
    "http://test.local:3000/host/my-room",
    "//example.com/live/my-room",
    "javascript:alert(1)",
    "data:text/plain,room-123",
  ];

  for (const input of inputs) {
    const res = parseSessionInput(input);
    if (res.valid) {
      assert.ok(!res.sessionId.includes("://"));
      assert.ok(!res.sessionId.includes("/"));
      assert.ok(!res.sessionId.includes(":"));
      assert.ok(isValidSessionId(res.sessionId));
    }
  }
});

test("13. validateCustomSessionId accepts plain IDs and trims whitespace", () => {
  const valid = validateCustomSessionId("  custom-all-hands-2026  ");
  assert.deepEqual(valid, {
    valid: true,
    sessionId: "custom-all-hands-2026",
  });
});

test("14. validateCustomSessionId rejects URLs", () => {
  const url = validateCustomSessionId("https://example.com/live/room-123");
  assert.equal(url.valid, false);
  assert.ok(url.error);

  const hostUrl = validateCustomSessionId("http://localhost:3000/host/room-123");
  assert.equal(hostUrl.valid, false);
  assert.ok(hostUrl.error);
});

test("15. validateCustomSessionId rejects empty, spaces, and invalid characters", () => {
  const empty = validateCustomSessionId("");
  assert.equal(empty.valid, false);

  const spaces = validateCustomSessionId("room with spaces");
  assert.equal(spaces.valid, false);

  const over64 = validateCustomSessionId("x".repeat(65));
  assert.equal(over64.valid, false);
});
