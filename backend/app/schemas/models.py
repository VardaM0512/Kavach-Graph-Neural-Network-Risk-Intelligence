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
    customer_loss: bool = False
    margin_change: float = Field(0.0, ge=-0.5, le=0.5, description="EBITDA margin change, e.g. -0.03")
    debt_change: float = Field(0.0, ge=-0.9, le=3.0, description="fractional change in borrowings")


# --------------------------- analyze ----------------------------------------
class Statements(BaseModel):
    revenue: float
    ebitda: float
    net_profit: float = 0
    interest_expense: float = 0
    assets: float = 0
    debt: float = 0
    equity: float = 0
    cash: float = 0
    current_assets: float = 0
    current_liabilities: float = 0
    inventory: float = 0
    ocf: float = 0
    capex: float = 0


class PriorYear(BaseModel):
    revenue: float | None = None
    ebitda: float | None = None
    year: int | None = None


class Counterparty(BaseModel):
    name: str = ""
    relation: str = Field(..., description="supplier | customer | parent | subsidiary | guarantor | peer")
    share: float = Field(..., ge=0, le=1, description="dependency share, e.g. 0.35 = 35% of revenue")
    health: str = Field("stable", description="strong | stable | weak | distressed")
    sector: str | None = None
    company_id: str | None = None


class AnalyzeRequest(BaseModel):
    name: str = "Unnamed company"
    sector: str | None = None
    fiscal_year: int | None = None
    promoter_pledge: float = Field(0.0, ge=0, le=1)
    current: Statements
    previous: PriorYear | None = None
    earlier: list[PriorYear] = []
    counterparties: list[Counterparty] = []
    shocks: dict | None = None


class YearStatements(Statements):
    year: int


class WorkspaceCompany(BaseModel):
    name: str
    sector: str | None = None
    promoter_pledge: float = Field(0.0, ge=0, le=1)
    defaulted: int | None = Field(None, description="1 = known to have defaulted, 0 = known not to")
    years: list[YearStatements] = Field(..., min_length=1)


class WorkspaceRelation(BaseModel):
    company: str
    counterparty: str
    relation: str = "customer"
    share: float = Field(0.2, ge=0, le=1)
    health: str = "stable"


class WorkspaceRequest(BaseModel):
    companies: list[WorkspaceCompany] = Field(..., min_length=1, max_length=500)
    relationships: list[WorkspaceRelation] = []


class AssistantRequest(BaseModel):
    text: str
    lang: str = "en"


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
