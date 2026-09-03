from collections.abc import Sequence
from typing import Literal, TypeAlias

from app.realtime.stt_protocol import TargetLanguage


SourceLanguage: TypeAlias = Literal["vi"]
TranslationErrorCode: TypeAlias = Literal[
    "provider_unavailable",
    "provider_error",
    "queue_overflow",
    "request_timeout",
    "internal_error",
]


def translation_configured_event(
    *,
    stream_id: str,
    source_language: SourceLanguage,
    target_language: TargetLanguage,
) -> dict[str, object]:
    return {
        "type": "translation.configured",
        "stream_id": stream_id,
        "source_language": source_language,
        "target_language": target_language,
    }


def translation_pending_event(
    *,
    stream_id: str,
    utterance_id: str,
    source_segment_ids: Sequence[str],
    source_text: str,
    source_language: SourceLanguage,
    target_language: TargetLanguage,
) -> dict[str, object]:
    return {
        "type": "translation.pending",
        "stream_id": stream_id,
        "utterance_id": utterance_id,
        "source_segment_ids": list(source_segment_ids),
        "source_text": source_text,
        "source_language": source_language,
        "target_language": target_language,
    }


def translation_final_event(
    *,
    stream_id: str,
    utterance_id: str,
    source_segment_ids: Sequence[str],
    source_text: str,
    translated_text: str,
    source_language: SourceLanguage,
    target_language: TargetLanguage,
) -> dict[str, object]:
    event = translation_pending_event(
        stream_id=stream_id,
        utterance_id=utterance_id,
        source_segment_ids=source_segment_ids,
        source_text=source_text,
        source_language=source_language,
        target_language=target_language,
    )
    event["type"] = "translation.final"
    event["translated_text"] = translated_text
    return event


def translation_utterance_error_event(
    *,
    stream_id: str,
    utterance_id: str,
    source_segment_ids: Sequence[str],
    source_text: str,
    source_language: SourceLanguage,
    target_language: TargetLanguage,
    code: TranslationErrorCode,
    message: str,
) -> dict[str, object]:
    event = translation_pending_event(
        stream_id=stream_id,
        utterance_id=utterance_id,
        source_segment_ids=source_segment_ids,
        source_text=source_text,
        source_language=source_language,
        target_language=target_language,
    )
    event.update(
        {
            "type": "translation.error",
            "scope": "utterance",
            "code": code,
            "message": message,
        }
    )
    return event


def translation_session_error_event(
    *,
    stream_id: str,
    source_language: SourceLanguage,
    target_language: TargetLanguage,
    code: TranslationErrorCode,
    message: str,
) -> dict[str, object]:
    return {
        "type": "translation.error",
        "scope": "session",
        "stream_id": stream_id,
        "source_language": source_language,
        "target_language": target_language,
        "code": code,
        "message": message,
    }
