"""Smoke tests for the Kavach ML pipeline (runs with NumPy + scikit-learn only)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from kavach_ml.config import SyntheticConfig
from kavach_ml.data import generate_economy, build_feature_frame, build_graph
from kavach_ml.models.numpy_gnn import NumpyGNN, RelationalNumpyGNN, HybridGNNEnsemble
from kavach_ml.models.altman import zscore_proba
from kavach_ml.evaluate import score, ks_statistic, precision_at_k
from kavach_ml.utils import make_splits
from kavach_ml.serve.engine import RiskEngine


def _bundle(n=200):
    eco = generate_economy(SyntheticConfig(n_companies=n))
    feats = build_feature_frame(eco.companies, eco.history)
    return eco, build_graph(eco, feats)


def test_graph_shapes():
    _, b = _bundle()
    assert b.X.shape[0] == b.num_nodes
    assert b.edge_index.shape[0] == 2
    assert b.y.shape[0] == b.num_nodes
    assert b.graph_features is not None


def test_graph_model_learns():
    _, b = _bundle(800)
    s = make_splits(b.y)
    gnn = NumpyGNN(k=1).fit(b.X, b.edge_index, b.y, s["train"])
    m = score(b.y[s["test"]], gnn.predict_proba(s["test"]))
    assert m["roc_auc"] > 0.6          # clearly better than random


def test_relational_and_hybrid_models():
    eco, b = _bundle(800)
    s = make_splits(b.y)
    assert b.edge_type is not None and b.relation_names is not None
    rg = RelationalNumpyGNN(k=1).fit(
        b.X, b.edge_index, b.edge_type, b.y, s["train"], len(b.relation_names))
    assert score(b.y[s["test"]], rg.predict_proba(s["test"]))["roc_auc"] > 0.6
    hy = HybridGNNEnsemble(k=1).fit(
        b.X, b.edge_index, b.edge_type, b.y, s["train"], len(b.relation_names))
    assert score(b.y[s["test"]], hy.predict_proba(s["test"]))["roc_auc"] > 0.55


def test_altman_and_metrics():
    eco, b = _bundle(300)
    zp = zscore_proba(eco.companies)
    assert zp.shape[0] == b.num_nodes and ((zp >= 0) & (zp <= 1)).all()
    assert 0 <= ks_statistic(b.y, zp) <= 1
    assert 0 <= precision_at_k(b.y, zp, 0.1) <= 1


def test_engine_endpoints():
    e = RiskEngine(SyntheticConfig(n_companies=300))
    cid = e.node_ids[0]
    assert 0 <= e.predict(cid)["distress_probability"] <= 1
    assert "components" in e.health_score(cid)
    assert e.scenario(cid, revenue_change=-0.2)["scenario_risk"] >= 0
    assert e.simulate_failure(cid)["affected_count"] >= 0
    assert "feature_drivers" in e.explain(cid)
    assert e.portfolio_risk([{"company_id": cid, "weight": 1.0}])["portfolio_distress_exposure"] >= 0


def test_engine_inductive_and_monotone():
    e = RiskEngine(SyntheticConfig(n_companies=400))
    # inductive scoring of a universe node reproduces the batch prediction
    i = 5
    h = e.model.embed_one(e.X[i], e._links_for(i))
    assert abs(e.model.proba_one(h) - float(e.proba[i])) < 1e-5
    # a harsher scenario can never lower risk
    cid = e.node_ids[i]
    mild = e.scenario(cid, revenue_change=-0.1)["scenario_risk"]
    harsh = e.scenario(cid, revenue_change=-0.4, interest_rate_change=0.03)["scenario_risk"]
    assert harsh >= mild - 1e-6
    # real-company analysis works from statements alone
    ex = e.analyze_template()["examples"][0]
    r = e.analyze(ex)
    assert 0 < r["distress_probability"] < 1 and r["risk_band"] in ("LOW", "MODERATE", "HIGH", "CRITICAL")
    sim = e.simulate_failure(cid)
    assert sim["rounds"] and sim["affected_count"] >= 0


def test_gnn_suite_pyg():
    import pytest
    pytest.importorskip("torch_geometric")
    e = RiskEngine(SyntheticConfig(n_companies=300, seed=11), members=("irgnn", "gcn"))
    assert set(e.suite.members) == {"irgnn", "gcn"}
    assert ((e.pd_low <= e.proba + 1e-9) & (e.proba <= e.pd_high + 1e-9)).all()
    r = e.analyze(e.analyze_template()["examples"][1])
    assert {"irgnn", "gcn"} <= set(r["model_members"]) and r["pd_low"] <= r["distress_probability"] <= r["pd_high"]
    # a known-defaulted counterparty can only raise risk
    ex = dict(e.analyze_template()["examples"][0])
    ok = e.analyze(ex)["distress_probability"]
    ex["counterparties"] = [dict(c, health="distressed") for c in ex["counterparties"]]
    assert e.analyze(ex)["distress_probability"] >= ok - 1e-6


def test_workspace_and_retrain():
    e = RiskEngine(SyntheticConfig(n_companies=300))
    base = e.analyze_template()["examples"]
    comps = []
    for k, ex in enumerate(base):
        cur = dict(ex["current"], year=2025)
        prev = {**ex["current"], "revenue": ex["previous"]["revenue"], "ebitda": ex["previous"]["ebitda"], "year": 2024}
        comps.append({"name": ex["name"], "sector": ex["sector"], "years": [prev, cur], "defaulted": k % 2})
    rels = [{"company": base[0]["name"], "counterparty": base[2]["name"], "relation": "customer", "share": 0.4}]
    out = e.score_workspace({"companies": comps, "relationships": rels})
    assert len(out["companies"]) == 3 and out["summary"]["internal_links"] == 1
    assert len(out["companies"][0]["timeline"]) == 2
    rt = e.retrain_with({"companies": comps, "relationships": rels})
    assert rt["labelled"] == 3
