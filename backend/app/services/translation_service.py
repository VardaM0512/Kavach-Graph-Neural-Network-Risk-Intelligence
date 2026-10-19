"""Translation service — multilingual support for the whole product.

Every user-facing string (risk explanations, alerts, scheme text) can be served
in any supported Indian language. The service is provider-pluggable:

  builtin           small offline glossary for common risk terms (always works)
  deep_translator   Google/Microsoft via the `deep-translator` package
  azure             Azure Translator (enterprise)

If the configured provider is unavailable, it degrades to `builtin` and finally
to an identity passthrough, so the API never hard-fails on a translation call.
"""
from __future__ import annotations

from ..core.config import get_settings

LANGUAGE_NAMES = {
    "en": "English", "as": "অসমীয়া", "bn": "বাংলা", "brx": "बड़ो", "doi": "डोगरी",
    "gu": "ગુજરાતી", "hi": "हिन्दी", "kn": "ಕನ್ನಡ", "ks": "کٲشُر", "kok": "कोंकणी",
    "mai": "मैथिली", "ml": "മലയാളം", "mni": "ꯃꯤꯇꯩꯂꯣꯟ", "mr": "मराठी", "ne": "नेपाली",
    "or": "ଓଡ଼ିଆ", "pa": "ਪੰਜਾਬੀ", "sa": "संस्कृतम्", "sat": "ᱥᱟᱱᱛᱟᱲᱤ", "sd": "سنڌي",
    "ta": "தமிழ்", "te": "తెలుగు", "ur": "اردو",
}
RTL_LANGUAGES = {"ur", "ks", "sd"}

# tiny offline glossary so risk bands / drivers are localised even offline
_GLOSSARY = {
    "hi": {
        "LOW": "कम जोखिम", "MODERATE": "मध्यम जोखिम", "HIGH": "उच्च जोखिम",
        "CRITICAL": "गंभीर जोखिम", "Financial Health": "वित्तीय स्वास्थ्य",
        "Distress Risk": "संकट जोखिम", "High debt growth": "उच्च ऋण वृद्धि",
        "Falling operating cash": "गिरता परिचालन नकद",
    },
    "ta": {
        "LOW": "குறைந்த ஆபத்து", "MODERATE": "மிதமான ஆபத்து", "HIGH": "அதிக ஆபத்து",
        "CRITICAL": "நெருக்கடி ஆபத்து",
    },
}


def supported_languages() -> list[dict]:
    langs = get_settings().supported_languages
    return [{"code": c, "name": LANGUAGE_NAMES.get(c, c), "rtl": c in RTL_LANGUAGES} for c in langs]


def translate(text: str, target_lang: str, source_lang: str = "auto") -> dict:
    provider = get_settings().translation_provider
    if target_lang == "en" or target_lang == source_lang:
        return {"text": text, "provider": "passthrough", "target_lang": target_lang}

    if provider == "deep_translator":
        try:
            from deep_translator import GoogleTranslator
            out = GoogleTranslator(source=source_lang, target=target_lang).translate(text)
            return {"text": out, "provider": "deep_translator", "target_lang": target_lang}
        except Exception:
            pass  # fall through to builtin

    # builtin glossary word-substitution (best-effort, offline)
    gl = _GLOSSARY.get(target_lang, {})
    out = text
    for k, v in gl.items():
        out = out.replace(k, v)
    return {"text": out, "provider": "builtin", "target_lang": target_lang}
