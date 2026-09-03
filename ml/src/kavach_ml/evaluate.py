"""Evaluation utilities — the honest scoreboard.

Because the distress class is rare, accuracy is misleading (a model that always
predicts "healthy" scores ~86% accuracy and is useless). We therefore lead with
PR-AUC and recall, tune the decision threshold on the validation set, and only
then report the test confusion matrix.
"""
from __future__ import annotations

import numpy as np
from sklearn.metrics import (
    roc_auc_score, average_precision_score, f1_score,
    precision_score, recall_score, confusion_matrix,
)


def best_threshold(y_true: np.ndarray, proba: np.ndarray) -> float:
    """Pick the threshold that maximises F1 on the given (validation) set."""
    grid = np.linspace(0.05, 0.95, 91)
    f1s = [f1_score(y_true, (proba >= t).astype(int), zero_division=0) for t in grid]
    return float(grid[int(np.argmax(f1s))])


def score(y_true: np.ndarray, proba: np.ndarray, threshold: float | None = None) -> dict:
    if threshold is None:
        threshold = best_threshold(y_true, proba)
    pred = (proba >= threshold).astype(int)
    out = {
        "roc_auc": float(roc_auc_score(y_true, proba)) if len(set(y_true)) > 1 else float("nan"),
        "pr_auc": float(average_precision_score(y_true, proba)),
        "f1": float(f1_score(y_true, pred, zero_division=0)),
        "precision": float(precision_score(y_true, pred, zero_division=0)),
        "recall": float(recall_score(y_true, pred, zero_division=0)),
        "ks": ks_statistic(y_true, proba),
        "precision_at_10pct": precision_at_k(y_true, proba, 0.10),
        "threshold": float(threshold),
    }
    tn, fp, fn, tp = confusion_matrix(y_true, pred, labels=[0, 1]).ravel()
    out["confusion"] = {"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)}
    return out


def ks_statistic(y_true: np.ndarray, proba: np.ndarray) -> float:
    """Kolmogorov–Smirnov statistic — max separation between the good/bad score
    distributions. A standard credit-risk metric (higher is better)."""
    order = np.argsort(proba)
    y = np.asarray(y_true)[order]
    pos = np.cumsum(y) / max(y.sum(), 1)
    neg = np.cumsum(1 - y) / max((1 - y).sum(), 1)
    return float(np.max(np.abs(pos - neg)))


def precision_at_k(y_true: np.ndarray, proba: np.ndarray, k_frac: float = 0.1) -> float:
    """Precision within the top-k% riskiest — how good the model is at ranking the
    worst offenders to the top, the way an analyst actually triages a watchlist."""
    n = max(1, int(len(proba) * k_frac))
    top = np.argsort(proba)[::-1][:n]
    return float(np.mean(np.asarray(y_true)[top]))


def comparison_table(scores: dict) -> str:
    """Render a markdown table of {model_name: metrics} sorted by PR-AUC."""
    cols = ["roc_auc", "pr_auc", "ks", "f1", "recall", "precision_at_10pct"]
    rows = sorted(scores.items(), key=lambda kv: kv[1]["pr_auc"], reverse=True)
    header = "| Model | " + " | ".join(c.upper() for c in cols) + " |\n"
    sep = "|" + "---|" * (len(cols) + 1) + "\n"
    body = ""
    for name, m in rows:
        body += f"| {name} | " + " | ".join(f"{m[c]:.3f}" for c in cols) + " |\n"
    return header + sep + body
