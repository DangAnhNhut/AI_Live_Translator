import json
from enum import Enum
from typing import Literal, TypeAlias

from pydantic import BaseModel, ConfigDict, ValidationError


ErrorCode: TypeAlias = Literal[
    "invalid_message",
    "invalid_state",
    "unsupported_audio",
    "provider_unavailable",
    "provider_error",
    "internal_error",
]
TranscriptKind: TypeAlias = Literal["interim", "final"]


class AudioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    encoding: Literal["pcm_s16le"]
    sample_rate_hz: Literal[16000]
    channels: Literal[1]


class SttStart(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stt.start"]
    audio: AudioConfig
    language: Literal["vi"]


class SttStop(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stt.stop"]


ControlMessage: TypeAlias = SttStart | SttStop


class ProtocolViolation(Exception):
    def __init__(self, code: ErrorCode, message: str):
        super().__init__(message)
        self.code = code
        self.message = message
        self.recoverable = False


def parse_control_message(text: str) -> ControlMessage:
    try:
        payload = json.loads(text)
    except (json.JSONDecodeError, TypeError) as exc:
        raise ProtocolViolation("invalid_message", "Control message must be valid JSON.") from exc

    if not isinstance(payload, dict):
        raise ProtocolViolation("invalid_message", "Control message must be a JSON object.")

    message_type = payload.get("type")
    if message_type == "stt.stop":
        try:
            return SttStop.model_validate(payload)
        except ValidationError as exc:
            raise ProtocolViolation("invalid_message", "Invalid stt.stop message.") from exc

    if message_type != "stt.start":
        raise ProtocolViolation("invalid_message", "Unknown control message type.")

    if set(payload) != {"type", "audio", "language"} or payload.get("language") != "vi":
        raise ProtocolViolation("invalid_message", "Invalid stt.start message.")

    try:
        return SttStart.model_validate(payload)
    except ValidationError as exc:
        raise ProtocolViolation("unsupported_audio", "Unsupported audio declaration.") from exc


def ready_event() -> dict[str, object]:
    return {"type": "stt.ready"}


def transcript_event(
    kind: TranscriptKind,
    segment_id: str,
    text: str,
    language: Literal["vi"] = "vi",
) -> dict[str, object]:
    return {
        "type": f"transcript.{kind}",
        "segment_id": segment_id,
        "text": text,
        "language": language,
    }


def error_event(code: ErrorCode, message: str) -> dict[str, object]:
    return {
        "type": "stt.error",
        "code": code,
        "message": message,
        "recoverable": False,
    }


def closed_event() -> dict[str, object]:
    return {"type": "stt.closed"}


class ConnectionState(str, Enum):
    CONNECTED = "CONNECTED"
    STARTING = "STARTING"
    STREAMING = "STREAMING"
    STOPPING = "STOPPING"
    ERROR = "ERROR"
    CLOSED = "CLOSED"


class SttStateMachine:
    def __init__(self) -> None:
        self.state = ConnectionState.CONNECTED

    def begin_start(self) -> None:
        self._transition(ConnectionState.CONNECTED, ConnectionState.STARTING)

    def mark_ready(self) -> None:
        self._transition(ConnectionState.STARTING, ConnectionState.STREAMING)

    def require_audio_allowed(self) -> None:
        if self.state is not ConnectionState.STREAMING:
            raise ProtocolViolation("invalid_state", "Binary audio is not accepted in this state.")

    def begin_stop(self) -> None:
        self._transition(ConnectionState.STREAMING, ConnectionState.STOPPING)

    def mark_error(self) -> None:
        if self.state is ConnectionState.CLOSED:
            raise ProtocolViolation("invalid_state", "Closed streams cannot enter ERROR.")
        self.state = ConnectionState.ERROR

    def mark_closed(self) -> None:
        self.state = ConnectionState.CLOSED

    def _transition(self, expected: ConnectionState, target: ConnectionState) -> None:
        if self.state is not expected:
            raise ProtocolViolation(
                "invalid_state",
                f"Cannot transition from {self.state} to {target}.",
            )
        self.state = target
