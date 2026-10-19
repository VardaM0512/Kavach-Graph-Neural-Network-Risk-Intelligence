from fastapi import APIRouter, HTTPException

from ..core.ml import get_engine
from ..schemas import ScenarioRequest

router = APIRouter(prefix="/scenario", tags=["scenario"])


@router.post("")
def run_scenario(req: ScenarioRequest):
    """Stress test: shock the statements and re-run the model."""
    try:
        return get_engine().scenario(
            req.company_id,
            revenue_change=req.revenue_change,
            interest_rate_change=req.interest_rate_change,
            supplier_failure=req.supplier_failure,
            customer_loss=req.customer_loss,
            margin_change=req.margin_change,
            debt_change=req.debt_change,
        )
    except KeyError:
        raise HTTPException(404, f"unknown company_id {req.company_id}")


@router.get("/{company_id}/sweep")
def sweep(company_id: str):
    """Risk curves versus revenue shock and versus rate shock."""
    try:
        return get_engine().scenario_sweep(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")
