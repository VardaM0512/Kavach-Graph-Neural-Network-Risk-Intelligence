"""Graph explainability: which connected companies drove this prediction.

Two mechanisms:
  * GAT attention weights (when a trained torch GAT model is supplied)
  * a model-agnostic neighbour-influence score computed from edge weights and
    each neighbour's own predicted risk — used by the NumPy demo and as a
    fallback. This is what powers the "Company B and Company C — two major
    connected suppliers — are showing elevated distress" narrative.
"""
from __future__ import annotations

import numpy as np


def explain_neighbours(node_i: int, edge_index: np.ndarray, edge_weight: np.ndarray,
                       node_proba: np.ndarray, node_ids, top_k: int = 5):
    """Rank 1-hop neighbours of node_i by influence = edge_weight * neighbour_risk."""
    influences = []
    for e in range(edge_index.shape[1]):
        a, b = edge_index[0, e], edge_index[1, e]
        if b == node_i:                                  # incoming message a -> i
            infl = float(edge_weight[e]) * float(node_proba[a])
            influences.append((int(a), infl, float(node_proba[a]), float(edge_weight[e])))
    influences.sort(key=lambda t: t[1], reverse=True)
    out = []
    for a, infl, risk, w in influences[:top_k]:
        out.append({
            "neighbour_id": node_ids[a],
            "influence": round(infl, 4),
            "neighbour_risk": round(risk, 4),
            "relationship_weight": round(w, 4),
        })
    return out


def gnn_explainer_topk(model, data, node_i: int, node_ids, top_k: int = 5):  # pragma: no cover
    """Wrap torch-geometric's GNNExplainer for a single node prediction."""
    from torch_geometric.explain import Explainer, GNNExplainer
    explainer = Explainer(
        model=model,
        algorithm=GNNExplainer(epochs=100),
        explanation_type="model",
        node_mask_type="attributes",
        edge_mask_type="object",
        model_config=dict(mode="binary_classification", task_level="node", return_type="raw"),
    )
    expl = explainer(data.x, data.edge_index, index=node_i)
    edge_mask = expl.edge_mask.cpu().numpy()
    top = np.argsort(edge_mask)[::-1][:top_k]
    return [
        {"src": node_ids[int(data.edge_index[0, e])],
         "dst": node_ids[int(data.edge_index[1, e])],
         "importance": float(edge_mask[e])}
        for e in top
    ]
