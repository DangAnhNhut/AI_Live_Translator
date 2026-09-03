from typing import Literal, TypeAlias

from app.realtime.stt_protocol import TargetLanguage


TtsErrorCode: TypeAlias = Literal[
    "provider_unavailable",
    "provider_error",
    "queue_overflow",
    "request_timeout",
    "invalid_audio",
    "internal_error",
]


def tts_configured_event(
    *,
    stream_id: str,
    target_language: TargetLanguage,
    voice: str | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "type": "tts.configured",
        "stream_id": stream_id,
        "target_language": target_language,
    }
    if voice is not None:
        event["voice"] = voice
    return event


def tts_pending_event(
    *,
    stream_id: str,
    utterance_id: str,
    target_language: TargetLanguage,
) -> dict[str, object]:
    return {
        "type": "tts.pending",
        "stream_id": stream_id,
        "utterance_id": utterance_id,
        "target_language": target_language,
    }


def tts_audio_event(
    *,
    stream_id: str,
    utterance_id: str,
    audio_id: str,
    target_language: TargetLanguage,
    mime_type: str,
    byte_length: int,
    sample_rate_hz: int | None = None,
) -> dict[str, object]:
    event: dict[str, object] = {
        "type": "tts.audio",
        "stream_id": stream_id,
        "utterance_id": utterance_id,
        "audio_id": audio_id,
        "target_language": target_language,
        "mime_type": mime_type,
        "byte_length": byte_length,
    }
    if sample_rate_hz is not None:
        event["sample_rate_hz"] = sample_rate_hz
    return event


def tts_utterance_error_event(
    *,
    stream_id: str,
    utterance_id: str,
    target_language: TargetLanguage,
    code: TtsErrorCode,
    message: str,
) -> dict[str, object]:
    event = tts_pending_event(
        stream_id=stream_id,
        utterance_id=utterance_id,
        target_language=target_language,
    )
    event.update(
        {
            "type": "tts.error",
            "scope": "utterance",
            "code": code,
            "message": message,
        }
    )
    return event


def tts_session_error_event(
    *,
    stream_id: str,
    target_language: TargetLanguage,
    code: TtsErrorCode,
    message: str,
) -> dict[str, object]:
    return {
        "type": "tts.error",
        "scope": "session",
        "stream_id": stream_id,
        "target_language": target_language,
        "code": code,
        "message": message,
    }
