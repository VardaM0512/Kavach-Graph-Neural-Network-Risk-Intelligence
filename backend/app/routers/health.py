from fastapi import APIRouter

from ..core.config import get_settings
from ..db import postgres, neo4j_db

router = APIRouter(tags=["health"])


@router.get("/health")
def health():
    """Service health — used by Docker/Render/K8s health checks."""
    s = get_settings()
    return {
        "status": "ok",
        "service": s.app_name,
        "environment": s.environment,
        "postgres_configured": postgres.is_configured(),
        "neo4j_configured": neo4j_db.is_configured(),
    }
