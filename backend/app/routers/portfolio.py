from fastapi import APIRouter, HTTPException

from ..core.ml import get_engine
from ..schemas import PortfolioRequest

router = APIRouter(prefix="/portfolio", tags=["portfolio"])


@router.post("/risk")
def portfolio_risk(req: PortfolioRequest):
    """Aggregate distress exposure + shared-network concentration for a portfolio."""
    try:
        holdings = [h.model_dump() for h in req.holdings]
        return get_engine().portfolio_risk(holdings)
    except KeyError as e:
        raise HTTPException(404, f"unknown company_id {e}")
