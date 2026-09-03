import asyncio
from collections.abc import Callable
from typing import Protocol

import httpx

from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
    TranslationResult,
)
from app.realtime.stt_protocol import TargetLanguage
from app.realtime.translation_protocol import SourceLanguage


DEFAULT_CLOUDFLARE_TRANSLATION_MODEL = "@cf/meta/m2m100-1.2b"
_CLOUDFLARE_API_BASE_URL = "https://api.cloudflare.com/client/v4"
_PROVIDER_LANGUAGE_CODES: dict[str, str] = {
    "vi": "vi",
    "en": "en",
    "ja": "ja",
    "ko": "ko",
    "zh-CN": "zh",
    "th": "th",
    "fr": "fr",
    "de": "de",
    "es": "es",
}


class CloudflareHttpResponse(Protocol):
    def raise_for_status(self) -> None: ...

    def json(self) -> object: ...


class CloudflareHttpClient(Protocol):
    async def post(
        self,
        url: str,
        *,
        headers: dict[str, str],
        json: dict[str, str],
    ) -> CloudflareHttpResponse: ...


CloudflareClientFactory = Callable[[], CloudflareHttpClient]


def _create_http_client() -> CloudflareHttpClient:
    return httpx.AsyncClient()


class CloudflareTranslator:
    def __init__(
        self,
        *,
        account_id: str,
        api_token: str,
        model: str = DEFAULT_CLOUDFLARE_TRANSLATION_MODEL,
        client: CloudflareHttpClient | None = None,
        client_factory: CloudflareClientFactory = _create_http_client,
    ) -> None:
        normalized_account_id = account_id.strip()
        normalized_api_token = api_token.strip()
        normalized_model = model.strip()
        if (
            not normalized_account_id
            or not normalized_api_token
            or not normalized_model
        ):
            raise TranslationProviderUnavailable(
                "Cloudflare Translation is unavailable"
            )

        self._endpoint = (
            f"{_CLOUDFLARE_API_BASE_URL}/accounts/"
            f"{normalized_account_id}/ai/run/{normalized_model}"
        )
        self._headers = {
            "Authorization": f"Bearer {normalized_api_token}"
        }
        if client is not None:
            self._client = client
            return
        try:
            self._client = client_factory()
        except Exception:
            raise TranslationProviderUnavailable(
                "Cloudflare Translation is unavailable"
            ) from None

    async def translate(
        self,
        *,
        text: str,
        source_language: SourceLanguage,
        target_language: TargetLanguage,
    ) -> TranslationResult:
        request = {
            "text": text,
            "source_lang": _PROVIDER_LANGUAGE_CODES[source_language],
            "target_lang": _PROVIDER_LANGUAGE_CODES[target_language],
        }
        try:
            response = await self._client.post(
                self._endpoint,
                headers=self._headers,
                json=request,
            )
            response.raise_for_status()
        except asyncio.CancelledError:
            raise
        except Exception:
            raise TranslationProviderError(
                "Cloudflare Translation request failed"
            ) from None

        try:
            payload = response.json()
        except Exception:
            raise TranslationProviderError(
                "Invalid Cloudflare Translation response"
            ) from None

        if not isinstance(payload, dict) or payload.get("success") is False:
            raise TranslationProviderError(
                "Invalid Cloudflare Translation response"
            )
        result = payload.get("result")
        if not isinstance(result, dict):
            raise TranslationProviderError(
                "Invalid Cloudflare Translation response"
            )
        translated_text = result.get("translated_text")
        if (
            not isinstance(translated_text, str)
            or not translated_text.strip()
        ):
            raise TranslationProviderError(
                "Invalid Cloudflare Translation response"
            )
        return TranslationResult(translated_text=translated_text)
