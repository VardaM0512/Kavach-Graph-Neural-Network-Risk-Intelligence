"""Inductive relational graph model — the production scorer.

A GraphSAGE-style model with *typed*, *directional* neighbourhoods. For every
company i the representation is

    h_i = [ x_i | mean_w(x_j : j supplies i) | mean_w(x_j : j buys from i)
                | mean_w(x_j : same business group) | mean_w(x_j : sector peers)
                | mean_w(m_j : any neighbour j)   | has-relation flags ]

where mean_w is a dependency-weighted mean (a 48% supplier counts more than a
3% one) and m_j is j's own 1-hop aggregate, giving a second hop. A calibrated
logistic head turns h_i into a 12-month probability of default.

Why this design:
  * Inductive: h_i only needs i's ratios and its counterparties' ratios, so a
    company that was never in the training graph — say, one typed in from a
    real annual report — can be scored by attaching it to the graph through the
    counterparties the user names.
  * Exactly explainable: the head is linear in h_i, so every prediction splits
    into per-feature contributions (own fundamentals) and per-relation and
    per-counterparty contributions (network), with no approximation.
  * Calibrated: trained without class re-weighting, so outputs are usable as
    PDs (Brier score is reported alongside AUC).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from scipy import sparse
from scipy.optimize import minimize

RELATIONS = ("suppliers", "customers", "group", "peers")
# A counterparty's dependency on you is not your dependency on it: a supplier
# that is 40% of *your* purchases may be only a small slice of *its* revenue.
REVERSE_DEPENDENCY = 0.35


class SignConstrainedLogit:
    """L2 logistic regression with per-coefficient sign bounds (L-BFGS-B).

    Sign constraints encode domain knowledge the data alone cannot guarantee
    under collinearity: a higher interest cover may never *raise* default risk,
    and a healthier counterparty may never make you riskier. This keeps every
    explanation the app shows economically coherent.
    """

    def __init__(self, C: float = 0.25):
        self.C = C

    def fit(self, H, y, signs: np.ndarray):
        n, d = H.shape
        lam = 1.0 / (self.C * n)
        y = y.astype(float)

        def f(wb):
            w, b = wb[:d], wb[d]
            z = H @ w + b
            p = 1 / (1 + np.exp(-z))
            loss = np.mean(np.logaddexp(0, z) - y * z) + 0.5 * lam * w @ w
            g = H.T @ (p - y) / n + lam * w
            return loss, np.append(g, np.mean(p - y))

        bounds = [(0, None) if s > 0 else (None, 0) if s < 0 else (None, None) for s in signs]
        bounds.append((None, None))
        res = minimize(f, np.zeros(d + 1), jac=True, method="L-BFGS-B", bounds=bounds,
                       options={"maxiter": 3000})
        self.coef_ = res.x[:d][None, :]
        self.intercept_ = np.array([res.x[d]])
        return self

    def predict_proba(self, H):
        z = np.clip(H @ self.coef_.ravel() + self.intercept_[0], -30, 30)
        p = 1 / (1 + np.exp(-z))
        return np.stack([1 - p, p], axis=1)


@dataclass
class Link:
    """One counterparty edge as seen from the focal company."""
    relation: str          # one of RELATIONS
    weight: float          # dependency share (0..1)
    x: np.ndarray          # counterparty's standardised features
    m: np.ndarray          # counterparty's 1-hop aggregate (for the 2nd hop)
    ref: str | None = None # counterparty id / label (for explanations)
    known: bool = False    # is the counterparty's default status known?
    y: float = 0.0         # 1 = known to be in default


def label_features_np(n: int, rel_rows, known: np.ndarray, label: np.ndarray) -> np.ndarray:
    """Per relation: dependency-weighted share of known counterparties in default,
    plus whether any counterparty status is known (mirrors gnn.label_features)."""
    num = np.zeros((n, len(RELATIONS)))
    den = np.zeros((n, len(RELATIONS)))
    rid = {r: k for k, r in enumerate(RELATIONS)}
    for i, j, r, w in rel_rows:
        if known[j]:
            num[i, rid[r]] += w * label[j]
            den[i, rid[r]] += w
    has = (den > 0).astype(np.float32)
    return np.concatenate([np.where(den > 0, num / np.maximum(den, 1e-9), 0.0), has], 1).astype(np.float32)


def directed_relations(edges: pd.DataFrame, idx: dict) -> list[tuple[int, int, str, float]]:
    """Expand the edge table into (focal, neighbour, relation, weight) rows."""
    out = []
    for s, d, t, w in zip(edges["src"].values, edges["dst"].values,
                          edges["type"].values, edges["weight"].values):
        a, b = idx[s], idx[d]
        w = float(w)
        if t == "SUPPLIES":            # a supplies b (w = share of b's purchases)
            out += [(b, a, "suppliers", w), (a, b, "customers", w * REVERSE_DEPENDENCY)]
        elif t == "CUSTOMER_OF":       # b is a customer of a (w = share of a's revenue)
            out += [(a, b, "customers", w), (b, a, "suppliers", w * REVERSE_DEPENDENCY)]
        elif t in ("OWNS", "BORROWS_FROM"):
            out += [(a, b, "group", w), (b, a, "group", w)]
        else:                          # SAME_INDUSTRY
            out += [(a, b, "peers", w), (b, a, "peers", w)]
    return out


class InductiveGraphModel:
    def __init__(self, C: float = 0.25, risk_signs: np.ndarray | None = None, use_labels: bool = False):
        self.clf = SignConstrainedLogit(C=C)
        self.risk_signs = risk_signs      # per own-feature: +1 raises risk, -1 lowers, 0 free
        self.use_labels = use_labels      # add counterparties' known default status
        self.F = None
        self.known = self.label = None

    # ------------------------------------------------------------ structure
    def build(self, X: np.ndarray, rel_rows: list[tuple[int, int, str, float]]):
        n, self.F = X.shape
        self.n = n
        mats = {}
        for r in RELATIONS:
            rows = [(i, j, w) for i, j, rr, w in rel_rows if rr == r]
            if rows:
                i, j, w = map(np.array, zip(*rows))
                mats[r] = sparse.csr_matrix((w, (i, j)), shape=(n, n))
            else:
                mats[r] = sparse.csr_matrix((n, n))
        self.A = mats
        self.A_all = sum(mats.values()).tocsr()
        return self

    @staticmethod
    def _rownorm(A):
        d = np.asarray(A.sum(1)).ravel()
        dinv = np.where(d > 0, 1.0 / np.maximum(d, 1e-12), 0.0)
        return sparse.diags(dinv) @ A, d > 0

    def embed(self, X: np.ndarray, known=None, label=None) -> tuple[np.ndarray, np.ndarray]:
        """Return (H, M1): the embedding and each node's 1-hop aggregate."""
        blocks, flags = [X], []
        for r in RELATIONS:
            An, has = self._rownorm(self.A[r])
            blocks.append(An @ X)
            flags.append(has.astype(np.float32))
        Aall, _ = self._rownorm(self.A_all)
        M1 = np.asarray(Aall @ X)
        blocks.append(Aall @ M1)
        parts = [np.asarray(b) for b in blocks] + [np.stack(flags, 1)]
        if self.use_labels:
            known = self.known if known is None else known
            label = self.label if label is None else label
            parts.append(label_features_np(X.shape[0], self.rel_rows, known, label))
        H = np.concatenate(parts, axis=1)
        return H.astype(np.float32), M1.astype(np.float32)

    # ------------------------------------------------------------- training
    def fit(self, X, rel_rows, y, train_idx, known=None):
        """known: which companies' default status is visible as an input (default:
        the training set). A company never sees its own label - only neighbours'."""
        self.build(X, rel_rows)
        self.rel_rows = rel_rows
        self.X = X
        if self.use_labels:
            self.known = np.zeros(len(y), bool)
            self.known[train_idx if known is None else known] = True
            self.label = np.asarray(y, float) * self.known
        self.H, self.M1 = self.embed(X)
        own = self.risk_signs if self.risk_signs is not None else np.zeros(self.F)
        # own + each relation block + second hop share the same economic signs
        signs = np.concatenate([own] * (len(RELATIONS) + 2) + [np.zeros(len(RELATIONS))])
        if self.use_labels:   # a defaulted counterparty can only raise risk
            signs = np.concatenate([signs, np.ones(len(RELATIONS)), np.zeros(len(RELATIONS))])
        self.clf.fit(self.H[train_idx], y[train_idx], signs)
        self.H_mean = self.H.mean(0)
        return self

    def predict_proba_all(self, H=None):
        return self.clf.predict_proba(self.H if H is None else H)[:, 1]

    def predict_proba(self, idx):
        return self.clf.predict_proba(self.H[idx])[:, 1]

    # ----------------------------------------------------- inductive scoring
    def embed_one(self, x: np.ndarray, links: list[Link]) -> np.ndarray:
        F = self.F
        blocks, flags = [x], []
        all_w, all_m = [], []
        for r in RELATIONS:
            ls = [l for l in links if l.relation == r and l.weight > 0]
            if ls:
                w = np.array([l.weight for l in ls])
                blocks.append((w[:, None] * np.stack([l.x for l in ls])).sum(0) / w.sum())
                flags.append(1.0)
            else:
                blocks.append(np.zeros(F))
                flags.append(0.0)
        ls = [l for l in links if l.weight > 0]
        if ls:
            w = np.array([l.weight for l in ls])
            blocks.append((w[:, None] * np.stack([l.m for l in ls])).sum(0) / w.sum())
        else:
            blocks.append(np.zeros(F))
        parts = blocks + [np.array(flags)]
        if self.use_labels:
            num = np.zeros(len(RELATIONS)); den = np.zeros(len(RELATIONS))
            for l in links:
                if l.known and l.weight > 0:
                    k = RELATIONS.index(l.relation)
                    num[k] += l.weight * l.y; den[k] += l.weight
            parts += [np.where(den > 0, num / np.maximum(den, 1e-9), 0.0), (den > 0).astype(float)]
        return np.concatenate(parts).astype(np.float32)

    def proba_one(self, h: np.ndarray) -> float:
        return float(self.clf.predict_proba(h[None, :])[0, 1])

    # -------------------------------------------------------- attribution
    @property
    def coef(self) -> np.ndarray:
        return self.clf.coef_.ravel()

    def block_slices(self) -> dict:
        F = self.F
        names = ["own", *RELATIONS, "second_hop"]
        out = {nm: slice(k * F, (k + 1) * F) for k, nm in enumerate(names)}
        base = len(names) * F
        out["flags"] = slice(base, base + len(RELATIONS))
        if self.use_labels:
            out["label_share"] = slice(base + len(RELATIONS), base + 2 * len(RELATIONS))
            out["label_has"] = slice(base + 2 * len(RELATIONS), base + 3 * len(RELATIONS))
        return out

    def contributions(self, h: np.ndarray) -> np.ndarray:
        """Exact log-odds contribution of each embedding slot vs. the universe mean."""
        return self.coef * (h - self.H_mean)

    def link_contribution(self, link: Link, links: list[Link]) -> float:
        """Exact share of the relation block's log-odds owed to one counterparty."""
        same = [l for l in links if l.relation == link.relation and l.weight > 0]
        tot = sum(l.weight for l in same) or 1.0
        sls = self.block_slices()
        sl = sls[link.relation]
        out = float((link.weight / tot) * (self.coef[sl] @ (link.x - self.H_mean[sl])))
        if self.use_labels and link.known:
            k = RELATIONS.index(link.relation)
            kn = sum(l.weight for l in same if l.known) or 1.0
            j = sls["label_share"].start + k
            out += float((link.weight / kn) * self.coef[j] * (link.y - self.H_mean[j]))
        return out
