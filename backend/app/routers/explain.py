from fastapi import APIRouter, HTTPException, Query

from ..core.ml import get_engine
from ..services import translation_service

router = APIRouter(prefix="/explain", tags=["explainability"])


@router.get("/{company_id}")
def explain(company_id: str, lang: str = Query("en")):
    """Explainable AI: feature drivers (SHAP-style) + network drivers.

    Optionally localises the human-readable driver labels via `lang`.
    """
    eng = get_engine()
    try:
        result = eng.explain(company_id)
    except KeyError:
        raise HTTPException(404, f"unknown company_id {company_id}")

    if lang != "en":
        for d in result["feature_drivers"]:
            d["label"] = translation_service.translate(d["feature"], lang)["text"]
    return result
