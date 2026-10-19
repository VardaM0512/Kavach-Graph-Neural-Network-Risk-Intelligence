"""Ask Kavach — natural-language query understanding over the risk engine.

Turns a typed or spoken question into a structured answer the app can render
as cards and read aloud in the user's language. Intents:

  company_risk   "how risky is Aravalli Steels"
  compare        "compare Aravalli Steels and Kalinga Power"
  scenario       "what if Aravalli Steels' revenue falls 25% and rates rise 150 bps"
  contagion      "what happens if Kalinga Power defaults"
  exposure       "who does Aravalli Steels depend on"
  top_risk       "riskiest cement companies"
  sector         "how is real estate doing"
  overview       "give me the market summary"

Answers are returned as data plus an English sentence; the client renders the
sentence from localised templates so the reply matches the UI language.
"""
from __future__ import annotations

import re

from kavach_ml.config import band_for

SECTOR_KEYWORDS = [
    (r"\bit services\b|\bsoftware\b|\binfotech\b|\btech(nology)? (firms|companies|sector)\b", "IT Services"),
    (r"\bpharma|\bdrug|\bhealthcare\b", "Pharmaceuticals"),
    (r"\bfmcg\b|\bconsumer goods\b|\bstaples\b", "FMCG"),
    (r"\bauto(mobile|motive)?s?\b|\bcomponents\b", "Auto & Components"),
    (r"\bcapital goods\b|\bengineering\b|\bmachinery\b", "Capital Goods"),
    (r"\bsteel|\bmetal", "Steel & Metals"),
    (r"\bcement", "Cement"),
    (r"\bchemical", "Chemicals"),
    (r"\btextile|\bapparel|\bgarment", "Textiles & Apparel"),
    (r"\bpower\b|\butilit|\benergy\b|\belectricity\b", "Power & Utilities"),
    (r"\binfra|\bepc\b|\bconstruction", "Infrastructure & EPC"),
    (r"\breal estate\b|\brealty\b|\bhousing\b|\bproperty\b", "Real Estate"),
    (r"\btelecom|\bmedia\b|\bbroadband\b", "Telecom & Media"),
    (r"\blogistic|\bfreight\b|\bshipping\b", "Logistics"),
    (r"\bretail", "Retail"),
    (r"\bhotel|\bhospitality\b|\btourism\b", "Hospitality"),
]

_WORDS = {
    "compare": r"\bcompare\b|\bvs\.?\b|\bversus\b|तुलना|ಹೋಲಿಸಿ|ஒப்பிடு",
    "what_if": r"\bwhat if\b|\bif\b|\bsuppose\b|\bscenario\b|\bstress\b|अगर|यदि",
    "fail": r"\bfails?\b|\bdefaults?\b|\bcollapses?\b|\bgoes bust\b|\bbankrupt|\binsolven|डूब|दिवालिया",
    "top": r"\briskiest\b|\bmost risky\b|\bhighest risk\b|\bworst\b|\btop\b|\bweakest\b|सबसे",
    "exposure": r"\bdepend|\bsuppliers?\b|\bcustomers?\b|\bexposure\b|\bnetwork\b|\bcounterpart|\bconnected\b",
    "overview": r"\bmarket\b|\boverall\b|\buniverse\b|\bsummary\b|\boverview\b|\beconomy\b",
}


def _has(key: str, t: str) -> bool:
    return re.search(_WORDS[key], t, re.I) is not None


def _sector(t: str) -> str | None:
    for pat, name in SECTOR_KEYWORDS:
        if re.search(pat, t, re.I):
            return name
    return None


def _percent_near(t: str, words: str) -> float | None:
    m = re.search(rf"(?:{words})[^0-9%]{{0,25}}?(-?\d+(?:\.\d+)?)\s*(%|percent|per cent)", t, re.I) or \
        re.search(rf"(-?\d+(?:\.\d+)?)\s*(%|percent|per cent)[^.]{{0,25}}?(?:{words})", t, re.I)
    return float(m.group(1)) if m else None


def _parse_scenario(t: str) -> dict:
    out = {}
    rev = _percent_near(t, r"revenue|sales|turnover|demand|topline|आय|बिक्री")
    if rev is not None:
        down = re.search(r"fall|drop|declin|down|lose|shrink|cut|घट|कम", t, re.I)
        out["revenue_change"] = -abs(rev) / 100 if down or rev < 0 else abs(rev) / 100
    m = re.search(r"(\d+(?:\.\d+)?)\s*(bps|basis points?)", t, re.I)
    if m:
        out["interest_rate_change"] = float(m.group(1)) / 10000
    else:
        r = _percent_near(t, r"rates?|interest|repo|ब्याज")
        if r is not None:
            out["interest_rate_change"] = abs(r) / 100 if abs(r) < 10 else abs(r) / 10000
    if re.search(r"supplier", t, re.I) and _has("fail", t):
        out["supplier_failure"] = True
    if re.search(r"(lose|loses|lost).{0,20}customer|customer.{0,20}(leaves|lost|defaults)", t, re.I):
        out["customer_loss"] = True
    return out


def _all_companies(engine, t: str) -> list[str]:
    parts = re.split(r"\bvs\.?\b|\bversus\b|\band\b|,|\bwith\b|और", t, flags=re.I)
    found = []
    for p in parts:
        cid = engine.resolve_company(p)
        if cid and cid not in found:
            found.append(cid)
    return found


def answer(engine, text: str) -> dict:
    t = text.strip()
    if not t:
        return {"intent": "help", "answer": "Ask me about any company, sector or scenario."}
    sector = _sector(t)
    companies = _all_companies(engine, t)
    cid = companies[0] if companies else None

    if _has("compare", t) and len(companies) >= 2:
        cards = [engine.company_card(c) for c in companies[:3]]
        riskiest = max(cards, key=lambda c: c["distress_probability"])
        return {"intent": "compare", "companies": cards,
                "data": {c["company_id"]: engine.peer_comparison(c["company_id"])["company"] for c in cards},
                "answer": f"{riskiest['name']} carries the higher default risk at "
                          f"{riskiest['distress_probability']:.1%} ({riskiest['implied_rating']})."}

    if cid and _has("fail", t) and not re.search(r"supplier", t, re.I):
        sim = engine.simulate_failure(cid)
        return {"intent": "contagion", "company": engine.company_card(cid),
                "data": {k: sim[k] for k in ("estimated_network_impact", "affected_count",
                                             "secondary_defaults", "debt_at_risk_cr")}
                        | {"top": sim["affected"][:5]},
                "answer": f"If {sim['failing_name']} defaults, {sim['affected_count']} companies see higher risk "
                          f"and {sim['secondary_defaults']} could follow it into default."}

    if cid and (_has("what_if", t) or re.search(r"%|bps", t)):
        shocks = _parse_scenario(t)
        if shocks:
            sc = engine.scenario(cid, **shocks)
            return {"intent": "scenario", "company": engine.company_card(cid), "data": sc,
                    "answer": f"Under that scenario {engine.company_card(cid)['name']}'s default probability moves "
                              f"from {sc['current_risk']:.1%} to {sc['scenario_risk']:.1%} "
                              f"({sc['current_rating']} to {sc['scenario_rating']})."}

    if cid and _has("exposure", t):
        ct = engine.contagion(cid)
        top = ct["top_exposures"][:3]
        names = ", ".join(x.get("name", x["neighbour_id"]) for x in top) or "no major counterparties"
        return {"intent": "exposure", "company": engine.company_card(cid), "data": ct,
                "answer": f"Its network adds {ct['network_uplift'] * 100:+.1f} points of risk. "
                          f"Biggest exposures: {names}."}

    if cid:
        card = engine.company_card(cid)
        pred = engine.predict(cid)
        ex = engine.explain(cid)
        top = ex["feature_drivers"][0] if ex["feature_drivers"] else None
        return {"intent": "company_risk", "company": card,
                "data": {"multi_horizon": pred["multi_horizon"], "top_driver": top,
                         "contagion": pred["network_contagion"]},
                "answer": f"{card['name']} has a {card['distress_probability']:.1%} probability of default over "
                          f"12 months, an implied rating of {card['implied_rating']} ({card['risk_band']} risk)."}

    if _has("top", t) or (sector and re.search(r"risk", t, re.I)):
        _, rows = engine.list_companies(limit=5, sector=sector, sort="risk")
        scope = sector or "the universe"
        return {"intent": "top_risk", "sector": sector, "companies": rows,
                "answer": f"The riskiest names in {scope} are led by {rows[0]['name']} at "
                          f"{rows[0]['distress_probability']:.1%}." if rows else "No companies found."}

    if sector:
        s = next(x for x in engine.sectors() if x["industry"] == sector)
        direction = "rising" if s["pd_change"] > 0.002 else "easing" if s["pd_change"] < -0.002 else "flat"
        return {"intent": "sector", "sector": sector, "data": s,
                "answer": f"{sector}: average default probability {s['avg_pd']:.1%}, {direction} versus last year; "
                          f"{s['high_share']:.0%} of companies are high risk."}

    if _has("overview", t):
        ov = engine.overview()
        return {"intent": "overview", "data": {k: ov[k] for k in ("mean_pd", "expected_defaults", "band_counts")},
                "answer": f"Across {ov['universe']['companies']} companies the average default probability is "
                          f"{ov['mean_pd']:.1%}; about {ov['expected_defaults']:.0f} defaults are expected in 12 months."}

    hits = engine.search(t, limit=3)
    return {"intent": "help", "companies": hits,
            "answer": "I couldn't pin that down. Try a company name, a sector, or a what-if."}


__all__ = ["answer", "band_for"]
