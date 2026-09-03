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
