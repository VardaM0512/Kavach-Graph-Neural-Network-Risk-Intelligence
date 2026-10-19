from fastapi import APIRouter

from ..core.ml import get_engine
from ..schemas import AssistantRequest
from ..services import assistant

router = APIRouter(prefix="/assistant", tags=["assistant"])


@router.post("")
def ask(req: AssistantRequest):
    """Natural-language question -> structured, renderable answer."""
    out = assistant.answer(get_engine(), req.text)
    out["lang"] = req.lang
    return out
