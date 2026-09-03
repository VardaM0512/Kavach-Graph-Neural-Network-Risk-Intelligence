from fastapi import APIRouter, HTTPException, Query

from ..core.ml import get_engine

router = APIRouter(prefix="/network", tags=["network"])


@router.get("/{company_id}/graph")
def ego_graph(company_id: str, hops: int = Query(1, ge=1, le=2)):
    """Ego network (nodes + edges) for the mobile graph-visualisation screen."""
    try:
        return get_engine().network_graph(company_id, hops=hops)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.get("/{company_id}/contagion")
def contagion(company_id: str):
    try:
        return get_engine().contagion(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.post("/{company_id}/simulate-failure")
def simulate_failure(company_id: str, max_depth: int = Query(3, ge=1, le=5)):
    """What-if network simulation: propagate this company's failure downstream."""
    try:
        return get_engine().simulate_failure(company_id, max_depth=max_depth)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.get("/heatmap")
def heatmap():
    """Industry-level risk heatmap."""
    return get_engine().heatmap()
