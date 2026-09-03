from pydantic_settings import BaseSettings, SettingsConfigDict

from pydantic import Field, SecretStr
from typing import Literal


class Settings(BaseSettings):
    app_name: str = "AI Live Translator"
    app_env: str = "development"
    app_host: str = "0.0.0.0"
    app_port: int = 8000

    stt_provider: str | None = None
    deepgram_api_key: SecretStr | None = None
    deepgram_model: str = "nova-3"
    deepgram_language: Literal["vi"] = "vi"
    deepgram_endpointing_ms: int = 300
    stt_benchmark: bool = False
    stt_transcript_trace: bool = False

    translation_provider: Literal["google_cloud", "cloudflare"] | None = None
    google_cloud_project_id: str | None = None
    google_cloud_location: str = "global"
    cloudflare_account_id: str | None = None
    cloudflare_api_token: SecretStr | None = None
    cloudflare_translation_model: str = "@cf/meta/m2m100-1.2b"
    translation_queue_max_size: int = Field(default=8, ge=1)
    translation_request_timeout_seconds: float = Field(default=10.0, gt=0)

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
