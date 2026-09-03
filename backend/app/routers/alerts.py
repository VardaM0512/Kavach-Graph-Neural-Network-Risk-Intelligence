from fastapi import APIRouter, Query

from ..core.ml import get_engine

router = APIRouter(prefix="/alerts", tags=["alerts"])


@router.get("/early-warning")
def early_warning(threshold: float = Query(0.6, ge=0.0, le=1.0)):
    """Early-warning feed: companies whose risk crossed into HIGH/CRITICAL."""
    return get_engine().early_warnings(threshold=threshold)
