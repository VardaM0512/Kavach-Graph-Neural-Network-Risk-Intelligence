"""RiskEngine — the inference + analytics core used by the FastAPI backend.

On startup it simulates the Indian corporate universe (see data/synthetic.py),
builds the typed supply-chain / ownership graph, trains the inductive
relational graph model (models/inductive.py) and back-scores every fiscal year
so trends are real model outputs, not decoration.

Two kinds of company can be scored:
  * universe companies (fictional, synthetic statements, full graph context)
  * any real company via `analyze()`: the caller supplies reported financials
    and names its key counterparties; the company is attached to the graph
    through them and scored inductively by the same model.

Everything is computed from statements -> ratios -> model, so stress tests and
contagion cascades re-run the model on shocked financials rather than applying
hand-tuned deltas.
"""
from __future__ import annotations

import difflib
import functools
import re
import threading

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, brier_score_loss, roc_auc_score

from ..config import SyntheticConfig, TrainConfig, band_for, implied_rating, HORIZONS_MONTHS
from ..data import generate_economy, build_feature_frame
from ..data.features import (FEATURE_NAMES, FEATURE_GROUPS, REQUIRED_FIELDS,
                             transform_features)
from ..data.synthetic import INDUSTRIES, SECTORS
from ..models.inductive import InductiveGraphModel, Link, RELATIONS, directed_relations
from ..utils import make_splits
from .suite import ModelSuite, NewNode

_LOCK = threading.Lock()

# + means "higher is healthier" for the health composite
_GOOD_SIGN = {
    "current_ratio": 1, "quick_ratio": 1, "cash_ratio": 1, "working_capital_to_assets": 1,
    "debt_to_equity": -1, "debt_to_assets": -1, "interest_coverage": 1, "net_debt_to_ebitda": -1,
    "ebitda_margin": 1, "net_margin": 1, "return_on_assets": 1, "return_on_equity": 1,
    "ocf_to_debt": 1, "fcf_margin": 1, "cash_burn_months": 1,
    "revenue_growth_yoy": 1, "revenue_cagr_3y": 1, "margin_trend": 1, "promoter_pledge": -1,
}
HEALTH_LABELS = ("strong", "stable", "weak", "distressed")
_REL_FROM_USER = {"supplier": "suppliers", "customer": "customers", "parent": "group",
                  "subsidiary": "group", "guarantor": "group", "group": "group", "peer": "peers"}
FAIL_PD = 0.5          # a counterparty above this PD is treated as defaulting in cascades
LGD = 0.45             # loss-given-default for expected-loss figures (Basel FIRB senior unsecured)


class RiskEngine:
    def __init__(self, synth: SyntheticConfig | None = None, members: tuple[str, ...] | None = None):
        self.synth = synth or SyntheticConfig()
        self.economy = generate_economy(self.synth)
        eco = self.economy
        self.fy = int(eco.companies["fy"].max())
        self.companies = eco.companies.reset_index(drop=True)
        self.node_ids = self.companies["company_id"].tolist()
        self._id_to_idx = {c: i for i, c in enumerate(self.node_ids)}
        self.history = eco.history

        # features + standardisation
        self.features = build_feature_frame(self.companies, self.history)
        T = transform_features(self.features)
        self.mu, self.sigma = T.mean(0), T.std(0) + 1e-6
        self.X = self._std_T(T)
        self.y = self.companies["distress"].values.astype(int)

        # graph
        self.rel_rows = directed_relations(eco.edges, self._id_to_idx)
        self._nbrs: list[list[tuple[int, str, float]]] = [[] for _ in self.node_ids]
        self._view: dict[tuple[int, int], list[tuple[str, float]]] = {}
        for i, j, r, w in self.rel_rows:
            self._nbrs[i].append((j, r, w))
            self._view.setdefault((i, j), []).append((r, w))

        self._signs = np.array([-_GOOD_SIGN[k] for k in FEATURE_NAMES], dtype=float)
        # honest evaluation on a held-out split, then refit on train+val
        splits = make_splits(self.y, TrainConfig())
        self.metrics = self._evaluate(splits)
        # production scorer: blend of graph models, trained once and cached
        self.suite = ModelSuite(self._signs, members).fit(self.X, self.rel_rows, self.y, self.synth)
        self.model = self.suite.irgnn                       # exact explanations come from this member
        self.H, self.M1 = self.model.H, self.model.M1
        self.proba, self.pd_low, self.pd_high, self.member_proba = self.suite.universe(self.X)

        # back-scored fiscal years (FY22..FY25) for timelines and movers
        self.year_proba = self._backscore()
        self.proba_prev = self.year_proba.get(self.fy - 1, self.proba)

        # composites for percentile-based health scores
        self._composite = {g: self._group_composite(self.features, g) for g in FEATURE_GROUPS}
        self._composite_sorted = {g: np.sort(v) for g, v in self._composite.items()}

        # counterparty archetypes for counterparties outside the universe
        self._archetypes = self._build_archetypes()
        self._co = self.companies.set_index("company_id")
        self._feat = self.features.set_index("company_id")

    # ================================================================ helpers
    def _std_T(self, T: np.ndarray) -> np.ndarray:
        return ((T - self.mu) / self.sigma).astype(np.float32)

    def _std_frame(self, f: pd.DataFrame) -> np.ndarray:
        return self._std_T(transform_features(f))

    def _idx(self, company_id: str) -> int:
        if company_id not in self._id_to_idx:
            raise KeyError(company_id)
        return self._id_to_idx[company_id]

    def _evaluate(self, splits) -> dict:
        tr, va, te = splits["train"], splits["val"], splits["test"]
        g = InductiveGraphModel(risk_signs=self._signs).fit(self.X, self.rel_rows, self.y, tr)
        pg = g.predict_proba(te)
        tab = LogisticRegression(max_iter=4000, C=0.25).fit(self.X[tr], self.y[tr])
        pt = tab.predict_proba(self.X[te])[:, 1]
        yt = self.y[te]

        def ks(p):
            order = np.argsort(-p)
            pos = np.cumsum(yt[order]) / max(yt.sum(), 1)
            neg = np.cumsum(1 - yt[order]) / max((1 - yt).sum(), 1)
            return float(np.max(np.abs(pos - neg)))

        def block(p):
            return {"roc_auc": round(float(roc_auc_score(yt, p)), 4),
                    "pr_auc": round(float(average_precision_score(yt, p)), 4),
                    "brier": round(float(brier_score_loss(yt, p)), 4),
                    "ks": round(ks(p), 4)}
        return {"graph_model": block(pg), "tabular_model": block(pt),
                "test_size": int(len(te)), "test_default_rate": round(float(yt.mean()), 4),
                "train_size": int(len(tr) + len(va))}

    def _year_frame(self, year: int) -> pd.DataFrame:
        h = self.history[self.history["year"] == year].set_index("company_id").reindex(self.node_ids)
        h = h.reset_index()
        h["promoter_pledge"] = self.companies["promoter_pledge"].values
        h["fy"] = year
        return h

    def _backscore(self) -> dict:
        out = {}
        years = sorted(self.history["year"].unique())[1:]           # need a prior year for growth
        for yr in years:
            if yr == self.fy:
                out[yr] = self.proba
                continue
            X = self._std_frame(build_feature_frame(self._year_frame(yr), self.history))
            out[int(yr)] = self.suite.universe(X)[0]
        return out

    def _group_composite(self, f: pd.DataFrame, group: str) -> np.ndarray:
        T = transform_features(f)
        Z = (T - self.mu) / self.sigma
        cols = [FEATURE_NAMES.index(k) for k in FEATURE_GROUPS[group]]
        signs = np.array([_GOOD_SIGN[FEATURE_NAMES[c]] for c in cols])
        return (Z[:, cols] * signs).mean(1)

    def _build_archetypes(self) -> dict:
        """Mean feature profile per (sector, health bucket) for unknown counterparties."""
        p = self.proba
        bucket = np.select([p < 0.02, p < 0.08, p < 0.30], [0, 1, 2], 3)
        bucket = np.where(self.y == 1, 3, bucket)
        sectors = self.companies["industry"].values
        out = {}
        for b, label in enumerate(HEALTH_LABELS):
            mask = bucket == b
            out[("*", label)] = (self.X[mask].mean(0), self.M1[mask].mean(0))
            for s in INDUSTRIES:
                m = mask & (sectors == s)
                if m.sum() >= 4:
                    out[(s, label)] = (self.X[m].mean(0), self.M1[m].mean(0))
        for s in INDUSTRIES:
            m = sectors == s
            out[(s, "typical")] = (np.median(self.X[m], 0), np.median(self.M1[m], 0))
        out[("*", "typical")] = (np.median(self.X, 0), np.median(self.M1, 0))
        return out

    def _archetype(self, sector: str | None, health: str):
        return self._archetypes.get((sector or "*", health)) or self._archetypes[("*", health)]

    def _links_for(self, i: int, X=None, M1=None) -> list[Link]:
        X = self.X if X is None else X
        M1 = self.M1 if M1 is None else M1
        return [Link(r, w, X[j], M1[j], self.node_ids[j], known=True, y=float(self.y[j]))
                for j, r, w in self._nbrs[i]]

    def _percentile(self, group: str, value: float) -> float:
        arr = self._composite_sorted[group]
        return float(np.searchsorted(arr, value) / len(arr))

    # ============================================================ cards/list
    def company_card(self, company_id: str) -> dict:
        i = self._idx(company_id)
        row = self.companies.iloc[i]
        p, p0 = float(self.proba[i]), float(self.proba_prev[i])
        return {
            "company_id": company_id,
            "name": row["name"],
            "industry": row["industry"],
            "group": row["group"],
            "hq": row["hq"],
            "revenue": round(float(row["revenue"]), 1),
            "distress_probability": round(p, 4),
            "previous_probability": round(p0, 4),
            "risk_band": band_for(p),
            "implied_rating": implied_rating(p),
            "pd_low": round(float(self.pd_low[i]), 4),
            "pd_high": round(float(self.pd_high[i]), 4),
            "health_score": self.health_score(company_id)["health_score"],
            "synthetic": True,
        }

    def list_companies(self, limit: int = 100, offset: int = 0, sector: str | None = None,
                       band: str | None = None, q: str | None = None, sort: str = "risk"):
        idx = np.arange(len(self.node_ids))
        co = self.companies
        if sector:
            idx = idx[co["industry"].values[idx] == sector]
        if band:
            bands = np.array([band_for(float(p)) for p in self.proba[idx]])
            idx = idx[bands == band.upper()]
        if q:
            ql = q.lower()
            idx = np.array([k for k in idx if ql in co["name"].iat[k].lower()
                            or ql in self.node_ids[k].lower()], dtype=int)
        if sort == "risk":
            idx = idx[np.argsort(-self.proba[idx])]
        elif sort == "safe":
            idx = idx[np.argsort(self.proba[idx])]
        elif sort == "movers":
            idx = idx[np.argsort(-(self.proba[idx] - self.proba_prev[idx]))]
        elif sort == "size":
            idx = idx[np.argsort(-co["revenue"].values[idx])]
        elif sort == "name":
            idx = idx[np.argsort(co["name"].values[idx])]
        total = len(idx)
        return total, [self.company_card(self.node_ids[k]) for k in idx[offset:offset + limit]]

    def search(self, q: str, limit: int = 8) -> list[dict]:
        ql = q.lower().strip()
        names = self.companies["name"].str.lower().values
        scored = []
        for k, nm in enumerate(names):
            cid = self.node_ids[k].lower()
            if ql == cid:
                s = 3.0
            elif nm.startswith(ql):
                s = 2.0
            elif ql in nm:
                s = 1.5
            else:
                s = difflib.SequenceMatcher(None, ql, nm[: len(ql) + 6]).ratio()
            scored.append((s, k))
        scored.sort(reverse=True)
        return [self.company_card(self.node_ids[k]) for s, k in scored[:limit] if s > 0.55]

    # ======================================================== core analytics
    def predict(self, company_id: str) -> dict:
        i = self._idx(company_id)
        p = float(self.proba[i])
        return {
            "company_id": company_id,
            "distress_probability": round(p, 4),
            "risk_band": band_for(p),
            "implied_rating": implied_rating(p),
            "multi_horizon": self.multi_horizon(company_id),
            "health_score": self.health_score(company_id)["health_score"],
            "network_contagion": self.contagion(company_id)["contagion_score"],
        }

    @staticmethod
    def _term_structure(p12: float, margin_trend: float, growth: float) -> dict:
        """Cumulative PD curve PD(t) = 1 - exp(-lambda * t^a), anchored at PD(12m) = p12.

        a < 1 front-loads the hazard (deteriorating firms: trouble arrives
        sooner); a > 1 back-loads it (improving firms).
        """
        lam = -np.log(max(1 - p12, 1e-6))
        kappa = float(np.clip(-4.0 * margin_trend - 0.8 * growth, -0.35, 0.5))
        a = 1.0 - 0.5 * kappa
        return {f"{h}m": round(float(1 - np.exp(-lam * (h / 12.0) ** a)), 4) for h in HORIZONS_MONTHS}

    def multi_horizon(self, company_id: str) -> dict:
        i = self._idx(company_id)
        f = self.features.iloc[i]
        return self._term_structure(float(self.proba[i]), float(f["margin_trend"]),
                                    float(f["revenue_growth_yoy"]))

    def _health_from_frame(self, f: pd.DataFrame) -> dict:
        comps = {}
        for g in ("liquidity", "leverage", "profitability", "cash_flow", "growth"):
            v = float(self._group_composite(f, g)[0])
            comps[g] = round(100 * self._percentile(g, v), 1)
        return {"health_score": round(float(np.mean(list(comps.values()))), 1), "components": comps}

    def health_score(self, company_id: str) -> dict:
        i = self._idx(company_id)
        comps = {g: round(100 * self._percentile(g, float(self._composite[g][i])), 1)
                 for g in ("liquidity", "leverage", "profitability", "cash_flow", "growth")}
        return {"company_id": company_id,
                "health_score": round(float(np.mean(list(comps.values()))), 1),
                "components": comps}

    def ratios(self, company_id: str) -> dict:
        f = self._feat.loc[company_id]
        return {k: round(float(f[k]), 4) for k in FEATURE_NAMES}

    def liquidity_risk(self, company_id: str) -> dict:
        r = self.ratios(company_id)
        return {k: r[k] for k in FEATURE_GROUPS["liquidity"]}

    def leverage_risk(self, company_id: str) -> dict:
        r = self.ratios(company_id)
        return {k: r[k] for k in FEATURE_GROUPS["leverage"]}

    # ------------------------------------------------------------- explain
    def _explain_h(self, h: np.ndarray, links: list[Link], names: dict | None = None) -> dict:
        m = self.model
        c = m.contributions(h)
        sl = m.block_slices()
        own = c[sl["own"]]
        drivers = sorted(
            [{"feature": FEATURE_NAMES[k], "contribution": round(float(own[k]), 4)} for k in range(len(own))],
            key=lambda d: abs(d["contribution"]), reverse=True)
        tot = sum(abs(d["contribution"]) for d in drivers[:8]) or 1.0
        for d in drivers:
            d["direction"] = "raises_risk" if d["contribution"] > 0 else "lowers_risk"
            d["share"] = round(abs(d["contribution"]) / tot, 3)
        relation = {r: round(float(c[sl[r]].sum()), 4) for r in RELATIONS}
        relation["second_hop"] = round(float(c[sl["second_hop"]].sum() + c[sl["flags"]].sum()), 4)
        if "label_share" in sl:
            relation["counterparty_defaults"] = round(float(c[sl["label_share"]].sum() + c[sl["label_has"]].sum()), 4)
        nbr = []
        for l in links:
            contrib = m.link_contribution(l, links)
            entry = {"neighbour_id": l.ref, "relation": l.relation,
                     "relationship_weight": round(float(l.weight), 4),
                     "influence": round(contrib, 4),
                     "defaulted": bool(l.known and l.y > 0.5)}
            if l.ref in self._id_to_idx:
                j = self._id_to_idx[l.ref]
                entry.update(name=self.companies["name"].iat[j],
                             industry=self.companies["industry"].iat[j],
                             neighbour_risk=round(float(self.proba[j]), 4))
            elif names and l.ref in names:
                entry.update(names[l.ref])
            nbr.append(entry)
        nbr.sort(key=lambda d: d["influence"], reverse=True)
        own_total = float(own.sum())
        net_total = float(sum(relation.values()))
        return {"feature_drivers": drivers[:8], "network_drivers": nbr[:10],
                "relation_drivers": relation,
                "own_logit": round(own_total, 4), "network_logit": round(net_total, 4),
                "base_logit": round(float(m.clf.intercept_[0] + m.coef @ m.H_mean), 4)}

    def explain(self, company_id: str) -> dict:
        i = self._idx(company_id)
        return {"company_id": company_id, **self._explain_h(self.H[i], self._links_for(i))}

    # ------------------------------------------------------------- network
    def _network_uplift(self, h: np.ndarray) -> tuple[float, float]:
        """PD with vs. without network information (network blocks at universe mean)."""
        m = self.model
        sl = m.block_slices()
        h0 = h.copy()
        for k in (*RELATIONS, "second_hop", *(("label_share", "label_has") if "label_share" in sl else ())):
            h0[sl[k]] = m.H_mean[sl[k]]
        h0[sl["flags"]] = m.H_mean[sl["flags"]]
        return m.proba_one(h), m.proba_one(h0)

    def contagion(self, company_id: str) -> dict:
        i = self._idx(company_id)
        p, p0 = self._network_uplift(self.H[i])
        ex = self._explain_h(self.H[i], self._links_for(i))
        score = float(np.clip(50 + 50 * np.tanh(ex["network_logit"]), 0, 100))
        return {"company_id": company_id,
                "contagion_score": round(score, 1),
                "network_uplift": round(p - p0, 4),
                "standalone_probability": round(p0, 4),
                "top_exposures": ex["network_drivers"][:5]}

    def centrality(self, company_id: str) -> dict:
        i = self._idx(company_id)
        deg = len(self._nbrs[i])
        return {"degree": deg, "degree_centrality": round(deg / max(len(self.node_ids) - 1, 1), 4)}

    def concentration(self, company_id: str) -> dict:
        i = self._idx(company_id)
        def hhi(rel):
            w = np.array([w for _, r, w in self._nbrs[i] if r == rel])
            if len(w) == 0:
                return 0.0
            s = w / w.sum()
            return float((s ** 2).sum())
        top_cust = max([w for _, r, w in self._nbrs[i] if r == "customers"], default=0.0)
        top_sup = max([w for _, r, w in self._nbrs[i] if r == "suppliers"], default=0.0)
        return {"supplier_concentration_hhi": round(hhi("suppliers"), 3),
                "customer_concentration_hhi": round(hhi("customers"), 3),
                "top_customer_share": round(float(top_cust), 3),
                "top_supplier_share": round(float(top_sup), 3)}

    def network_graph(self, company_id: str, hops: int = 1, max_nodes: int = 60) -> dict:
        """Ego network around a company, with names, relations and dependency weights."""
        i = self._idx(company_id)
        depth = {i: 0}
        frontier = [i]
        for d in range(1, hops + 1):
            nxt = []
            for a in frontier:
                for j, _, w in sorted(self._nbrs[a], key=lambda t: -t[2]):
                    if j not in depth:
                        depth[j] = d
                        nxt.append(j)
            frontier = nxt
        keep = sorted(depth, key=lambda k: (depth[k], -self.proba[k]))[:max_nodes]
        keep_set = set(keep)
        nodes = [{"id": self.node_ids[j], "name": self.companies["name"].iat[j],
                  "industry": self.companies["industry"].iat[j], "depth": depth[j],
                  "risk": round(float(self.proba[j]), 4), "band": band_for(float(self.proba[j])),
                  "revenue": round(float(self.companies["revenue"].iat[j]), 1)} for j in keep]
        edges, seen = [], set()
        for s, d, t, w in zip(self.economy.edges["src"], self.economy.edges["dst"],
                              self.economy.edges["type"], self.economy.edges["weight"]):
            a, b = self._id_to_idx[s], self._id_to_idx[d]
            if a in keep_set and b in keep_set and (a, b, t) not in seen:
                seen.add((a, b, t))
                edges.append({"source": s, "target": d, "type": t, "weight": round(float(w), 3)})
        return {"center": company_id, "nodes": nodes, "edges": edges}

    # ------------------------------------------------------------- scenario
    def _shock_raw(self, row: pd.Series, revenue_change=0.0, interest_rate_change=0.0,
                   margin_change=0.0, debt_change=0.0) -> pd.Series:
        r = row.copy()
        revenue_change = max(float(revenue_change), -0.9)
        rev0, ebitda0 = float(r["revenue"]), float(r["ebitda"])
        # operating leverage: lost revenue carries its contribution margin
        contrib = float(np.clip(ebitda0 / max(rev0, 1e-6) + 0.30, 0.2, 0.9))
        d_rev = rev0 * revenue_change
        r["revenue"] = rev0 + d_rev
        r["ebitda"] = ebitda0 + d_rev * contrib + r["revenue"] * margin_change
        r["debt"] = float(r["debt"]) * (1 + debt_change)
        r["interest_expense"] = float(r["interest_expense"]) * (1 + debt_change) + r["debt"] * interest_rate_change
        d_ebitda = r["ebitda"] - ebitda0
        d_int = r["interest_expense"] - float(row["interest_expense"])
        d_pbt = d_ebitda - d_int
        r["net_profit"] = float(r["net_profit"]) + d_pbt * (0.748 if d_pbt > 0 else 1.0)
        r["ocf"] = float(r["ocf"]) + d_ebitda * 0.85
        r["current_assets"] = float(r["current_assets"]) * (1 + 0.5 * revenue_change)
        return r

    def _score_rows(self, items: list[tuple[pd.Series, pd.DataFrame, list[Link]]],
                    extra_edges: list[list[tuple[int, str, float]]] | None = None):
        """Score many (statements, history, counterparties) items in one network pass.

        Counterparties that are universe companies with their true status attach
        directly; anything else (an external counterparty, a failed supplier in a
        stress test, a status the user asserts) becomes a pseudo node carrying its
        features and default status. `extra_edges[k]` adds edges from other new
        nodes (indices into `items`) for workspace scoring.
        Returns a list of dicts: p, lo, hi, members, h, f.
        """
        frames, nodes, pseudo_x, pseudo_y = [], [], [], []
        n = len(self.node_ids)
        pseudo_idx: dict[int, int] = {}
        for row, history, links in items:
            f = build_feature_frame(pd.DataFrame([row]), history)
            frames.append(f)
            edges = []
            for l in links:
                j = self._id_to_idx.get(l.ref) if isinstance(l.ref, str) else None
                if j is not None and l.known and float(self.y[j]) == float(l.y):
                    edges.append((j, l.relation, l.weight))
                else:
                    key = id(l)
                    if key not in pseudo_idx:
                        pseudo_idx[key] = len(pseudo_x)
                        pseudo_x.append(l.x)
                        pseudo_y.append(float(l.y) if l.known else 0.0)
                    edges.append((n + pseudo_idx[key], l.relation, l.weight))
            nodes.append(NewNode(self._std_frame(f)[0], links, edges))
        base = n + len(pseudo_x)
        for k, extra in enumerate(extra_edges or []):
            nodes[k].edges += [(base + src, rel, w) for src, rel, w in extra]
        p, lo, hi, members, hs = self.suite.extend(self.X, nodes, pseudo_x, pseudo_y)
        return [{"p": float(p[k]), "lo": float(lo[k]), "hi": float(hi[k]),
                 "members": {m: float(v[k]) for m, v in members.items()}, "h": hs[k], "f": frames[k]}
                for k in range(len(items))]

    def _score_row(self, row: pd.Series, history: pd.DataFrame, links: list[Link]):
        r = self._score_rows([(row, history, links)])[0]
        return r["p"], r["h"], r["f"]

    def scenario(self, company_id: str, revenue_change: float = 0.0,
                 interest_rate_change: float = 0.0, supplier_failure: bool = False,
                 customer_loss: bool = False, margin_change: float = 0.0,
                 debt_change: float = 0.0) -> dict:
        i = self._idx(company_id)
        row = self.companies.iloc[i]
        links = self._links_for(i)
        base_links = list(links)
        notes = []
        rev_change = revenue_change
        if customer_loss:
            cust = [l for l in links if l.relation == "customers"]
            if cust:
                top = max(cust, key=lambda l: l.weight)
                rev_change += -top.weight
                links = [l for l in links if l is not top]
                notes.append({"type": "customer_loss", "company_id": top.ref, "share": round(top.weight, 3)})
        if supplier_failure:
            sups = [l for l in links if l.relation == "suppliers"]
            if sups:
                top = max(sups, key=lambda l: l.weight)
                # the supplier is now *known* to be in default: its status flows through the model
                links = [Link(l.relation, l.weight, l.x, l.m, l.ref, known=True, y=1.0) if l is top else l
                         for l in links]
                margin_change -= 0.08 * top.weight
                notes.append({"type": "supplier_failure", "company_id": top.ref, "share": round(top.weight, 3)})
        shocked = self._shock_raw(row, rev_change, interest_rate_change, margin_change, debt_change)
        # score an unshocked copy alongside, so the delta isolates the shock itself
        r0, r1 = self._score_rows([(row, self.history, base_links), (shocked, self.history, links)])
        base, p, f = r0["p"], r1["p"], r1["f"]
        before = self.ratios(company_id)
        after = {k: round(float(f[k].iat[0]), 4) for k in FEATURE_NAMES}
        changed = sorted(
            [{"feature": k, "before": before[k], "after": after[k]} for k in FEATURE_NAMES
             if abs(after[k] - before[k]) > 1e-3],
            key=lambda d: -abs(d["after"] - d["before"]) / (abs(d["before"]) + 0.05))[:6]
        return {"company_id": company_id,
                "current_risk": round(base, 4),
                "scenario_risk": round(p, 4),
                "delta": round(p - base, 4),
                "scenario_low": round(r1["lo"], 4), "scenario_high": round(r1["hi"], 4),
                "current_band": band_for(base), "scenario_band": band_for(p),
                "current_rating": implied_rating(base), "scenario_rating": implied_rating(p),
                "changed_ratios": changed, "events": notes,
                "inputs": {"revenue_change": revenue_change,
                           "interest_rate_change": interest_rate_change,
                           "margin_change": margin_change, "debt_change": debt_change,
                           "supplier_failure": supplier_failure, "customer_loss": customer_loss}}

    def scenario_sweep(self, company_id: str) -> dict:
        """Risk as a function of revenue shock and of rate shock (for charts)."""
        i = self._idx(company_id)
        row = self.companies.iloc[i]
        links = self._links_for(i)
        revs, rates = np.linspace(-0.5, 0.3, 17), np.linspace(-0.02, 0.05, 15)
        items = [(self._shock_raw(row, revenue_change=float(rc)), self.history, links) for rc in revs]
        items += [(self._shock_raw(row, interest_rate_change=float(dr)), self.history, links) for dr in rates]
        out = self._score_rows(items)
        rev = [{"x": round(float(x), 3), "risk": round(o["p"], 4), "low": round(o["lo"], 4), "high": round(o["hi"], 4)}
               for x, o in zip(revs, out[:len(revs)])]
        rate = [{"x": round(float(x), 4), "risk": round(o["p"], 4), "low": round(o["lo"], 4), "high": round(o["hi"], 4)}
                for x, o in zip(rates, out[len(revs):])]
        return {"company_id": company_id, "revenue": rev, "rate": rate}

    # --------------------------------------------------------- cascade sim
    def simulate_failure(self, failing_company_id: str, max_depth: int = 4) -> dict:
        """Default a company and propagate the economic consequences round by round.

        Each round: counterparties of newly failed firms take statement-level
        hits (lost revenue from a defaulted customer, input disruption from a
        failed supplier, loss of group support), the model re-scores the whole
        universe, and anyone crossing FAIL_PD defaults in the next round.
        """
        start = self._idx(failing_company_id)
        raw = self.companies.copy()
        failed = {start}
        newly = [start]
        base_p = self.proba.copy()
        cur_p = base_p.copy()
        rounds = []
        for rnd in range(1, max_depth + 1):
            if not newly:
                break
            for f in newly:
                for j, _, _ in self._nbrs[f]:
                    if j in failed:
                        continue
                    # read the dependency from j's side: how much does j rely on f?
                    for rel, w in self._view.get((j, f), []):
                        rev = raw.at[j, "revenue"]
                        mg = raw.at[j, "ebitda"] / max(rev, 1e-6)
                        if rel == "customers":      # f was j's customer -> lost sales
                            loss = 0.6 * w
                            hit = rev * loss * np.clip(mg + 0.3, 0.2, 0.9)
                            raw.at[j, "revenue"] = rev * (1 - loss)
                            raw.at[j, "ebitda"] -= hit
                            raw.at[j, "net_profit"] -= hit
                            raw.at[j, "ocf"] -= hit * 0.85
                            raw.at[j, "current_assets"] -= rev * w * 0.06   # receivable write-off
                        elif rel == "suppliers":    # f supplied j -> input disruption
                            raw.at[j, "ebitda"] -= rev * 0.03 * w
                            raw.at[j, "net_profit"] -= rev * 0.03 * w
                        elif rel == "group":        # group stress: funding cost + guarantees
                            raw.at[j, "interest_expense"] *= 1 + 0.3 * w
                            raw.at[j, "net_profit"] -= 0.02 * w * raw.at[f, "debt"]
            # Own features: shocked statements. Counterparties are seen at their
            # original profile, and defaulted ones carry a known default status
            # that the graph models propagate.
            X_own = self._std_frame(build_feature_frame(raw, self.history))
            label = self.y.astype(float).copy()
            label[list(failed)] = 1.0
            new_p = self.suite.universe(self.X, np.ones(len(label), bool), label, own_X=X_own)[0]
            new_p[list(failed)] = 1.0
            next_fail = [k for k in np.where(new_p >= FAIL_PD)[0]
                         if k not in failed and base_p[k] < FAIL_PD and new_p[k] - base_p[k] >= 0.15]
            stressed = [k for k in np.argsort(-(new_p - cur_p)) if new_p[k] - cur_p[k] >= 0.005 and k not in failed][:40]
            rounds.append({
                "round": rnd,
                "defaults": [self.node_ids[k] for k in next_fail],
                "stressed": [{"company_id": self.node_ids[k], "name": self.companies["name"].iat[k],
                              "before": round(float(base_p[k]), 4), "after": round(float(new_p[k]), 4)}
                             for k in stressed],
            })
            cur_p = new_p
            failed |= set(next_fail)
            newly = next_fail
        delta = cur_p - base_p
        delta[start] = 0
        order = [k for k in np.argsort(-delta) if delta[k] >= 0.002]
        affected = [{"company_id": self.node_ids[k], "name": self.companies["name"].iat[k],
                     "industry": self.companies["industry"].iat[k],
                     "impact": round(float(delta[k]), 4), "before": round(float(base_p[k]), 4),
                     "after": round(float(cur_p[k]), 4), "defaulted": bool(k in failed)}
                    for k in order[:60]]
        exposure = float(sum(self.companies["debt"].iat[k] for k in failed if k != start))
        level = "SYSTEMIC" if len(failed) > 6 else "HIGH" if len(order) > 25 else "MODERATE" if order else "LOW"
        # subgraph for the animation: failing node + everyone affected
        keep = [start] + order[:59]
        keep_set = set(keep)
        sub_edges = []
        for s, d, t, w in zip(self.economy.edges["src"], self.economy.edges["dst"],
                              self.economy.edges["type"], self.economy.edges["weight"]):
            a, b = self._id_to_idx[s], self._id_to_idx[d]
            if a in keep_set and b in keep_set and t != "SAME_INDUSTRY":
                sub_edges.append({"source": s, "target": d, "type": t, "weight": round(float(w), 3)})
        return {"failing_company": failing_company_id,
                "failing_name": self.companies["name"].iat[start],
                "estimated_network_impact": level,
                "affected_count": len(order),
                "secondary_defaults": len(failed) - 1,
                "debt_at_risk_cr": round(exposure, 1),
                "rounds": rounds,
                "affected": affected,
                "edges": sub_edges}

    # ------------------------------------------------------------ portfolio
    def portfolio_risk(self, holdings: list[dict]) -> dict:
        total_w = sum(h["weight"] for h in holdings) or 1.0
        rows, idxs, ws = [], [], []
        for h in holdings:
            i = self._idx(h["company_id"])
            w = h["weight"] / total_w
            p = float(self.proba[i])
            idxs.append(i); ws.append(w)
            rows.append({"company_id": h["company_id"], "name": self.companies["name"].iat[i],
                         "industry": self.companies["industry"].iat[i],
                         "weight": round(w, 4), "risk": round(p, 4), "band": band_for(p),
                         "expected_loss": round(w * p * LGD, 5)})
        ws = np.array(ws)
        ps = self.proba[idxs]
        exposure = float(ws @ ps)
        # shared counterparties: neighbours that several holdings depend on
        hits: dict[int, float] = {}
        holders: dict[int, set] = {}
        for i, w in zip(idxs, ws):
            for j, r, ew in self._nbrs[i]:
                if r == "peers":
                    continue
                hits[j] = hits.get(j, 0) + w * ew
                holders.setdefault(j, set()).add(self.node_ids[i])
        shared = sorted([(j, v) for j, v in hits.items() if len(holders[j]) > 1],
                        key=lambda t: -t[1])[:6]
        # pairwise links between holdings (default correlation proxy)
        hold_set = set(idxs)
        links = sum(1 for i in idxs for j, r, _ in self._nbrs[i] if j in hold_set and r != "peers") // 2
        sectors: dict[str, float] = {}
        for r in rows:
            sectors[r["industry"]] = sectors.get(r["industry"], 0) + r["weight"]
        stress = []
        for label, kw in (("Revenue -20%", {"revenue_change": -0.2}),
                          ("Rates +200 bps", {"interest_rate_change": 0.02}),
                          ("Top supplier fails", {"supplier_failure": True})):
            sp = np.array([self.scenario(self.node_ids[i], **kw)["scenario_risk"] for i in idxs])
            stress.append({"scenario": label, "exposure": round(float(ws @ sp), 4)})
        return {"portfolio_distress_exposure": round(exposure, 4),
                "expected_loss": round(exposure * LGD, 5),
                "band": band_for(exposure),
                "implied_rating": implied_rating(exposure),
                "concentration_hhi": round(float((ws ** 2).sum()), 4),
                "interlinked_pairs": int(links),
                "holdings": rows,
                "sectors": [{"industry": k, "weight": round(v, 4)} for k, v in sorted(sectors.items(), key=lambda t: -t[1])],
                "stress": stress,
                "shared_network_exposure": [
                    {"company_id": self.node_ids[j], "name": self.companies["name"].iat[j],
                     "risk": round(float(self.proba[j]), 4), "portfolio_weight": round(float(v), 4),
                     "linked_holdings": sorted(holders[j])} for j, v in shared]}

    # ------------------------------------------------------ extra analytics
    def peer_comparison(self, company_id: str) -> dict:
        i = self._idx(company_id)
        industry = self.companies["industry"].iat[i]
        mask = self.companies["industry"].values == industry
        f = self.features[mask]
        r = self.ratios(company_id)
        keys = ["ebitda_margin", "debt_to_equity", "interest_coverage", "current_ratio",
                "revenue_growth_yoy", "ocf_to_debt"]
        return {"company_id": company_id, "industry": industry, "peer_count": int(mask.sum()),
                "company": {k: r[k] for k in keys} | {"risk": round(float(self.proba[i]), 4)},
                "industry_median": {k: round(float(f[k].median()), 4) for k in keys}
                | {"risk": round(float(np.median(self.proba[mask])), 4)},
                "risk_rank": int((self.proba[mask] > self.proba[i]).sum() + 1)}

    def risk_timeline(self, company_id: str) -> dict:
        i = self._idx(company_id)
        pts = [{"year": int(y), "risk": round(float(p[i]), 4)} for y, p in sorted(self.year_proba.items())]
        trend = "rising" if pts[-1]["risk"] > pts[0]["risk"] * 1.15 else \
                "falling" if pts[-1]["risk"] < pts[0]["risk"] * 0.85 else "stable"
        return {"company_id": company_id, "timeline": pts, "trend": trend}

    def statements(self, company_id: str) -> dict:
        g = self.history[self.history["company_id"] == company_id].sort_values("year")
        cols = ["revenue", "ebitda", "net_profit", "interest_expense", "debt", "equity", "cash", "ocf", "capex"]
        return {"company_id": company_id, "unit": "INR crore",
                "years": [{"year": int(r["year"]), **{c: round(float(r[c]), 1) for c in cols}}
                          for _, r in g.iterrows()]}

    def anomalies(self, company_id: str) -> dict:
        g = self.history[self.history["company_id"] == company_id].sort_values("year")
        flags = []
        rev, ebd, debt, ocf, np_ = (g[c].values for c in ("revenue", "ebitda", "debt", "ocf", "net_profit"))
        if len(rev) >= 2:
            ch = rev[-1] / max(rev[-2], 1e-6) - 1
            if ch < -0.15:
                flags.append({"type": "revenue_drop", "magnitude": round(float(ch), 3)})
            dg = debt[-1] / max(debt[-2], 1e-6) - 1
            if dg > 0.3 and debt[-1] > 0.2 * rev[-1]:
                flags.append({"type": "debt_surge", "magnitude": round(float(dg), 3)})
            m1, m0 = ebd[-1] / max(rev[-1], 1e-6), ebd[-2] / max(rev[-2], 1e-6)
            if m1 - m0 < -0.04:
                flags.append({"type": "margin_compression", "magnitude": round(float(m1 - m0), 3)})
            if np_[-1] > 0 and ocf[-1] < 0.3 * np_[-1]:
                flags.append({"type": "earnings_quality", "magnitude": round(float(ocf[-1] / max(np_[-1], 1e-6)), 3)})
        pledge = float(self.companies["promoter_pledge"].iat[self._idx(company_id)])
        if pledge > 0.35:
            flags.append({"type": "high_pledge", "magnitude": round(pledge, 3)})
        return {"company_id": company_id, "anomalies": flags,
                "anomaly_score": round(min(1.0, len(flags) * 0.3), 3)}

    def company_detail(self, company_id: str) -> dict:
        return {
            **self.company_card(company_id),
            "prediction": self.predict(company_id),
            "health": self.health_score(company_id),
            "ratios": self.ratios(company_id),
            "concentration": self.concentration(company_id),
            "centrality": self.centrality(company_id),
            "contagion": self.contagion(company_id),
            "explain": self.explain(company_id),
            "peer_comparison": self.peer_comparison(company_id),
            "risk_timeline": self.risk_timeline(company_id),
            "statements": self.statements(company_id),
            "anomalies": self.anomalies(company_id),
            "incorporated": int(self.companies["incorporated"].iat[self._idx(company_id)]),
            "promoter_pledge": round(float(self.companies["promoter_pledge"].iat[self._idx(company_id)]), 3),
        }

    def heatmap(self) -> dict:
        return {"industries": [{"industry": s["industry"], "avg_risk": s["avg_pd"], "band": band_for(s["avg_pd"])}
                               for s in self.sectors()]}

    def sectors(self) -> list[dict]:
        out = []
        co, f = self.companies, self.features
        for s in INDUSTRIES:
            m = co["industry"].values == s
            if not m.any():
                continue
            p, p0 = self.proba[m], self.proba_prev[m]
            out.append({"industry": s, "count": int(m.sum()),
                        "avg_pd": round(float(p.mean()), 4), "median_pd": round(float(np.median(p)), 4),
                        "pd_change": round(float(p.mean() - p0.mean()), 4),
                        "high_share": round(float((p >= 0.10).mean()), 4),
                        "median_icr": round(float(f["interest_coverage"][m].median()), 2),
                        "median_de": round(float(f["debt_to_equity"][m].median()), 2),
                        "median_margin": round(float(f["ebitda_margin"][m].median()), 4),
                        "cyclicality": SECTORS[s]["beta"], "rate_sensitivity": SECTORS[s]["rate_beta"],
                        "revenue_cr": round(float(co["revenue"][m].sum()), 0)})
        out.sort(key=lambda d: -d["avg_pd"])
        return out

    def early_warnings(self, threshold: float = 0.10) -> dict:
        alerts = []
        for i, cid in enumerate(self.node_ids):
            p, p0 = float(self.proba[i]), float(self.proba_prev[i])
            crossed = band_for(p) != band_for(p0) and p > p0
            if p >= threshold or (crossed and p - p0 > 0.02):
                reason = "band_downgrade" if crossed else "high_pd"
                alerts.append({"company_id": cid, "name": self.companies["name"].iat[i],
                               "industry": self.companies["industry"].iat[i],
                               "risk": round(p, 4), "previous": round(p0, 4),
                               "band": band_for(p), "previous_band": band_for(p0),
                               "reason": reason})
        alerts.sort(key=lambda a: (a["reason"] != "band_downgrade", -a["risk"]))
        return {"count": len(alerts), "alerts": alerts[:80]}

    def overview(self) -> dict:
        p = self.proba
        bands = {b: 0 for b in ("LOW", "MODERATE", "HIGH", "CRITICAL")}
        for v in p:
            bands[band_for(float(v))] += 1
        edges = [0, 0.0025, 0.005, 0.01, 0.02, 0.03, 0.05, 0.075, 0.10, 0.15, 0.20, 0.30, 0.50, 0.75, 1.0001]
        hist, _ = np.histogram(p, bins=edges)
        f = self.features
        scatter = [{"id": self.node_ids[k], "name": self.companies["name"].iat[k],
                    "industry": self.companies["industry"].iat[k],
                    "de": round(float(f["debt_to_equity"].iat[k]), 3),
                    "icr": round(float(f["interest_coverage"].iat[k]), 3),
                    "margin": round(float(f["ebitda_margin"].iat[k]), 4),
                    "revenue": round(float(self.companies["revenue"].iat[k]), 1),
                    "pd": round(float(p[k]), 4)} for k in range(len(p))]
        _, movers = self.list_companies(limit=8, sort="movers")
        _, top = self.list_companies(limit=8, sort="risk")
        trend = [{"year": int(y), "avg_pd": round(float(v.mean()), 4),
                  "high_share": round(float((v >= 0.10).mean()), 4)} for y, v in sorted(self.year_proba.items())]
        macro = self.economy.macro.to_dict(orient="records") if self.economy.macro is not None else []
        return {
            "universe": {"companies": len(p), "sectors": int(self.companies["industry"].nunique()),
                         "groups": int((self.companies["group"] != "standalone").sum()),
                         "relationships": int(len(self.economy.edges)), "fiscal_year": self.fy,
                         "debt_cr": round(float(self.companies["debt"].sum()), 0)},
            "mean_pd": round(float(p.mean()), 4),
            "expected_defaults": round(float(p.sum()), 1),
            "debt_weighted_pd": round(float((p * self.companies["debt"]).sum() / self.companies["debt"].sum()), 4),
            "band_counts": bands,
            "pd_histogram": [{"lo": edges[k], "hi": min(edges[k + 1], 1.0), "count": int(hist[k])} for k in range(len(hist))],
            "sectors": self.sectors(),
            "scatter": scatter,
            "top_risk": top, "movers": movers,
            "trend": trend, "macro": macro,
            "model": self.model_card(),
        }

    def model_card(self) -> dict:
        """What is serving, and how well it does. Prefers the 5-fold CV benchmark
        (ml/scripts/benchmark.py) over the single held-out split."""
        import json
        from ..config import ARTIFACTS
        bench = None
        bp = ARTIFACTS / "benchmark.json"
        if bp.exists():
            bench = json.loads(bp.read_text())
        m = dict(self.metrics)
        names = {"irgnn": "linear relational GNN", "gcn": "PyG GCN", "gat": "PyG GAT"}
        card = {"name": "Blend of " + " + ".join(names.get(x, x) for x in self.suite.members),
                "members": list(self.suite.members), "status": self.suite.status,
                "explanations": "exact attributions from the linear relational GNN member",
                "uses_counterparty_defaults": True,
                "relations": list(RELATIONS), "features": FEATURE_NAMES,
                "trained_on": f"{len(self.node_ids)} simulated Indian companies, FY{self.fy - 4}-FY{self.fy}",
                "multi_horizon": "3/6/24-month PDs are derived from the 12-month PD with a hazard curve; "
                                 "only the 12-month PD is predicted by the model",
                "evaluation": "single held-out split", **m}
        if bench:
            models = bench["models"]
            pick = "blend" if "blend" in models else "irgnn_labels"
            card.update(evaluation=bench["meta"]["protocol"], test_size=bench["meta"]["companies"],
                        graph_model=models[pick], tabular_model=models.get("logreg", m["tabular_model"]),
                        benchmark=models)
        return card

    # ============================================================== analyze
    def analyze_template(self) -> dict:
        return {"required_fields": REQUIRED_FIELDS, "sectors": INDUSTRIES,
                "relations": list(_REL_FROM_USER), "health_levels": list(HEALTH_LABELS),
                "unit": "INR crore", "examples": _EXAMPLES}

    def _statements_x(self, st: dict, sector: str | None = None) -> np.ndarray:
        """Standardised features of a counterparty given by its own statements."""
        row = pd.Series({"company_id": "CP", "fy": self.fy, "promoter_pledge": 0.0,
                         **{k: float(st.get(k, 0) or 0) for k in REQUIRED_FIELDS}})
        return self._std_frame(build_feature_frame(pd.DataFrame([row]), None))[0]

    def _prepare(self, payload: dict):
        """payload -> (row, history, links, names, assumptions, sector, current)."""
        sector = payload.get("sector") if payload.get("sector") in SECTORS else None
        cur = {k: float(payload["current"].get(k, 0) or 0) for k in REQUIRED_FIELDS}
        fy = int(payload.get("fiscal_year") or self.fy)
        hist_rows = []
        for e in payload.get("earlier") or []:
            if e.get("revenue"):
                hist_rows.append({"company_id": "X", "year": int(e.get("year") or fy - 3),
                                  "revenue": float(e["revenue"]), "ebitda": float(e.get("ebitda") or 0)})
        prev = payload.get("previous")
        if prev and prev.get("revenue"):
            hist_rows.append({"company_id": "X", "year": int(prev.get("year") or fy - 1),
                              "revenue": float(prev["revenue"]), "ebitda": float(prev.get("ebitda") or 0)})
        history = pd.DataFrame(hist_rows, columns=["company_id", "year", "revenue", "ebitda"])
        row = pd.Series({"company_id": "X", "fy": fy,
                         "promoter_pledge": float(payload.get("promoter_pledge") or 0), **cur})
        if "revenue_growth" in payload:
            row["revenue_growth"] = float(payload["revenue_growth"])

        links: list[Link] = []
        names: dict[str, dict] = {}
        assumptions = []
        for k, cp in enumerate(payload.get("counterparties") or []):
            rel = _REL_FROM_USER.get(str(cp.get("relation", "")).lower())
            share = float(cp.get("share") or 0)
            if not rel or share <= 0:
                continue
            ref = cp.get("company_id")
            health = cp.get("health") if cp.get("health") in HEALTH_LABELS else "stable"
            defaulted = health == "distressed"
            if ref in self._id_to_idx:                       # a universe company
                j = self._id_to_idx[ref]
                links.append(Link(rel, share, self.X[j], self.M1[j], ref, known=True, y=float(self.y[j])))
                continue
            ref = f"cp{k}"
            cp_sector = cp.get("sector") if cp.get("sector") in SECTORS else sector
            if cp.get("statements"):                         # a real company the user analysed
                x = self._statements_x(cp["statements"], cp_sector)
                m1 = self._archetype(cp_sector, "typical")[1]
                source = "statements"
            else:                                            # status template
                x, m1 = self._archetype(cp_sector, health)
                source = "template"
            names[ref] = {"name": cp.get("name") or f"Counterparty {k + 1}", "health": health,
                          "industry": cp_sector, "neighbour_risk": None, "source": source}
            links.append(Link(rel, share, x, m1, ref, known=True, y=1.0 if defaulted else 0.0))
        if sector:
            x, m1 = self._archetype(sector, "typical")
            links.append(Link("peers", 0.3, x, m1, "sector_peers"))
            names["sector_peers"] = {"name": f"{sector} peers (median)", "industry": sector}
        if not any(l.relation in ("suppliers", "customers") for l in links):
            x, m1 = self._archetype(sector, "typical")
            links += [Link("suppliers", 0.5, x, m1, "assumed_suppliers"),
                      Link("customers", 0.5, x, m1, "assumed_customers")]
            names["assumed_suppliers"] = {"name": "Typical suppliers (assumed)", "industry": sector}
            names["assumed_customers"] = {"name": "Typical customers (assumed)", "industry": sector}
            assumptions.append("no_counterparties")
        if history.empty and "revenue_growth" not in payload:
            assumptions.append("no_history")
        return row, history, links, names, assumptions, sector, cur

    def _report(self, r: dict, links, names, assumptions, sector, cur, payload) -> dict:
        p, h, f = r["p"], r["h"], r["f"]
        ratios = {k: round(float(f[k].iat[0]), 4) for k in FEATURE_NAMES}
        ood = []
        for k in FEATURE_NAMES:
            lo, hi = np.quantile(self.features[k], [0.01, 0.99])
            v = ratios[k]
            if v < lo or v > hi:
                ood.append({"feature": k, "value": v, "p01": round(float(lo), 4), "p99": round(float(hi), 4)})
        p_net, p_alone = self._network_uplift(h)
        ex = self._explain_h(h, links, names)
        health = self._health_from_frame(f)
        peers = None
        if sector:
            mask = self.companies["industry"].values == sector
            keys = ["ebitda_margin", "debt_to_equity", "interest_coverage", "current_ratio",
                    "revenue_growth_yoy", "ocf_to_debt"]
            peers = {"industry": sector, "peer_count": int(mask.sum()),
                     "company": {k: ratios[k] for k in keys} | {"risk": round(p, 4)},
                     "industry_median": {k: round(float(self.features[k][mask].median()), 4) for k in keys}
                     | {"risk": round(float(np.median(self.proba[mask])), 4)},
                     "risk_rank": int((self.proba[mask] > p).sum() + 1)}
        return {
            "name": payload.get("name") or "Unnamed company", "industry": sector, "synthetic": False,
            "fiscal_year": int(payload.get("fiscal_year") or self.fy),
            "distress_probability": round(p, 4), "pd_low": round(r["lo"], 4), "pd_high": round(r["hi"], 4),
            "model_members": {k: round(v, 4) for k, v in r["members"].items()},
            "risk_band": band_for(p), "implied_rating": implied_rating(p),
            "multi_horizon": self._term_structure(p, ratios["margin_trend"], ratios["revenue_growth_yoy"]),
            "multi_horizon_method": "derived",
            "health": health, "health_score": health["health_score"], "ratios": ratios,
            "explain": ex,
            "contagion": {"contagion_score": round(float(np.clip(50 + 50 * np.tanh(ex["network_logit"]), 0, 100)), 1),
                          "network_uplift": round(p_net - p_alone, 4),
                          "standalone_probability": round(p_alone, 4)},
            "peer_comparison": peers,
            "out_of_distribution": ood, "data_checks": _sanity(cur), "assumptions": assumptions,
            "counterparties_used": len([l for l in links if l.ref not in ("sector_peers", "assumed_suppliers", "assumed_customers")]),
        }

    def analyze(self, payload: dict, shocks: dict | None = None) -> dict:
        """Score a company that is not in the universe, from reported financials.

        payload = {
          name, sector, fiscal_year, promoter_pledge (0..1),
          current:  {revenue, ebitda, net_profit, interest_expense, assets, debt, equity, cash,
                     current_assets, current_liabilities, inventory, ocf, capex},
          previous: {year, revenue, ebitda}, earlier: [{year, revenue, ebitda}, ...],
          counterparties: [{name, relation, share, health, company_id? | statements?}]
        }
        """
        row, history, links, names, assumptions, sector, cur = self._prepare(payload)
        if shocks:
            row = self._shock_raw(row, shocks.get("revenue_change", 0), shocks.get("interest_rate_change", 0),
                                  shocks.get("margin_change", 0), shocks.get("debt_change", 0))
        r = self._score_rows([(row, history, links)])[0]
        return self._report(r, links, names, assumptions, sector, cur, payload)

    # ============================================================ workspace
    def _ws_payload(self, c: dict, rels: list, internal_names: set, upto: int | None = None) -> dict:
        ys = sorted([y for y in c["years"] if upto is None or y["year"] <= upto], key=lambda y: -y["year"])
        cur = ys[0]
        pl = {"name": c["name"], "sector": c.get("sector"), "fiscal_year": cur["year"],
              "promoter_pledge": c.get("promoter_pledge") or 0,
              "current": {k: cur.get(k, 0) for k in REQUIRED_FIELDS},
              "earlier": [{"year": y["year"], "revenue": y.get("revenue"), "ebitda": y.get("ebitda")} for y in ys[2:]],
              "counterparties": []}
        if len(ys) > 1:
            pl["previous"] = {"year": ys[1]["year"], "revenue": ys[1].get("revenue"), "ebitda": ys[1].get("ebitda")}
        me = c["name"].strip().lower()
        for r in rels:
            if r["company"].strip().lower() != me or r["counterparty"].strip().lower() in internal_names:
                continue
            pl["counterparties"].append({"name": r["counterparty"], "relation": r.get("relation", "customer"),
                                         "share": r.get("share", 0.2), "health": r.get("health", "stable")})
        return pl

    def score_workspace(self, ws: dict) -> dict:
        """Score the user's own companies as a connected network.

        ws = {companies: [{name, sector, promoter_pledge, defaulted?, years: [{year, ...statements}]}],
              relationships: [{company, counterparty, relation, share, health}]}

        * a counterparty that is another workspace company links to that
          company's real financials (and its known default status, if given)
        * every fiscal year with a prior year is scored, giving real trends
        * a contagion pass defaults each company in turn and measures the
          impact on the others: systemic importance inside your portfolio
        """
        comps = ws["companies"]
        rels = ws.get("relationships") or []
        key = {c["name"].strip().lower(): k for k, c in enumerate(comps)}
        internal_names = set(key)
        warnings: list[str] = []
        n_ws = len(comps)

        jobs = [(k, None) for k in range(n_ws)]
        for k, c in enumerate(comps):
            years = sorted({y["year"] for y in c["years"]})
            jobs += [(k, yr) for yr in years[:-1]]            # every earlier fiscal year (first one: growth assumed flat)
        payloads = [self._ws_payload(comps[k], rels, internal_names, yr) for k, yr in jobs]
        prepared = [list(self._prepare(pl)) for pl in payloads]

        internal: list[list[tuple[int, str, float]]] = [[] for _ in jobs]
        labels = [c.get("defaulted") for c in comps]
        for r in rels:
            a, b = r["company"].strip().lower(), r["counterparty"].strip().lower()
            rel = _REL_FROM_USER.get(str(r.get("relation", "customer")).lower())
            if a in key and rel is None:
                warnings.append(f"unknown relation '{r.get('relation')}' for {r['company']}")
                continue
            if a in key and b in key:
                ka, kb = key[a], key[b]
                share = float(r.get("share") or 0.2)
                internal[ka].append((kb, rel, share))
                xb = self._std_frame(build_feature_frame(pd.DataFrame([prepared[kb][0]]), prepared[kb][1]))[0]
                ref = f"ws:{comps[kb]['name']}"
                prepared[ka][2] = [l for l in prepared[ka][2] if l.ref not in ("assumed_suppliers", "assumed_customers")]
                prepared[ka][2].append(Link(rel, share, xb, xb, ref,
                                            known=labels[kb] is not None, y=float(labels[kb] or 0)))
                prepared[ka][3][ref] = {"name": comps[kb]["name"], "industry": comps[kb].get("sector"),
                                        "source": "workspace"}
                prepared[ka][4] = [x for x in prepared[ka][4] if x != "no_counterparties"]
        items = [(p[0], p[1], p[2]) for p in prepared]
        scored = self._score_rows(items, extra_edges=internal)

        reports = []
        for k, c in enumerate(comps):
            p = prepared[k]
            rep = self._report(scored[k], p[2], p[3], p[4], p[5], p[6], payloads[k])
            trend = [{"year": jobs[j][1], "risk": round(scored[j]["p"], 4), "low": round(scored[j]["lo"], 4),
                      "high": round(scored[j]["hi"], 4)} for j in range(n_ws, len(jobs)) if jobs[j][0] == k]
            trend.append({"year": rep["fiscal_year"], "risk": rep["distress_probability"],
                          "low": rep["pd_low"], "high": rep["pd_high"]})
            rep["timeline"] = sorted(trend, key=lambda t: t["year"])
            rep["years"] = sorted(c["years"], key=lambda y: y["year"])
            rep["defaulted"] = c.get("defaulted")
            reports.append(rep)

        # contagion inside the workspace: default each linked company, re-score the rest
        systemic = []
        lat_internal = internal[:n_ws]
        if n_ws > 1 and any(lat_internal):
            base = np.array([r["distress_probability"] for r in reports])
            for k in range(n_ws):
                if not any(src == k for e in lat_internal for src, _, _ in e):
                    continue
                ref = f"ws:{comps[k]['name']}"
                items2 = [(prepared[j][0], prepared[j][1],
                           [Link(l.relation, l.weight, l.x, l.m, l.ref, known=True, y=1.0) if l.ref == ref else l
                            for l in prepared[j][2]]) for j in range(n_ws)]
                after = np.array([o["p"] for o in self._score_rows(items2, extra_edges=lat_internal)])
                d = after - base
                d[k] = 0
                hits = [{"name": comps[j]["name"], "before": round(float(base[j]), 4), "after": round(float(after[j]), 4)}
                        for j in np.argsort(-d) if d[j] > 0.002]
                systemic.append({"name": comps[k]["name"], "impact": round(float(d.sum()), 4), "affected": hits[:10]})
            systemic.sort(key=lambda s: -s["impact"])

        nodes = [{"id": c["name"], "name": c["name"], "industry": c.get("sector"),
                  "risk": reports[k]["distress_probability"], "band": reports[k]["risk_band"],
                  "revenue": float(sorted(c["years"], key=lambda y: -y["year"])[0].get("revenue") or 0),
                  "depth": 1} for k, c in enumerate(comps)]
        edges = []
        canon = {c["name"].strip().lower(): c["name"] for c in comps}
        for r in rels:
            a = canon.get(r["company"].strip().lower())
            if not a:
                continue
            b = canon.get(r["counterparty"].strip().lower())
            if not b:
                b = r["counterparty"]
                if not any(nd["id"] == b for nd in nodes):
                    st = r.get("health", "stable")
                    nodes.append({"id": b, "name": b, "industry": None, "external": True, "depth": 2,
                                  "risk": 0.6 if st == "distressed" else 0.12 if st == "weak" else 0.02,
                                  "band": None, "revenue": 300})
            rel = str(r.get("relation", "customer")).lower()
            src, dst = (b, a) if rel == "supplier" else (a, b)
            typ = "SUPPLIES" if rel == "supplier" else "CUSTOMER_OF" if rel == "customer" else "OWNS"
            edges.append({"source": src, "target": dst, "type": typ, "weight": float(r.get("share") or 0.2)})
        pds = np.array([r["distress_probability"] for r in reports])
        return {"companies": reports, "network": {"nodes": nodes, "edges": edges},
                "systemic": systemic,
                "summary": {"count": n_ws, "mean_pd": round(float(pds.mean()), 4),
                            "expected_defaults": round(float(pds.sum()), 2),
                            "bands": {b: int(sum(1 for r in reports if r["risk_band"] == b))
                                      for b in ("LOW", "MODERATE", "HIGH", "CRITICAL")},
                            "internal_links": int(sum(len(e) for e in lat_internal))},
                "warnings": warnings}

    def retrain_with(self, ws: dict) -> dict:
        """Mix the user's labelled companies into training and report the effect.

        Uses the interpretable member (fast enough to retrain per request). With
        8+ labels a leave-one-out check on the user's own companies is reported.
        """
        from ..models.inductive import SignConstrainedLogit
        labelled = [c for c in ws["companies"] if c.get("defaulted") in (0, 1)]
        if len(labelled) < 2 or len({c["defaulted"] for c in labelled}) < 2:
            raise ValueError("need at least one defaulted and one non-defaulted company (column 'defaulted')")
        before = self.score_workspace({"companies": labelled, "relationships": ws.get("relationships") or []})["companies"]
        names = {c["name"].strip().lower() for c in labelled}
        prep = [self._prepare(self._ws_payload(c, ws.get("relationships") or [], names)) for c in labelled]
        H_user = np.stack([self.model.embed_one(
            self._std_frame(build_feature_frame(pd.DataFrame([p[0]]), p[1]))[0], p[2]) for p in prep])
        y_user = np.array([c["defaulted"] for c in labelled], float)
        weight = max(1, int(len(self.y) / (10 * len(labelled))))       # user labels count more than synthetic ones
        signs = np.concatenate([np.concatenate([self._signs] * (len(RELATIONS) + 2) + [np.zeros(len(RELATIONS))]),
                                np.ones(len(RELATIONS)), np.zeros(len(RELATIONS))])
        clf = SignConstrainedLogit(C=0.25).fit(np.concatenate([self.model.H] + [H_user] * weight),
                                               np.concatenate([self.y] + [y_user] * weight), signs)
        after_p = clf.predict_proba(H_user)[:, 1]
        old_p = self.model.clf.predict_proba(H_user)[:, 1]
        loo = None
        if len(labelled) >= 8:
            preds = []
            for k in range(len(labelled)):
                m = np.ones(len(labelled), bool)
                m[k] = False
                c2 = SignConstrainedLogit(C=0.25).fit(np.concatenate([self.model.H] + [H_user[m]] * weight),
                                                      np.concatenate([self.y] + [y_user[m]] * weight), signs)
                preds.append(c2.predict_proba(H_user[k:k + 1])[0, 1])
            try:
                loo = {"roc_auc_user_loo": round(float(roc_auc_score(y_user, preds)), 4),
                       "roc_auc_user_synthetic_only": round(float(roc_auc_score(y_user, old_p)), 4)}
            except ValueError:
                loo = None
        return {"labelled": len(labelled), "defaults": int(y_user.sum()), "weight_per_label": weight,
                "member": "irgnn",
                "companies": [{"name": c["name"], "defaulted": c["defaulted"],
                               "pd_blend_before": b["distress_probability"],
                               "pd_member_before": round(float(o), 4), "pd_member_after": round(float(a), 4)}
                              for c, b, o, a in zip(labelled, before, old_p, after_p)],
                "leave_one_out": loo}

    # ============================================================ assistant
    def resolve_company(self, text: str) -> str | None:
        m = re.search(r"\bC\d{4}\b", text, re.I)
        if m and m.group(0).upper() in self._id_to_idx:
            return m.group(0).upper()
        tl = text.lower()
        best, best_s = None, 0.0
        for k, nm in enumerate(self.companies["name"].str.lower().values):
            core = nm.replace(" ltd", "")
            words = core.split()
            if core in tl:
                return self.node_ids[k]
            if words[0] in tl and len(words[0]) >= 5:
                s = 0.8 + 0.2 * sum(w in tl for w in words[1:]) / max(len(words) - 1, 1)
            else:
                s = max((difflib.SequenceMatcher(None, words[0], t).ratio()
                         for t in re.findall(r"[a-z]{5,}", tl)), default=0) * 0.85
            if s > best_s:
                best, best_s = self.node_ids[k], s
        return best if best_s >= 0.72 else None


def _sanity(c: dict) -> list[dict]:
    out = []
    if c["revenue"] <= 0:
        out.append({"field": "revenue", "issue": "must_be_positive"})
    if c["assets"] < c["current_assets"]:
        out.append({"field": "assets", "issue": "less_than_current_assets"})
    if c["ebitda"] > c["revenue"]:
        out.append({"field": "ebitda", "issue": "exceeds_revenue"})
    if c["equity"] + c["debt"] > c["assets"] * 1.6 and c["assets"] > 0:
        out.append({"field": "assets", "issue": "liabilities_inconsistent"})
    if c["inventory"] > c["current_assets"]:
        out.append({"field": "inventory", "issue": "exceeds_current_assets"})
    return out


# illustrative, fictional profiles to pre-fill the analyzer (INR crore)
_EXAMPLES = [
    {"key": "epc", "name": "Leveraged EPC contractor", "sector": "Infrastructure & EPC", "promoter_pledge": 0.42,
     "current": {"revenue": 4200, "ebitda": 390, "net_profit": -60, "interest_expense": 360, "assets": 7600,
                 "debt": 3900, "equity": 1650, "cash": 120, "current_assets": 3900, "current_liabilities": 3600,
                 "inventory": 900, "ocf": 140, "capex": 160},
     "previous": {"revenue": 4650, "ebitda": 520},
     "counterparties": [{"name": "State power utility", "relation": "customer", "share": 0.38, "health": "weak"},
                        {"name": "Steel supplier", "relation": "supplier", "share": 0.30, "health": "stable"}]},
    {"key": "it", "name": "Cash-rich IT services firm", "sector": "IT Services", "promoter_pledge": 0.0,
     "current": {"revenue": 9800, "ebitda": 2250, "net_profit": 1550, "interest_expense": 35, "assets": 9100,
                 "debt": 180, "equity": 7400, "cash": 2900, "current_assets": 6100, "current_liabilities": 1900,
                 "inventory": 0, "ocf": 1800, "capex": 260},
     "previous": {"revenue": 8900, "ebitda": 2050},
     "counterparties": [{"name": "US retail client", "relation": "customer", "share": 0.18, "health": "strong"}]},
    {"key": "textile", "name": "Stressed textile exporter", "sector": "Textiles & Apparel", "promoter_pledge": 0.25,
     "current": {"revenue": 1450, "ebitda": 95, "net_profit": -48, "interest_expense": 88, "assets": 1900,
                 "debt": 980, "equity": 520, "cash": 22, "current_assets": 820, "current_liabilities": 760,
                 "inventory": 410, "ocf": 30, "capex": 45},
     "previous": {"revenue": 1720, "ebitda": 175},
     "counterparties": [{"name": "European apparel brand", "relation": "customer", "share": 0.45, "health": "weak"},
                        {"name": "Cotton yarn mill", "relation": "supplier", "share": 0.4, "health": "stable"}]},
]


@functools.lru_cache(maxsize=1)
def get_engine() -> RiskEngine:
    """Process-wide singleton so the model trains once per server."""
    with _LOCK:
        return RiskEngine()
