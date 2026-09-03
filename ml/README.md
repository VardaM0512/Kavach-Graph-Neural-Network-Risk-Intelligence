# Kavach ML — GNN Corporate Distress Engine

The machine-learning core of Kavach. It builds a company **relationship graph**,
engineers financial features, trains **tabular baselines** and **Graph Neural
Networks**, and serves distress predictions + network analytics to the FastAPI
backend.

## Why a graph?

A company can look healthy on its own balance sheet yet fail because its biggest
supplier collapses or its key customer defaults. Tabular models see only a
company's *own* numbers. A GNN passes messages along supplier / customer /
ownership / lending edges, so each company's prediction is informed by the health
of everything it is connected to. Our synthetic economy deliberately includes
**network-induced distress** (healthy firms that fail purely because their
neighbours fail) — cases a tabular model structurally cannot get right.

## Layout

```
src/kavach_ml/
  config.py            paths, edge types, risk bands, hyper-parameters
  data/
    synthetic.py       generates a realistic company economy + relationships + labels
    features.py        financial ratio feature engineering (liquidity/leverage/…)
    graph.py           graph construction + structural features (HHI, PageRank, …)
  models/
    baselines.py       LogisticRegression, RandomForest, XGBoost (no graph)
    gnn.py             GCN, GraphSAGE, GAT  (torch-geometric)
    numpy_gnn.py       dependency-light SGC-style GNN (runs anywhere)
  train.py             torch GNN training loop (focal loss, class weights, early stop)
  evaluate.py          PR-AUC / ROC-AUC / F1 / recall + comparison table
  explain/             SHAP (tabular) + attention / neighbour influence (graph)
  serve/engine.py      RiskEngine — inference + all analytics used by the API
scripts/
  quick_demo.py        end-to-end run with NumPy + sklearn only
  run_pipeline.py      auto-detects torch; trains full GCN/GraphSAGE/GAT if available
tests/                 pytest smoke tests
```

## Quick start

```bash
pip install -r requirements.txt          # full stack (torch, PyG, xgboost, shap)
# or just numpy/pandas/scikit-learn for the lightweight path

python scripts/quick_demo.py             # runs anywhere, prints the scoreboard
python -m kavach_ml.train --model gat    # full GAT training (needs torch + PyG)
pytest tests/ -q
```

## Handling class imbalance

Distress is the rare class, so **accuracy is not used as a headline metric**. The
pipeline uses class weighting + focal loss, tunes the decision threshold on the
validation set, and reports **PR-AUC and recall** first. See `evaluate.py`.

## Swapping in real data

Replace `data/synthetic.generate_economy()` with a loader that returns the same
three frames (`companies`, `edges`, `history`) from your real sources — company
financials from Postgres and relationships from Neo4j. Every downstream module is
unchanged.
