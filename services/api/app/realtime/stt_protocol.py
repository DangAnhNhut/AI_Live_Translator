import json
from enum import Enum
from typing import Literal, TypeAlias

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_validator,
    model_validator,
)


ErrorCode: TypeAlias = Literal[
    "invalid_message",
    "invalid_state",
    "unsupported_audio",
    "session_producer_conflict",
    "provider_unavailable",
    "provider_error",
    "internal_error",
]
TranscriptKind: TypeAlias = Literal["interim", "final"]
TargetLanguage: TypeAlias = Literal[
    "en",
    "ja",
    "ko",
    "zh-CN",
    "th",
    "fr",
    "de",
    "es",
]


class AudioConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    encoding: Literal["pcm_s16le"]
    sample_rate_hz: Literal[16000]
    channels: Literal[1]


class TranslationConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    target_language: TargetLanguage


class TtsConfig(BaseModel):
    model_config = ConfigDict(extra="forbid")

    enabled: bool = Field(strict=True)
    voice: str | None = Field(default=None, min_length=1, max_length=128)

    @field_validator("voice")
    @classmethod
    def reject_blank_voice(cls, value: str | None) -> str | None:
        if value is not None and not value.strip():
            raise ValueError("voice must not be blank")
        return value


class SttStart(BaseModel):
    model_config = ConfigDict(extra="forbid")

    type: Literal["stt.start"]
    audio: AudioConfig
    language: Literal["vi"]
    session_id: str | None = Field(
        default=None,
        min_length=1,
        max_length=64,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$",
    )
    translation: TranslationConfig | None = None
    tts: TtsConfig | None = None

    @model_validator(mode="after")
    def require_translation_for_enabled_tts(self) -> "SttStart":
        if self.tts is not None and self.tts.enabled and self.translation is None:
            raise ValueError("enabled TTS requires translation")
        return self


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

    required_fields = {"type", "audio", "language"}
    allowed_fields = required_fields | {"session_id", "translation", "tts"}
    if (
        not required_fields.issubset(payload)
        or not set(payload).issubset(allowed_fields)
        or payload.get("language") != "vi"
        or ("session_id" in payload and payload["session_id"] is None)
        or ("translation" in payload and payload["translation"] is None)
        or ("tts" in payload and payload["tts"] is None)
    ):
        raise ProtocolViolation("invalid_message", "Invalid stt.start message.")

    try:
        return SttStart.model_validate(payload)
    except ValidationError as exc:
        if any(
            not error["loc"]
            or error["loc"][:1]
            in (("session_id",), ("translation",), ("tts",))
            for error in exc.errors()
        ):
            raise ProtocolViolation(
                "invalid_message", "Invalid stt.start message."
            ) from exc
        raise ProtocolViolation("unsupported_audio", "Unsupported audio declaration.") from exc


def ready_event(*, stream_id: str | None = None) -> dict[str, object]:
    event: dict[str, object] = {"type": "stt.ready"}
    if stream_id is not None:
        event["stream_id"] = stream_id
    return event


def transcript_event(
    kind: TranscriptKind,
    segment_id: str,
    text: str,
    language: Literal["vi"] = "vi",
    *,
    stream_id: str | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "type": f"transcript.{kind}",
        "segment_id": segment_id,
        "text": text,
        "language": language,
    }
    if stream_id is not None:
        event["stream_id"] = stream_id
    return event


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
