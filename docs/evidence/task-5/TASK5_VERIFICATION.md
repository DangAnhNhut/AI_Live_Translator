# Task 5 Verification Evidence

## Scope

Task 5 verifies the current technical baseline before moving to P1.3.

The Google Stitch link is currently a UI prototype for design/flow review only.
Permission, Listening, Paused, Reconnecting, Error, Stop, and Timer behaviors
have not yet been implemented as production UI state logic.

---

## Git

Branch:

feature/stt-technical-spike

Verification:

- Working tree clean
- No uncommitted changes before verification

---

## Backend

### Automated tests

Command:

python -m pytest -v

Result:

PASS - 52/52 tests passed

Covered areas include:

- CORS
- STT control protocol
- STT state machine
- Provider-neutral STT boundary
- STT WebSocket lifecycle
- Invalid WebSocket states
- Provider failure normalization
- Interim/final transcript rules
- Stop/final flush behavior
- Abrupt client disconnect cleanup
- WebSocket echo endpoint

Note:

One non-blocking Starlette TestClient deprecation warning is currently present.

---

## Backend Runtime

Command:

uvicorn app.main:app --reload

Result:

PASS

Server:

http://127.0.0.1:8000

---

## WebSocket Runtime

Endpoint:

/ws/test

Runtime verification:

- Connect: PASS
- Send message: PASS
- Receive echoed message: PASS
- Disconnect: PASS

Verified message:

Xin chao tu Task 5 runtime verification

---

## STT WebSocket Runtime

Endpoint:

/ws/stt

Input:

stt.start
audio encoding: pcm_s16le
sample rate: 16000 Hz
channels: 1
language: vi

Runtime result:

PASS - STT WebSocket protocol/error path behaves as designed.

Server response:

stt.error
code: provider_unavailable
recoverable: false

followed by:

stt.closed

Interpretation:

The provider-neutral STT WebSocket baseline is working.
A real STT provider is not configured yet, therefore real speech-to-text
transcription has not been verified.

---

## Web

npm run lint

PASS

npm run build

PASS

Next.js production build compiled successfully.

npm test

N/A - no automated test script is currently configured in package.json.

---

## Mobile

flutter test

PASS - 22/22 tests passed

Covered behavior includes:

- Backend health online
- Backend health offline
- Health retry
- Retry loading state
- WebSocket connect
- WebSocket disconnect
- WebSocket send/receive echo
- Remote WebSocket close handling

flutter analyze

PASS - No issues found

---

## UI Prototype

Google Stitch is currently used only for:

- UI design review
- Expected user flow review
- Visual state review

The Stitch prototype is not the runtime implementation.

The following runtime UI states remain pending implementation/verification:

- Permission
- Connecting
- Listening
- Paused
- Reconnecting
- Error
- Stop behavior
- Session timer

---

## Task 5 Status

PASS:
- Backend automated verification
- Backend runtime
- WebSocket runtime
- STT protocol/runtime error path
- Web lint
- Web production build
- Mobile automated tests
- Mobile static analysis

PENDING:
- Real STT provider integration
- Real microphone audio -> transcript verification
- Production UI state machine
- Full UI runtime flow verification

P1.3 should not start until the agreed Task 5 acceptance scope is reviewed.
