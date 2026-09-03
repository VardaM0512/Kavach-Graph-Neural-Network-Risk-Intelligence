from fastapi import APIRouter, HTTPException

from ..core.ml import get_engine
from ..schemas import ScenarioRequest

router = APIRouter(prefix="/scenario", tags=["scenario"])


@router.post("")
def run_scenario(req: ScenarioRequest):
    """Stress test: recompute risk under revenue / rate / supplier-failure shocks."""
    try:
        return get_engine().scenario(
            req.company_id,
            revenue_change=req.revenue_change,
            interest_rate_change=req.interest_rate_change,
            supplier_failure=req.supplier_failure,
        )
    except KeyError:
        raise HTTPException(404, f"unknown company_id {req.company_id}")


@router.get("/{company_id}/sweep")
def revenue_sweep(company_id: str):
    """Pre-baked stress ladder for the scenario screen (revenue -10/-20/-30%)."""
    eng = get_engine()
    try:
        return {"company_id": company_id, "sweep": [
            {"scenario": "current", **eng.scenario(company_id)},
            {"scenario": "revenue -10%", **eng.scenario(company_id, revenue_change=-0.10)},
            {"scenario": "revenue -20%", **eng.scenario(company_id, revenue_change=-0.20)},
            {"scenario": "revenue -30%", **eng.scenario(company_id, revenue_change=-0.30)},
            {"scenario": "rates +200bps", **eng.scenario(company_id, interest_rate_change=0.02)},
        ]}
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")
