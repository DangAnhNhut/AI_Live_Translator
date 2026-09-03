from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from app.core.config import Settings, settings
from app.realtime.stt_protocol import TargetLanguage
from app.realtime.translation_protocol import SourceLanguage


@dataclass(frozen=True, slots=True)
class TranslationResult:
    translated_text: str


class TranslationProviderUnavailable(Exception):
    pass


class TranslationProviderError(Exception):
    pass


@runtime_checkable
class Translator(Protocol):
    async def translate(
        self,
        *,
        text: str,
        source_language: SourceLanguage,
        target_language: TargetLanguage,
    ) -> TranslationResult:
        raise NotImplementedError


TranslatorFactory = Callable[[], Translator]


def unconfigured_translator_factory() -> Translator:
    raise TranslationProviderUnavailable(
        "Translation provider is not configured"
    )


def get_translator_factory(
    configured_settings: Settings | None = None,
) -> TranslatorFactory:
    active_settings = configured_settings or settings
    if active_settings.translation_provider == "cloudflare":
        account_id = active_settings.cloudflare_account_id
        api_token = active_settings.cloudflare_api_token
        model = active_settings.cloudflare_translation_model
        if (
            account_id is not None
            and account_id.strip()
            and api_token is not None
            and api_token.get_secret_value().strip()
            and model.strip()
        ):
            normalized_account_id = account_id.strip()
            normalized_api_token = api_token.get_secret_value().strip()
            normalized_model = model.strip()

            def cloudflare_translator_factory() -> Translator:
                from app.ai.cloudflare_translation import CloudflareTranslator

                return CloudflareTranslator(
                    account_id=normalized_account_id,
                    api_token=normalized_api_token,
                    model=normalized_model,
                )

            return cloudflare_translator_factory

    project_id = active_settings.google_cloud_project_id
    location = active_settings.google_cloud_location
    if (
        active_settings.translation_provider == "google_cloud"
        and project_id is not None
        and project_id.strip()
        and location.strip()
    ):
        normalized_project_id = project_id.strip()
        normalized_location = location.strip()

        def google_cloud_translator_factory() -> Translator:
            from app.ai.google_cloud_translation import GoogleCloudTranslator

            return GoogleCloudTranslator(
                project_id=normalized_project_id,
                location=normalized_location,
            )

        return google_cloud_translator_factory
    return unconfigured_translator_factory
