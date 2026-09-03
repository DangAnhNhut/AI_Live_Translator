from dataclasses import FrozenInstanceError

import pytest

import app.ai.cloudflare_translation as cloudflare_adapter
import app.ai.google_cloud_translation as google_adapter
from app.ai.translation import (
    TranslationProviderUnavailable,
    TranslationResult,
    get_translator_factory,
)
from app.core.config import Settings


def test_translation_result_is_provider_neutral_and_immutable():
    result = TranslationResult(translated_text="Hello.")

    assert result.translated_text == "Hello."
    with pytest.raises(FrozenInstanceError):
        result.translated_text = "Changed."


def test_unconfigured_factory_fails_only_when_translation_is_constructed():
    settings = Settings(
        _env_file=None,
        translation_provider=None,
        google_cloud_project_id=None,
    )

    factory = get_translator_factory(settings)

    with pytest.raises(TranslationProviderUnavailable) as error:
        factory()
    assert str(error.value) == "Translation provider is not configured"


def test_missing_google_project_fails_lazily_without_adc_lookup():
    settings = Settings(
        _env_file=None,
        translation_provider="google_cloud",
        google_cloud_project_id="  ",
    )

    factory = get_translator_factory(settings)

    with pytest.raises(TranslationProviderUnavailable) as error:
        factory()
    assert str(error.value) == "Translation provider is not configured"


def test_configured_google_factory_is_lazy_and_passes_provider_config(
    monkeypatch,
):
    constructions: list[tuple[str, str]] = []
    sentinel = object()

    def recording_translator(*, project_id: str, location: str):
        constructions.append((project_id, location))
        return sentinel

    monkeypatch.setattr(
        google_adapter,
        "GoogleCloudTranslator",
        recording_translator,
    )
    settings = Settings(
        _env_file=None,
        translation_provider="google_cloud",
        google_cloud_project_id=" project-123 ",
        google_cloud_location=" europe-west1 ",
    )

    factory = get_translator_factory(settings)

    assert constructions == []
    assert factory() is sentinel
    assert constructions == [("project-123", "europe-west1")]


def test_configured_cloudflare_factory_is_lazy_and_passes_provider_config(
    monkeypatch,
):
    constructions: list[tuple[str, str, str]] = []
    sentinel = object()

    def recording_translator(*, account_id: str, api_token: str, model: str):
        constructions.append((account_id, api_token, model))
        return sentinel

    monkeypatch.setattr(
        cloudflare_adapter,
        "CloudflareTranslator",
        recording_translator,
    )
    settings = Settings(
        _env_file=None,
        translation_provider="cloudflare",
        cloudflare_account_id=" account-123 ",
        cloudflare_api_token=" token-value ",
        cloudflare_translation_model=" @cf/meta/m2m100-1.2b ",
    )

    factory = get_translator_factory(settings)

    assert constructions == []
    assert factory() is sentinel
    assert constructions == [
        ("account-123", "token-value", "@cf/meta/m2m100-1.2b")
    ]


@pytest.mark.parametrize(
    ("account_id", "api_token"),
    ((None, "token-value"), ("account-123", None), (" ", "token-value"), ("account-123", " ")),
)
def test_missing_cloudflare_credentials_fail_lazily_and_safely(
    account_id,
    api_token,
):
    settings = Settings(
        _env_file=None,
        translation_provider="cloudflare",
        cloudflare_account_id=account_id,
        cloudflare_api_token=api_token,
    )

    factory = get_translator_factory(settings)

    with pytest.raises(TranslationProviderUnavailable) as error:
        factory()
    assert str(error.value) == "Translation provider is not configured"
    assert "token-value" not in str(error.value)
