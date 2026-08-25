# Phase 1 — STT Technical Spike Design

**Date:** 2026-08-25
**Status:** Approved design, documented for implementation planning
**Scope:** Phase 1 technical spike; P1.1 is contract and architecture documentation only

## 1. Purpose

Phase 1 will prove that microphone audio from the Web and Flutter clients can flow through the FastAPI backend to a streaming speech-to-text (STT) provider and return realtime Vietnamese transcripts with acceptable latency, accuracy, stability, and recovery behavior.

This phase is a technical spike, not a full product implementation. Its output is evidence that supports a later product decision about whether the selected STT approach is suitable.

P1.1 defines the provider-neutral client protocol, audio contract, backend boundary, state model, error model, and measurement requirements. It does not implement `/ws/stt` or select an STT provider.

## 2. Architectural Context

```text
Web microphone
        \
         -> FastAPI WebSocket -> STT Provider Adapter -> normalized transcript events
        /
Flutter microphone
```

The backend is the source of truth for STT stream lifecycle and AI orchestration.

- Web and Mobile clients send audio only to the FastAPI backend. They never call an STT provider directly.
- FastAPI owns the public WebSocket protocol and connection state.
- A provider adapter owns the provider-specific streaming protocol.
- Provider credentials and configuration remain server-side.
- Raw provider responses are normalized before any event is sent to a client.
- Replacing the STT provider must not require a change to the Web or Mobile protocol.
- The existing `/ws/test` behavior remains unchanged. `/ws/stt` will be a separate endpoint when implemented later.

## 3. Phase 1 Scope

Phase 1 consists of:

1. **P1.1 — STT protocol and audio contract:** define the public protocol and provider boundary.
2. **P1.2 — `/ws/stt` backend baseline:** implement client protocol handling and connection state.
3. **P1.3 — STT provider adapter:** select and integrate a streaming STT provider behind the adapter boundary.
4. **P1.4 — Web microphone streaming:** capture and send compliant microphone audio from Web.
5. **P1.5 — Flutter microphone streaming:** capture and send compliant microphone audio from Flutter.
6. **P1.6 — Interim/final caption rendering:** distinguish and render normalized transcript events.
7. **P1.7 — Vietnamese latency/accuracy benchmark:** test repeatable Vietnamese samples and record results.
8. **P1.8 — Reconnect/error/stability:** exercise disconnections, provider failures, recovery, and continuous streaming.
9. **P1.9 — Spike conclusion:** document evidence and recommend whether to proceed with the selected approach.

## 4. Explicit Non-goals

Phase 1 does not include:

- translation;
- text-to-speech (TTS);
- speaker diarization;
- recording;
- transcript search;
- AI summaries;
- custom dictionaries;
- QR or session sharing;
- billing;
- administration features;
- production-scale authentication or authorization; or
- production-scale session persistence.

The protocol must remain minimal and must not reserve product-level fields for these later features.

## 5. WebSocket Transport and Lifecycle

The initial transport is one WebSocket connection per STT stream at the future `/ws/stt` endpoint.

- Control messages use JSON text frames.
- Audio chunks use binary WebSocket frames.
- Realtime audio chunks must not be encoded as JSON or base64.
- Each connection represents only one STT stream. A client opens a new connection for another stream or after a terminal close.

The normal lifecycle is:

```text
Client                         Backend
  |--- JSON stt.start ---------->|
  |<-- JSON stt.ready -----------|
  |--- binary audio chunk ------>|
  |--- binary audio chunk ------>|
  |             ...              |
  |<-- transcript.interim -------|
  |<-- transcript.final ---------|
  |--- JSON stt.stop ----------->|
  |<-- final transcript(s) ------|  when available after provider flush
  |<-- JSON stt.closed ----------|
```

Clients must wait for `stt.ready` before sending binary audio. `stt.ready` means the backend and provider adapter are ready to accept audio for this stream; WebSocket acceptance alone does not imply streaming readiness.

## 6. Initial Audio Contract

All Phase 1 audio binary frames contain raw audio with this provider-neutral format:

| Property | Required value |
|---|---|
| Encoding | PCM signed 16-bit (`pcm_s16le`) |
| Byte order | Little-endian |
| Channels | 1 (mono) |
| Sample rate | 16,000 Hz |
| Transport | Binary WebSocket frames |
| Target chunk duration | Approximately 100–250 ms |

At 16 kHz, mono, and 16 bits per sample, a 100–250 ms target corresponds to approximately 3,200–8,000 bytes per binary frame. This byte range is guidance for normal chunking, not an additional codec or framing format.

PCM is selected for the spike because it is directly observable, easy to inspect and reproduce, straightforward to benchmark, and portable across provider adapters. Opus/WebM and other codec or bandwidth optimizations are deferred until benchmark evidence establishes whether they are necessary. No codec negotiation is part of the V1 contract.

An empty binary frame is invalid. Binary frames that do not conform to the declared audio format are unsupported audio. The backend is not required to resample, remix, or transcode during this spike.

## 7. Client-to-Backend Control Messages

Every control message is one complete JSON object in a text frame. Unknown or additional fields are not part of the V1 contract and may be rejected as `invalid_message`; clients must not depend on them.

### 7.1 `stt.start`

The client starts the stream with:

```json
{
  "type": "stt.start",
  "audio": {
    "encoding": "pcm_s16le",
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "language": "vi"
}
```

Required V1 fields and semantics:

| Field | Semantics |
|---|---|
| `type` | Must be the exact string `stt.start`. |
| `audio.encoding` | Must be `pcm_s16le`. Samples are signed 16-bit little-endian PCM. |
| `audio.sample_rate_hz` | Must be the integer `16000`. |
| `audio.channels` | Must be the integer `1`. |
| `language` | Must be `vi`, requesting Vietnamese recognition. It is a BCP 47 language tag restricted to Vietnamese for this spike. |

The backend validates the request before starting the provider adapter. A valid request moves the connection from `CONNECTED` to `STARTING`. The backend sends `stt.ready` only after provider startup succeeds and the connection enters `STREAMING`.

### 7.2 Binary audio

Each binary frame sent in `STREAMING` contains the next contiguous chunk of the declared PCM stream. Frame order is audio order. The public protocol adds no sequence number or timestamp to audio frames in V1; the backend records receipt timing internally.

### 7.3 `stt.stop`

The client requests an orderly stop with:

```json
{
  "type": "stt.stop"
}
```

`stt.stop` is valid only in `STREAMING`. It moves the connection to `STOPPING`. The backend asks the adapter to finish input and flush any available final transcript. It sends any resulting `transcript.final` events before `stt.closed` when possible. A provider failure or timeout during the flush is reported as a normalized `stt.error`, followed by terminal closure.

## 8. Backend-to-Client Events

All backend events are JSON objects sent in text frames. The backend owns these public event shapes.

### 8.1 Common required field

Every event has a required `type` string that identifies its schema and meaning. V1 event consumers must branch on `type` and must not inspect raw provider payloads.

### 8.2 `stt.ready`

```json
{
  "type": "stt.ready"
}
```

This event confirms that startup completed and the connection is in `STREAMING`. The client may begin sending binary audio only after receiving it.

### 8.3 Transcript events

Interim example:

```json
{
  "type": "transcript.interim",
  "segment_id": "seg_001",
  "text": "xin chào mọi...",
  "language": "vi"
}
```

Final example:

```json
{
  "type": "transcript.final",
  "segment_id": "seg_001",
  "text": "Xin chào mọi người.",
  "language": "vi"
}
```

Required V1 transcript fields and stable semantics:

| Field | Semantics |
|---|---|
| `type` | `transcript.interim` is a mutable recognition hypothesis. `transcript.final` is the immutable final result for the segment. |
| `segment_id` | A non-empty, backend-assigned identifier stable for all revisions of the same logical segment and unique within the WebSocket stream. It is opaque to clients and need not be stable across connections. |
| `text` | The complete current UTF-8 transcript text for this segment, not a character-level delta. A later interim with the same `segment_id` replaces the earlier interim. Final text replaces the interim and must not be revised afterward. |
| `language` | The normalized BCP 47 language tag for the recognized text; `vi` for this spike. It must not contain a provider-specific language identifier. |

The backend may emit zero or more interim revisions before one final event for a segment. It may also emit a final event without a preceding interim. Event order for a segment is preserved. After a final event, the backend must not emit another interim or final event for the same `segment_id`.

Only the four fields above are required in the V1 transcript contract. Provider confidence, provider request IDs, raw timing objects, alternative hypotheses, token data, and raw provider payloads are not public V1 fields. If they are useful during the spike, the backend may retain them as optional internal/provider metadata for logs or benchmarks. Clients must not receive or depend on that metadata unless a later, separately approved contract change defines it.

### 8.4 `stt.error`

```json
{
  "type": "stt.error",
  "code": "invalid_state",
  "message": "Binary audio is not accepted before stt.ready.",
  "recoverable": false
}
```

Required V1 error fields:

| Field | Semantics |
|---|---|
| `type` | Must be `stt.error`. |
| `code` | One normalized category from the table below. |
| `message` | A safe, concise explanation suitable for client display or diagnostics. It must not contain credentials, raw provider payloads, or sensitive server details. |
| `recoverable` | Whether the same WebSocket connection can continue without restarting the stream. |

Normalized error categories:

| Code | Meaning | Default behavior |
|---|---|---|
| `invalid_message` | A text frame is malformed JSON, is not an object, has an unknown message type, or fails the message schema. | Terminal for V1; send the error and close. |
| `invalid_state` | A valid frame or control type is received in a state where it is not allowed. | Terminal for V1; send the error and close. |
| `unsupported_audio` | The declared audio contract is unsupported, or received audio is detectably incompatible or empty. | Terminal; send the error and close. |
| `provider_unavailable` | The configured provider cannot be reached or cannot start the stream. | Terminal for this connection; a new connection may be attempted later. |
| `provider_error` | The provider fails after startup or returns an unusable response. | Terminal for this connection; a new connection may be attempted later. |
| `internal_error` | An unexpected backend or adapter failure occurs. | Terminal; send a safe error when possible and close. |

All V1 protocol errors are terminal to keep spike behavior deterministic. Accordingly, normalized errors emitted by the backend currently use `recoverable: false`. The field is retained to make terminal behavior explicit, not to introduce an in-connection recovery system. Recovery means creating a new WebSocket stream after closure. Provider-specific error codes and payloads may be recorded internally but must not replace or extend the public envelope.

If the client transport disconnects so abruptly that no event can be delivered, the backend records the failure internally and closes provider resources without promising an `stt.error` delivery.

### 8.5 `stt.closed`

```json
{
  "type": "stt.closed"
}
```

This is the terminal protocol event. It means the backend has stopped accepting audio, completed best-effort provider cleanup, and will close the WebSocket. On a normal `stt.stop`, it follows any final transcript produced during flush. On an error path, it follows `stt.error` when the connection is still writable. Clients must not send additional frames after receiving it.

## 9. Connection State Model

The state is connection-local and owned by the FastAPI WebSocket handler.

```text
WebSocket accepted
      |
      v
  CONNECTED -- valid stt.start --> STARTING -- adapter ready --> STREAMING
      |                                |                         |
      | invalid frame                  | startup failure         | valid stt.stop
      v                                v                         v
    ERROR <-------------------------- ERROR                   STOPPING
      |                                                          |
      | error sent / cleanup                                     | flush + cleanup
      v                                                          v
   CLOSED <---------------------------------------------------- CLOSED

Transport disconnect from any non-closed state -> CLOSED after best-effort cleanup.
Unexpected failure from STARTING, STREAMING, or STOPPING -> ERROR -> CLOSED.
```

State semantics:

| State | Meaning |
|---|---|
| `CONNECTED` | WebSocket is accepted; the backend is waiting for exactly one `stt.start`. |
| `STARTING` | The start request is valid and the adapter is establishing the provider stream. Audio is not yet accepted. |
| `STREAMING` | `stt.ready` has been sent; binary audio and one `stt.stop` are accepted. |
| `STOPPING` | Input is closed; the backend is flushing final results and cleaning up. No client input is accepted. |
| `ERROR` | A terminal normalized error is being reported and resources are being cleaned up. |
| `CLOSED` | Terminal state; no frames are accepted or emitted after the WebSocket closes. |

Invalid transitions and inputs:

| Input | State | Result |
|---|---|---|
| Binary audio | `CONNECTED` or `STARTING` | `invalid_state`; audio before `stt.start`/`stt.ready` is not accepted. |
| `stt.start` | `STARTING`, `STREAMING`, or `STOPPING` | `invalid_state`; duplicate start is forbidden. |
| `stt.stop` | `CONNECTED` or `STARTING` | `invalid_state`; no stream is ready to stop. |
| Binary audio | `STOPPING` | `invalid_state`; audio after `stt.stop` is forbidden. |
| Any client frame | `ERROR` or `CLOSED` | Not processed; the backend is closing or the transport is already closed. |
| Malformed/unknown text control | Any input-accepting state | `invalid_message`. |
| Text frame where binary audio is expected | `STREAMING` | `invalid_message` unless it is the valid `stt.stop` control. |

The backend should reject an invalid transition with one `stt.error`, perform best-effort cleanup, send `stt.closed` if possible, and close the WebSocket. This simple terminal policy is deliberate for the spike.

## 10. Provider Adapter Boundary

The backend implementation will separate public protocol handling from provider integration.

### FastAPI WebSocket responsibilities

- accept and close the client WebSocket;
- parse and validate `stt.start` and `stt.stop` text frames;
- validate frame type and enforce the connection state machine;
- pass ordered PCM chunks to the adapter only while streaming;
- convert adapter outputs into the normalized public events;
- assign or preserve backend segment IDs with V1 semantics;
- map adapter failures to normalized error categories; and
- record connection-level benchmark and failure measurements.

### Provider adapter responsibilities

- establish and close the provider-specific streaming session;
- translate the provider-neutral start configuration into provider settings;
- send PCM chunks using the provider's streaming protocol;
- request an orderly provider flush on stop;
- interpret provider-specific interim, final, and failure responses;
- return provider-neutral transcript results and adapter errors to the WebSocket layer; and
- keep provider credentials, endpoints, SDK types, raw messages, and configuration server-side.

The conceptual boundary can be implemented later with operations equivalent to:

```text
start(audio_config, language)
send_audio(bytes)
finish_input()
events -> interim | final | adapter_error
close()
```

This is a behavioral interface, not a required code signature. P1.3 may choose asynchronous types that fit FastAPI and the selected provider, provided the responsibilities and public protocol remain unchanged. Provider selection and integration are explicitly deferred to P1.3.

## 11. Spike Observability and Benchmark Measurements

Phase 1 needs targeted measurements, not production-scale observability infrastructure. The backend should record monotonic timestamps where elapsed time is calculated and wall-clock timestamps where event correlation is useful.

At minimum, record internally:

- stream start: WebSocket acceptance, valid `stt.start` receipt, adapter-start attempt, and `stt.ready` emission;
- each audio chunk receipt time, byte count, and connection-local ordering information;
- each interim transcript receipt time from the adapter and normalized event emission time;
- each final transcript receipt time from the adapter and normalized event emission time;
- `stt.stop` receipt, provider flush completion, `stt.closed` emission, and transport close;
- client disconnects, reconnect attempts/successes observed as new streams, provider startup failures, midstream provider failures, protocol errors, and cleanup outcomes.

These measurements support at least:

- startup latency from accepted `stt.start` to `stt.ready`;
- interim and final latency relative to the relevant received audio boundary;
- backend normalization/dispatch overhead;
- stream duration and final-flush duration;
- continuous-stream reliability; and
- failure and reconnect outcomes.

Audio-to-transcript latency cannot be measured honestly from server receipt time alone unless the benchmark defines the relevant audio boundary. P1.7 must use repeatable samples and a documented method that associates known utterance timing or end-of-utterance timing with received chunks, then reports the calculation consistently for Web and Flutter.

Benchmark identifiers, raw provider metadata, detailed timestamps, and provider error details remain internal by default. The required V1 client events contain no benchmark fields. Logs and reports must not include credentials, secrets, or raw sensitive configuration.

## 12. Reconnect, Failure, and Stability Expectations

V1 does not resume an STT stream across WebSocket connections. A disconnected or terminally failed stream is closed and cleaned up. Reconnect creates a new WebSocket, sends a new `stt.start`, waits for a new `stt.ready`, and produces a new connection-local segment ID namespace.

The spike must make failures visible to clients when transport permits, using `stt.error` followed by `stt.closed`. Client UI should distinguish a stopped/closed stream from an active stream and expose reconnect failure rather than silently discarding it. Exact retry timing and production backoff policy are outside P1.1; P1.8 will test a minimal bounded reconnect behavior without promising transcript continuity across connections.

Continuous-stream testing must document test duration, client type, audio sample/input conditions, transcript event counts, disconnects, provider errors, and whether cleanup and restart succeeded. Acceptance thresholds are evidence-driven outputs of benchmarking rather than guessed values in P1.1.

## 13. Phase 1 Success Criteria

The completed spike must demonstrate that:

1. Web microphone audio flows through the backend and STT adapter to realtime transcript events.
2. Flutter microphone audio flows through the backend and STT adapter to realtime transcript events.
3. Interim and final transcript events are distinguishable.
4. Vietnamese speech quality is tested with repeatable samples.
5. End-to-end latency is measured rather than guessed.
6. Continuous streaming stability is tested.
7. Disconnect/reconnect and provider failures are handled visibly.
8. The provider can be replaced behind the adapter without changing the client protocol.
9. Results are documented so the team can decide whether the selected STT approach is suitable for the product.

## 14. P1.1 Definition of Done

P1.1 is complete when:

- the public WebSocket message contract is unambiguous;
- the binary audio transport and PCM format are unambiguous;
- the connection state model and invalid transitions are defined;
- normalized errors and terminal behavior are defined;
- the provider adapter boundary and responsibilities are defined;
- assumptions, scope, and non-goals are explicit;
- no provider-specific implementation detail leaks into the public protocol; and
- implementation of the contract can begin without selecting an STT provider.

## 15. Assumptions and Deferred Decisions

The design assumes the existing FastAPI, Next.js, and Flutter baseline WebSocket connectivity remains available and that `/ws/test` continues unchanged.

The following decisions are intentionally deferred:

- actual STT provider selection, credentials, SDK, and integration details to P1.3;
- benchmark samples, scoring method, and evidence-based acceptance thresholds to P1.7;
- minimal reconnect timing and stability test procedure to P1.8; and
- codec or bandwidth optimization until benchmark evidence justifies a separate decision.

These deferred implementation choices must remain compatible with the public V1 protocol defined here. Any future change to that protocol requires separate human approval.
