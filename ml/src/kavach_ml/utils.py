"""Small shared helpers: stratified splits, seeding, JSON-safe conversion."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from sklearn.model_selection import train_test_split

from .config import TrainConfig


def make_splits(y: np.ndarray, cfg: TrainConfig | None = None) -> dict:
    """Stratified train / val / test index split (preserves the rare class)."""
    cfg = cfg or TrainConfig()
    idx = np.arange(len(y))
    train_idx, temp_idx = train_test_split(
        idx, test_size=cfg.val_size + cfg.test_size,
        stratify=y, random_state=cfg.seed,
    )
    rel_test = cfg.test_size / (cfg.val_size + cfg.test_size)
    val_idx, test_idx = train_test_split(
        temp_idx, test_size=rel_test, stratify=y[temp_idx], random_state=cfg.seed,
    )
    return {"train": train_idx, "val": val_idx, "test": test_idx}


def save_json(obj, path: Path):
    def default(o):
        if isinstance(o, (np.floating, np.integer)):
            return o.item()
        if isinstance(o, np.ndarray):
            return o.tolist()
        return str(o)
    Path(path).write_text(json.dumps(obj, indent=2, default=default))
