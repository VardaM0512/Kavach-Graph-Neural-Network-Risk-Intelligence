from fastapi import APIRouter, HTTPException, Query

from ..core.ml import get_engine

router = APIRouter(prefix="/companies", tags=["companies"])


@router.get("")
def list_companies(limit: int = Query(50, le=500), offset: int = 0,
                   band: str | None = None, sector: str | None = None,
                   q: str | None = None, sort: str = Query("risk", pattern="^(risk|safe|movers|size|name)$")):
    """Screener: filter by band / sector / text, sort by risk, movers, size or name."""
    total, cards = get_engine().list_companies(limit=limit, offset=offset, sector=sector,
                                               band=band, q=q, sort=sort)
    return {"total": total, "count": len(cards), "companies": cards}


@router.get("/search")
def search(q: str = Query(..., min_length=1), limit: int = 8):
    """Fuzzy name search (typo-tolerant) for the command bar."""
    return {"query": q, "results": get_engine().search(q, limit=limit)}


@router.get("/{company_id}")
def company_detail(company_id: str):
    """Everything the company page needs in one call."""
    try:
        return get_engine().company_detail(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")


@router.get("/{company_id}/statements")
def statements(company_id: str):
    try:
        return get_engine().statements(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")
