"""ModelSuite — the production scorer.

Members (all graph models; all see counterparties' known default status):
  irgnn   linear relational GNN, sign-constrained, exactly explainable
  gcn     PyTorch Geometric GCN, 5-seed ensemble, Platt-calibrated
  gat     PyTorch Geometric GAT, 5-seed ensemble, Platt-calibrated

Production PD = average of member log-odds. The uncertainty band is the 10th-90th
percentile over all individual networks (every seed of every member), i.e. how
much equally plausible models disagree. Explanations come from the irgnn member,
whose attribution is exact; the UI labels them that way.

Trained PyG networks are cached in ml/artifacts/models/<key>.pt, keyed on the
data config and model version, so a restart loads instead of retraining and
scores are identical across restarts.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass

import numpy as np
from scipy.special import expit, logit

from ..config import ARTIFACTS, SyntheticConfig, TrainConfig
from ..models.inductive import InductiveGraphModel, Link
from ..utils import make_splits

MODEL_VERSION = "kavach-suite-2"

try:
    import torch
    from ..models.gnn import GNNEnsemble, build_tensors, extend_graph, seed_probas
    HAVE_TORCH = True
except Exception:  # pragma: no cover - torch optional
    HAVE_TORCH = False


def _L(p):
    return logit(np.clip(p, 1e-6, 1 - 1e-6))


@dataclass
class NewNode:
    """A company scored inductively (Analyze, workspace, scenario copy)."""
    x: np.ndarray                     # standardised features
    links: list                       # list[Link] for the irgnn member
    edges: list                       # (src_index, relation, weight) into this node; src may be another new node
    known: bool = False               # own default status known (only used for *other* nodes' inputs)
    y: float = 0.0


class ModelSuite:
    def __init__(self, signs: np.ndarray, members: tuple[str, ...] | None = None):
        self.signs = signs
        wanted = os.getenv("KAVACH_MODELS", "irgnn,gcn,gat").split(",")
        self.members = tuple(m for m in (members or wanted) if m == "irgnn" or HAVE_TORCH)
        self.irgnn: InductiveGraphModel | None = None
        self.gnns: dict[str, "GNNEnsemble"] = {}
        self.g = None
        self.status: dict = {}

    # --------------------------------------------------------------- fitting
    def cache_key(self, synth: SyntheticConfig, n: int) -> str:
        blob = json.dumps({"v": MODEL_VERSION, "synth": repr(synth), "n": n,
                           "members": [m for m in self.members if m != "irgnn"]}, sort_keys=True)
        return hashlib.sha1(blob.encode()).hexdigest()[:16]

    def fit(self, X, rel_rows, y, synth: SyntheticConfig):
        t0 = time.time()
        n = len(y)
        splits = make_splits(y, TrainConfig())
        tr, va = splits["train"], splits["val"]
        everyone = np.arange(n)
        # serving: every company's status is visible to its counterparties (never to itself)
        self.irgnn = InductiveGraphModel(risk_signs=self.signs, use_labels=True).fit(
            X, rel_rows, y, np.concatenate([tr, va]), known=everyone)
        self.y = np.asarray(y, float)
        gnn_names = [m for m in self.members if m != "irgnn"]
        loaded = False
        if gnn_names:
            self.g = build_tensors(X, rel_rows)
            path = ARTIFACTS / "models" / f"{self.cache_key(synth, n)}.pt"
            if path.exists():
                st = torch.load(path, weights_only=False)
                self.gnns = {k: GNNEnsemble.from_state(v, X.shape[1]) for k, v in st.items()}
                loaded = True
            else:
                for m in gnn_names:
                    self.gnns[m] = GNNEnsemble(m).fit(self.g, y, tr, va)
                path.parent.mkdir(parents=True, exist_ok=True)
                torch.save({k: v.state() for k, v in self.gnns.items()}, path)
            self.known_t = torch.ones(n, dtype=torch.bool)
            self.label_t = torch.tensor(y, dtype=torch.float32)
        self.status = {"members": list(self.members), "torch": HAVE_TORCH, "cached": loaded,
                       "seconds": round(time.time() - t0, 1), "version": MODEL_VERSION}
        return self

    # ----------------------------------------------------------- universe
    def universe(self, X, known=None, label=None, own_X=None):
        """PDs for every universe company. `own_X` optionally replaces each company's
        own features while neighbours keep `X` (used by contagion cascades)."""
        H, _ = self.irgnn.embed(X, known, label)
        if own_X is not None:
            H[:, self.irgnn.block_slices()["own"]] = own_X
        logits = {"irgnn": _L(self.irgnn.predict_proba_all(H))}
        seeds = [logits["irgnn"][None, :]]
        if self.gnns:
            kt = self.known_t if known is None else torch.tensor(known, dtype=torch.bool)
            lt = self.label_t if label is None else torch.tensor(label, dtype=torch.float32)
            g = self._with_x(X)            # neighbours' view of the network
            for m, ens in self.gnns.items():
                ps = seed_probas(ens, g, kt, lt)
                logits[m] = _L(ens.proba(g, kt, lt))
                seeds.append(_L(ps))
        return self._blend(logits, np.concatenate(seeds))

    def _with_x(self, X):
        from ..models.gnn import GraphTensors
        g = GraphTensors(torch.tensor(X, dtype=torch.float32), self.g.src, self.g.dst, self.g.rel, self.g.w)
        g.w_norm = self.g.w_norm
        return g

    @staticmethod
    def _blend(logits: dict, seed_logits: np.ndarray):
        p = expit(np.mean(list(logits.values()), axis=0))
        lo = expit(np.percentile(seed_logits, 10, axis=0))
        hi = expit(np.percentile(seed_logits, 90, axis=0))
        members = {k: expit(v) for k, v in logits.items()}
        return p, np.minimum(lo, p), np.maximum(hi, p), members

    # --------------------------------------------------------- inductive
    def extend(self, X_univ, nodes: list[NewNode], pseudo_x: list[np.ndarray] | None = None,
               pseudo_label: list[float] | None = None):
        """Score new companies attached to the universe.

        Edge sources are universe indices (0..N-1), pseudo counterparties
        (N..N+P-1, rows of pseudo_x) or other new nodes (N+P..). Returns
        (p, lo, hi, member_probs, irgnn_h) with one entry per new node.
        """
        hs = [self.irgnn.embed_one(nd.x, nd.links) for nd in nodes]
        logits = {"irgnn": _L(np.array([self.irgnn.proba_one(h) for h in hs]))}
        seeds = [logits["irgnn"][None, :]]
        if self.gnns:
            n = X_univ.shape[0]
            px = list(pseudo_x or [])
            new_x = np.array(px + [nd.x for nd in nodes]) if (px or nodes) else np.zeros((0, X_univ.shape[1]))
            base = n + len(px)
            edges = [(src, base + k, rel, w) for k, nd in enumerate(nodes) for src, rel, w in nd.edges]
            g = extend_graph(self.g if X_univ is None else self._with_x(X_univ), new_x, edges)
            known = torch.cat([self.known_t, torch.ones(len(px), dtype=torch.bool),
                               torch.tensor([nd.known for nd in nodes], dtype=torch.bool)])
            label = torch.cat([self.label_t, torch.tensor(pseudo_label or [0.0] * len(px), dtype=torch.float32),
                               torch.tensor([nd.y for nd in nodes], dtype=torch.float32)])
            idx = np.arange(base, base + len(nodes))
            for m, ens in self.gnns.items():
                logits[m] = _L(ens.proba(g, known, label)[idx])
                seeds.append(_L(seed_probas(ens, g, known, label)[:, idx]))
        p, lo, hi, members = self._blend(logits, np.concatenate(seeds))
        return p, lo, hi, members, hs
