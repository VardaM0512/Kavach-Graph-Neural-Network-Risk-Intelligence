"""Model zoo: tabular baselines + graph neural networks.

The GNN models require torch/torch-geometric; they are imported lazily so the
data pipeline and baselines run in a torch-free environment.
"""
from .baselines import train_baselines, BaselineResult

__all__ = ["train_baselines", "BaselineResult"]


def load_gnn(name: str):  # pragma: no cover - requires torch
    from . import gnn
    return {
        "gcn": gnn.GCN,
        "graphsage": gnn.GraphSAGE,
        "gat": gnn.GAT,
        "rgcn": gnn.RGCN,
    }[name]
