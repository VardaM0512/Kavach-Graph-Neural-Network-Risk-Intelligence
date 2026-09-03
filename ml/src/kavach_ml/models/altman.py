"""Altman Z-Score — the classic 1968 bankruptcy baseline.

Every serious paper in this field benchmarks against Altman's Z-Score (Altman,
1968), a linear discriminant over five financial ratios. We include it so the
scoreboard shows how far modern ML — and especially graph structure — improves on
the 55-year-old industry-standard baseline.

    Z = 1.2·X1 + 1.4·X2 + 3.3·X3 + 0.6·X4 + 1.0·X5

    X1 = working capital / total assets
    X2 = retained earnings / total assets   (proxied by accumulated profitability)
    X3 = EBIT / total assets
    X4 = equity / total liabilities          (book proxy for market value of equity)
    X5 = sales / total assets

Distress zones: Z < 1.81 → distress, 1.81–2.99 → grey, > 2.99 → safe.
A lower Z ⇒ higher distress risk, so we predict with a monotonically decreasing map.
"""
from __future__ import annotations

import numpy as np
import pandas as pd


def zscore(companies: pd.DataFrame) -> np.ndarray:
    c = companies
    ta = c["assets"].clip(lower=1e-6)
    tl = (c["debt"] + c["current_liabilities"]).clip(lower=1e-6)
    wc = c["current_assets"] - c["current_liabilities"]
    x1 = wc / ta
    x2 = c["net_profit"] / ta                       # retained-earnings proxy
    x3 = c["ebitda"] / ta                           # EBIT proxy
    x4 = c["equity"] / tl
    x5 = c["revenue"] / ta
    return (1.2 * x1 + 1.4 * x2 + 3.3 * x3 + 0.6 * x4 + 1.0 * x5).values


def zscore_proba(companies: pd.DataFrame) -> np.ndarray:
    """Turn Z into a distress probability via a logistic map centred at Z=1.81."""
    z = zscore(companies)
    return 1.0 / (1.0 + np.exp(1.2 * (z - 1.81)))   # lower Z ⇒ higher risk
