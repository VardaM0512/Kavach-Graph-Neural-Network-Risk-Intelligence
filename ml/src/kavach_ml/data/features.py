"""Financial feature engineering.

Turns raw statement fields (revenue, debt, cash, ...) into the normalised
ratio features that both the tabular baselines and the GNN node features use.
All ratios are defensively clipped so a single divide-by-near-zero can't blow
up training.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from ..config import HORIZONS_MONTHS


def _safe(numer, denom, cap=1e6):
    denom = np.where(np.abs(denom) < 1e-6, 1e-6, denom)
    return np.clip(numer / denom, -cap, cap)


def build_feature_frame(companies: pd.DataFrame, history: pd.DataFrame | None = None) -> pd.DataFrame:
    c = companies
    f = pd.DataFrame({"company_id": c["company_id"].values})

    # --- liquidity ---------------------------------------------------------
    f["current_ratio"] = _safe(c["current_assets"], c["current_liabilities"])
    f["quick_ratio"] = _safe(c["current_assets"] - c["inventory"], c["current_liabilities"])
    f["cash_ratio"] = _safe(c["cash"], c["current_liabilities"])
    f["working_capital_to_assets"] = _safe(c["current_assets"] - c["current_liabilities"], c["assets"])

    # --- leverage ----------------------------------------------------------
    f["debt_to_equity"] = _safe(c["debt"], c["equity"])
    f["debt_to_assets"] = _safe(c["debt"], c["assets"])
    f["interest_coverage"] = _safe(c["ebitda"], c["interest_expense"])
    f["net_debt_to_ebitda"] = _safe(c["debt"] - c["cash"], c["ebitda"])

    # --- profitability -----------------------------------------------------
    f["net_margin"] = _safe(c["net_profit"], c["revenue"])
    f["operating_margin"] = _safe(c["ebitda"] - c["capex"], c["revenue"])
    f["return_on_assets"] = _safe(c["net_profit"], c["assets"])
    f["return_on_equity"] = _safe(c["net_profit"], c["equity"])

    # --- cash flow ---------------------------------------------------------
    f["ocf_to_debt"] = _safe(c["ocf"], c["debt"])
    f["fcf_margin"] = _safe(c["fcf"], c["revenue"])
    monthly_burn = np.where(c["fcf"] < 0, -c["fcf"] / 12.0, np.nan)
    f["cash_burn_months"] = np.where(
        np.isnan(monthly_burn), 60.0, np.clip(_safe(c["cash"], monthly_burn), 0, 60)
    )

    # --- growth / trend ----------------------------------------------------
    f["revenue_growth_yoy"] = c["revenue_growth"].values
    f["revenue_cagr_3y"], f["profit_trend_slope"] = _trend_features(c, history)

    return f


def _trend_features(companies: pd.DataFrame, history: pd.DataFrame | None):
    n = len(companies)
    if history is None:
        return companies["revenue_growth"].values, np.zeros(n)
    cagr = np.zeros(n)
    slope = np.zeros(n)
    ids = companies["company_id"].values
    hist_by = {cid: g.sort_values("year") for cid, g in history.groupby("company_id")}
    for i, cid in enumerate(ids):
        g = hist_by.get(cid)
        if g is None or len(g) < 2:
            continue
        rev = g["revenue"].values
        years = len(rev) - 1
        cagr[i] = (rev[-1] / max(rev[0], 1e-6)) ** (1.0 / max(years, 1)) - 1.0
        # slope of net_profit over time (normalised by mean revenue)
        prof = g["net_profit"].values
        x = np.arange(len(prof))
        slope[i] = np.polyfit(x, prof, 1)[0] / max(abs(rev.mean()), 1e-6)
    return np.clip(cagr, -1, 5), np.clip(slope, -1, 1)


def make_multihorizon_labels(latent_prob: np.ndarray, base_label: np.ndarray) -> dict:
    """Derive per-horizon labels from the latent distress probability.

    In a real system these come from *observed* outcomes at 3/6/12/24 months.
    Here we synthesise monotonic horizon labels: the further out, the more
    likely distress has materialised for a genuinely at-risk company.
    """
    out = {}
    for h in HORIZONS_MONTHS:
        scale = min(1.0, 0.4 + h / 24.0)                 # longer horizon => higher hazard
        out[h] = (latent_prob * scale > 0.5).astype(int) | (base_label & (h >= 12))
    return out
