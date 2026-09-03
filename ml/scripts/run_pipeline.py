"""Full training pipeline entry point.

If torch + torch-geometric are installed it trains GCN/GraphSAGE/GAT and writes
model artifacts; otherwise it runs the NumPy reference pipeline. Either way it
emits ml/artifacts/comparison.md — the model scoreboard used in the README.

    python ml/scripts/run_pipeline.py            # auto-detect
    python ml/scripts/run_pipeline.py --torch    # force torch path
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))


def _has_torch() -> bool:
    try:
        import torch  # noqa
        import torch_geometric  # noqa
        return True
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--torch", action="store_true", help="force torch/PyG training path")
    args = ap.parse_args()

    if args.torch or _has_torch():
        print("torch + torch-geometric detected -> training GCN / GraphSAGE / GAT")
        from kavach_ml.config import TrainConfig
        from kavach_ml.data import generate_economy, build_feature_frame, build_graph
        from kavach_ml.train import train_gnn
        from kavach_ml.evaluate import comparison_table
        from kavach_ml.models.baselines import train_baselines
        from kavach_ml.evaluate import score
        from kavach_ml.utils import make_splits, save_json
        from kavach_ml.config import ARTIFACTS

        eco = generate_economy()
        feats = build_feature_frame(eco.companies, eco.history)
        bundle = build_graph(eco, feats)
        cfg = TrainConfig()
        splits = make_splits(bundle.y, cfg)
        scores = {}
        base = train_baselines(bundle.X, bundle.y, splits["train"], splits["val"], splits["test"])
        for _, r in base.items():
            thr = score(bundle.y[splits["val"]], r.val_proba)["threshold"]
            scores[r.name] = score(bundle.y[splits["test"]], r.test_proba, threshold=thr)
        for name in ("gcn", "graphsage", "gat"):
            _, _, m = train_gnn(name, bundle, cfg)
            scores[name] = m
        table = comparison_table(scores)
        print(table)
        (ARTIFACTS / "comparison.md").write_text(table)
        save_json(scores, ARTIFACTS / "comparison.json")
    else:
        print("torch not found -> running NumPy reference pipeline (scripts/quick_demo.py)")
        import quick_demo
        quick_demo.main()


if __name__ == "__main__":
    main()
