"""Central configuration for the Kavach ML pipeline.

Everything the pipeline needs (paths, hyper-parameters, edge types, risk bands)
lives here so the training scripts stay thin and reproducible.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parents[2]          # .../ml
ARTIFACTS = ROOT / "artifacts"                       # trained models + metrics
DATA_DIR = ROOT / "data"                             # generated datasets
ARTIFACTS.mkdir(exist_ok=True)
DATA_DIR.mkdir(exist_ok=True)

RANDOM_SEED = 42

# ---------------------------------------------------------------------------
# Graph schema — the relationship types that make this a graph problem
# ---------------------------------------------------------------------------
EDGE_TYPES = ("SUPPLIES", "CUSTOMER_OF", "OWNS", "BORROWS_FROM", "SAME_INDUSTRY")

# ---------------------------------------------------------------------------
# Risk banding — how a probability becomes a human-readable band
# ---------------------------------------------------------------------------
# Bands sit on the *calibrated* 12-month probability of default (PD), the way a
# credit desk reads it: a 10% PD is already a sub-investment-grade name.
RISK_BANDS = [
    (0.00, 0.03, "LOW"),
    (0.03, 0.10, "MODERATE"),
    (0.10, 0.30, "HIGH"),
    (0.30, 1.01, "CRITICAL"),
]

# PD -> implied rating (upper PD bound per grade, roughly CRISIL/S&P 1-yr default
# experience). Used purely as a familiar reading aid, not an actual rating.
IMPLIED_RATINGS = [
    (0.0005, "AAA"), (0.0012, "AA"), (0.004, "A"), (0.015, "BBB"),
    (0.05, "BB"), (0.15, "B"), (0.35, "CCC"), (0.60, "CC"), (1.01, "C"),
]

# Prediction horizons (months) for the multi-horizon head
HORIZONS_MONTHS = (3, 6, 12, 24)


@dataclass
class SyntheticConfig:
    """Controls the synthetic-economy generator in data/synthetic.py."""
    n_companies: int = 1500
    n_banks: int = 25
    n_industries: int = 12
    avg_suppliers: float = 1.8
    avg_customers: float = 1.8
    distress_base_rate: float = 0.08      # ~Indian corporate default rate across a cycle
    contagion_strength: float = 0.9       # how strongly counterparty distress propagates
    years_of_history: int = 4
    seed: int = RANDOM_SEED


@dataclass
class TrainConfig:
    """Hyper-parameters shared across the GNN trainers."""
    hidden_dim: int = 64
    n_layers: int = 2
    dropout: float = 0.3
    lr: float = 5e-3
    weight_decay: float = 5e-4
    epochs: int = 200
    patience: int = 30                    # early-stopping patience
    # class-imbalance handling
    use_class_weights: bool = True
    focal_gamma: float = 2.0
    # GAT
    gat_heads: int = 4
    # split
    val_size: float = 0.15
    test_size: float = 0.15
    seed: int = RANDOM_SEED
    models: tuple = field(default_factory=lambda: (
        "logreg", "random_forest", "xgboost", "gcn", "graphsage", "gat",
    ))


def implied_rating(prob: float) -> str:
    for hi, grade in IMPLIED_RATINGS:
        if prob < hi:
            return grade
    return "C"


def band_for(prob: float) -> str:
    """Map a distress probability to a risk band label."""
    for lo, hi, name in RISK_BANDS:
        if lo <= prob < hi:
            return name
    return "CRITICAL"
