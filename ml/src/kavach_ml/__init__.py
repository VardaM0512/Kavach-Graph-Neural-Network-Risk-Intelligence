"""Kavach ML — Graph Neural Network based corporate financial distress intelligence.

This package contains the full modelling pipeline:

    data/     synthetic data generation, financial feature engineering, graph construction
    models/   tabular baselines (LogReg, RandomForest, XGBoost) + GNNs (GCN, GraphSAGE, GAT)
    explain/  SHAP (tabular) and GNNExplainer / attention (graph) explainability
    serve/    inference utilities used by the FastAPI backend

The design goal is a *fair experiment*: train every model on the same split and
show that adding graph structure (relationships between companies) measurably
improves distress prediction over purely tabular models.
"""

__version__ = "0.1.0"

FEATURE_ORDER = [
    # liquidity
    "current_ratio", "quick_ratio", "cash_ratio", "working_capital_to_assets",
    # leverage
    "debt_to_equity", "debt_to_assets", "interest_coverage", "net_debt_to_ebitda",
    # profitability
    "net_margin", "operating_margin", "return_on_assets", "return_on_equity",
    # cash flow
    "ocf_to_debt", "fcf_margin", "cash_burn_months",
    # growth / trend
    "revenue_growth_yoy", "revenue_cagr_3y", "profit_trend_slope",
    # graph-derived (populated by data/graph.py)
    "supplier_concentration_hhi", "customer_concentration_hhi",
    "neighbour_distress_mean", "pagerank", "degree_centrality",
]
