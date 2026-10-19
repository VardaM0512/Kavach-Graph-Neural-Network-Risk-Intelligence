"""Router registry — assembles all API routers under /api."""
from fastapi import APIRouter

from . import (
    health, auth, companies, predictions, network,
    scenario, portfolio, alerts, explain, language, voice, ml,
    overview, analyze, assistant, ingest,
)

api_router = APIRouter(prefix="/api")
api_router.include_router(health.router)
api_router.include_router(auth.router)
api_router.include_router(companies.router)
api_router.include_router(predictions.router)
api_router.include_router(network.router)
api_router.include_router(scenario.router)
api_router.include_router(portfolio.router)
api_router.include_router(alerts.router)
api_router.include_router(explain.router)
api_router.include_router(language.router)
api_router.include_router(voice.router)
api_router.include_router(ml.router)
api_router.include_router(overview.router)
api_router.include_router(analyze.router)
api_router.include_router(assistant.router)
api_router.include_router(ingest.router)
