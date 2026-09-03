import asyncio
from types import SimpleNamespace

import pytest

from app.ai.translation import (
    TranslationProviderError,
    TranslationProviderUnavailable,
    TranslationResult,
)
from app.ai.google_cloud_translation import GoogleCloudTranslator


class FakeGoogleTranslationClient:
    def __init__(self, *, response=None, error: Exception | None = None):
        self.response = response
        self.error = error
        self.requests = []

    async def translate_text(self, *, request):
        self.requests.append(request)
        if self.error is not None:
            raise self.error
        return self.response


def translated_response(text: str):
    return SimpleNamespace(
        translations=(SimpleNamespace(translated_text=text),)
    )


def test_google_adapter_sends_exact_advanced_nmt_request():
    client = FakeGoogleTranslationClient(
        response=translated_response("Hello everyone.")
    )
    translator = GoogleCloudTranslator(
        project_id="project-123",
        location="global",
        client=client,
    )

    result = asyncio.run(
        translator.translate(
            text="Xin chào mọi người.",
            source_language="vi",
            target_language="en",
        )
    )

    assert client.requests == [
        {
            "parent": "projects/project-123/locations/global",
            "contents": ["Xin chào mọi người."],
            "source_language_code": "vi",
            "target_language_code": "en",
            "mime_type": "text/plain",
            "model": (
                "projects/project-123/locations/global/models/general/nmt"
            ),
        }
    ]
    assert result == TranslationResult(translated_text="Hello everyone.")
    assert not hasattr(result, "translations")


def test_google_adapter_preserves_provider_translated_text_exactly():
    client = FakeGoogleTranslationClient(
        response=translated_response("  Hello.  ")
    )
    translator = GoogleCloudTranslator(
        project_id="project-123",
        location="us-central1",
        client=client,
    )

    result = asyncio.run(
        translator.translate(
            text="Xin chào.",
            source_language="vi",
            target_language="en",
        )
    )

    assert result.translated_text == "  Hello.  "


def test_google_provider_exception_is_sanitized():
    secret_detail = "credential token secret-provider-detail"
    client = FakeGoogleTranslationClient(
        error=RuntimeError(secret_detail)
    )
    translator = GoogleCloudTranslator(
        project_id="project-123",
        location="global",
        client=client,
    )

    async def exercise():
        with pytest.raises(TranslationProviderError) as error:
            await translator.translate(
                text="Xin chào.",
                source_language="vi",
                target_language="en",
            )
        return str(error.value)

    message = asyncio.run(exercise())

    assert message == "Google Cloud Translation request failed"
    assert secret_detail not in message


@pytest.mark.parametrize(
    "response",
    (
        None,
        SimpleNamespace(translations=()),
        SimpleNamespace(translations=(SimpleNamespace(),)),
        translated_response(""),
        translated_response("   "),
    ),
)
def test_google_malformed_or_empty_response_is_controlled(response):
    translator = GoogleCloudTranslator(
        project_id="project-123",
        location="global",
        client=FakeGoogleTranslationClient(response=response),
    )

    async def exercise():
        with pytest.raises(TranslationProviderError) as error:
            await translator.translate(
                text="Xin chào.",
                source_language="vi",
                target_language="en",
            )
        return str(error.value)

    assert asyncio.run(exercise()) == "Invalid Google Translation response"


def test_google_client_construction_failure_is_controlled_and_sanitized():
    def failing_client_factory():
        raise RuntimeError("raw ADC credential path")

    with pytest.raises(TranslationProviderUnavailable) as error:
        GoogleCloudTranslator(
            project_id="project-123",
            location="global",
            client_factory=failing_client_factory,
        )

    assert str(error.value) == "Google Cloud Translation is unavailable"
    assert "credential" not in str(error.value)
