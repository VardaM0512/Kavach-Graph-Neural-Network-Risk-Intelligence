"""Optional PostgreSQL layer (SQLAlchemy async).

PostgreSQL is the structured store for company profiles, financial statements,
users, predictions, alerts, portfolios and model versions. The app runs fully on
the synthetic engine when `KAVACH_POSTGRES_URL` is unset; wire this in for
persistence.
"""
from __future__ import annotations

from ..core.config import get_settings

_engine = None
_session_factory = None


def is_configured() -> bool:
    return bool(get_settings().postgres_url)


async def init_engine():  # pragma: no cover - requires a live DB
    global _engine, _session_factory
    if not is_configured():
        return None
    from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker
    _engine = create_async_engine(get_settings().postgres_url, pool_pre_ping=True)
    _session_factory = async_sessionmaker(_engine, expire_on_commit=False)
    return _engine


async def healthcheck() -> bool:  # pragma: no cover
    if not _engine:
        return False
    from sqlalchemy import text
    async with _engine.connect() as conn:
        await conn.execute(text("SELECT 1"))
    return True
