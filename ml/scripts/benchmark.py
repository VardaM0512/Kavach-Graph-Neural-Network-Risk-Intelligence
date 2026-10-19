"""Honest model benchmark: 5-fold stratified cross-validation on the synthetic universe.

    python ml/scripts/benchmark.py            (needs torch + torch_geometric for the GNN rows)

Every model sees the same folds. Inside each fold, 18% of the training part is
held out for early stopping / calibration. Graph models that use counterparties'
known default status only ever see labels from the training part of the fold;
test companies' labels are hidden.

Writes ml/artifacts/benchmark.json and benchmark.md (mean ± std over folds).
"""
from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import numpy as np
from scipy.special import expit, logit
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score
from sklearn.model_selection import StratifiedKFold, train_test_split

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from kavach_ml.config import ARTIFACTS  # noqa: E402
from kavach_ml.models.altman import zscore_proba  # noqa: E402
from kavach_ml.models.inductive import InductiveGraphModel  # noqa: E402
from kavach_ml.serve.engine import RiskEngine  # noqa: E402

try:
    from kavach_ml.models.gnn import GNNEnsemble, build_tensors  # noqa: E402
    HAVE_TORCH = True
except Exception:  # pragma: no cover
    HAVE_TORCH = False

LABELS = {
    "altman": "Altman Z-score (1968)",
    "logreg": "Logistic regression, own ratios",
    "irgnn": "Linear relational GNN, ratios only",
    "irgnn_labels": "Linear relational GNN + counterparty defaults",
    "gcn": "PyG GCN + counterparty defaults",
    "gat": "PyG GAT + counterparty defaults",
    "rgcn": "PyG R-GCN + counterparty defaults",
    "blend": "Blend: linear relational GNN + GCN + GAT",
}


def run(folds: int = 5, seeds=(0, 1, 2)):
    e = RiskEngine()
    y = e.y
    g = build_tensors(e.X, e.rel_rows) if HAVE_TORCH else None
    res: dict[str, list] = {}
    L = lambda p: logit(np.clip(p, 1e-6, 1 - 1e-6))  # noqa: E731
    t0 = time.time()
    for k, (trv, te) in enumerate(StratifiedKFold(folds, shuffle=True, random_state=7).split(e.X, y)):
        tr, va = train_test_split(trv, test_size=0.18, stratify=y[trv], random_state=k)
        P = {"altman": zscore_proba(e.companies),
             "logreg": LogisticRegression(max_iter=3000, C=0.25).fit(e.X[trv], y[trv]).predict_proba(e.X)[:, 1],
             "irgnn": InductiveGraphModel(risk_signs=e._signs).fit(e.X, e.rel_rows, y, trv).predict_proba_all(),
             "irgnn_labels": InductiveGraphModel(risk_signs=e._signs, use_labels=True)
                             .fit(e.X, e.rel_rows, y, trv).predict_proba_all()}
        if HAVE_TORCH:
            for arch in ("gcn", "gat", "rgcn"):
                P[arch] = GNNEnsemble(arch, seeds=seeds).fit(g, y, tr, va).proba(g)
            P["blend"] = expit((L(P["irgnn_labels"]) + L(P["gcn"]) + L(P["gat"])) / 3)
        for m, p in P.items():
            res.setdefault(m, []).append((roc_auc_score(y[te], p[te]), average_precision_score(y[te], p[te]),
                                          brier_score_loss(y[te], p[te])))
        print(f"fold {k + 1}/{folds}  {time.time() - t0:.0f}s", flush=True)

    summary = {}
    for m, v in res.items():
        a = np.array(v)
        summary[m] = {"label": LABELS[m],
                      "roc_auc": round(a[:, 0].mean(), 4), "roc_auc_std": round(a[:, 0].std(), 4),
                      "pr_auc": round(a[:, 1].mean(), 4), "pr_auc_std": round(a[:, 1].std(), 4),
                      "brier": round(a[:, 2].mean(), 4)}
    meta = {"folds": folds, "companies": int(len(y)), "default_rate": round(float(y.mean()), 4),
            "protocol": "5-fold stratified CV; graph models see only training-fold labels"}
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "benchmark.json").write_text(json.dumps({"meta": meta, "models": summary}, indent=2), encoding="utf-8")
    rows = sorted(summary.items(), key=lambda kv: -kv[1]["roc_auc"])
    md = ["| Model | ROC-AUC | PR-AUC | Brier |", "|---|---|---|---|"]
    md += [f"| {s['label']} | {s['roc_auc']:.3f} ± {s['roc_auc_std']:.3f} | {s['pr_auc']:.3f} ± {s['pr_auc_std']:.3f} "
           f"| {s['brier']:.4f} |" for _, s in rows]
    (ARTIFACTS / "benchmark.md").write_text("\n".join(md) + "\n", encoding="utf-8")
    print("\n".join(md))


if __name__ == "__main__":
    run()
