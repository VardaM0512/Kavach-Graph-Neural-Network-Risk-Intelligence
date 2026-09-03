"""Tabular baselines: Logistic Regression, Random Forest, XGBoost.

These deliberately ignore the graph structure and see only each company's own
feature vector. Comparing them against the GNNs in evaluate.py is how we prove
that relationships add predictive value.

XGBoost/LightGBM are optional; if not installed we fall back to sklearn's
GradientBoosting so the pipeline still runs.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from sklearn.ensemble import RandomForestClassifier, GradientBoostingClassifier
from sklearn.linear_model import LogisticRegression


@dataclass
class BaselineResult:
    name: str
    model: object
    val_proba: np.ndarray
    test_proba: np.ndarray


def _make_xgboost(scale_pos_weight: float):
    try:
        from xgboost import XGBClassifier
        return XGBClassifier(
            n_estimators=400, max_depth=4, learning_rate=0.05,
            subsample=0.9, colsample_bytree=0.8,
            scale_pos_weight=scale_pos_weight, eval_metric="aucpr",
            tree_method="hist", n_jobs=-1, random_state=42,
        ), "xgboost"
    except Exception:
        return GradientBoostingClassifier(
            n_estimators=300, max_depth=3, learning_rate=0.05, random_state=42,
        ), "xgboost(gbdt-fallback)"


def train_baselines(X, y, train_idx, val_idx, test_idx, which=("logreg", "random_forest", "xgboost")):
    pos = y[train_idx].sum()
    neg = len(train_idx) - pos
    spw = float(neg / max(pos, 1))                       # class-imbalance weight

    results: dict[str, BaselineResult] = {}
    for name in which:
        if name == "logreg":
            model = LogisticRegression(max_iter=1000, class_weight="balanced", C=1.0)
            label = "logreg"
        elif name == "random_forest":
            model = RandomForestClassifier(
                n_estimators=400, max_depth=None, class_weight="balanced_subsample",
                n_jobs=-1, random_state=42,
            )
            label = "random_forest"
        elif name == "xgboost":
            model, label = _make_xgboost(spw)
        else:
            continue

        model.fit(X[train_idx], y[train_idx])
        results[name] = BaselineResult(
            name=label,
            model=model,
            val_proba=model.predict_proba(X[val_idx])[:, 1],
            test_proba=model.predict_proba(X[test_idx])[:, 1],
        )
    return results
