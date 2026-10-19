"""Real-company ingestion: turn tickers, spreadsheets and annual-report PDFs into
the `analyze()` payload the risk engine already understands.

    fetch_ticker("RELIANCE")        -> NSE/BSE statements via Yahoo Finance
    parse_table(bytes, "x.xlsx")    -> many companies x fiscal years + relationships
    extract_pdf(bytes)              -> best-effort line-item extraction for review

All monetary values are normalised to INR crore. Nothing here is trusted
blindly: every path returns the numbers it found so the user can confirm them.
"""
from __future__ import annotations

import io
import math
import re

import pandas as pd

from kavach_ml.data.features import REQUIRED_FIELDS
from kavach_ml.data.synthetic import INDUSTRIES

CRORE = 1e7

# ----------------------------------------------------------------- sectors
_SECTOR_HINTS = [
    (r"software|it services|information technology|technology", "IT Services"),
    (r"pharma|drug|biotech|health", "Pharmaceuticals"),
    (r"household|personal products|food|beverage|tobacco|consumer defensive|packaged", "FMCG"),
    (r"auto", "Auto & Components"),
    (r"machinery|electrical equipment|industrial|engineering|aerospace|defen", "Capital Goods"),
    (r"steel|metal|mining|aluminium|aluminum|copper", "Steel & Metals"),
    (r"cement|building materials", "Cement"),
    (r"chemical|fertili|agro", "Chemicals"),
    (r"textile|apparel|garment", "Textiles & Apparel"),
    (r"utilit|power|electric|energy|oil|gas|refin", "Power & Utilities"),
    (r"construction|infrastructure|engineering & construction|epc", "Infrastructure & EPC"),
    (r"real estate|realty|reit", "Real Estate"),
    (r"telecom|communication|media|broadcast|entertainment", "Telecom & Media"),
    (r"logistic|shipping|freight|transport|airline|marine", "Logistics"),
    (r"retail|department|specialty stores|e-commerce|internet retail", "Retail"),
    (r"hotel|lodging|resort|travel|leisure|restaurant", "Hospitality"),
]


def map_sector(*texts: str | None) -> str | None:
    blob = " ".join(t for t in texts if t).lower()
    if not blob:
        return None
    for name in INDUSTRIES:
        if name.lower() in blob:
            return name
    for pat, name in _SECTOR_HINTS:
        if re.search(pat, blob):
            return name
    return None


# ------------------------------------------------------------------ ticker
def _get(df: pd.DataFrame, col, *names, default=None):
    for n in names:
        if n in df.index:
            v = df.at[n, col]
            if v is not None and not (isinstance(v, float) and math.isnan(v)):
                return float(v)
    return default


def fetch_ticker(symbol: str) -> dict:
    """Fetch annual statements for an Indian listed company (NSE first, then BSE)."""
    import yfinance as yf

    sym = symbol.strip().upper()
    tried = [sym] if "." in sym else [f"{sym}.NS", f"{sym}.BO"]
    for s in tried:
        t = yf.Ticker(s)
        try:
            fin, bs, cf = t.financials, t.balance_sheet, t.cashflow
        except Exception:
            continue
        if fin is None or fin.empty or bs is None or bs.empty:
            continue
        info = {}
        for _ in range(2):                    # Yahoo's info endpoint is flaky; retry once
            try:
                info = t.info or {}
            except Exception:
                info = {}
            if info.get("financialCurrency"):
                break
        currency = info.get("financialCurrency") or "INR"
        fx = _fx_series(currency)             # e.g. Infosys files in USD
        years = []
        for col in sorted(set(fin.columns) & set(bs.columns), reverse=True):
            c = col
            rev = _get(fin, c, "Total Revenue", "Operating Revenue")
            if rev is None:
                continue
            ebitda = _get(fin, c, "EBITDA", "Normalized EBITDA")
            if ebitda is None:
                ebit = _get(fin, c, "EBIT", "Operating Income", default=0.0)
                ebitda = ebit + _get(fin, c, "Reconciled Depreciation", default=0.0)
            cfc = c if (cf is not None and c in cf.columns) else None
            debt = _get(bs, c, "Total Debt", default=None)
            if debt is None:
                debt = _get(bs, c, "Long Term Debt", default=0.0) + _get(bs, c, "Current Debt", default=0.0)
            row = {
                "year": int(pd.Timestamp(c).year),
                "revenue": rev,
                "ebitda": ebitda,
                "net_profit": _get(fin, c, "Net Income", "Net Income Common Stockholders", default=0.0),
                "interest_expense": abs(_get(fin, c, "Interest Expense", "Interest Expense Non Operating", default=0.0)),
                "assets": _get(bs, c, "Total Assets", default=0.0),
                "debt": debt,
                "equity": _get(bs, c, "Stockholders Equity", "Common Stock Equity", "Total Equity Gross Minority Interest", default=0.0),
                "cash": _get(bs, c, "Cash And Cash Equivalents", "Cash Cash Equivalents And Short Term Investments", default=0.0),
                "current_assets": _get(bs, c, "Current Assets", default=0.0),
                "current_liabilities": _get(bs, c, "Current Liabilities", default=0.0),
                "inventory": _get(bs, c, "Inventory", default=0.0),
                "ocf": _get(cf, cfc, "Operating Cash Flow", default=0.0) if cfc is not None else 0.0,
                "capex": abs(_get(cf, cfc, "Capital Expenditure", "Purchase Of PPE", default=0.0)) if cfc is not None else 0.0,
            }
            rate = _fx_at(fx, pd.Timestamp(c)) if fx is not None else 1.0
            for k in REQUIRED_FIELDS:
                row[k] = round(row[k] * rate / CRORE, 2)
            if fx is not None:
                row["fx_rate"] = round(rate, 3)
            years.append(row)
        if not years:
            continue
        return {
            "symbol": s,
            "name": info.get("longName") or info.get("shortName") or sym,
            "sector": map_sector(info.get("industry"), info.get("sector")),
            "source_sector": " / ".join(x for x in (info.get("sector"), info.get("industry")) if x),
            "currency": currency,
            "converted_to_inr": currency != "INR",
            "years": years,
            "payload": years_to_payload(info.get("longName") or sym,
                                        map_sector(info.get("industry"), info.get("sector")), years),
        }
    raise LookupError(f"no annual statements found for {symbol}")


def _fx_series(currency: str):
    """Daily <currency>/INR closes, or None for INR."""
    if currency == "INR":
        return None
    import yfinance as yf
    h = yf.Ticker(f"{currency}INR=X").history(period="10y")
    if h is None or h.empty:
        raise LookupError(f"no {currency}/INR rate available")
    close = h["Close"]
    close.index = close.index.tz_localize(None)
    return close


def _fx_at(series, when: pd.Timestamp) -> float:
    """Rate on (or just before) the statement date."""
    s = series[series.index <= when]
    return float(s.iloc[-1] if len(s) else series.iloc[0])


def years_to_payload(name: str, sector: str | None, years: list[dict], **extra) -> dict:
    """Newest year -> `current`, the one before -> `previous`, older -> `earlier`."""
    ys = sorted(years, key=lambda r: r["year"], reverse=True)
    cur = ys[0]
    payload = {
        "name": name, "sector": sector, "fiscal_year": cur["year"],
        "current": {k: float(cur.get(k) or 0) for k in REQUIRED_FIELDS},
        "earlier": [{"year": r["year"], "revenue": r.get("revenue"), "ebitda": r.get("ebitda")} for r in ys[2:]],
        "counterparties": [],
    }
    if len(ys) > 1:
        payload["previous"] = {"year": ys[1]["year"], "revenue": ys[1].get("revenue"), "ebitda": ys[1].get("ebitda")}
    payload.update(extra)
    return payload


# ------------------------------------------------------------ spreadsheets
_ALIASES = {
    "company": ["company", "company name", "name", "entity"],
    "fiscal_year": ["fiscal_year", "fiscal year", "year", "fy"],
    "sector": ["sector", "industry"],
    "revenue": ["revenue", "revenue from operations", "sales", "total revenue", "turnover"],
    "ebitda": ["ebitda", "operating profit", "pbdit"],
    "net_profit": ["net_profit", "net profit", "pat", "profit after tax", "net income"],
    "interest_expense": ["interest_expense", "interest", "finance costs", "finance cost", "interest expense"],
    "assets": ["assets", "total assets"],
    "debt": ["debt", "total debt", "borrowings", "total borrowings"],
    "equity": ["equity", "net worth", "shareholders equity", "total equity"],
    "cash": ["cash", "cash and cash equivalents", "cash & equivalents"],
    "current_assets": ["current_assets", "current assets", "total current assets"],
    "current_liabilities": ["current_liabilities", "current liabilities", "total current liabilities"],
    "inventory": ["inventory", "inventories", "stock"],
    "ocf": ["ocf", "operating cash flow", "cash from operations", "cfo"],
    "capex": ["capex", "capital expenditure", "purchase of ppe"],
    "promoter_pledge": ["promoter_pledge", "promoter pledge", "pledge", "pledged %"],
    "defaulted": ["defaulted", "default", "label", "distress"],
    # relationship sheet
    "counterparty": ["counterparty", "counterparty name", "partner"],
    "relation": ["relation", "relationship", "type"],
    "share": ["share", "share %", "dependency", "weight"],
    "health": ["health", "status"],
}
_UNIT = {"crore": 1.0, "cr": 1.0, "lakh": 0.01, "lakhs": 0.01, "million": 0.1, "mn": 0.1, "inr": 1e-7, "rupees": 1e-7}


def _norm_cols(df: pd.DataFrame) -> pd.DataFrame:
    lookup = {a: k for k, al in _ALIASES.items() for a in al}
    df = df.rename(columns=lambda c: lookup.get(re.sub(r"[_\s]+", " ", str(c).strip().lower()).replace(" ", " "),
                                                 lookup.get(str(c).strip().lower(), str(c).strip().lower())))
    return df


def _num(v) -> float | None:
    if v is None or (isinstance(v, float) and math.isnan(v)):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    s = str(v).strip().replace(",", "").replace("₹", "")
    neg = s.startswith("(") and s.endswith(")")
    s = s.strip("()")
    try:
        x = float(s.rstrip("%"))
    except ValueError:
        return None
    return -x if neg else x


def parse_table(data: bytes, filename: str, unit: str = "crore") -> dict:
    """Parse CSV / Excel into companies (by fiscal year) and relationships.

    Sheet 1 (or the CSV): one row per company per fiscal year.
    Sheet 2 (optional, or a sheet named 'relationships'): company, counterparty,
    relation, share (% or 0..1), health.
    """
    scale = _UNIT.get(unit.lower(), 1.0)
    name = filename.lower()
    if name.endswith((".xlsx", ".xlsm", ".xls")):
        sheets = pd.read_excel(io.BytesIO(data), sheet_name=None)
        keys = list(sheets)
        fin_key = next((k for k in keys if "rel" not in k.lower()), keys[0])
        rel_key = next((k for k in keys if "rel" in k.lower() or "counter" in k.lower()), None)
        fin = sheets[fin_key]
        rel = sheets[rel_key] if rel_key else None
    else:
        fin, rel = pd.read_csv(io.BytesIO(data)), None
    fin = _norm_cols(fin)
    missing = [c for c in ("company", "revenue", "ebitda") if c not in fin.columns]
    if missing:
        raise ValueError(f"missing columns: {', '.join(missing)}")
    if "fiscal_year" not in fin.columns:
        fin["fiscal_year"] = 2025
    warnings = []
    companies: dict[str, dict] = {}
    for _, r in fin.iterrows():
        comp = str(r["company"]).strip()
        if not comp or comp.lower() == "nan":
            continue
        try:
            fy = int(_num(r["fiscal_year"]))
        except (TypeError, ValueError):
            warnings.append(f"{comp}: bad fiscal year {r['fiscal_year']!r}")
            continue
        row = {"year": fy}
        for k in REQUIRED_FIELDS:
            v = _num(r.get(k))
            row[k] = (v or 0.0) * scale
            if v is None and k in ("revenue", "ebitda"):
                warnings.append(f"{comp} FY{fy}: {k} missing")
        c = companies.setdefault(comp, {"name": comp, "years": [], "sector": None, "promoter_pledge": 0.0, "defaulted": None})
        sec = r.get("sector")
        if isinstance(sec, str) and sec.strip():
            c["sector"] = map_sector(sec) or c["sector"]
        pl = _num(r.get("promoter_pledge"))
        if pl is not None:
            c["promoter_pledge"] = pl / 100 if pl > 1 else pl
        d = _num(r.get("defaulted"))
        if d is not None:
            c["defaulted"] = int(d > 0)
        c["years"].append(row)
    relationships = []
    if rel is not None:
        rel = _norm_cols(rel)
        for _, r in rel.iterrows():
            comp, cp = str(r.get("company", "")).strip(), str(r.get("counterparty", "")).strip()
            if not comp or not cp or comp.lower() == "nan":
                continue
            share = _num(r.get("share")) or 0.0
            relationships.append({
                "company": comp, "counterparty": cp,
                "relation": str(r.get("relation", "customer")).strip().lower(),
                "share": share / 100 if share > 1 else share,
                "health": str(r.get("health", "stable")).strip().lower() if isinstance(r.get("health"), str) else "stable",
            })
    return {"companies": list(companies.values()), "relationships": relationships, "warnings": warnings}


TEMPLATE_COLUMNS = ["company", "fiscal_year", "sector", *REQUIRED_FIELDS, "promoter_pledge", "defaulted"]


def template_csv() -> str:
    ex = [
        ["Example Steel Ltd", 2025, "Steel & Metals", 5200, 760, 180, 210, 8100, 3100, 2900, 240, 2600, 2200, 900, 610, 420, 12, ""],
        ["Example Steel Ltd", 2024, "Steel & Metals", 5600, 910, 320, 190, 7900, 2800, 2750, 300, 2700, 2100, 950, 720, 510, 12, ""],
    ]
    out = io.StringIO()
    pd.DataFrame(ex, columns=TEMPLATE_COLUMNS).to_csv(out, index=False)
    return out.getvalue()


# --------------------------------------------------------------------- PDF
_PDF_LINES = {
    "revenue": [r"revenue from operations", r"total revenue", r"net sales", r"income from operations"],
    "net_profit": [r"profit for the (?:year|period)", r"net profit after tax", r"profit after tax"],
    "interest_expense": [r"finance costs?", r"interest expense"],
    "assets": [r"total assets"],
    "equity": [r"total equity", r"equity attributable to owners", r"net worth"],
    "cash": [r"cash and cash equivalents"],
    "current_assets": [r"total current assets"],
    "current_liabilities": [r"total current liabilities"],
    "inventory": [r"inventories"],
    "ocf": [r"net cash (?:generated )?(?:from|used in) operating activities", r"net cash flow from operating"],
    "capex": [r"(?:purchase|acquisition) of property,? plant and equipment", r"capital expenditure"],
    "depreciation": [r"depreciation and amorti[sz]ation expense", r"depreciation"],
    "borrow_nc": [r"non-current borrowings", r"long[- ]term borrowings", r"^\s*borrowings"],
    "borrow_c": [r"(?<!non-)(?<!non )current borrowings", r"short[- ]term borrowings"],
    "pbt": [r"profit before tax"],
}
_NUM_RE = re.compile(r"\(?-?[\d,]+\.?\d*\)?")


def extract_pdf(data: bytes, max_pages: int = 60) -> dict:
    """Best-effort extraction of the 13 statement fields from an annual report.

    Scans text lines for standard Ind AS line items and takes the first number
    on the line (the current year column). Returns found values, the matched
    line for each (so the user can verify), the detected unit and gaps.
    """
    import pdfplumber

    found: dict[str, float] = {}
    evidence: dict[str, str] = {}
    unit_scale, unit_label = 1.0, "crore (assumed)"
    with pdfplumber.open(io.BytesIO(data)) as pdf:
        for page in pdf.pages[:max_pages]:
            text = page.extract_text() or ""
            low = text.lower()
            if "unit_found" not in evidence:
                m = re.search(r"(?:₹|rs\.?|inr)\s*(?:in\s*)?(crores?|lakhs?|millions?)", low)
                if m:
                    word = m.group(1)
                    unit_scale = 1.0 if word.startswith("crore") else 0.01 if word.startswith("lakh") else 0.1
                    unit_label = word
                    evidence["unit_found"] = m.group(0)
            for line in text.splitlines():
                l = line.lower().strip()
                for field, pats in _PDF_LINES.items():
                    if field in found:
                        continue
                    if any(re.search(p, l) for p in pats):
                        nums = [n for n in _NUM_RE.findall(line) if re.search(r"\d", n)]
                        # skip note references like "21" or years like "2025"
                        vals = [_num(n) for n in nums if len(n.replace(",", "").strip("()-")) >= 3
                                and not re.fullmatch(r"20\d\d", n.strip())]
                        vals = [v for v in vals if v is not None]
                        if vals:
                            found[field] = vals[0] * unit_scale
                            evidence[field] = line.strip()[:160]
    current = {k: round(found.get(k, 0.0), 2) for k in REQUIRED_FIELDS if k in found}
    if "capex" in current:                       # shown in brackets as a cash outflow
        current["capex"] = abs(current["capex"])
    if "borrow_nc" in found or "borrow_c" in found:
        current["debt"] = round(found.get("borrow_nc", 0.0) + found.get("borrow_c", 0.0), 2)
    if "pbt" in found and "interest_expense" in found:
        current["ebitda"] = round(found["pbt"] + found["interest_expense"] + found.get("depreciation", 0.0), 2)
    missing = [k for k in REQUIRED_FIELDS if k not in current]
    evidence.pop("unit_found", None)
    return {"current": current, "evidence": evidence, "unit": unit_label, "missing": missing}
