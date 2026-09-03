from fastapi import APIRouter

from ..core.ml import get_engine

router = APIRouter(prefix="/ml", tags=["ml"])


@router.get("/model-comparison")
def model_comparison():
    """Return the latest model scoreboard (baselines vs GNNs), if available."""
    from pathlib import Path
    import json
    p = Path(__file__).resolve().parents[3] / "ml" / "artifacts" / "comparison.json"
    if p.exists():
        return {"available": True, "scores": json.loads(p.read_text())}
    return {"available": False,
            "hint": "run `python ml/scripts/quick_demo.py` to generate the comparison"}


@router.get("/dataset-summary")
def dataset_summary():
    """Summary of the loaded economy: node/edge counts, distress rate, features."""
    eng = get_engine()
    return {
        **eng.economy.summary(),
        "num_features": eng.bundle.num_features,
        "feature_names": eng.bundle.feature_names,
    }
