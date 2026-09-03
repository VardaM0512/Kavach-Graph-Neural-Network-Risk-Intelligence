"""Pydantic request/response schemas."""
from __future__ import annotations

from pydantic import BaseModel, Field


# ----------------------------- auth -----------------------------------------
class LoginRequest(BaseModel):
    email: str
    password: str


class RegisterRequest(BaseModel):
    email: str
    password: str = Field(min_length=6)
    name: str | None = None


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    user: dict


# --------------------------- scenarios --------------------------------------
class ScenarioRequest(BaseModel):
    company_id: str
    revenue_change: float = Field(0.0, ge=-1.0, le=1.0, description="fractional change, e.g. -0.2")
    interest_rate_change: float = Field(0.0, ge=-0.2, le=0.2, description="absolute, e.g. 0.02 = +200bps")
    supplier_failure: bool = False


# --------------------------- portfolio --------------------------------------
class Holding(BaseModel):
    company_id: str
    weight: float = Field(gt=0)


class PortfolioRequest(BaseModel):
    holdings: list[Holding]


# --------------------------- language / voice -------------------------------
class TranslateRequest(BaseModel):
    text: str
    target_lang: str = "hi"
    source_lang: str = "auto"


class TTSRequest(BaseModel):
    text: str
    lang: str = "en"
    voice: str | None = None


class VoiceQueryResponse(BaseModel):
    transcript: str
    detected_lang: str
    answer: str
    audio_base64: str | None = None
