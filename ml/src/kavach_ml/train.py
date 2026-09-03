"""GNN training loop (torch / torch-geometric).

Full-batch transductive training on the company graph. Handles the rare-class
problem with class weighting + focal loss, tunes the threshold on validation,
and early-stops on validation PR-AUC.

Run:
    python -m kavach_ml.train --model gat --epochs 200

For an environment without torch installed, use scripts/quick_demo.py, which
runs a NumPy reference GNN + the sklearn baselines end-to-end.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

from .config import TrainConfig, ARTIFACTS
from .data import generate_economy, build_feature_frame, build_graph
from .evaluate import score
from .utils import make_splits


def focal_bce(logits, targets, alpha, gamma):  # pragma: no cover - torch
    import torch
    import torch.nn.functional as F
    p = torch.sigmoid(logits)
    ce = F.binary_cross_entropy_with_logits(logits, targets, reduction="none")
    p_t = p * targets + (1 - p) * (1 - targets)
    a_t = alpha * targets + (1 - alpha) * (1 - targets)
    loss = a_t * (1 - p_t) ** gamma * ce
    return loss.mean()


def train_gnn(model_name: str, bundle, cfg: TrainConfig | None = None):  # pragma: no cover - torch
    import torch
    from .models import load_gnn

    cfg = cfg or TrainConfig()
    torch.manual_seed(cfg.seed)
    data = bundle.to_pyg()

    splits = make_splits(bundle.y, cfg)
    train_mask = torch.zeros(bundle.num_nodes, dtype=torch.bool)
    val_mask = torch.zeros(bundle.num_nodes, dtype=torch.bool)
    train_mask[splits["train"]] = True
    val_mask[splits["val"]] = True

    pos = bundle.y[splits["train"]].sum()
    neg = len(splits["train"]) - pos
    alpha = float(neg / (pos + neg))                     # weight the rare class up

    Model = load_gnn(model_name)
    model = Model(
        in_dim=bundle.num_features, hidden=cfg.hidden_dim, layers=cfg.n_layers,
        dropout=cfg.dropout, heads=cfg.gat_heads,
    )
    opt = torch.optim.Adam(model.parameters(), lr=cfg.lr, weight_decay=cfg.weight_decay)
    y = data.y.float()

    best_pr, best_state, wait = -1.0, None, 0
    for epoch in range(cfg.epochs):
        model.train()
        opt.zero_grad()
        logit, _ = model(data.x, data.edge_index, data.edge_weight)
        loss = focal_bce(logit[train_mask], y[train_mask], alpha, cfg.focal_gamma)
        loss.backward()
        opt.step()

        model.eval()
        with torch.no_grad():
            vlogit, _ = model(data.x, data.edge_index, data.edge_weight)
            vproba = torch.sigmoid(vlogit[val_mask]).cpu().numpy()
        m = score(bundle.y[splits["val"]], vproba)
        if m["pr_auc"] > best_pr:
            best_pr, best_state, wait = m["pr_auc"], model.state_dict(), 0
        else:
            wait += 1
            if wait >= cfg.patience:
                break

    if best_state:
        model.load_state_dict(best_state)
    model.eval()
    with torch.no_grad():
        logit, _ = model(data.x, data.edge_index, data.edge_weight)
        proba = torch.sigmoid(logit).cpu().numpy()

    thr = score(bundle.y[splits["val"]], proba[splits["val"]])["threshold"]
    test_metrics = score(bundle.y[splits["test"]], proba[splits["test"]], threshold=thr)

    out = ARTIFACTS / f"gnn_{model_name}.pt"
    torch.save({"state_dict": model.state_dict(),
                "feature_names": bundle.feature_names,
                "threshold": thr, "config": cfg.__dict__}, out)
    return model, proba, test_metrics


def main():  # pragma: no cover
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="gat", choices=["gcn", "graphsage", "gat"])
    ap.add_argument("--epochs", type=int, default=200)
    args = ap.parse_args()

    eco = generate_economy()
    feats = build_feature_frame(eco.companies, eco.history)
    bundle = build_graph(eco, feats)
    cfg = TrainConfig(epochs=args.epochs)
    _, _, metrics = train_gnn(args.model, bundle, cfg)
    print(f"{args.model} test metrics:", metrics)


if __name__ == "__main__":
    main()
