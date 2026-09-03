from fastapi import APIRouter

from ..schemas import TranslateRequest
from ..services import translation_service

router = APIRouter(prefix="/language", tags=["language"])


@router.get("/supported")
def supported():
    """List supported UI + content languages."""
    return {"languages": translation_service.supported_languages()}


@router.post("/translate")
def translate(req: TranslateRequest):
    """Translate arbitrary text (risk explanations, alerts) into a target language."""
    return translation_service.translate(req.text, req.target_lang, req.source_lang)
