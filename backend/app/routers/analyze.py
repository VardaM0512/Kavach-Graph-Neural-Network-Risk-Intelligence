"""Score a real company from its reported financials (not in the universe)."""
from fastapi import APIRouter, HTTPException

from ..core.ml import get_engine
from ..schemas import AnalyzeRequest

router = APIRouter(prefix="/analyze", tags=["analyze"])


@router.get("/template")
def template():
    """Required fields, sectors, counterparty relations and pre-fill examples."""
    return get_engine().analyze_template()


@router.post("")
def analyze(req: AnalyzeRequest):
    payload = req.model_dump(exclude={"shocks"})
    try:
        return get_engine().analyze(payload, shocks=req.shocks)
    except (KeyError, ValueError) as e:
        raise HTTPException(422, f"could not score company: {e}")
