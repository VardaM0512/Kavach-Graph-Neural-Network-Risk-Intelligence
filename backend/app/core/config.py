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

    # Databases (optional — app runs on the synthetic engine if unset)
    postgres_url: str | None = None          # postgresql+asyncpg://user:pass@host/db
    neo4j_uri: str | None = None             # bolt://host:7687
    neo4j_user: str = "neo4j"
    neo4j_password: str = "password"

    # Providers (optional)
    tts_provider: str = "stub"               # stub | gtts | azure | google
    stt_provider: str = "stub"               # stub | whisper | azure | google
    translation_provider: str = "builtin"    # builtin | deep_translator | azure

    # Supported UI + content languages (multilingual product)
    supported_languages: list[str] = [
        "en", "hi", "bn", "ta", "te", "mr", "gu", "kn", "ml", "pa", "or", "as",
    ]

    cors_origins: list[str] = ["*"]

    class Config:
        env_prefix = "KAVACH_"
        env_file = ".env"
        extra = "ignore"


@lru_cache
def get_settings() -> Settings:
    return Settings()
