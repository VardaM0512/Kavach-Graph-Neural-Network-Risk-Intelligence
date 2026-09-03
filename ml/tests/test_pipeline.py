"""Smoke tests for the Kavach ML pipeline (runs with NumPy + scikit-learn only)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from kavach_ml.config import SyntheticConfig
from kavach_ml.data import generate_economy, build_feature_frame, build_graph
from kavach_ml.models.numpy_gnn import NumpyGNN
from kavach_ml.evaluate import score
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
    _, b = _bundle(300)
    s = make_splits(b.y)
    gnn = NumpyGNN(k=1).fit(b.X, b.edge_index, b.y, s["train"])
    m = score(b.y[s["test"]], gnn.predict_proba(s["test"]))
    assert m["roc_auc"] > 0.7          # clearly better than random


def test_engine_endpoints():
    e = RiskEngine(SyntheticConfig(n_companies=150))
    cid = e.bundle.node_ids[0]
    assert 0 <= e.predict(cid)["distress_probability"] <= 1
    assert "components" in e.health_score(cid)
    assert e.scenario(cid, revenue_change=-0.2)["scenario_risk"] >= 0
    assert e.simulate_failure(cid)["affected_count"] >= 0
    assert "feature_drivers" in e.explain(cid)
    assert e.portfolio_risk([{"company_id": cid, "weight": 1.0}])["portfolio_distress_exposure"] >= 0
