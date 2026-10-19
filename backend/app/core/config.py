"""Backend settings, loaded from environment (.env supported)."""
from __future__ import annotations

from functools import lru_cache

try:
    from pydantic_settings import BaseSettings
except Exception:  # pragma: no cover - fallback for pydantic v1
    from pydantic import BaseSettings  # type: ignore


class Settings(BaseSettings):
    app_name: str = "Kavach Risk Intelligence API"
    environment: str = "development"

    # Auth
    jwt_secret: str = "change-me-in-production"
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24

    # Providers (optional)
    tts_provider: str = "stub"               # stub | gtts | azure | google
    stt_provider: str = "stub"               # stub | whisper | azure | google
    translation_provider: str = "builtin"    # builtin | deep_translator | azure

    # English + all 22 languages of the Eighth Schedule of the Constitution of India
    supported_languages: list[str] = [
        "en", "as", "bn", "brx", "doi", "gu", "hi", "kn", "ks", "kok", "mai", "ml",
        "mni", "mr", "ne", "or", "pa", "sa", "sat", "sd", "ta", "te", "ur",
    ]

    cors_origins: list[str] = ["*"]

    class Config:
        env_prefix = "KAVACH_"
        env_file = ".env"
        extra = "ignore"


@lru_cache
def get_settings() -> Settings:
    return Settings()
