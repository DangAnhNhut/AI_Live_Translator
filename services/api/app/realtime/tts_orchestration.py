import asyncio
import logging
from collections.abc import Sequence
from typing import cast

from app.realtime.stt_protocol import TargetLanguage
from app.realtime.translation_session import TranslationEventPublisher
from app.realtime.tts_protocol import tts_session_error_event
from app.realtime.tts_session import TtsSession


_LOGGER = logging.getLogger(__name__)
_INTERNAL_ERROR_MESSAGE = "Speech synthesis failed for this passage."


class TranslationFinalTtsBridge:
    """Publishes Translation events and routes committed results to TTS."""

    def __init__(
        self,
        *,
        publish_event: TranslationEventPublisher,
        tts_session: TtsSession,
        stream_id: str,
        target_language: TargetLanguage,
    ) -> None:
        self._publish_event = publish_event
        self._tts_session = tts_session
        self._stream_id = stream_id
        self._target_language = target_language
        self._active = True

    async def publish(self, event: dict[str, object]) -> None:
        await self._publish_event(event)
        if not self._active or event.get("type") != "translation.final":
            return
        try:
            await self._tts_session.submit(
                stream_id=_required_str(event, "stream_id"),
                utterance_id=_required_str(event, "utterance_id"),
                source_segment_ids=_required_string_sequence(
                    event, "source_segment_ids"
                ),
                translated_text=_required_str(event, "translated_text"),
                target_language=_required_target(
                    event, self._target_language
                ),
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            await self._disable_tts(type(exc).__name__)

    async def _disable_tts(self, exception_name: str) -> None:
        self._active = False
        _LOGGER.warning(
            "Disabling translation-to-TTS bridge after %s", exception_name
        )
        try:
            await self._tts_session.abort()
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _LOGGER.warning(
                "TTS abort failed with %s", type(exc).__name__
            )
        try:
            await self._publish_event(
                tts_session_error_event(
                    stream_id=self._stream_id,
                    target_language=self._target_language,
                    code="internal_error",
                    message=_INTERNAL_ERROR_MESSAGE,
                )
            )
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _LOGGER.warning(
                "TTS session-error publication failed with %s",
                type(exc).__name__,
            )


def _required_str(event: dict[str, object], field: str) -> str:
    value = event.get(field)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _required_string_sequence(
    event: dict[str, object], field: str
) -> Sequence[str]:
    value = event.get(field)
    if (
        not isinstance(value, Sequence)
        or isinstance(value, (str, bytes))
        or not value
        or any(
            not isinstance(segment_id, str) or not segment_id.strip()
            for segment_id in value
        )
    ):
        raise ValueError(f"{field} must contain non-empty strings")
    return cast(Sequence[str], value)


def _required_target(
    event: dict[str, object], target_language: TargetLanguage
) -> TargetLanguage:
    value = _required_str(event, "target_language")
    if value != target_language:
        raise ValueError("target_language does not match TtsSession")
    return target_language
