"""Graph construction + graph-derived features.

Consumes an `Economy` and the tabular feature frame, and produces a
`GraphBundle` with everything the models need:

  X            (N, F) node feature matrix  (tabular + graph-derived features)
  y            (N,)   binary distress labels
  edge_index   (2, E) COO edges (undirected, deduplicated)
  edge_weight  (E,)   relationship weights
  feature_names, node_ids

Graph-derived features (concentration, neighbour distress, centrality) are the
signal a purely tabular model cannot see. We compute them with NumPy + a small
power-iteration PageRank so the module has no hard dependency on torch/networkx,
but `to_pyg()` will hand back a torch-geometric `Data` object when available.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from .synthetic import Economy


@dataclass
class GraphBundle:
    X: np.ndarray                     # (N, F) financial node features (model input)
    y: np.ndarray
    edge_index: np.ndarray            # (2, E)
    edge_weight: np.ndarray           # (E,)
    feature_names: list
    node_ids: list
    graph_features: pd.DataFrame = None  # structural features for analytics (NOT model input)
    edge_type: np.ndarray = None      # (E,) relation id per edge (for relational/heterogeneous GNN)
    relation_names: tuple = None      # names indexed by edge_type
    mu: np.ndarray = None             # standardisation stats (for scoring new companies)
    sigma: np.ndarray = None

    @property
    def num_nodes(self) -> int:
        return self.X.shape[0]

    @property
    def num_features(self) -> int:
        return self.X.shape[1]

    def to_pyg(self):  # pragma: no cover - requires torch_geometric
        import torch
        from torch_geometric.data import Data
        return Data(
            x=torch.tensor(self.X, dtype=torch.float32),
            y=torch.tensor(self.y, dtype=torch.long),
            edge_index=torch.tensor(self.edge_index, dtype=torch.long),
            edge_weight=torch.tensor(self.edge_weight, dtype=torch.float32),
        )


def _herfindahl(weights: np.ndarray) -> float:
    """Concentration index in [0, 1]; 1.0 == single dominant counterparty."""
    if len(weights) == 0:
        return 0.0
    s = weights / max(weights.sum(), 1e-9)
    return float(np.sum(s ** 2))


def build_graph(economy: Economy, feature_frame: pd.DataFrame) -> GraphBundle:
    companies = economy.companies
    edges = economy.edges
    node_ids = companies["company_id"].tolist()
    idx = {c: i for i, c in enumerate(node_ids)}
    n = len(node_ids)

    # --- COO edge list (undirected for message passing) --------------------
    from ..config import EDGE_TYPES
    rel_to_id = {r: i for i, r in enumerate(EDGE_TYPES)}
    src = edges["src"].map(idx).values
    dst = edges["dst"].map(idx).values
    w = edges["weight"].values.astype(np.float32)
    et = edges["type"].map(rel_to_id).values.astype(np.int64)
    edge_index = np.vstack([
        np.concatenate([src, dst]),
        np.concatenate([dst, src]),
    ]).astype(np.int64)
    edge_weight = np.concatenate([w, w]).astype(np.float32)
    edge_type = np.concatenate([et, et]).astype(np.int64)   # relation id, undirected-duplicated

    # --- graph-derived features -------------------------------------------
    distress = companies["distress"].values.astype(float)

    # supplier / customer concentration (HHI) from the directed edges
    sup_hhi = np.zeros(n)
    cus_hhi = np.zeros(n)
    for cid, grp in edges[edges["type"] == "SUPPLIES"].groupby("dst"):
        sup_hhi[idx[cid]] = _herfindahl(grp["weight"].values)
    for cid, grp in edges[edges["type"] == "CUSTOMER_OF"].groupby("src"):
        cus_hhi[idx[cid]] = _herfindahl(grp["weight"].values)

    # neighbour distress mean (1-hop) — leaks no own label, only neighbours'
    neigh = _neighbour_mean(edge_index, distress, n)

    # centrality
    deg = _degree_centrality(edge_index, n)
    pr = _pagerank(edge_index, n)

    graph_feats = pd.DataFrame({
        "company_id": node_ids,
        "supplier_concentration_hhi": sup_hhi,
        "customer_concentration_hhi": cus_hhi,
        "neighbour_distress_mean": neigh,
        "pagerank": pr,
        "degree_centrality": deg,
    })

    # IMPORTANT: model node-features are the company's OWN financial ratios only.
    # The graph models reach neighbour information through message passing over
    # `edge_index`; the tabular baselines cannot — that is the experiment.
    # `graph_features` (concentration, centrality, neighbour distress) is kept
    # separate and used only by the analytics engine / explainability, never fed
    # to the classifiers, to keep the comparison fair and leakage-free.
    from .features import FEATURE_NAMES, transform_features
    feature_names = list(FEATURE_NAMES)
    X = transform_features(feature_frame)                 # clip + log-compress

    mu, sigma = X.mean(0), X.std(0) + 1e-6                # z-score standardisation
    X = (X - mu) / sigma

    return GraphBundle(
        X=X,
        y=companies["distress"].values.astype(np.int64),
        edge_index=edge_index,
        edge_weight=edge_weight,
        feature_names=feature_names,
        node_ids=node_ids,
        graph_features=graph_feats,
        edge_type=edge_type,
        relation_names=EDGE_TYPES,
        mu=mu,
        sigma=sigma,
    )


def _neighbour_mean(edge_index: np.ndarray, values: np.ndarray, n: int) -> np.ndarray:
    acc = np.zeros(n)
    cnt = np.zeros(n)
    for a, b in zip(edge_index[0], edge_index[1]):
        acc[b] += values[a]
        cnt[b] += 1
    return np.where(cnt > 0, acc / np.maximum(cnt, 1), values.mean())


def _degree_centrality(edge_index: np.ndarray, n: int) -> np.ndarray:
    deg = np.zeros(n)
    for a in edge_index[0]:
        deg[a] += 1
    return deg / max(n - 1, 1)


def _pagerank(edge_index: np.ndarray, n: int, damping: float = 0.85, iters: int = 60) -> np.ndarray:
    """Power-iteration PageRank on the (undirected) adjacency."""
    outdeg = np.zeros(n)
    for a in edge_index[0]:
        outdeg[a] += 1
    outdeg = np.maximum(outdeg, 1)
    rank = np.full(n, 1.0 / n)
    for _ in range(iters):
        contrib = np.zeros(n)
        r_over_deg = rank / outdeg
        for a, b in zip(edge_index[0], edge_index[1]):
            contrib[b] += r_over_deg[a]
        rank = (1 - damping) / n + damping * contrib
    return rank / rank.max()
