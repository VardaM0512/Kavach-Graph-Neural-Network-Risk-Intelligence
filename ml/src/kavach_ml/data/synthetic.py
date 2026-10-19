"""Synthetic Indian corporate economy — a statistically realistic training universe.

We do not ship a licensed financial dataset, so the model is trained on a
*simulated* economy that is built to look like the real one in the ways that
matter for credit risk:

  * 16 Indian sectors, each with its own operating profile (margins, asset
    intensity, leverage, working-capital cycle, capex intensity, cyclicality)
    calibrated to typical ranges of listed Indian mid/large caps.
  * Heavy-tailed firm sizes (log-normal revenue in Rs crore, median ~Rs 900 cr).
  * Full, internally consistent financial statements: P&L, balance sheet and
    cash-flow are derived from each other, not drawn independently.
  * Five fiscal years (FY21-FY25) driven by a shared macro path: the FY21 Covid
    shock, the FY22 rebound, the FY23-FY24 rate-hike cycle (+250 bps), and
    sector-specific cycles. Firms carry AR(1) idiosyncratic shocks, margins
    mean-revert, and loss-making firms fund themselves with fresh debt.
  * A supply-chain graph that follows a sector input-output matrix (steel ->
    auto and capital goods, cement -> infra and real estate, ...), with
    preferential attachment so large suppliers become hubs, plus Indian-style
    business groups (holding company -> subsidiaries, intra-group guarantees).
  * Distress (default / IBC admission / downgrade to D within 12 months) is
    drawn from a hazard model on fundamentals, then a *cascade* runs: losing a
    customer that is 30% of your revenue, or a parent that guarantees your debt,
    can push an otherwise healthy firm over. Base rate ~8%, close to the Indian
    corporate default experience across a cycle.

The model only ever sees scale-free ratios and trends, which is why a model
trained here can be applied to a real company's reported financials (see
`RiskEngine.analyze`). All entities and names are fictional.

Returned object: an `Economy` with
  companies : one row per company (latest-year statements + metadata + label)
  edges     : [src, dst, type, weight]  (weight = dependency share in 0..1)
  history   : [company_id, year, <statement fields>] for FY21..FY25
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from ..config import SyntheticConfig, EDGE_TYPES


@dataclass
class Economy:
    companies: pd.DataFrame
    edges: pd.DataFrame
    history: pd.DataFrame
    macro: pd.DataFrame | None = None

    def summary(self) -> dict:
        return {
            "n_companies": len(self.companies),
            "n_edges": len(self.edges),
            "distress_rate": round(float(self.companies["distress"].mean()), 4),
            "edge_types": self.edges["type"].value_counts().to_dict(),
            "n_sectors": int(self.companies["industry"].nunique()),
            "n_groups": int(self.companies["group"].nunique()),
        }


# ---------------------------------------------------------------------------
# Sector operating profiles
#   margin   : median EBITDA margin           asset_turn : revenue / total assets
#   de       : median debt / equity           cr         : median current ratio
#   capex    : capex / revenue                beta       : sensitivity to GDP cycle
#   rate_beta: sensitivity to interest rates  growth     : long-run nominal growth
# ---------------------------------------------------------------------------
SECTORS = {
    "IT Services":          dict(margin=0.22, asset_turn=1.05, de=0.08, cr=2.6, capex=0.03, beta=0.6, rate_beta=0.2, growth=0.11, weight=0.06),
    "Pharmaceuticals":      dict(margin=0.21, asset_turn=0.80, de=0.25, cr=2.2, capex=0.06, beta=0.3, rate_beta=0.3, growth=0.10, weight=0.07),
    "FMCG":                 dict(margin=0.17, asset_turn=1.45, de=0.15, cr=1.4, capex=0.04, beta=0.3, rate_beta=0.2, growth=0.09, weight=0.06),
    "Auto & Components":    dict(margin=0.12, asset_turn=1.20, de=0.55, cr=1.3, capex=0.06, beta=1.4, rate_beta=0.9, growth=0.09, weight=0.09),
    "Capital Goods":        dict(margin=0.11, asset_turn=0.85, de=0.50, cr=1.4, capex=0.04, beta=1.3, rate_beta=0.8, growth=0.10, weight=0.08),
    "Steel & Metals":       dict(margin=0.14, asset_turn=0.75, de=0.95, cr=1.1, capex=0.09, beta=1.6, rate_beta=1.0, growth=0.08, weight=0.07),
    "Cement":               dict(margin=0.18, asset_turn=0.65, de=0.60, cr=1.1, capex=0.10, beta=1.2, rate_beta=0.9, growth=0.08, weight=0.04),
    "Chemicals":            dict(margin=0.16, asset_turn=0.90, de=0.40, cr=1.7, capex=0.07, beta=1.0, rate_beta=0.6, growth=0.10, weight=0.07),
    "Textiles & Apparel":   dict(margin=0.10, asset_turn=1.00, de=0.85, cr=1.3, capex=0.05, beta=1.1, rate_beta=1.0, growth=0.06, weight=0.06),
    "Power & Utilities":    dict(margin=0.30, asset_turn=0.30, de=1.60, cr=1.0, capex=0.14, beta=0.5, rate_beta=1.4, growth=0.07, weight=0.05),
    "Infrastructure & EPC": dict(margin=0.12, asset_turn=0.55, de=1.30, cr=1.2, capex=0.05, beta=1.3, rate_beta=1.5, growth=0.09, weight=0.07),
    "Real Estate":          dict(margin=0.24, asset_turn=0.22, de=1.10, cr=1.6, capex=0.02, beta=1.5, rate_beta=1.8, growth=0.08, weight=0.05),
    "Telecom & Media":      dict(margin=0.28, asset_turn=0.35, de=1.80, cr=0.8, capex=0.18, beta=0.7, rate_beta=1.2, growth=0.07, weight=0.03),
    "Logistics":            dict(margin=0.13, asset_turn=1.10, de=0.70, cr=1.2, capex=0.07, beta=1.1, rate_beta=0.8, growth=0.10, weight=0.05),
    "Retail":               dict(margin=0.09, asset_turn=1.60, de=0.60, cr=1.2, capex=0.05, beta=1.0, rate_beta=0.7, growth=0.12, weight=0.05),
    "Hospitality":          dict(margin=0.20, asset_turn=0.40, de=1.20, cr=0.9, capex=0.08, beta=1.7, rate_beta=1.1, growth=0.08, weight=0.03),
}
INDUSTRIES = list(SECTORS)

# Input-output: which sectors supply which (supplier sector -> customer sectors)
SUPPLY_LINKS = {
    "Steel & Metals": ["Auto & Components", "Capital Goods", "Infrastructure & EPC", "Real Estate", "Power & Utilities"],
    "Cement": ["Infrastructure & EPC", "Real Estate"],
    "Chemicals": ["Pharmaceuticals", "Textiles & Apparel", "FMCG", "Auto & Components"],
    "Capital Goods": ["Power & Utilities", "Infrastructure & EPC", "Steel & Metals", "Cement", "Auto & Components"],
    "Auto & Components": ["Logistics", "Auto & Components"],
    "Power & Utilities": ["Steel & Metals", "Cement", "Chemicals", "Textiles & Apparel", "Real Estate"],
    "Logistics": ["FMCG", "Retail", "Auto & Components", "Pharmaceuticals", "Steel & Metals"],
    "IT Services": ["Retail", "FMCG", "Telecom & Media", "Auto & Components", "Hospitality", "Logistics"],
    "Textiles & Apparel": ["Retail"],
    "FMCG": ["Retail", "Hospitality"],
    "Pharmaceuticals": ["Retail"],
    "Infrastructure & EPC": ["Power & Utilities", "Real Estate", "Telecom & Media"],
    "Telecom & Media": ["IT Services", "Retail", "FMCG"],
    "Real Estate": ["Retail", "Hospitality", "IT Services"],
    "Retail": ["FMCG"],
    "Hospitality": ["IT Services"],
}

YEARS = (2021, 2022, 2023, 2024, 2025)            # fiscal years FY21..FY25
# macro path: real GDP growth, inflation, repo-rate change vs. FY20 baseline
MACRO = pd.DataFrame({
    "year": YEARS,
    "gdp_growth": [-0.058, 0.097, 0.070, 0.082, 0.065],
    "inflation": [0.062, 0.055, 0.067, 0.054, 0.046],
    "repo_rate": [0.040, 0.040, 0.0625, 0.065, 0.0625],
})
MACRO["rate_delta"] = MACRO["repo_rate"] - 0.0515     # vs. pre-Covid repo

# fictional name parts (coined so that combinations are not real listed firms)
_PLACE = ["Aravalli", "Sahyadri", "Vindhyan", "Narmadeya", "Konkanam", "Shivalika", "Kaveriya",
          "Tapovan", "Godavaram", "Malabaric", "Deccanica", "Gangetic", "Nilgiris", "Satpura",
          "Brahmaputra", "Chambal", "Mahanadi", "Sabarmati", "Kosala", "Avanti", "Magadh",
          "Kalinga", "Vidarbha", "Saurashtra", "Mewar", "Kutchi", "Baroda", "Indus", "Pallava",
          "Chola", "Hoysala", "Rashtra", "Vijaya", "Amaravati", "Ujjayini", "Dwaraka", "Kanchi",
          "Pataliputra", "Tamralipta", "Suvarna", "Vasundhara", "Prithvi", "Akash", "Agneya",
          "Varuna", "Meghna", "Teesta", "Pennar", "Krishnaraj", "Tungabhadra"]
_COIN = ["vat", "dhan", "jyoti", "shakti", "prabha", "setu", "dhara", "kiran", "deep", "veer",
         "sagar", "nidhi", "mitra", "tej", "ratna", "gram", "kul", "path"]
_SUFFIX = {
    "IT Services": ["Infotech", "Digital Systems", "Softlabs", "Technologies"],
    "Pharmaceuticals": ["Lifesciences", "Pharma", "Remedies", "Biologics"],
    "FMCG": ["Consumer Products", "Foods", "Naturals", "Home Care"],
    "Auto & Components": ["Autocomp", "Motors", "Forgings", "Axles"],
    "Capital Goods": ["Engineering", "Heavy Industries", "Electricals", "Machines"],
    "Steel & Metals": ["Steels", "Alloys", "Ispat", "Metalworks"],
    "Cement": ["Cements", "Building Materials"],
    "Chemicals": ["Chemicals", "Polychem", "Specialty Chem", "Organics"],
    "Textiles & Apparel": ["Textiles", "Spinners", "Fabrics", "Apparels"],
    "Power & Utilities": ["Power", "Energy", "Urja", "Renewables"],
    "Infrastructure & EPC": ["Infraprojects", "Constructions", "Buildcon", "EPC"],
    "Real Estate": ["Estates", "Realty", "Developers", "Habitat"],
    "Telecom & Media": ["Telelinks", "Broadband", "Media Networks"],
    "Logistics": ["Logistics", "Freight", "Shipping", "Cargo Movers"],
    "Retail": ["Retail", "Mart", "Bazaar", "Stores"],
    "Hospitality": ["Hotels", "Resorts", "Hospitality"],
}


def _sigmoid(x):
    return 1.0 / (1.0 + np.exp(-x))


def _names(industry: np.ndarray, rng) -> list[str]:
    used, out = set(), []
    for ind in industry:
        for _ in range(50):
            base = rng.choice(_PLACE)
            if rng.uniform() < 0.35:
                base = base[: max(4, len(base) - 2)] + rng.choice(_COIN)
            name = f"{base} {rng.choice(_SUFFIX[ind])} Ltd"
            if name not in used:
                break
        used.add(name)
        out.append(name)
    return out


def generate_economy(cfg: SyntheticConfig | None = None) -> Economy:
    cfg = cfg or SyntheticConfig()
    rng = np.random.default_rng(cfg.seed)
    n = cfg.n_companies

    w = np.array([SECTORS[s]["weight"] for s in INDUSTRIES])
    industry = rng.choice(INDUSTRIES, size=n, p=w / w.sum())
    prof = pd.DataFrame([SECTORS[s] for s in industry])

    # ---- firm-level persistent traits ------------------------------------
    size0 = np.exp(rng.normal(np.log(650), 1.15, size=n))           # FY21 revenue, Rs cr
    quality = rng.normal(0, 1, size=n)                              # management / moat
    margin_star = np.clip(prof["margin"] * np.exp(rng.normal(0, 0.35, n)) + 0.015 * quality, -0.05, 0.6)
    asset_turn = prof["asset_turn"] * np.exp(rng.normal(0, 0.25, n))
    de0 = prof["de"] * np.exp(rng.normal(0, 0.55, n) - 0.15 * quality)
    cr_star = prof["cr"] * np.exp(rng.normal(0, 0.22, n) + 0.05 * quality)
    capex_int = prof["capex"] * np.exp(rng.normal(0, 0.3, n))
    growth_star = prof["growth"] + 0.025 * quality + rng.normal(0, 0.03, n)
    promoter_pledge = np.clip(rng.beta(1.2, 6, n) - 0.05 * quality, 0, 0.9)   # share of promoter stake pledged
    cust_conc = rng.beta(1.6, 4.0, n)                               # top-customer share of revenue (pre-graph)

    # ---- simulate FY21..FY25 ---------------------------------------------
    hist_rows = []
    rev = size0.copy()
    debt = None
    shock = np.zeros(n)
    margin = margin_star.copy()
    cash_buf = None
    equity = None
    for t, year in enumerate(YEARS):
        m = MACRO.iloc[t]
        shock = 0.45 * shock + rng.normal(0, 0.12, n)                   # AR(1) idiosyncratic
        cyc = prof["beta"].values * (m["gdp_growth"] - 0.065)
        g = growth_star - 0.065 + m["gdp_growth"] + m["inflation"] - 0.05 + cyc + shock if t else 0
        rev = rev * (1 + np.clip(g, -0.6, 1.0)) if t else rev
        rate_hit = prof["rate_beta"].values * m["rate_delta"] * 0.6
        margin = 0.6 * margin + 0.4 * margin_star + 0.5 * cyc - rate_hit + rng.normal(0, 0.02, n)
        margin = np.clip(margin, -0.35, 0.65)

        assets = rev / asset_turn
        if debt is None:
            equity = assets / (1 + de0 + 0.35)
            debt = equity * de0
            cash_buf = assets * np.clip(rng.normal(0.07, 0.04, n), 0.005, 0.3)
        ebitda = rev * margin
        dep = assets * rng.uniform(0.025, 0.045, n)
        rate = np.clip(m["repo_rate"] + 0.03 + 0.012 * np.log1p(debt / np.maximum(equity, 1)) + rng.normal(0, 0.008, n), 0.06, 0.22)
        interest = debt * rate
        pbt = ebitda - dep - interest
        tax = np.where(pbt > 0, pbt * 0.252, 0.0)
        pat = pbt - tax
        capex = rev * capex_int * (1 + 0.6 * (g if t else 0))
        delta_wc = rev * 0.12 * (g if t else 0) + rng.normal(0, 0.01, n) * rev
        ocf = ebitda - tax - delta_wc
        fcf = ocf - capex - interest
        # financing: negative FCF is funded first by cash, then by new debt;
        # positive FCF repays debt / builds cash
        draw = np.minimum(np.maximum(-fcf, 0), cash_buf * 0.6)
        new_debt = np.maximum(-fcf - draw, 0)
        repay = np.where(fcf > 0, fcf * 0.55, 0)
        debt = np.maximum(debt + new_debt - np.minimum(repay, debt * 0.15), 0)
        cash_buf = np.maximum(cash_buf - draw + np.where(fcf > 0, fcf * 0.45, 0), assets * 0.004)
        equity = np.maximum(equity + pat - np.where(pat > 0, pat * 0.2, 0), assets * 0.02)  # 20% payout
        cur_liab = rev * np.clip(rng.normal(0.16, 0.04, n), 0.05, 0.4) + debt * 0.18
        cur_assets = cur_liab * np.clip(cr_star * (1 + 0.8 * np.clip(margin - margin_star, -0.3, 0.3)) + rng.normal(0, 0.08, n), 0.25, 6)
        inventory = cur_assets * rng.uniform(0.15, 0.45, n)
        total_assets = np.maximum(assets, equity + debt + cur_liab * 0.5)
        hist_rows.append(pd.DataFrame({
            "company_id": [f"C{i:04d}" for i in range(n)], "year": year,
            "revenue": rev, "ebitda": ebitda, "depreciation": dep, "interest_expense": interest,
            "net_profit": pat, "assets": total_assets, "debt": debt, "equity": equity,
            "cash": cash_buf, "current_assets": cur_assets, "current_liabilities": cur_liab,
            "inventory": inventory, "ocf": ocf, "capex": capex, "fcf": ocf - capex,
        }))
    history = pd.concat(hist_rows, ignore_index=True)

    last = history[history["year"] == YEARS[-1]].reset_index(drop=True)
    prev = history[history["year"] == YEARS[-2]].reset_index(drop=True)
    companies = last.drop(columns=["year"]).copy()
    companies.insert(1, "name", _names(industry, rng))
    companies.insert(2, "industry", industry)
    companies["revenue_growth"] = (last["revenue"] / prev["revenue"].clip(lower=1e-6) - 1).values
    companies["promoter_pledge"] = promoter_pledge
    companies["incorporated"] = rng.integers(1948, 2015, n)
    companies["hq"] = rng.choice(["Mumbai", "Delhi NCR", "Bengaluru", "Chennai", "Hyderabad", "Pune",
                                  "Ahmedabad", "Kolkata", "Coimbatore", "Indore", "Jaipur", "Vadodara"], n)
    companies["synthetic"] = True
    companies["fy"] = YEARS[-1]

    # ---- business groups + graph ----------------------------------------
    group = _assign_groups(n, rng)
    companies["group"] = group
    edges = _generate_edges(companies, cfg, rng, cust_conc)

    # ---- hazard model on fundamentals -----------------------------------
    c = companies
    icr = c["ebitda"] / c["interest_expense"].clip(lower=1e-3)
    dte = c["debt"] / c["equity"].clip(lower=1e-3)
    nd_ebitda = (c["debt"] - c["cash"]) / c["ebitda"].where(c["ebitda"] > 1e-3, 1e-3)
    nd_ebitda = np.where(c["ebitda"] <= 0, 12.0, np.clip(nd_ebitda, -5, 20))
    liq = c["current_assets"] / c["current_liabilities"].clip(lower=1e-3)
    roa = c["net_profit"] / c["assets"].clip(lower=1e-3)
    ocf_debt = c["ocf"] / c["debt"].clip(lower=1)
    margin_trend = (c["ebitda"] / c["revenue"]).values - (prev["ebitda"] / prev["revenue"].clip(lower=1e-6)).values
    size = np.log(c["revenue"].clip(lower=1))

    z = (
        -1.15 * np.log1p(np.clip(icr, 0, 50))
        + 0.55 * np.log1p(np.clip(dte, 0, 15))
        + 0.12 * np.clip(nd_ebitda, -5, 20)
        - 0.9 * np.log(np.clip(liq, 0.2, 5))
        - 9.0 * np.clip(roa, -0.4, 0.3)
        - 0.8 * np.tanh(ocf_debt)
        - 3.0 * np.clip(c["revenue_growth"], -0.6, 0.6)
        - 6.0 * np.clip(margin_trend, -0.2, 0.2)
        + 1.6 * c["promoter_pledge"]
        - 0.12 * (size - size.mean())
        + 0.25 * (prof["beta"].values - 1.0)
    )
    z = np.asarray(z, dtype=float)
    fundamental = _sigmoid(z - np.quantile(z, 1 - cfg.distress_base_rate * 0.75) + rng.normal(0, 0.35, n))
    distress = (rng.uniform(size=n) < fundamental * 0.75).astype(int) * (fundamental > 0.3)
    companies["distress_pre_cascade"] = distress

    # ---- contagion cascade ----------------------------------------------
    distress = _cascade(companies, edges, distress, fundamental, cfg, rng)

    flip = rng.uniform(size=n) < 0.015                        # reporting noise
    distress = np.where(flip, 1 - distress, distress)

    companies["fundamental_risk"] = fundamental
    companies["neighbour_risk"] = _neighbour_mean(companies["company_id"].values, edges, fundamental)
    companies["latent_prob"] = fundamental
    companies["distress"] = distress.astype(int)
    return Economy(companies=companies, edges=edges, history=history, macro=MACRO.copy())


def _assign_groups(n: int, rng) -> np.ndarray:
    """~35% of firms belong to a business group (8-60 groups, Pareto-sized)."""
    n_groups = max(4, int(n * 0.03))
    in_group = rng.uniform(size=n) < 0.35
    sizes = rng.pareto(1.3, n_groups) + 1
    gid = rng.choice(n_groups, size=n, p=sizes / sizes.sum())
    return np.where(in_group, np.char.add("G", gid.astype(str)), "standalone")


def _generate_edges(companies: pd.DataFrame, cfg: SyntheticConfig, rng, cust_conc) -> pd.DataFrame:
    ids = companies["company_id"].values
    ind = companies["industry"].values
    rev = companies["revenue"].values
    n = len(ids)
    by_sector = {s: np.where(ind == s)[0] for s in INDUSTRIES}
    supplier_of = {s: [] for s in INDUSTRIES}                 # customer sector -> supplier sectors
    for sup, custs in SUPPLY_LINKS.items():
        for cs in custs:
            supplier_of[cs].append(sup)

    rows = []
    in_deg = np.ones(n)                                       # for preferential attachment

    def add(a, b, etype, weight):
        if a != b:
            rows.append((ids[a], ids[b], etype, float(weight)))

    for i in range(n):
        # suppliers (from upstream sectors), preferential by size x popularity
        k = max(1, rng.poisson(cfg.avg_suppliers))
        pool = np.concatenate([by_sector[s] for s in supplier_of[ind[i]]] or [np.arange(n)])
        pool = pool[pool != i]
        if len(pool):
            p = np.sqrt(rev[pool]) * in_deg[pool]
            chosen = rng.choice(pool, size=min(k, len(pool)), replace=False, p=p / p.sum())
            shares = rng.dirichlet(np.ones(len(chosen)) * 0.7)
            for j, s in zip(chosen, shares):
                add(j, i, "SUPPLIES", s)
                in_deg[j] += 1
        # customers: the top customer carries `cust_conc` of revenue
        k = max(1, rng.poisson(cfg.avg_customers))
        downstream = SUPPLY_LINKS.get(ind[i], [])
        pool = np.concatenate([by_sector[s] for s in downstream]) if downstream else np.arange(n)
        pool = pool[pool != i]
        if len(pool):
            p = np.sqrt(rev[pool])
            chosen = rng.choice(pool, size=min(k, len(pool)), replace=False, p=p / p.sum())
            rest = rng.dirichlet(np.ones(max(len(chosen) - 1, 1)))
            shares = np.concatenate([[cust_conc[i]], (1 - cust_conc[i]) * rest])[: len(chosen)]
            for j, s in zip(chosen, shares):
                add(i, j, "CUSTOMER_OF", s)

    # business groups: flagship (largest) owns the rest; cross-guarantees
    grp = companies["group"].values
    for g in np.unique(grp):
        if g == "standalone":
            continue
        members = np.where(grp == g)[0]
        if len(members) < 2:
            continue
        flagship = members[np.argmax(rev[members])]
        for mbr in members:
            if mbr == flagship:
                continue
            add(flagship, mbr, "OWNS", rng.uniform(0.51, 1.0))
            if rng.uniform() < 0.45:
                add(mbr, flagship, "BORROWS_FROM", rng.uniform(0.2, 0.8))   # guarantee / ICD

    # sector peers (competitive set) — sparse
    for s, members in by_sector.items():
        if len(members) < 2:
            continue
        for i in members:
            j = rng.choice(members)
            add(i, j, "SAME_INDUSTRY", 0.3)

    edges = pd.DataFrame(rows, columns=["src", "dst", "type", "weight"])
    edges = edges.drop_duplicates(subset=["src", "dst", "type"]).reset_index(drop=True)
    assert set(edges["type"]).issubset(set(EDGE_TYPES))
    return edges


def _cascade(companies, edges, distress, fundamental, cfg, rng, rounds: int = 3) -> np.ndarray:
    """Propagate distress along economic dependencies for a few rounds."""
    idx = {c: i for i, c in enumerate(companies["company_id"].values)}
    src = edges["src"].map(idx).values
    dst = edges["dst"].map(idx).values
    typ = edges["type"].values
    w = edges["weight"].values
    d = distress.astype(float).copy()
    for _ in range(rounds):
        pressure = np.zeros(len(d))
        # customer defaults -> revenue loss for the supplier (src = supplier i)
        m = typ == "CUSTOMER_OF"
        np.add.at(pressure, src[m], d[dst[m]] * w[m] * 1.6)
        # supplier defaults -> input disruption for the buyer
        m = typ == "SUPPLIES"
        np.add.at(pressure, dst[m], d[src[m]] * w[m] * 0.9)
        # parent distress -> subsidiary (loss of support); subsidiary -> parent via guarantee
        m = typ == "OWNS"
        np.add.at(pressure, dst[m], d[src[m]] * w[m] * 1.4)
        m = typ == "BORROWS_FROM"
        np.add.at(pressure, dst[m], d[src[m]] * w[m] * 0.8)
        p_new = 1 - np.exp(-cfg.contagion_strength * pressure * (0.15 + fundamental))
        hit = (rng.uniform(size=len(d)) < p_new) & (d == 0)
        if not hit.any():
            break
        d[hit] = 1
    return d.astype(int)


def _neighbour_mean(ids: np.ndarray, edges: pd.DataFrame, values: np.ndarray) -> np.ndarray:
    idx = {c: i for i, c in enumerate(ids)}
    a = edges["src"].map(idx).values
    b = edges["dst"].map(idx).values
    acc = np.zeros(len(ids)); cnt = np.zeros(len(ids))
    np.add.at(acc, b, values[a]); np.add.at(cnt, b, 1)
    np.add.at(acc, a, values[b]); np.add.at(cnt, a, 1)
    return np.where(cnt > 0, acc / np.maximum(cnt, 1), values.mean())


if __name__ == "__main__":  # pragma: no cover
    eco = generate_economy()
    print(eco.summary())
