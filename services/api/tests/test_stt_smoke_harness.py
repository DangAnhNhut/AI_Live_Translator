import asyncio
import json


class FakeBackendWebSocket:
    def __init__(self, incoming: tuple[dict[str, object], ...]) -> None:
        self.incoming = asyncio.Queue()
        for event in incoming:
            self.incoming.put_nowait(json.dumps(event))
        self.sent: list[str | bytes] = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        return False

    def __aiter__(self):
        return self

    async def __anext__(self):
        message = await self.recv()
        return message

    async def recv(self) -> str:
        return await self.incoming.get()

    async def send(self, message: str | bytes) -> None:
        self.sent.append(message)


class FakeBackendConnector:
    def __init__(self, websocket: FakeBackendWebSocket) -> None:
        self.websocket = websocket
        self.calls: list[str] = []

    def __call__(self, uri: str):
        self.calls.append(uri)
        return self.websocket


def test_smoke_harness_streams_pcm_through_backend_and_prints_timed_events(
    tmp_path,
    capsys,
):
    from scripts.stt_smoke import run_smoke

    audio = b"\x00\x00\x01\x00"
    audio_path = tmp_path / "vietnamese-sample.pcm"
    audio_path.write_bytes(audio)
    websocket = FakeBackendWebSocket(
        (
            {"type": "stt.ready"},
            {
                "type": "transcript.interim",
                "segment_id": "seg_001",
                "text": "xin chào",
                "language": "vi",
            },
            {
                "type": "transcript.final",
                "segment_id": "seg_001",
                "text": "Xin chào.",
                "language": "vi",
            },
            {"type": "stt.closed"},
        )
    )
    connector = FakeBackendConnector(websocket)

    asyncio.run(
        run_smoke(
            audio_path,
            "ws://127.0.0.1:8000/ws/stt",
            connector=connector,
            pace_audio=False,
        )
    )

    assert connector.calls == ["ws://127.0.0.1:8000/ws/stt"]
    assert json.loads(websocket.sent[0]) == {
        "type": "stt.start",
        "audio": {
            "encoding": "pcm_s16le",
            "sample_rate_hz": 16000,
            "channels": 1,
        },
        "language": "vi",
    }
    assert websocket.sent[1] == audio
    assert json.loads(websocket.sent[2]) == {"type": "stt.stop"}
    output = capsys.readouterr().out
    assert "[+" in output
    assert "stt.ready" in output
    assert "transcript.interim" in output
    assert "transcript.final" in output
    assert "stt.closed" in output
