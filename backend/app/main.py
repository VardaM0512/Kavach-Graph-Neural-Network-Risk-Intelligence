"""Kavach API — FastAPI application entry point.

    uvicorn app.main:app --reload --port 8000

Docs at /docs (Swagger) and /redoc. The ML engine warms up lazily on the first
prediction request, or eagerly at startup if KAVACH_WARM_ENGINE=1.
"""
from __future__ import annotations

import os
from pathlib import Path

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse

from .core.config import get_settings
from .routers import api_router

settings = get_settings()
web_dir = Path(os.getenv("KAVACH_WEB_DIR", "/app/web"))
web_index = web_dir / "index.html"

app = FastAPI(
    title=settings.app_name,
    version="0.1.0",
    description=(
        "Corporate Financial Risk Intelligence Platform — Graph Neural Network "
        "distress prediction, network contagion analytics, explainable AI, "
        "scenario stress-testing, portfolio risk, and a multilingual voice API."
    ),
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(api_router)


@app.get("/", tags=["root"])
def root():
    if web_index.is_file():
        return FileResponse(web_index)
    return {"service": settings.app_name, "docs": "/docs", "health": "/api/health"}


@app.on_event("startup")
async def _startup():
    # optional eager warmup so the first request isn't slow
    if os.getenv("KAVACH_WARM_ENGINE") == "1":
        from .core.ml import get_engine
        get_engine()


@app.get("/{path:path}", include_in_schema=False)
def web_client_route(path: str):
    if path == "api" or path.startswith("api/"):
        raise HTTPException(status_code=404, detail="Not Found")
    if not web_index.is_file():
        raise HTTPException(status_code=404, detail="Not Found")

    root = web_dir.resolve()
    requested = (root / path).resolve()
    if requested.is_relative_to(root) and requested.is_file():
        return FileResponse(requested)
    if Path(path).suffix:
        raise HTTPException(status_code=404, detail="Not Found")
    return FileResponse(web_index)
