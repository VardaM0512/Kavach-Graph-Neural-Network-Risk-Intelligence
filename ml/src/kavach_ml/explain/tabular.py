"""Tabular explainability: SHAP when available, linear attribution otherwise.

The backend calls `feature_contributions` to answer "why is this company's risk
high?" — returning the signed contribution of each feature so the mobile app can
render the +18% / +14% / -5% bars.
"""
from __future__ import annotations

import numpy as np


def explain_tabular(model, X_background: np.ndarray, X_row: np.ndarray, feature_names):
    """Return per-feature SHAP values for one row (falls back gracefully)."""
    try:
        import shap
        explainer = shap.Explainer(model, X_background)
        vals = explainer(X_row.reshape(1, -1)).values[0]
        return dict(zip(feature_names, vals.tolist()))
    except Exception:
        return _linear_attribution(model, X_background, X_row, feature_names)


def _linear_attribution(model, X_background, X_row, feature_names):
    """Cheap, always-available attribution.

    For linear models use coef * (x - mean). For tree/ensemble models fall back
    to feature_importances_ * (x - mean) as a directional proxy.
    """
    mean = X_background.mean(0)
    if hasattr(model, "coef_"):
        w = np.ravel(model.coef_)
    elif hasattr(model, "feature_importances_"):
        w = np.ravel(model.feature_importances_) * np.sign(X_row - mean + 1e-9)
    else:
        w = np.ones_like(mean)
    contrib = w * (X_row - mean)
    return dict(zip(feature_names, contrib.tolist()))


def feature_contributions(model, X_background, X_row, feature_names, top_k: int = 6):
    """Human-facing summary: top positive (risk-raising) and negative drivers."""
    contrib = explain_tabular(model, X_background, X_row, feature_names)
    ordered = sorted(contrib.items(), key=lambda kv: abs(kv[1]), reverse=True)[:top_k]
    total = sum(abs(v) for _, v in ordered) or 1.0
    return [
        {
            "feature": k,
            "contribution": round(float(v), 4),
            "direction": "raises_risk" if v > 0 else "lowers_risk",
            "share": round(abs(v) / total, 3),
        }
        for k, v in ordered
    ]
