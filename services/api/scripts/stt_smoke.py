"""Developer CLI for streaming raw PCM audio through the local /ws/stt endpoint."""

import argparse
import asyncio
import json
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

from websockets.asyncio.client import connect


DEFAULT_WS_URL = "ws://127.0.0.1:8000/ws/stt"
PCM_BYTES_PER_SECOND = 16000 * 1 * 2
CHUNK_SIZE = PCM_BYTES_PER_SECOND // 10


def _print_event(event: dict[str, object], started_at: float) -> None:
    elapsed = time.perf_counter() - started_at
    print(f"[+{elapsed:.3f}s] {json.dumps(event, ensure_ascii=False)}", flush=True)


async def _receive_until_closed(websocket: Any, started_at: float) -> None:
    async for raw_message in websocket:
        event = json.loads(raw_message)
        if not isinstance(event, dict):
            continue
        _print_event(event, started_at)
        if event.get("type") == "stt.closed":
            return


async def run_smoke(
    audio_path: Path,
    ws_url: str = DEFAULT_WS_URL,
    *,
    connector: Callable[..., Any] = connect,
    pace_audio: bool = True,
) -> None:
    started_at = time.perf_counter()
    async with connector(ws_url) as websocket:
        await websocket.send(
            json.dumps(
                {
                    "type": "stt.start",
                    "audio": {
                        "encoding": "pcm_s16le",
                        "sample_rate_hz": 16000,
                        "channels": 1,
                    },
                    "language": "vi",
                },
                separators=(",", ":"),
            )
        )
        first_event = json.loads(await websocket.recv())
        if not isinstance(first_event, dict):
            raise RuntimeError("Backend returned a non-object STT event")
        _print_event(first_event, started_at)

        if first_event.get("type") != "stt.ready":
            if first_event.get("type") != "stt.closed":
                await _receive_until_closed(websocket, started_at)
            return

        receiver = asyncio.create_task(_receive_until_closed(websocket, started_at))
        try:
            with audio_path.open("rb") as audio_file:
                while chunk := audio_file.read(CHUNK_SIZE):
                    await websocket.send(chunk)
                    if pace_audio:
                        await asyncio.sleep(len(chunk) / PCM_BYTES_PER_SECOND)
            await websocket.send('{"type":"stt.stop"}')
            await receiver
        finally:
            if not receiver.done():
                receiver.cancel()
                try:
                    await receiver
                except asyncio.CancelledError:
                    pass


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Stream raw PCM S16LE 16 kHz mono audio through the local STT backend."
        )
    )
    parser.add_argument("audio_path", type=Path)
    parser.add_argument("--url", default=DEFAULT_WS_URL)
    args = parser.parse_args()
    asyncio.run(run_smoke(args.audio_path, args.url))


if __name__ == "__main__":
    main()
