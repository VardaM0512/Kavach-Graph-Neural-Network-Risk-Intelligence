"""Bridge from the API to the ML RiskEngine.

Adds the ml package to the path and exposes a cached engine instance. The engine
trains once at first use (a few seconds on synthetic data) and is then shared
across all requests.
"""
from __future__ import annotations

import sys
from pathlib import Path

# make `kavach_ml` importable whether run from repo root or the backend dir
_ML_SRC = Path(__file__).resolve().parents[3] / "ml" / "src"
if _ML_SRC.exists() and str(_ML_SRC) not in sys.path:
    sys.path.insert(0, str(_ML_SRC))

from kavach_ml.serve import get_engine  # noqa: E402

__all__ = ["get_engine"]
