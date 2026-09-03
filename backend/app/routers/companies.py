from fastapi import APIRouter, HTTPException, Query

from ..core.ml import get_engine

router = APIRouter(prefix="/companies", tags=["companies"])


@router.get("")
def list_companies(limit: int = Query(50, le=200), offset: int = 0,
                   band: str | None = None):
    eng = get_engine()
    cards = eng.list_companies(limit=limit, offset=offset)
    if band:
        cards = [c for c in cards if c["risk_band"] == band.upper()]
    return {"count": len(cards), "companies": cards}


@router.get("/search")
def search(q: str = Query(..., min_length=1), limit: int = 20):
    eng = get_engine()
    ql = q.lower()
    hits = [eng.company_card(cid) for cid in eng.bundle.node_ids
            if ql in cid.lower() or ql in eng._companies.loc[cid, "name"].lower()][:limit]
    return {"query": q, "results": hits}


@router.get("/{company_id}")
def company_detail(company_id: str):
    eng = get_engine()
    try:
        return {
            **eng.company_card(company_id),
            "health": eng.health_score(company_id),
            "liquidity": eng.liquidity_risk(company_id),
            "leverage": eng.leverage_risk(company_id),
            "concentration": eng.concentration(company_id),
            "centrality": eng.centrality(company_id),
            "peer_comparison": eng.peer_comparison(company_id),
            "risk_timeline": eng.risk_timeline(company_id),
            "anomalies": eng.anomalies(company_id),
        }
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")
