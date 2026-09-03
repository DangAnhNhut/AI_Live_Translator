import asyncio

import httpx
import pytest

from app.ai.cloudflare_translation import CloudflareTranslator
from app.ai.translation import TranslationProviderError, TranslationResult


class FakeCloudflareResponse:
    def __init__(
        self,
        *,
        payload: object | None = None,
        status_code: int = 200,
        json_error: Exception | None = None,
    ) -> None:
        self._payload = payload
        self._json_error = json_error
        self._request = httpx.Request("POST", "https://example.test")
        self._response = httpx.Response(
            status_code,
            request=self._request,
        )

    def raise_for_status(self) -> None:
        self._response.raise_for_status()

    def json(self) -> object:
        if self._json_error is not None:
            raise self._json_error
        return self._payload


class FakeCloudflareClient:
    def __init__(
        self,
        *,
        response: FakeCloudflareResponse | None = None,
        error: Exception | None = None,
    ) -> None:
        self.response = response
        self.error = error
        self.requests: list[dict[str, object]] = []

    async def post(self, url: str, **kwargs: object) -> object:
        self.requests.append({"url": url, **kwargs})
        if self.error is not None:
            raise self.error
        return self.response


def successful_response(text: str) -> FakeCloudflareResponse:
    return FakeCloudflareResponse(
        payload={
            "result": {"translated_text": text},
            "success": True,
            "errors": [],
            "messages": [],
        }
    )


def run_translation(
    translator: CloudflareTranslator,
    *,
    target_language: str = "en",
) -> TranslationResult:
    return asyncio.run(
        translator.translate(
            text="Xin chao nguyen van.",
            source_language="vi",
            target_language=target_language,
        )
    )


def test_cloudflare_adapter_sends_expected_endpoint_headers_and_payload():
    client = FakeCloudflareClient(
        response=successful_response("Hello exactly.")
    )
    translator = CloudflareTranslator(
        account_id=" account-123 ",
        api_token="test-token",
        model=" @cf/meta/m2m100-1.2b ",
        client=client,
    )

    result = run_translation(translator)

    assert client.requests == [
        {
            "url": (
                "https://api.cloudflare.com/client/v4/accounts/"
                "account-123/ai/run/@cf/meta/m2m100-1.2b"
            ),
            "headers": {"Authorization": "Bearer test-token"},
            "json": {
                "text": "Xin chao nguyen van.",
                "source_lang": "vi",
                "target_lang": "en",
            },
        }
    ]
    assert result == TranslationResult(translated_text="Hello exactly.")
    assert type(result) is TranslationResult


@pytest.mark.parametrize(
    ("target_language", "provider_language"),
    (
        ("en", "en"),
        ("ja", "ja"),
        ("ko", "ko"),
        ("zh-CN", "zh"),
        ("th", "th"),
        ("fr", "fr"),
        ("de", "de"),
        ("es", "es"),
    ),
)
def test_cloudflare_adapter_maps_only_provider_language_codes(
    target_language: str,
    provider_language: str,
):
    client = FakeCloudflareClient(response=successful_response("Translated"))
    translator = CloudflareTranslator(
        account_id="account-123",
        api_token="test-token",
        model="@cf/meta/m2m100-1.2b",
        client=client,
    )

    run_translation(translator, target_language=target_language)

    assert client.requests[0]["json"] == {
        "text": "Xin chao nguyen van.",
        "source_lang": "vi",
        "target_lang": provider_language,
    }


def test_cloudflare_adapter_preserves_translated_text_exactly():
    translator = CloudflareTranslator(
        account_id="account-123",
        api_token="test-token",
        model="@cf/meta/m2m100-1.2b",
        client=FakeCloudflareClient(
            response=successful_response("  Hello.  ")
        ),
    )

    result = run_translation(translator)

    assert result.translated_text == "  Hello.  "


@pytest.mark.parametrize(
    "response",
    (
        FakeCloudflareResponse(payload=None),
        FakeCloudflareResponse(payload=[]),
        FakeCloudflareResponse(payload={"success": True}),
        FakeCloudflareResponse(payload={"success": True, "result": None}),
        FakeCloudflareResponse(
            payload={"success": True, "result": {}}
        ),
        FakeCloudflareResponse(
            payload={"success": True, "result": {"translated_text": ""}}
        ),
        FakeCloudflareResponse(
            payload={"success": True, "result": {"translated_text": "   "}}
        ),
        FakeCloudflareResponse(
            payload={"success": False, "result": {"translated_text": "bad"}}
        ),
    ),
)
def test_cloudflare_malformed_or_unsuccessful_response_is_controlled(response):
    translator = CloudflareTranslator(
        account_id="account-123",
        api_token="test-token",
        model="@cf/meta/m2m100-1.2b",
        client=FakeCloudflareClient(response=response),
    )

    with pytest.raises(TranslationProviderError) as error:
        run_translation(translator)

    assert str(error.value) == "Invalid Cloudflare Translation response"


def test_cloudflare_malformed_json_is_controlled():
    translator = CloudflareTranslator(
        account_id="account-123",
        api_token="test-token",
        model="@cf/meta/m2m100-1.2b",
        client=FakeCloudflareClient(
            response=FakeCloudflareResponse(
                json_error=ValueError("raw response detail")
            )
        ),
    )

    with pytest.raises(TranslationProviderError) as error:
        run_translation(translator)

    assert str(error.value) == "Invalid Cloudflare Translation response"


@pytest.mark.parametrize("status_code", (401, 403, 429, 500, 503))
def test_cloudflare_http_failure_is_sanitized(status_code: int):
    translator = CloudflareTranslator(
        account_id="account-secret",
        api_token="token-secret",
        model="@cf/meta/m2m100-1.2b",
        client=FakeCloudflareClient(
            response=FakeCloudflareResponse(status_code=status_code)
        ),
    )

    with pytest.raises(TranslationProviderError) as error:
        run_translation(translator)

    message = str(error.value)
    assert message == "Cloudflare Translation request failed"
    assert "token-secret" not in message
    assert "account-secret" not in message
    assert str(status_code) not in message


@pytest.mark.parametrize(
    "provider_error",
    (
        httpx.ReadTimeout("raw timeout token-secret"),
        httpx.ConnectError("raw network token-secret"),
    ),
)
def test_cloudflare_transport_failure_is_sanitized(provider_error):
    translator = CloudflareTranslator(
        account_id="account-secret",
        api_token="token-secret",
        model="@cf/meta/m2m100-1.2b",
        client=FakeCloudflareClient(error=provider_error),
    )

    with pytest.raises(TranslationProviderError) as error:
        run_translation(translator)

    message = str(error.value)
    assert message == "Cloudflare Translation request failed"
    assert "token-secret" not in message
    assert "account-secret" not in message

