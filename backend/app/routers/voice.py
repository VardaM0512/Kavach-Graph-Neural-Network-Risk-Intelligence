"""Voice routes — the audio pipeline.

Speak -> STT -> understand -> answer -> translate -> TTS -> hear.

  POST /api/voice/tts          text  -> spoken audio (base64)
  POST /api/voice/stt          audio -> transcript
  POST /api/voice/ask          audio -> transcript -> risk answer -> spoken answer
"""
from __future__ import annotations

import re

from fastapi import APIRouter, UploadFile, File, Form

from ..schemas import TTSRequest, VoiceQueryResponse
from ..services import audio_service, translation_service
from ..core.ml import get_engine

router = APIRouter(prefix="/voice", tags=["voice"])


@router.post("/tts")
def text_to_speech(req: TTSRequest):
    """Read any text aloud in the requested language (auto-translated first)."""
    text = req.text
    if req.lang != "en":
        text = translation_service.translate(req.text, req.lang)["text"]
    return audio_service.synthesize(text, lang=req.lang, voice=req.voice)


@router.post("/stt")
async def speech_to_text(file: UploadFile = File(...), lang: str = Form("auto")):
    audio = await file.read()
    return audio_service.transcribe(audio, lang=lang)


@router.post("/ask", response_model=VoiceQueryResponse)
async def voice_ask(file: UploadFile = File(...), lang: str = Form("auto")):
    """Full voice loop: transcribe a spoken query, answer it, and speak the answer."""
    audio = await file.read()
    stt = audio_service.transcribe(audio, lang=lang)
    transcript = stt["transcript"]
    reply_lang = stt["detected_lang"]

    # naive intent: find a company id like C0007 in the transcript
    m = re.search(r"[Cc]\d{3,4}", transcript)
    eng = get_engine()
    if m:
        cid = m.group(0).upper().zfill(5) if not m.group(0).upper().startswith("C0") else m.group(0).upper()
        try:
            p = eng.predict(cid)
            answer = (f"{cid} has a distress probability of "
                      f"{int(p['distress_probability']*100)} percent, rated {p['risk_band']}.")
        except KeyError:
            answer = f"I could not find company {cid}."
    else:
        alerts = eng.early_warnings()
        answer = f"There are currently {alerts['count']} companies in the high-risk band."

    if reply_lang != "en":
        answer = translation_service.translate(answer, reply_lang)["text"]
    spoken = audio_service.synthesize(answer, lang=reply_lang)
    return VoiceQueryResponse(
        transcript=transcript, detected_lang=reply_lang,
        answer=answer, audio_base64=spoken["audio_base64"],
    )
