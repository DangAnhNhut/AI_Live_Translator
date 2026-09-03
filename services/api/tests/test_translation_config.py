import pytest
from pydantic import ValidationError

from app.core.config import Settings


def test_translation_configuration_defaults_are_bounded_and_stt_safe():
    settings = Settings(
        _env_file=None,
        translation_provider=None,
        google_cloud_project_id=None,
    )

    assert settings.translation_provider is None
    assert settings.google_cloud_project_id is None
    assert settings.google_cloud_location == "global"
    assert settings.cloudflare_account_id is None
    assert settings.cloudflare_api_token is None
    assert settings.cloudflare_translation_model == "@cf/meta/m2m100-1.2b"
    assert settings.translation_queue_max_size == 8
    assert settings.translation_request_timeout_seconds == 10.0


def test_google_translation_configuration_preserves_explicit_values():
    settings = Settings(
        _env_file=None,
        translation_provider="google_cloud",
        google_cloud_project_id="project-123",
        google_cloud_location="us-central1",
        translation_queue_max_size=3,
        translation_request_timeout_seconds=2.5,
    )

    assert settings.translation_provider == "google_cloud"
    assert settings.google_cloud_project_id == "project-123"
    assert settings.google_cloud_location == "us-central1"
    assert settings.translation_queue_max_size == 3
    assert settings.translation_request_timeout_seconds == 2.5


def test_cloudflare_translation_configuration_preserves_explicit_values():
    settings = Settings(
        _env_file=None,
        translation_provider="cloudflare",
        cloudflare_account_id="account-123",
        cloudflare_api_token="token-value",
        cloudflare_translation_model="@cf/custom/model",
    )

    assert settings.translation_provider == "cloudflare"
    assert settings.cloudflare_account_id == "account-123"
    assert settings.cloudflare_api_token.get_secret_value() == "token-value"
    assert settings.cloudflare_translation_model == "@cf/custom/model"


@pytest.mark.parametrize(
    ("field", "value"),
    (
        ("translation_queue_max_size", 0),
        ("translation_request_timeout_seconds", 0),
    ),
)
def test_translation_bounds_reject_non_positive_values(field, value):
    with pytest.raises(ValidationError):
        Settings(_env_file=None, **{field: value})
