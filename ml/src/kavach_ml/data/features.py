"""Financial feature engineering.

Turns raw statement fields (revenue, debt, cash, ...) into scale-free ratio
features. Two layers:

  build_feature_frame  human-readable ratios (shown in the app as-is)
  transform_features   the model view: winsorised to plausible bounds and
                       log-compressed where ratios are heavy-tailed, so a real
                       company with an interest cover of 400x or a negative
                       EBITDA cannot push the model off the training manifold.

Because both layers only use ratios and trends, the same code scores a company
from the synthetic universe or one typed in from a real annual report.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

# feature -> (low clip, high clip, log-compress?)
FEATURE_SPEC: dict[str, tuple[float, float, bool]] = {
    # liquidity
    "current_ratio": (0.1, 8.0, True),
    "quick_ratio": (0.05, 6.0, True),
    "cash_ratio": (0.0, 5.0, True),
    "working_capital_to_assets": (-0.6, 0.7, False),
    # leverage
    "debt_to_equity": (0.0, 15.0, True),
    "debt_to_assets": (0.0, 1.2, False),
    "interest_coverage": (-10.0, 50.0, True),
    "net_debt_to_ebitda": (-5.0, 20.0, False),
    # profitability
    "ebitda_margin": (-0.5, 0.7, False),
    "net_margin": (-0.8, 0.5, False),
    "return_on_assets": (-0.4, 0.35, False),
    "return_on_equity": (-1.0, 0.8, False),
    # cash flow
    "ocf_to_debt": (-1.0, 3.0, False),
    "fcf_margin": (-0.6, 0.4, False),
    "cash_burn_months": (0.0, 60.0, False),
    # growth / trend
    "revenue_growth_yoy": (-0.7, 1.0, False),
    "revenue_cagr_3y": (-0.5, 0.8, False),
    "margin_trend": (-0.3, 0.3, False),
    # governance
    "promoter_pledge": (0.0, 1.0, False),
}
FEATURE_NAMES = list(FEATURE_SPEC)

FEATURE_GROUPS = {
    "liquidity": ["current_ratio", "quick_ratio", "cash_ratio", "working_capital_to_assets"],
    "leverage": ["debt_to_equity", "debt_to_assets", "interest_coverage", "net_debt_to_ebitda"],
    "profitability": ["ebitda_margin", "net_margin", "return_on_assets", "return_on_equity"],
    "cash_flow": ["ocf_to_debt", "fcf_margin", "cash_burn_months"],
    "growth": ["revenue_growth_yoy", "revenue_cagr_3y", "margin_trend"],
    "governance": ["promoter_pledge"],
}

# Raw statement fields a caller must supply (Rs crore unless noted)
REQUIRED_FIELDS = [
    "revenue", "ebitda", "net_profit", "interest_expense", "assets", "debt", "equity",
    "cash", "current_assets", "current_liabilities", "inventory", "ocf", "capex",
]


def _safe(numer, denom):
    numer = np.asarray(numer, dtype=float)
    denom = np.asarray(denom, dtype=float)
    denom = np.where(np.abs(denom) < 1e-6, np.where(denom < 0, -1e-6, 1e-6), denom)
    return numer / denom


def build_feature_frame(companies: pd.DataFrame, history: pd.DataFrame | None = None) -> pd.DataFrame:
    c = companies.reset_index(drop=True)
    f = pd.DataFrame({"company_id": c["company_id"].values})

    f["current_ratio"] = _safe(c["current_assets"], c["current_liabilities"])
    f["quick_ratio"] = _safe(c["current_assets"] - c["inventory"], c["current_liabilities"])
    f["cash_ratio"] = _safe(c["cash"], c["current_liabilities"])
    f["working_capital_to_assets"] = _safe(c["current_assets"] - c["current_liabilities"], c["assets"])

    f["debt_to_equity"] = np.where(c["equity"] <= 0, 15.0, _safe(c["debt"], c["equity"]))
    f["debt_to_assets"] = _safe(c["debt"], c["assets"])
    f["interest_coverage"] = np.where(c["interest_expense"] <= 1e-3, 50.0,
                                      _safe(c["ebitda"], c["interest_expense"]))
    nd = c["debt"] - c["cash"]
    f["net_debt_to_ebitda"] = np.where(c["ebitda"] <= 0, np.where(nd > 0, 20.0, -5.0),
                                       _safe(nd, c["ebitda"]))

    f["ebitda_margin"] = _safe(c["ebitda"], c["revenue"])
    f["net_margin"] = _safe(c["net_profit"], c["revenue"])
    f["return_on_assets"] = _safe(c["net_profit"], c["assets"])
    f["return_on_equity"] = np.where(c["equity"] <= 0, -1.0, _safe(c["net_profit"], c["equity"]))

    f["ocf_to_debt"] = np.where(c["debt"] <= 1e-3, 3.0, _safe(c["ocf"], c["debt"]))
    fcf = c["ocf"] - c["capex"]
    f["fcf_margin"] = _safe(fcf, c["revenue"])
    burn = np.where(fcf < 0, -fcf / 12.0, np.nan)
    f["cash_burn_months"] = np.where(np.isnan(burn), 60.0, np.clip(_safe(c["cash"], burn), 0, 60))

    growth, cagr, mtrend = _trend_features(c, history)
    f["revenue_growth_yoy"] = growth
    f["revenue_cagr_3y"] = cagr
    f["margin_trend"] = mtrend
    f["promoter_pledge"] = c["promoter_pledge"].values if "promoter_pledge" in c else 0.0

    for k, (lo, hi, _) in FEATURE_SPEC.items():
        f[k] = np.clip(np.nan_to_num(f[k].astype(float), nan=0.0), lo, hi)
    return f


def _trend_features(companies: pd.DataFrame, history: pd.DataFrame | None):
    """YoY growth, 3-year CAGR and EBITDA-margin change.

    The current statements in `companies` are the latest point; `history`
    supplies the prior fiscal years (any rows at or after the current fiscal
    year, `fy`, are ignored, so shocked current statements are respected).
    """
    n = len(companies)
    growth = companies["revenue_growth"].values.astype(float).copy() if "revenue_growth" in companies else np.zeros(n)
    cagr = growth.copy()
    mtrend = np.zeros(n)
    if history is None or len(history) == 0:
        return growth, cagr, mtrend
    fy = int(companies["fy"].max()) if "fy" in companies else int(history["year"].max())
    prior = history[history["year"] < fy]
    if prior.empty:
        return growth, cagr, mtrend
    ids = companies["company_id"].values
    rev_p = prior.pivot_table(index="company_id", columns="year", values="revenue").reindex(ids)
    ebd_p = prior.pivot_table(index="company_id", columns="year", values="ebitda").reindex(ids)
    rev_now = companies["revenue"].values.astype(float)
    m_now = _safe(companies["ebitda"].values, rev_now)

    cols = list(rev_p.columns)
    R = rev_p.values.astype(float)
    E = ebd_p.values.astype(float)
    has_prev = ~np.isnan(R[:, -1])
    rev_prev = np.where(has_prev, R[:, -1], np.nan)
    growth = np.where(has_prev, rev_now / np.maximum(np.nan_to_num(rev_prev, nan=1.0), 1e-6) - 1, growth)
    mtrend = np.where(has_prev, m_now - _safe(np.nan_to_num(E[:, -1]), np.nan_to_num(rev_prev, nan=1.0)), 0.0)
    # CAGR over up to 3 prior years: pick the oldest available within the window
    back = np.full(n, np.nan)
    span = np.zeros(n)
    for k in range(min(3, len(cols)), 0, -1):
        col = R[:, -k]
        take = np.isnan(back) & ~np.isnan(col)
        back = np.where(take, col, back)
        span = np.where(take, k, span)
    ok = ~np.isnan(back) & (span > 0)
    cagr = np.where(ok, (np.maximum(rev_now, 1e-6) / np.maximum(np.nan_to_num(back, nan=1.0), 1e-6))
                    ** (1.0 / np.maximum(span, 1)) - 1.0, growth)
    return growth, cagr, mtrend


def transform_features(f: pd.DataFrame) -> np.ndarray:
    """Model view: clip + signed-log compression of heavy-tailed ratios."""
    cols = []
    for k, (lo, hi, logc) in FEATURE_SPEC.items():
        v = np.clip(f[k].values.astype(float), lo, hi)
        if logc:
            v = np.sign(v) * np.log1p(np.abs(v))
        cols.append(v)
    return np.stack(cols, axis=1).astype(np.float32)


def make_multihorizon_labels(latent_prob: np.ndarray, base_label: np.ndarray) -> dict:
    """Synthetic per-horizon labels (in production: observed outcomes at 3/6/12/24m)."""
    from ..config import HORIZONS_MONTHS
    out = {}
    for h in HORIZONS_MONTHS:
        scale = min(1.0, 0.4 + h / 24.0)
        out[h] = (latent_prob * scale > 0.5).astype(int) | (base_label & (h >= 12))
    return out
