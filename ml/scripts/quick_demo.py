"""End-to-end demo that runs anywhere (NumPy + scikit-learn only).

Generates the synthetic economy, builds the graph, trains the tabular baselines
and the NumPy reference GNNs, and prints the model-comparison table that proves
graph structure improves distress prediction.

    python ml/scripts/quick_demo.py

For the full torch/torch-geometric GCN/GraphSAGE/GAT training, see
`python -m kavach_ml.train --model gat`.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from kavach_ml.config import SyntheticConfig, TrainConfig                # noqa: E402
from kavach_ml.data import generate_economy, build_feature_frame, build_graph  # noqa: E402
from kavach_ml.models.baselines import train_baselines                   # noqa: E402
from kavach_ml.models.numpy_gnn import (                                 # noqa: E402
    NumpyGNN, RelationalNumpyGNN, HybridGNNEnsemble)
from kavach_ml.models.altman import zscore_proba                         # noqa: E402
from kavach_ml.evaluate import score, comparison_table                   # noqa: E402
from kavach_ml.utils import make_splits, save_json                       # noqa: E402
from kavach_ml.config import ARTIFACTS                                    # noqa: E402


def main():
    print("1. Generating synthetic economy ...")
    eco = generate_economy(SyntheticConfig())
    print("   ", eco.summary())

    print("2. Engineering features + building graph ...")
    feats = build_feature_frame(eco.companies, eco.history)
    bundle = build_graph(eco, feats)
    print(f"    nodes={bundle.num_nodes}  features={bundle.num_features}  "
          f"edges={bundle.edge_index.shape[1]}")

    cfg = TrainConfig()
    splits = make_splits(bundle.y, cfg)
    tr, va, te = splits["train"], splits["val"], splits["test"]

    scores = {}

    print("3. Classic baseline — Altman Z-Score (1968) ...")
    zp = zscore_proba(eco.companies)
    scores["altman_zscore"] = score(bundle.y[te], zp[te])

    print("4. Tabular ML baselines (own features only, no graph) ...")
    base = train_baselines(bundle.X, bundle.y, tr, va, te,
                           which=("logreg", "random_forest", "xgboost"))
    for name, res in base.items():
        thr = score(bundle.y[va], res.val_proba)["threshold"]
        scores[res.name] = score(bundle.y[te], res.test_proba, threshold=thr)

    print("5. Homogeneous GNNs (single-relation message passing) ...")
    for tag, mode in [("gcn(numpy)", "gcn"), ("graphsage(numpy)", "mean")]:
        gnn = NumpyGNN(k=1, mode=mode).fit(bundle.X, bundle.edge_index, bundle.y, tr)
        proba = gnn.predict_proba_all()
        thr = score(bundle.y[va], proba[va])["threshold"]
        scores[tag] = score(bundle.y[te], proba[te], threshold=thr)

    print("6. Relational GNN (R-GCN-style, per-edge-type message passing) ...")
    rgnn = RelationalNumpyGNN(k=1, mode="gcn").fit(
        bundle.X, bundle.edge_index, bundle.edge_type, bundle.y, tr,
        n_relations=len(bundle.relation_names))
    rp = rgnn.predict_proba_all()
    thr = score(bundle.y[va], rp[va])["threshold"]
    scores["relational_gnn(rgcn)"] = score(bundle.y[te], rp[te], threshold=thr)

    print("7. Hybrid GNN + gradient boosting (SOTA recipe) ...")
    hyb = HybridGNNEnsemble(k=1, mode="gcn").fit(
        bundle.X, bundle.edge_index, bundle.edge_type, bundle.y, tr,
        n_relations=len(bundle.relation_names))
    hp = hyb.predict_proba_all()
    thr = score(bundle.y[va], hp[va])["threshold"]
    scores["hybrid_gnn+gbdt"] = score(bundle.y[te], hp[te], threshold=thr)

    print("\n===== MODEL COMPARISON (test set, sorted by PR-AUC) =====\n")
    table = comparison_table(scores)
    print(table)

    save_json(scores, ARTIFACTS / "comparison.json")
    (ARTIFACTS / "comparison.md").write_text(table)
    print(f"Saved metrics -> {ARTIFACTS/'comparison.json'}")
    print("\nInterpretation: the graph models should top the table on PR-AUC / recall,")
    print("because distress labels depend on neighbours' health, which tabular models cannot see.")


if __name__ == "__main__":
    main()
