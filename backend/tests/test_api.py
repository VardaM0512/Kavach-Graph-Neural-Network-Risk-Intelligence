"""API smoke tests using FastAPI's TestClient (synthetic engine, no external DBs)."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))          # backend/
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "ml" / "src"))

from fastapi.testclient import TestClient
from app.main import app

client = TestClient(app)


def _token():
    r = client.post("/api/auth/login", json={"email": "demo@kavach.ai", "password": "demo1234"})
    assert r.status_code == 200
    return r.json()["access_token"]


def test_health():
    assert client.get("/api/health").json()["status"] == "ok"


def test_auth_and_company_flow():
    _token()  # login works
    companies = client.get("/api/companies?limit=5").json()["companies"]
    assert companies, "expected at least one company"
    cid = companies[0]["company_id"]

    assert 0 <= client.get(f"/api/predictions/{cid}").json()["distress_probability"] <= 1
    assert "nodes" in client.get(f"/api/network/{cid}/graph").json()
    assert "feature_drivers" in client.get(f"/api/explain/{cid}").json()

    sc = client.post("/api/scenario", json={"company_id": cid, "revenue_change": -0.2}).json()
    assert "scenario_risk" in sc

    pf = client.post("/api/portfolio/risk", json={"holdings": [{"company_id": cid, "weight": 1.0}]}).json()
    assert "portfolio_distress_exposure" in pf


def test_language_and_voice():
    langs = client.get("/api/language/supported").json()["languages"]
    assert any(l["code"] == "hi" for l in langs)
    tts = client.post("/api/voice/tts", json={"text": "High risk", "lang": "hi"}).json()
    assert tts["audio_base64"]


def test_every_get_endpoint_responds():
    cid = client.get("/api/companies?limit=1").json()["companies"][0]["company_id"]
    for path in ["/api/ml/dataset-summary", "/api/ml/model-comparison", "/api/overview", "/api/sectors",
                 "/api/model", "/api/analyze/template", "/api/alerts/early-warning", "/api/network/heatmap",
                 f"/api/companies/{cid}/statements", f"/api/predictions/{cid}/multi-horizon",
                 f"/api/predictions/{cid}/health-score", f"/api/network/{cid}/contagion"]:
        r = client.get(path)
        assert r.status_code == 200, (path, r.text[:200])


def test_analyze_and_workspace():
    tpl = client.get("/api/analyze/template").json()
    rep = client.post("/api/analyze", json=tpl["examples"][0]).json()
    assert 0 <= rep["pd_low"] <= rep["distress_probability"] <= rep["pd_high"] <= 1
    yr = lambda y, r: {"year": y, "revenue": r, "ebitda": r * .12, "net_profit": r * .04, "interest_expense": r * .03,
                       "assets": r * 1.2, "debt": r * .5, "equity": r * .4, "cash": r * .05,
                       "current_assets": r * .4, "current_liabilities": r * .35}
    ws = {"companies": [{"name": "A", "sector": "Steel & Metals", "years": [yr(2024, 900), yr(2025, 1000)]},
                        {"name": "B", "sector": "Steel & Metals", "years": [yr(2025, 500)]}],
          "relationships": [{"company": "A", "counterparty": "B", "relation": "supplier", "share": .4}]}
    base = {c["name"]: c["distress_probability"] for c in client.post("/api/workspace/score", json=ws).json()["companies"]}
    ws["companies"][1]["defaulted"] = 1
    hit = {c["name"]: c["distress_probability"] for c in client.post("/api/workspace/score", json=ws).json()["companies"]}
    assert hit["A"] >= base["A"]
