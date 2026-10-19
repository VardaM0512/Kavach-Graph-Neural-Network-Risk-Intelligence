from fastapi import APIRouter, Query

from ..core.ml import get_engine

router = APIRouter(prefix="/alerts", tags=["alerts"])


@router.get("/early-warning")
def early_warning(threshold: float = Query(0.10, ge=0.0, le=1.0)):
    """Band downgrades since last fiscal year first, then names above the PD threshold."""
    return get_engine().early_warnings(threshold=threshold)
