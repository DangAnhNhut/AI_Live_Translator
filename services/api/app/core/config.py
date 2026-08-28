from pydantic_settings import BaseSettings, SettingsConfigDict

from pydantic import SecretStr
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

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )


settings = Settings()
