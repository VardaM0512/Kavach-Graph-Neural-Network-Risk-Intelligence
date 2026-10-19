"""Real-company input: ticker auto-fill, spreadsheet upload, annual-report PDFs,
and a workspace that scores *your* companies as their own connected network."""
from __future__ import annotations

from fastapi import APIRouter, File, Form, HTTPException, UploadFile
from fastapi.responses import PlainTextResponse

from ..core.ml import get_engine
from ..schemas import WorkspaceRequest
from ..services import ingest

router = APIRouter(tags=["real companies"])

MAX_UPLOAD = 15 * 1024 * 1024


async def _read(file: UploadFile) -> bytes:
    data = await file.read()
    if len(data) > MAX_UPLOAD:
        raise HTTPException(413, "file too large (15 MB max)")
    return data


@router.get("/ingest/ticker/{symbol}")
def ticker(symbol: str):
    """Fetch an NSE/BSE company's annual statements and return an analyze payload."""
    try:
        return ingest.fetch_ticker(symbol)
    except LookupError as e:
        raise HTTPException(404, str(e))
    except Exception as e:  # network / provider errors
        raise HTTPException(502, f"market data provider failed: {e}")


@router.get("/ingest/template.csv", response_class=PlainTextResponse)
def template():
    """CSV template: one row per company per fiscal year (INR crore)."""
    return PlainTextResponse(ingest.template_csv(), headers={
        "Content-Disposition": 'attachment; filename="kavach_template.csv"'})


@router.post("/ingest/table")
async def table(file: UploadFile = File(...), unit: str = Form("crore")):
    """Parse a CSV/Excel file into companies x fiscal years (+ relationships sheet)."""
    try:
        return ingest.parse_table(await _read(file), file.filename or "upload.csv", unit)
    except ValueError as e:
        raise HTTPException(422, str(e))


@router.post("/ingest/pdf")
async def pdf(file: UploadFile = File(...)):
    """Best-effort extraction of statement line items from an annual report."""
    try:
        return ingest.extract_pdf(await _read(file))
    except Exception as e:
        raise HTTPException(422, f"could not read PDF: {e}")


@router.post("/workspace/score")
def workspace(req: WorkspaceRequest):
    """Score a set of real companies together: counterparties that are also in the
    set are linked to each other's actual financials, every fiscal year is scored
    for trends, and the set gets its own network view and contagion analysis."""
    try:
        return get_engine().score_workspace(req.model_dump())
    except (KeyError, ValueError) as e:
        raise HTTPException(422, str(e))


@router.post("/analyze/batch")
async def analyze_batch(file: UploadFile = File(...), unit: str = Form("crore")):
    """Upload a spreadsheet and score every company in it in one call."""
    try:
        parsed = ingest.parse_table(await _read(file), file.filename or "upload.csv", unit)
    except ValueError as e:
        raise HTTPException(422, str(e))
    if not parsed["companies"]:
        raise HTTPException(422, "no companies found in file")
    out = get_engine().score_workspace(parsed)
    out["warnings"] = parsed["warnings"] + out.get("warnings", [])
    return out


@router.post("/workspace/retrain")
def retrain(req: WorkspaceRequest):
    """Retrain with your labelled companies (defaulted = 1/0) mixed into the
    synthetic universe and report before/after metrics."""
    try:
        return get_engine().retrain_with(req.model_dump())
    except ValueError as e:
        raise HTTPException(422, str(e))
