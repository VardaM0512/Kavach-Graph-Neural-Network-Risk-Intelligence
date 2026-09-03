"""RiskEngine — the inference + analytics core used by the FastAPI backend.

On startup it builds a self-contained synthetic economy, constructs the graph,
and trains the lightweight NumPy GNN so every API endpoint returns real,
consistent numbers with zero external services. In production you swap the two
data sources marked `# DATA SOURCE` for Postgres (financials) and Neo4j
(relationships); nothing else changes.

Everything the product's 25 features need is computed here:
  - distress probability + risk band
  - multi-horizon (3/6/12/24m) risk
  - financial health score (0-100)
  - liquidity / leverage / profitability / cash-flow sub-scores
  - network contagion + centrality
  - supplier / customer concentration
  - explainability (feature contributions + neighbour influence)
  - scenario / stress testing + supplier-failure simulation
  - portfolio exposure
  - peer comparison + risk timeline + anomaly flags
"""
from __future__ import annotations

import functools
import threading

import numpy as np

from ..config import SyntheticConfig, TrainConfig, band_for, HORIZONS_MONTHS
from ..data import generate_economy, build_feature_frame, build_graph
from ..models.numpy_gnn import NumpyGNN
from ..explain import feature_contributions, explain_neighbours
from ..utils import make_splits

_LOCK = threading.Lock()


class RiskEngine:
    def __init__(self, synth: SyntheticConfig | None = None):
        self.economy = generate_economy(synth or SyntheticConfig())
        self.features = build_feature_frame(self.economy.companies, self.economy.history)
        self.bundle = build_graph(self.economy, self.features)
        self._id_to_idx = {c: i for i, c in enumerate(self.bundle.node_ids)}

        # train the graph model (fast, NumPy). Torch models load here in prod.
        splits = make_splits(self.bundle.y, TrainConfig())
        self.model = NumpyGNN(k=1, mode="gcn").fit(
            self.bundle.X, self.bundle.edge_index, self.bundle.y, splits["train"]
        )
        self.proba = self.model.predict_proba_all()
        self._companies = self.economy.companies.set_index("company_id")
        self._feat = self.features.set_index("company_id")
        self._gfeat = self.bundle.graph_features.set_index("company_id")

    # ------------------------------------------------------------------ core
    def _idx(self, company_id: str) -> int:
        if company_id not in self._id_to_idx:
            raise KeyError(company_id)
        return self._id_to_idx[company_id]

    def list_companies(self, limit: int = 100, offset: int = 0):
        ids = self.bundle.node_ids[offset:offset + limit]
        return [self.company_card(cid) for cid in ids]

    def company_card(self, company_id: str) -> dict:
        i = self._idx(company_id)
        row = self._companies.loc[company_id]
        p = float(self.proba[i])
        return {
            "company_id": company_id,
            "name": row["name"],
            "industry": row["industry"],
            "distress_probability": round(p, 4),
            "risk_band": band_for(p),
            "health_score": self.health_score(company_id)["health_score"],
        }

    # ------------------------------------------------------- risk & horizons
    def predict(self, company_id: str) -> dict:
        i = self._idx(company_id)
        p = float(self.proba[i])
        return {
            "company_id": company_id,
            "distress_probability": round(p, 4),
            "risk_band": band_for(p),
            "multi_horizon": self.multi_horizon(company_id),
            "health_score": self.health_score(company_id)["health_score"],
            "network_contagion": self.contagion(company_id)["contagion_score"],
        }

    def multi_horizon(self, company_id: str) -> dict:
        i = self._idx(company_id)
        base = float(self.proba[i])
        out = {}
        for h in HORIZONS_MONTHS:
            # hazard accumulates with horizon; bounded in [0,1]
            scale = 0.55 + 0.45 * (h / 24.0)
            out[f"{h}m"] = round(min(0.999, base * scale + (1 - base) * 0.02 * (h / 3)), 4)
        return out

    # ----------------------------------------------------------- sub-scores
    def health_score(self, company_id: str) -> dict:
        f = self._feat.loc[company_id]
        liquidity = _clip01((f["current_ratio"] - 0.8) / 2.0)
        leverage = _clip01(1 - (f["debt_to_equity"]) / 4.0)
        profitability = _clip01((f["net_margin"] + 0.1) / 0.4)
        cashflow = _clip01((f["ocf_to_debt"] + 0.2) / 1.2)
        growth = _clip01((f["revenue_growth_yoy"] + 0.2) / 0.6)
        sub = {
            "liquidity": round(liquidity * 100, 1),
            "leverage": round(leverage * 100, 1),
            "profitability": round(profitability * 100, 1),
            "cash_flow": round(cashflow * 100, 1),
            "growth": round(growth * 100, 1),
        }
        score = float(np.mean(list(sub.values())))
        return {"company_id": company_id, "health_score": round(score, 1), "components": sub}

    def liquidity_risk(self, company_id: str) -> dict:
        f = self._feat.loc[company_id]
        return {"current_ratio": round(float(f["current_ratio"]), 3),
                "quick_ratio": round(float(f["quick_ratio"]), 3),
                "cash_ratio": round(float(f["cash_ratio"]), 3),
                "working_capital_to_assets": round(float(f["working_capital_to_assets"]), 3)}

    def leverage_risk(self, company_id: str) -> dict:
        f = self._feat.loc[company_id]
        return {"debt_to_equity": round(float(f["debt_to_equity"]), 3),
                "debt_to_assets": round(float(f["debt_to_assets"]), 3),
                "interest_coverage": round(float(f["interest_coverage"]), 3),
                "net_debt_to_ebitda": round(float(f["net_debt_to_ebitda"]), 3)}

    # ------------------------------------------------------------- network
    def contagion(self, company_id: str) -> dict:
        i = self._idx(company_id)
        neighbours = explain_neighbours(
            i, self.bundle.edge_index, self.bundle.edge_weight, self.proba,
            self.bundle.node_ids, top_k=8,
        )
        if neighbours:
            score = float(np.mean([n["influence"] for n in neighbours])) * 100
        else:
            score = 0.0
        return {"company_id": company_id,
                "contagion_score": round(min(score, 100.0), 1),
                "top_exposures": neighbours[:5]}

    def centrality(self, company_id: str) -> dict:
        f = self._gfeat.loc[company_id]
        return {"pagerank": round(float(f["pagerank"]), 4),
                "degree_centrality": round(float(f["degree_centrality"]), 4)}

    def concentration(self, company_id: str) -> dict:
        f = self._gfeat.loc[company_id]
        return {"supplier_concentration_hhi": round(float(f["supplier_concentration_hhi"]), 3),
                "customer_concentration_hhi": round(float(f["customer_concentration_hhi"]), 3)}

    def network_graph(self, company_id: str, hops: int = 1) -> dict:
        """Ego network around a company for the mobile graph screen."""
        i = self._idx(company_id)
        ei = self.bundle.edge_index
        nodes = {i}
        frontier = {i}
        for _ in range(hops):
            nxt = set()
            for e in range(ei.shape[1]):
                a, b = ei[0, e], ei[1, e]
                if a in frontier:
                    nxt.add(int(b))
                if b in frontier:
                    nxt.add(int(a))
            nodes |= nxt
            frontier = nxt
        node_list = [{"id": self.bundle.node_ids[j],
                      "risk": round(float(self.proba[j]), 3),
                      "band": band_for(float(self.proba[j]))} for j in nodes]
        edge_list = []
        seen = set()
        for e in range(ei.shape[1]):
            a, b = int(ei[0, e]), int(ei[1, e])
            if a in nodes and b in nodes and (a, b) not in seen and (b, a) not in seen:
                edge_list.append({"source": self.bundle.node_ids[a],
                                  "target": self.bundle.node_ids[b],
                                  "weight": round(float(self.bundle.edge_weight[e]), 3)})
                seen.add((a, b))
        return {"center": company_id, "nodes": node_list, "edges": edge_list}

    # ----------------------------------------------------------- explainable
    def explain(self, company_id: str) -> dict:
        i = self._idx(company_id)
        contrib = feature_contributions(
            self.model.clf, self.model._H, self.model._H[i],
            [f"{n}" for n in self.bundle.feature_names] + [f"nbr::{n}" for n in self.bundle.feature_names],
            top_k=6,
        )
        neigh = explain_neighbours(
            i, self.bundle.edge_index, self.bundle.edge_weight, self.proba,
            self.bundle.node_ids, top_k=5,
        )
        return {"company_id": company_id,
                "feature_drivers": contrib,
                "network_drivers": neigh}

    # ------------------------------------------------------------- scenario
    def scenario(self, company_id: str, revenue_change: float = 0.0,
                 interest_rate_change: float = 0.0,
                 supplier_failure: bool = False) -> dict:
        """Recompute risk under a what-if shock (fast, closed-form approximation)."""
        i = self._idx(company_id)
        base = float(self.proba[i])
        shock = 0.0
        shock += -1.6 * revenue_change                    # revenue down => risk up
        shock += 2.5 * interest_rate_change               # rates up => risk up
        if supplier_failure:
            shock += 0.20 + 0.3 * self.concentration(company_id)["supplier_concentration_hhi"]
        scenario_prob = _clip01(base + shock)
        return {"company_id": company_id,
                "current_risk": round(base, 4),
                "scenario_risk": round(scenario_prob, 4),
                "delta": round(scenario_prob - base, 4),
                "inputs": {"revenue_change": revenue_change,
                           "interest_rate_change": interest_rate_change,
                           "supplier_failure": supplier_failure}}

    def simulate_failure(self, failing_company_id: str, max_depth: int = 3) -> dict:
        """Propagate a supplier failure through the graph (BFS with decay)."""
        start = self._idx(failing_company_id)
        ei = self.bundle.edge_index
        impact = {start: 1.0}
        frontier = {start: 1.0}
        for depth in range(1, max_depth + 1):
            nxt: dict[int, float] = {}
            for node, strength in frontier.items():
                for e in range(ei.shape[1]):
                    if ei[0, e] == node:                  # message node -> b
                        b = int(ei[1, e])
                        decayed = strength * 0.5 * float(self.bundle.edge_weight[e])
                        if decayed > impact.get(b, 0):
                            nxt[b] = max(nxt.get(b, 0), decayed)
            for b, s in nxt.items():
                impact[b] = max(impact.get(b, 0), s)
            frontier = nxt
        affected = [{"company_id": self.bundle.node_ids[j], "impact": round(v, 3)}
                    for j, v in sorted(impact.items(), key=lambda kv: kv[1], reverse=True)
                    if j != start][:20]
        level = "HIGH" if len(affected) > 8 else "MODERATE" if affected else "LOW"
        return {"failing_company": failing_company_id,
                "estimated_network_impact": level,
                "affected_count": len(affected),
                "affected": affected}

    # ------------------------------------------------------------- portfolio
    def portfolio_risk(self, holdings: list[dict]) -> dict:
        """holdings = [{company_id, weight}]; returns exposure + concentration."""
        total_w = sum(h["weight"] for h in holdings) or 1.0
        exposure = 0.0
        rows = []
        neighbour_hits: dict[str, float] = {}
        for h in holdings:
            cid = h["company_id"]
            w = h["weight"] / total_w
            p = float(self.proba[self._idx(cid)])
            exposure += w * p
            rows.append({"company_id": cid, "weight": round(w, 3),
                         "risk": round(p, 4), "band": band_for(p)})
            for n in self.contagion(cid)["top_exposures"]:
                neighbour_hits[n["neighbour_id"]] = neighbour_hits.get(n["neighbour_id"], 0) + w
        shared = sorted(neighbour_hits.items(), key=lambda kv: kv[1], reverse=True)[:3]
        return {"portfolio_distress_exposure": round(exposure, 4),
                "band": band_for(exposure),
                "holdings": rows,
                "shared_network_exposure": [{"company_id": c, "portfolio_weight": round(w, 3)}
                                            for c, w in shared]}

    # -------------------------------------------------------- extra analytics
    def peer_comparison(self, company_id: str) -> dict:
        row = self._companies.loc[company_id]
        industry = row["industry"]
        peers_idx = [self._idx(c) for c in self._companies.index
                     if self._companies.loc[c, "industry"] == industry]
        f = self._feat
        peer_ids = [self.bundle.node_ids[j] for j in peers_idx]
        def avg(col):
            return float(np.mean([f.loc[c, col] for c in peer_ids]))
        return {"company_id": company_id, "industry": industry,
                "company": {"debt_to_equity": round(float(f.loc[company_id, "debt_to_equity"]), 3),
                            "revenue_growth": round(float(f.loc[company_id, "revenue_growth_yoy"]), 3),
                            "health_score": self.health_score(company_id)["health_score"],
                            "risk": round(float(self.proba[self._idx(company_id)]), 4)},
                "industry_avg": {"debt_to_equity": round(avg("debt_to_equity"), 3),
                                 "revenue_growth": round(avg("revenue_growth_yoy"), 3),
                                 "risk": round(float(np.mean([self.proba[j] for j in peers_idx])), 4)}}

    def risk_timeline(self, company_id: str) -> dict:
        """Back-cast risk trend from historical revenue trajectory."""
        i = self._idx(company_id)
        current = float(self.proba[i])
        hist = self.economy.history
        g = hist[hist["company_id"] == company_id].sort_values("year")
        points = []
        revs = g["revenue"].values
        for k, (_, r) in enumerate(g.iterrows()):
            # scale current risk by how much smaller revenue was then
            factor = revs[-1] / max(r["revenue"], 1e-6)
            past_risk = _clip01(current / max(factor, 1e-6))
            points.append({"year": int(r["year"]), "risk": round(past_risk, 4)})
        points.sort(key=lambda p: p["year"])
        trend = "accelerating" if len(points) > 1 and points[-1]["risk"] > points[0]["risk"] else "stable"
        return {"company_id": company_id, "timeline": points, "trend": trend}

    def anomalies(self, company_id: str) -> dict:
        """Flag abrupt YoY changes in the history series."""
        g = self.economy.history
        g = g[g["company_id"] == company_id].sort_values("year")
        flags = []
        rev = g["revenue"].values
        if len(rev) >= 2:
            change = (rev[-1] - rev[-2]) / max(abs(rev[-2]), 1e-6)
            if change < -0.25:
                flags.append({"type": "revenue_drop", "magnitude": round(float(change), 3)})
        return {"company_id": company_id, "anomalies": flags,
                "anomaly_score": round(min(1.0, len(flags) * 0.5), 3)}

    def heatmap(self) -> dict:
        """Industry-level average risk for the risk heatmap screen."""
        df = self._companies.copy()
        df["risk"] = [self.proba[self._idx(c)] for c in df.index]
        out = df.groupby("industry")["risk"].mean().sort_values(ascending=False)
        return {"industries": [{"industry": k, "avg_risk": round(float(v), 4),
                                "band": band_for(float(v))} for k, v in out.items()]}

    def early_warnings(self, threshold: float = 0.6) -> dict:
        """Companies whose risk crossed into HIGH/CRITICAL — for the alert feed."""
        alerts = []
        for i, cid in enumerate(self.bundle.node_ids):
            p = float(self.proba[i])
            if p >= threshold:
                alerts.append({"company_id": cid, "risk": round(p, 4), "band": band_for(p)})
        alerts.sort(key=lambda a: a["risk"], reverse=True)
        return {"count": len(alerts), "alerts": alerts[:50]}


def _clip01(x) -> float:
    return float(min(1.0, max(0.0, x)))


@functools.lru_cache(maxsize=1)
def get_engine() -> RiskEngine:
    """Process-wide singleton so the model trains once per server."""
    with _LOCK:
        return RiskEngine()
