"""Universe-level analytics: market overview, sectors, model card."""
from fastapi import APIRouter

from ..core.ml import get_engine

router = APIRouter(tags=["overview"])


@router.get("/overview")
def overview():
    """KPIs, PD distribution, sector table, leverage/coverage scatter, movers, macro."""
    return get_engine().overview()


@router.get("/sectors")
def sectors():
    return {"sectors": get_engine().sectors()}


@router.get("/model")
def model_card():
    """How the model was trained and how well it does on held-out data."""
    return get_engine().model_card()
