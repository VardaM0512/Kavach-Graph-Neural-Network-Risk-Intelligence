from fastapi import APIRouter

from ..core.config import get_settings

router = APIRouter(tags=["health"])


@router.get("/health")
def health():
    """Service health — used by Docker/Render/K8s health checks."""
    s = get_settings()
    return {
        "status": "ok",
        "service": s.app_name,
        "environment": s.environment,
        "model": __import__("app.core.ml", fromlist=["model_status"]).model_status(),
    }
