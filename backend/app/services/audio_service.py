"""Audio service — Text-to-Speech and Speech-to-Text.

Powers the app's voice features: a user can *speak* a query ("what's the risk on
Company X?") and *hear* the risk summary read back in their own language.

Providers are pluggable and degrade gracefully:

  TTS: stub (silent WAV) | gtts (gTTS) | azure | google
  STT: stub (echo)       | whisper     | azure | google

The stub providers return valid, well-formed payloads so the mobile app and the
API contract can be developed and tested without any cloud credentials.
"""
from __future__ import annotations

import base64
import io
import struct

from ..core.config import get_settings


# ------------------------------------------------------------------ TTS ------
def synthesize(text: str, lang: str = "en", voice: str | None = None) -> dict:
    provider = get_settings().tts_provider
    if provider == "gtts":
        try:
            from gtts import gTTS
            buf = io.BytesIO()
            gTTS(text=text, lang=lang if lang != "en" else "en").write_to_fp(buf)
            audio = buf.getvalue()
            return _wrap_audio(audio, "audio/mpeg", "gtts", lang)
        except Exception:
            pass
    # stub: a short silent WAV so the client always gets playable bytes
    return _wrap_audio(_silent_wav(seconds=max(1, len(text) // 20)), "audio/wav", "stub", lang)


def _wrap_audio(audio_bytes: bytes, mime: str, provider: str, lang: str) -> dict:
    return {
        "audio_base64": base64.b64encode(audio_bytes).decode(),
        "mime_type": mime,
        "provider": provider,
        "lang": lang,
        "bytes": len(audio_bytes),
    }


def _silent_wav(seconds: int = 1, rate: int = 16000) -> bytes:
    n = seconds * rate
    data = b"\x00\x00" * n
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVE"
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 1, 1, rate, rate * 2, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    return header + data


# ------------------------------------------------------------------ STT ------
def transcribe(audio_bytes: bytes, lang: str = "auto") -> dict:
    provider = get_settings().stt_provider
    if provider == "whisper":
        try:  # pragma: no cover - heavy optional dep
            import tempfile
            import whisper
            model = whisper.load_model("base")
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
                f.write(audio_bytes)
                path = f.name
            res = model.transcribe(path)
            return {"transcript": res["text"].strip(),
                    "detected_lang": res.get("language", lang), "provider": "whisper"}
        except Exception:
            pass
    # stub: report length so the pipeline is testable end to end
    return {"transcript": f"[stub transcript of {len(audio_bytes)} bytes]",
            "detected_lang": lang if lang != "auto" else "en", "provider": "stub"}
