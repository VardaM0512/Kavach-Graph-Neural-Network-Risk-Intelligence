from fastapi import APIRouter, HTTPException

from ..core.ml import get_engine

router = APIRouter(prefix="/predictions", tags=["predictions"])


@router.get("/{company_id}")
def predict(company_id: str):
    """Primary distress prediction + multi-horizon + health + contagion."""
    try:
        return get_engine().predict(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.get("/{company_id}/multi-horizon")
def multi_horizon(company_id: str):
    try:
        return {"company_id": company_id, "horizons": get_engine().multi_horizon(company_id)}
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.get("/{company_id}/health-score")
def health_score(company_id: str):
    try:
        return get_engine().health_score(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")
