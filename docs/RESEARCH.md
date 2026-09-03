# Kavach — Research Foundation & Literature Review

This document grounds every major design decision in Kavach in the published
literature on corporate bankruptcy / financial-distress prediction and graph
machine learning. It is written so a reviewer (or an interviewer) can trace each
component back to the paper that motivates it.

> TL;DR of the field, 2024–2026: the frontier has moved from single-company
> tabular models to **heterogeneous / relational GNNs** over supplier–customer–
> ownership–lending graphs, with **hybrid GNN + gradient-boosting ensembles** and
> **dynamic (temporal) heterogeneous GNNs** for contagion. Kavach implements this
> exact progression.

---

## 1. How the field evolved (and where Kavach sits)

| Era | Approach | Representative work | In Kavach |
|---|---|---|---|
| 1968– | Statistical discriminant on financial ratios | **Altman Z-Score** (Altman, 1968) | `models/altman.py` — included as the classic baseline |
| 2000s–2010s | Machine learning on tabular ratios | Logistic Regression, Random Forest, **XGBoost** (Chen & Guestrin, 2016) | `models/baselines.py` |
| 2017–2019 | Homogeneous GNNs | **GCN** (Kipf & Welling, 2017); **GraphSAGE** (Hamilton et al., 2017); **GAT** (Veličković et al., 2018) | `models/gnn.py`, `models/numpy_gnn.py` |
| 2018–2020 | Relational / heterogeneous GNNs | **R-GCN** (Schlichtkrull et al., 2018); **HGT** (Hu et al., 2020) | `models/gnn.py::RGCN`, `models/numpy_gnn.py::RelationalNumpyGNN` |
| 2024–2026 | Heterogeneous + hybrid + dynamic for credit/distress | HGNN-EBP (2025); Relational-GNN + ensemble (2026); dynamic guarantee-network GNN (2026); attention-enhanced distress GNN (2025) | relational + hybrid + contagion + roadmap temporal |

Kavach is deliberately a *ladder*: it trains every rung and puts them on one
scoreboard, so the value added by each modelling idea is measured, not asserted.

---

## 2. The core thesis, and the papers behind it

**Thesis:** corporate distress is a *network* phenomenon — a firm can fail because
its counterparties fail — so relationship structure carries predictive signal that
a single-company model cannot access.

This is now well supported:

- **Attention-enhanced GNN for financial distress and bankruptcy risk prediction**
  (Applied Economics Letters, 2025) — shows attention over a firm's relational
  neighbourhood improves distress prediction. → motivates Kavach's **GAT** and the
  attention-based explanations.
- **Enterprise Bankruptcy Prediction via Heterogeneous GNN (HGNN-EBP)**
  (Mathematics 13(17):2755, MDPI, 2025) — builds a heterogeneous graph over
  enterprises, suppliers and financial institutions with three relation types
  (`A_supply`, `A_equity`, `A_lending`) and fuses internal attributes with external
  topology; evaluated on 32,459 Chinese enterprises. → directly motivates Kavach's
  **five typed relations** (SUPPLIES / CUSTOMER_OF / OWNS / BORROWS_FROM /
  SAME_INDUSTRY) and the **RelationalNumpyGNN / RGCN**.
- **Relational Graph Modeling for Credit Default Prediction: Heterogeneous GNNs
  and Hybrid Ensemble Learning** (arXiv:2601.14633, 2026) — finds that
  relation-aware GNNs help most as a *complementary* component: concatenating
  learned graph embeddings with tabular features and feeding a gradient-boosted
  tree beats either alone. → directly motivates Kavach's **HybridGNNEnsemble**
  (`[ tabular ⊕ graph embedding ] → XGBoost`).
- **Default prediction and contagion risk assessment in corporate guarantee
  networks via dynamic heterogeneous GNNs** (J. King Saud Univ. Comp. & Info. Sci.,
  2026) — models risk propagation through guarantee networks with a *dynamic*
  heterogeneous GNN. → motivates Kavach's **network-contagion scoring**,
  **failure simulation**, and the **temporal-GNN roadmap item**.
- **Credit Risk Analysis for SMEs Using Graph Neural Networks in Supply Chain**
  (arXiv:2507.07854, 2025) and **Supply-chain financial risk assessment: a
  modified graph attention network** (Finance Research Letters, 2025) — establish
  supplier–customer graphs + GAT for SME credit risk. → motivates the supply-chain
  edges and concentration features.

---

## 3. Design decisions ↔ evidence

### 3.1 Heterogeneous / relational modelling (the flagship)
Real corporate edges are not interchangeable: a 48%-of-purchases supplier link is
not the same as a minority equity stake. **R-GCN** (Schlichtkrull et al., 2018)
learns a separate transformation per relation type; **HGT** (Hu et al., 2020) adds
type-aware attention. HGNN-EBP (2025) shows this is the right inductive bias for
enterprise bankruptcy. Kavach implements per-relation message passing in both a
torch `RGCN` (`RGCNConv`) and a dependency-light `RelationalNumpyGNN`.

### 3.2 Hybrid GNN + gradient boosting
The 2026 relational-GNN paper's headline result is that the **hybrid** (graph
embedding ⊕ tabular → boosted trees) is the strongest configuration at scale, and
that standalone GNNs give "limited lift" over a strong LightGBM baseline. Kavach
reproduces this recipe and — honestly — shows it needs *scale* to pay off (see §5).

### 3.3 Class imbalance
Distress is rare (the Taiwanese benchmark is 3.23% bankrupt). The literature uses
**focal loss** (Lin et al., 2017), cost-sensitive weighting (`scale_pos_weight`),
threshold tuning, and reports **PR-AUC / recall / KS** rather than accuracy;
**GraphSMOTE** (Zhao et al., 2021) oversamples minority nodes in embedding space.
Kavach uses focal loss + class weights + `scale_pos_weight` + validation threshold
tuning, and reports PR-AUC, recall, **KS statistic** and **precision@k**
(`evaluate.py`). GraphSMOTE is a documented extension point.

### 3.4 Explainability
**GNNExplainer** (Ying et al., 2019) and attention weights are the standard tools
for explaining node predictions on graphs; **SHAP** (Lundberg & Lee, 2017) for the
tabular side. Kavach exposes all three (`explain/`), turning them into the app's
feature-driver bars and "which connected company drove this" narrative — mirroring
the network-analysis + explainable-ML bankruptcy work (Springer *Computational
Economics*, 2025).

### 3.5 Dynamic / temporal (roadmap)
Relationships evolve; **EvolveGCN** (Pareja et al., 2020) and temporal GNNs model
this, and the 2026 guarantee-network paper shows dynamic heterogeneous GNNs improve
contagion assessment. Kavach ships a snapshot model and lists temporal modelling as
the primary roadmap item, with the history/timeline plumbing already in place.

---

## 4. Real-world benchmark datasets (for swapping out the synthetic economy)

From *Datasets for Advanced Bankruptcy Prediction: A Survey and Taxonomy*
(arXiv:2411.01928, 2024):

| Dataset | Scope | Notes |
|---|---|---|
| **American** (Lombardo et al., 2022) | 8,262 US firms, 1999–2018, 78,682 firm-years | Chapter 7/11 labels; time-based split |
| **Polish** (UCI) | Polish firms 2000–2012 | 64 financial ratios as features |
| **Taiwanese** (UCI / Kaggle) | 6,819 firms, 1999–2009 | 95 variables; 3.23% bankrupt; no missing values |
| **SMEsD** (Wei et al., 2024) | 3,976 Chinese SMEs 2014–2021 | includes lawsuit/litigation graph |
| **HAT** (2021) | 13,489 Chinese firms | board-member + shareholder networks |

Kavach's loader contract (`generate_economy` → `companies`, `edges`, `history`) is
designed so any of these — plus a relationship source such as Neo4j — can replace
the synthetic generator without changing a downstream line.

---

## 5. Honest reading of Kavach's own results

On the shipped synthetic economy (1,200 firms, ~31% distress, strong contagion),
the scoreboard (`ml/artifacts/comparison.md`) typically shows:

- **Relational GNN and homogeneous GNNs lead on PR-AUC / KS**, matching the
  literature's finding that graph structure helps when distress is network-driven.
- **Logistic regression is a stubbornly strong tabular baseline** — consistent with
  bankruptcy-prediction surveys that repeatedly caution against assuming complex
  models dominate simple ones.
- **The classic Altman Z-Score is weak** on a network-driven economy because its
  fixed 1968 weights see neither learned feature importance nor the graph — the
  precise gap the rest of the ladder fills.
- **The hybrid GNN+GBDT needs scale**: on a few hundred nodes, tree ensembles
  under-fit relative to a linear head; its advantage appears as the graph grows,
  exactly as the 2026 relational-GNN paper reports on millions of nodes.

This "the simple baseline is hard to beat, and the graph advantage depends on
regime" honesty is itself a finding the surveys emphasise, and is a stronger story
than an unqualified "our GNN wins".

---

## References

1. Altman, E. I. (1968). *Financial Ratios, Discriminant Analysis and the Prediction of Corporate Bankruptcy.* The Journal of Finance, 23(4).
2. Chen, T., & Guestrin, C. (2016). *XGBoost: A Scalable Tree Boosting System.* KDD.
3. Kipf, T. N., & Welling, M. (2017). *Semi-Supervised Classification with Graph Convolutional Networks.* ICLR.
4. Hamilton, W., Ying, R., & Leskovec, J. (2017). *Inductive Representation Learning on Large Graphs (GraphSAGE).* NeurIPS.
5. Veličković, P., et al. (2018). *Graph Attention Networks.* ICLR.
6. Brody, S., Alon, U., & Yahav, E. (2022). *How Attentive are Graph Attention Networks? (GATv2).* ICLR.
7. Schlichtkrull, M., et al. (2018). *Modeling Relational Data with Graph Convolutional Networks (R-GCN).* ESWC.
8. Hu, Z., et al. (2020). *Heterogeneous Graph Transformer.* The Web Conference (WWW).
9. Pareja, A., et al. (2020). *EvolveGCN: Evolving Graph Convolutional Networks for Dynamic Graphs.* AAAI.
10. Lin, T.-Y., et al. (2017). *Focal Loss for Dense Object Detection.* ICCV.
11. Ying, R., et al. (2019). *GNNExplainer: Generating Explanations for Graph Neural Networks.* NeurIPS.
12. Lundberg, S., & Lee, S.-I. (2017). *A Unified Approach to Interpreting Model Predictions (SHAP).* NeurIPS.
13. Zhao, T., Zhang, X., & Wang, S. (2021). *GraphSMOTE: Imbalanced Node Classification on Graphs with Graph Neural Networks.* WSDM.
14. *Enterprise Bankruptcy Prediction Model Based on Heterogeneous Graph Neural Network (HGNN-EBP).* Mathematics 13(17):2755, MDPI, 2025. https://www.mdpi.com/2227-7390/13/17/2755
15. *Relational Graph Modeling for Credit Default Prediction: Heterogeneous GNNs and Hybrid Ensemble Learning.* arXiv:2601.14633, 2026. https://arxiv.org/abs/2601.14633
16. *Default prediction and contagion risk assessment in corporate guarantee networks via dynamic heterogeneous graph neural networks.* J. King Saud Univ. Comp. & Info. Sci., 2026. https://link.springer.com/article/10.1007/s44443-026-00904-2
17. *Attention-enhanced graph neural network for financial distress and bankruptcy risk prediction.* Applied Economics Letters, 2025. https://www.tandfonline.com/doi/full/10.1080/13504851.2025.2491726
18. *Credit Risk Analysis for SMEs Using Graph Neural Networks in Supply Chain.* arXiv:2507.07854, 2025. https://arxiv.org/abs/2507.07854
19. *Supply chain financial risk assessment: A modified graph attention neural network.* Finance Research Letters, 2025. https://www.sciencedirect.com/science/article/abs/pii/S1544612325015399
20. *Datasets for Advanced Bankruptcy Prediction: A Survey and Taxonomy.* arXiv:2411.01928, 2024. https://arxiv.org/html/2411.01928v1
21. *Survey, classification and critical analysis of the literature on corporate bankruptcy and financial distress prediction.* ScienceDirect, 2024. https://www.sciencedirect.com/science/article/pii/S2666827024000033
22. *Enhanced Bankruptcy Prediction Model Based on Network Analysis and Explainable Machine Learning.* Computational Economics, Springer, 2025. https://link.springer.com/article/10.1007/s10614-025-11016-w

> Citation note: foundational entries (1–13) are standard references; entries
> 14–22 are recent works located via literature search — verify exact author lists
> and page numbers against the linked source before formal citation.
