"""NumPy reference GNN — a dependency-light stand-in for the torch models.

This implements the *core idea* of a graph neural network — message passing:
repeatedly average each node's features with its neighbours' features, then
train a linear classifier on the propagated representation. This is exactly the
Simplified Graph Convolution (SGC, Wu et al. 2019) view of a GCN, and it lets
the whole pipeline run and demonstrate "graph beats tabular" with only NumPy +
scikit-learn installed.

The production models in gnn.py (GCN / GraphSAGE / GAT on torch-geometric) are
the real deliverable; this module exists so the repo runs end-to-end anywhere
and so the model-comparison table can be produced in CI without a GPU.
"""
from __future__ import annotations

import numpy as np
from sklearn.linear_model import LogisticRegression


def _normalised_adj(edge_index: np.ndarray, n: int, mode: str = "gcn") -> np.ndarray:
    A = np.zeros((n, n), dtype=np.float32)
    for a, b in zip(edge_index[0], edge_index[1]):
        A[a, b] = 1.0
    A = A + np.eye(n, dtype=np.float32)                  # add self-loops
    deg = A.sum(1)
    if mode == "gcn":                                     # symmetric normalisation
        dinv = 1.0 / np.sqrt(np.maximum(deg, 1e-9))
        return (A * dinv[None, :]) * dinv[:, None]
    dinv = 1.0 / np.maximum(deg, 1e-9)                    # mean aggregation (SAGE-like)
    return A * dinv[:, None]


def propagate(X: np.ndarray, edge_index: np.ndarray, k: int = 2, mode: str = "gcn") -> np.ndarray:
    """Message passing: H = A_norm^k X, then concat with the raw features."""
    A = _normalised_adj(edge_index, X.shape[0], mode)
    H = X.copy()
    for _ in range(k):
        H = A @ H
    return np.concatenate([X, H], axis=1)                # skip-connection to raw feats


class NumpyGNN:
    """SGC-style graph model: k-hop propagation + logistic head."""

    def __init__(self, k: int = 2, mode: str = "gcn", C: float = 1.0):
        self.k = k
        self.mode = mode
        self.clf = LogisticRegression(max_iter=2000, class_weight="balanced", C=C)
        self._edge_index = None
        self._n = None

    def fit(self, X, edge_index, y, train_idx):
        self._edge_index, self._n = edge_index, X.shape[0]
        H = propagate(X, edge_index, self.k, self.mode)
        self._H = H
        self.clf.fit(H[train_idx], y[train_idx])
        return self

    def predict_proba_all(self):
        return self.clf.predict_proba(self._H)[:, 1]

    def predict_proba(self, idx):
        return self.clf.predict_proba(self._H[idx])[:, 1]
