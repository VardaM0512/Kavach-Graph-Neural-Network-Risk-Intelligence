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

from .data.features import FEATURE_NAMES as FEATURE_ORDER  # noqa: E402,F401
