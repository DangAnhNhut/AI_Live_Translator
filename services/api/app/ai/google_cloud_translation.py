import asyncio
from collections.abc import Awaitable, Callable
from typing import Protocol

from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
    TranslationResult,
)
from app.realtime.stt_protocol import TargetLanguage
from app.realtime.translation_protocol import SourceLanguage


class GoogleTranslationClient(Protocol):
    def translate_text(
        self,
        *,
        request: dict[str, object],
    ) -> Awaitable[object]: ...


GoogleClientFactory = Callable[[], GoogleTranslationClient]


def _create_google_translation_client() -> GoogleTranslationClient:
    from google.cloud import translate_v3

    return translate_v3.TranslationServiceAsyncClient()


class GoogleCloudTranslator:
    def __init__(
        self,
        *,
        project_id: str,
        location: str,
        client: GoogleTranslationClient | None = None,
        client_factory: GoogleClientFactory = _create_google_translation_client,
    ) -> None:
        self._parent = f"projects/{project_id}/locations/{location}"
        if client is not None:
            self._client = client
            return
        try:
            self._client = client_factory()
        except Exception:
            raise TranslationProviderUnavailable(
                "Google Cloud Translation is unavailable"
            ) from None

    async def translate(
        self,
        *,
        text: str,
        source_language: SourceLanguage,
        target_language: TargetLanguage,
    ) -> TranslationResult:
        request: dict[str, object] = {
            "parent": self._parent,
            "contents": [text],
            "source_language_code": source_language,
            "target_language_code": target_language,
            "mime_type": "text/plain",
            "model": f"{self._parent}/models/general/nmt",
        }
        try:
            response = await self._client.translate_text(request=request)
        except asyncio.CancelledError:
            raise
        except Exception:
            raise TranslationProviderError(
                "Google Cloud Translation request failed"
            ) from None

        translations = getattr(response, "translations", None)
        if not translations:
            raise TranslationProviderError(
                "Invalid Google Translation response"
            )
        translated_text = getattr(translations[0], "translated_text", None)
        if not isinstance(translated_text, str) or not translated_text.strip():
            raise TranslationProviderError(
                "Invalid Google Translation response"
            )
        return TranslationResult(translated_text=translated_text)
