"""Synthetic corporate economy generator.

We do not ship a licensed financial dataset. Instead we generate a *realistic
synthetic economy* whose distress labels depend on BOTH:

  1. a company's own fundamentals (leverage, liquidity, profitability, cash flow), and
  2. the health of the companies it is connected to (supplier / customer / owner / bank).

Because (2) is baked into the labels, a purely tabular model cannot capture the
full signal — which is exactly why the graph models win in evaluate.py. This is
an honest, reproducible stand-in for real data such as filings, credit-bureau
feeds, or a licensed distress dataset; swap `generate_economy` for a real loader
and the rest of the pipeline is unchanged.

Returned object: an `Economy` with
  companies   : DataFrame, one row per company (raw financials + latent risk)
  edges       : DataFrame [src, dst, type, weight]
  history      : DataFrame [company_id, year, revenue, net_profit, ...] time-series
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

    def summary(self) -> dict:
        return {
            "n_companies": len(self.companies),
            "n_edges": len(self.edges),
            "distress_rate": round(float(self.companies["distress"].mean()), 4),
            "edge_types": self.edges["type"].value_counts().to_dict(),
        }


INDUSTRIES = [
    "Technology", "Manufacturing", "Energy", "Retail", "Healthcare",
    "Financials", "Materials", "Utilities", "Telecom", "Realty",
    "Consumer", "Logistics",
]


def _sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def generate_economy(cfg: SyntheticConfig | None = None) -> Economy:
    cfg = cfg or SyntheticConfig()
    rng = np.random.default_rng(cfg.seed)
    n = cfg.n_companies

    # --- industry + size ---------------------------------------------------
    industry_idx = rng.integers(0, cfg.n_industries, size=n)
    industry = np.array(INDUSTRIES)[industry_idx % len(INDUSTRIES)]
    # log-normal revenue in crore
    revenue = np.exp(rng.normal(6.0, 1.1, size=n))          # ~ tens..thousands cr
    assets = revenue * rng.uniform(0.8, 2.5, size=n)

    # --- capital structure -------------------------------------------------
    leverage = rng.beta(2, 5, size=n) * 4.0                 # debt/equity, skew low
    debt = assets * _sigmoid((leverage - 1.2)) * rng.uniform(0.3, 0.7, size=n)
    equity = np.maximum(assets - debt, assets * 0.05)
    cash = assets * rng.uniform(0.02, 0.25, size=n)

    # --- profitability -----------------------------------------------------
    base_margin = rng.normal(0.08, 0.10, size=n)            # some firms lose money
    net_profit = revenue * base_margin
    ebitda = revenue * (base_margin + rng.uniform(0.04, 0.12, size=n))
    interest_expense = debt * rng.uniform(0.06, 0.12, size=n)

    # --- cash flow ---------------------------------------------------------
    ocf = net_profit * rng.uniform(0.5, 1.6, size=n) + rng.normal(0, revenue * 0.03)
    capex = revenue * rng.uniform(0.02, 0.10, size=n)
    fcf = ocf - capex

    # --- growth ------------------------------------------------------------
    revenue_growth = rng.normal(0.06, 0.18, size=n)

    companies = pd.DataFrame({
        "company_id": [f"C{i:04d}" for i in range(n)],
        "name": [f"Company {i}" for i in range(n)],
        "industry": industry,
        "revenue": revenue,
        "assets": assets,
        "debt": debt,
        "equity": equity,
        "cash": cash,
        "net_profit": net_profit,
        "ebitda": ebitda,
        "interest_expense": interest_expense,
        "ocf": ocf,
        "fcf": fcf,
        "capex": capex,
        "current_assets": assets * rng.uniform(0.2, 0.5, size=n),
        "current_liabilities": debt * rng.uniform(0.3, 0.6, size=n) + revenue * 0.05,
        "inventory": assets * rng.uniform(0.03, 0.15, size=n),
        "revenue_growth": revenue_growth,
    })

    # --- relationships (the graph) ----------------------------------------
    edges = _generate_edges(companies, cfg, rng)

    # --- latent risk from fundamentals ------------------------------------
    dte = companies["debt"] / companies["equity"]
    icr = companies["ebitda"] / companies["interest_expense"].clip(lower=1e-6)
    liq = companies["current_assets"] / companies["current_liabilities"]
    margin = companies["net_profit"] / companies["revenue"]
    ocf_debt = companies["ocf"] / companies["debt"].clip(lower=1e-6)

    z = (
        1.4 * (dte - 1.0)
        - 0.9 * np.tanh(icr / 4.0)
        - 1.1 * (liq - 1.0)
        - 6.0 * margin
        - 1.3 * np.tanh(ocf_debt)
        - 4.0 * companies["revenue_growth"]
    )
    fundamental_risk = _sigmoid(z.values - 1.4)             # centred near base rate

    # --- contagion: neighbours' fundamental risk raises own risk ----------
    neigh_risk = _neighbour_mean(companies["company_id"].values, edges, fundamental_risk)
    combined = np.clip(
        fundamental_risk + cfg.contagion_strength * (neigh_risk - fundamental_risk.mean()),
        0.001, 0.999,
    )

    # calibrate to target base rate, then assign labels with mild noise so the
    # distress class stays realistically rare (~distress_base_rate).
    thresh = np.quantile(combined, 1.0 - cfg.distress_base_rate)
    prob = _sigmoid(12.0 * (combined - thresh))
    distress = (combined >= thresh).astype(int)

    # Network-induced distress: some firms with *healthy* fundamentals fail purely
    # because their direct counterparties are failing. These are the cases a
    # tabular model (which sees only own financials) structurally cannot get, and
    # a message-passing GNN can — this is the crux of the whole experiment.
    n_distressed_neighbours = _count_distressed_neighbours(
        companies["company_id"].values, edges, distress
    )
    healthy_fundamentals = fundamental_risk < np.quantile(fundamental_risk, 0.6)
    network_induced = healthy_fundamentals & (n_distressed_neighbours >= 2)
    induce = network_induced & (rng.uniform(size=n) < 0.7)
    distress = np.where(induce, 1, distress)

    flip = rng.uniform(size=n) < 0.03                      # 3% label noise
    distress = np.where(flip, 1 - distress, distress)

    companies["fundamental_risk"] = fundamental_risk
    companies["neighbour_risk"] = neigh_risk
    companies["latent_prob"] = prob
    companies["distress"] = distress

    history = _generate_history(companies, cfg, rng)
    return Economy(companies=companies, edges=edges, history=history)


def _generate_edges(companies: pd.DataFrame, cfg: SyntheticConfig, rng) -> pd.DataFrame:
    ids = companies["company_id"].values
    n = len(ids)
    rows = []

    def add(src_i, dst_i, etype, weight):
        rows.append((ids[src_i], ids[dst_i], etype, float(weight)))

    for i in range(n):
        # suppliers (weighted; enables concentration risk)
        k_sup = rng.poisson(cfg.avg_suppliers)
        if k_sup:
            sup = rng.choice(n, size=min(k_sup, n - 1), replace=False)
            w = rng.dirichlet(np.ones(len(sup)) * 0.6)     # skewed => concentration
            for j, wj in zip(sup, w):
                if j != i:
                    add(j, i, "SUPPLIES", wj)               # supplier -> company
        # customers
        k_cus = rng.poisson(cfg.avg_customers)
        if k_cus:
            cus = rng.choice(n, size=min(k_cus, n - 1), replace=False)
            w = rng.dirichlet(np.ones(len(cus)) * 0.6)
            for j, wj in zip(cus, w):
                if j != i:
                    add(i, j, "CUSTOMER_OF", wj)            # company -> customer
        # ownership (subsidiaries) — sparse
        if rng.uniform() < 0.12:
            j = rng.integers(0, n)
            if j != i:
                add(i, j, "OWNS", 1.0)
        # bank borrowing
        if rng.uniform() < 0.5:
            j = rng.integers(0, n)
            if j != i:
                add(i, j, "BORROWS_FROM", rng.uniform(0.2, 1.0))

    # industry co-membership edges (sample a few per company to bound density)
    for ind, grp in companies.groupby("industry"):
        members = grp.index.values
        for i in members:
            peers = rng.choice(members, size=min(1, len(members)), replace=False)
            for p in peers:
                if p != i:
                    add(i, p, "SAME_INDUSTRY", 0.5)

    edges = pd.DataFrame(rows, columns=["src", "dst", "type", "weight"])
    edges = edges.drop_duplicates(subset=["src", "dst", "type"]).reset_index(drop=True)
    assert set(edges["type"]).issubset(set(EDGE_TYPES))
    return edges


def _count_distressed_neighbours(ids: np.ndarray, edges: pd.DataFrame, distress: np.ndarray) -> np.ndarray:
    idx = {c: i for i, c in enumerate(ids)}
    cnt = np.zeros(len(ids))
    for src, dst in zip(edges["src"].values, edges["dst"].values):
        a, b = idx[src], idx[dst]
        cnt[b] += distress[a]
        cnt[a] += distress[b]
    return cnt


def _neighbour_mean(ids: np.ndarray, edges: pd.DataFrame, values: np.ndarray) -> np.ndarray:
    idx = {c: i for i, c in enumerate(ids)}
    acc = np.zeros(len(ids))
    cnt = np.zeros(len(ids))
    for src, dst in zip(edges["src"].values, edges["dst"].values):
        a, b = idx[src], idx[dst]
        acc[b] += values[a]; cnt[b] += 1
        acc[a] += values[b]; cnt[a] += 1
    out = np.where(cnt > 0, acc / np.maximum(cnt, 1), values.mean())
    return out


def _generate_history(companies: pd.DataFrame, cfg: SyntheticConfig, rng) -> pd.DataFrame:
    """Back-cast a few years of revenue/profit so trend features are meaningful."""
    rows = []
    this_year = 2026
    for _, c in companies.iterrows():
        g = c["revenue_growth"]
        # distressed firms tend to decelerate over time
        drift = -0.06 if c["distress"] else 0.0
        rev = c["revenue"]
        prof = c["net_profit"]
        for back in range(cfg.years_of_history):
            year = this_year - back
            rows.append((c["company_id"], year, rev, prof))
            factor = 1.0 / (1.0 + g + drift * back + rng.normal(0, 0.03))
            rev *= factor
            prof *= factor * rng.uniform(0.9, 1.1)
    return pd.DataFrame(rows, columns=["company_id", "year", "revenue", "net_profit"])


if __name__ == "__main__":  # pragma: no cover
    eco = generate_economy()
    print(eco.summary())
