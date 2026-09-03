"""Graph Neural Network models: GCN, GraphSAGE, GAT.

Built on torch-geometric. Each model shares a common structure:

    input features -> [N graph-conv layers with ReLU + dropout] -> embedding
                   -> distress head (binary)
                   -> multi-horizon head (3/6/12/24 month logits)

GAT additionally exposes attention weights, which the explainability layer turns
into "which connected companies drove this prediction".

This module is only imported when torch + torch_geometric are installed
(see models/__init__.py::load_gnn). The tabular baselines and the NumPy demo do
not need it.
"""
from __future__ import annotations

import torch
import torch.nn as nn
import torch.nn.functional as F
from torch_geometric.nn import GCNConv, SAGEConv, GATConv

from ..config import HORIZONS_MONTHS


class _Heads(nn.Module):
    """Shared prediction heads: one binary distress logit + multi-horizon logits."""

    def __init__(self, dim: int):
        super().__init__()
        self.distress = nn.Linear(dim, 1)
        self.horizons = nn.Linear(dim, len(HORIZONS_MONTHS))

    def forward(self, h):
        return self.distress(h).squeeze(-1), self.horizons(h)


class GCN(nn.Module):
    def __init__(self, in_dim, hidden=64, layers=2, dropout=0.3, **_):
        super().__init__()
        self.convs = nn.ModuleList()
        self.convs.append(GCNConv(in_dim, hidden))
        for _ in range(layers - 1):
            self.convs.append(GCNConv(hidden, hidden))
        self.dropout = dropout
        self.heads = _Heads(hidden)

    def embed(self, x, edge_index, edge_weight=None):
        for conv in self.convs:
            x = F.relu(conv(x, edge_index, edge_weight))
            x = F.dropout(x, p=self.dropout, training=self.training)
        return x

    def forward(self, x, edge_index, edge_weight=None):
        h = self.embed(x, edge_index, edge_weight)
        return self.heads(h)


class GraphSAGE(nn.Module):
    def __init__(self, in_dim, hidden=64, layers=2, dropout=0.3, **_):
        super().__init__()
        self.convs = nn.ModuleList()
        self.convs.append(SAGEConv(in_dim, hidden))
        for _ in range(layers - 1):
            self.convs.append(SAGEConv(hidden, hidden))
        self.dropout = dropout
        self.heads = _Heads(hidden)

    def embed(self, x, edge_index, edge_weight=None):
        for conv in self.convs:
            x = F.relu(conv(x, edge_index))
            x = F.dropout(x, p=self.dropout, training=self.training)
        return x

    def forward(self, x, edge_index, edge_weight=None):
        return self.heads(self.embed(x, edge_index))


class GAT(nn.Module):
    """Graph Attention Network — learns per-neighbour attention weights.

    The attention weights are the route to explainability: for a given company
    we can read off which connected companies the model attended to.
    """

    def __init__(self, in_dim, hidden=64, layers=2, dropout=0.3, heads=4, **_):
        super().__init__()
        self.convs = nn.ModuleList()
        self.convs.append(GATConv(in_dim, hidden, heads=heads, dropout=dropout))
        for _ in range(layers - 2):
            self.convs.append(GATConv(hidden * heads, hidden, heads=heads, dropout=dropout))
        self.convs.append(GATConv(hidden * heads, hidden, heads=1, concat=True, dropout=dropout))
        self.dropout = dropout
        self.heads = _Heads(hidden)

    def embed(self, x, edge_index, edge_weight=None, return_attention=False):
        att = None
        for i, conv in enumerate(self.convs):
            if return_attention and i == len(self.convs) - 1:
                x, att = conv(x, edge_index, return_attention_weights=True)
            else:
                x = conv(x, edge_index)
            x = F.elu(x)
            x = F.dropout(x, p=self.dropout, training=self.training)
        return (x, att) if return_attention else x

    def forward(self, x, edge_index, edge_weight=None):
        return self.heads(self.embed(x, edge_index))

    @torch.no_grad()
    def attention_for(self, x, edge_index):
        """Return (edge_index, attention) for explainability."""
        self.eval()
        _, (att_edge_index, att) = self.embed(x, edge_index, return_attention=True)
        return att_edge_index, att
