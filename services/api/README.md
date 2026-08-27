# Realtime STT backend development

Checkpoint A enables the backend to use Deepgram as the real realtime STT
upstream. The public client flow remains `stt.start`, binary PCM audio, and
`stt.stop`; clients receive only the existing normalized transcript, error,
and closed events.

## Configuration

Run the API from `services/api` so Pydantic Settings loads `services/api/.env`.
Copy the repository `.env.example` locally and configure:

```dotenv
STT_PROVIDER=deepgram
DEEPGRAM_API_KEY=<your Deepgram API key>
DEEPGRAM_MODEL=nova-3
DEEPGRAM_LANGUAGE=vi
DEEPGRAM_ENDPOINTING_MS=300
```

Never commit the local `.env` or include the key in logs, screenshots, or bug
reports. If the provider is unset, unsupported, or selected without a key,
`/ws/stt` returns the existing `provider_unavailable` lifecycle.

## Run the backend

From `services/api` in PowerShell:

```powershell
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload
```

The configured flow is:

```text
developer client -> ws://127.0.0.1:8000/ws/stt -> Deepgram adapter
                 <- normalized interim/final/error/closed events <-
```

The adapter sends the existing PCM S16LE, 16 kHz, mono client audio to
Deepgram as `linear16` and keeps provider JSON and segment tracking internal.

## Run the real-provider smoke harness

Prepare a raw headerless PCM S16LE, 16000 Hz, mono file. With the backend
running and configured, run from `services/api`:

```powershell
.\.venv\Scripts\python.exe scripts\stt_smoke.py D:\path\sample-vi.pcm
```

Use `--url` only if the local backend is listening at another WebSocket URL.
The harness connects to our backend—not Deepgram directly—and prints elapsed
timestamps with ready, interim, final, error, and closed events for basic
latency observation.

Real microphone capture and streaming are a later checkpoint. This checkpoint
only enables the real STT upstream provider in the backend.
