"""PyTorch Geometric graph neural networks for corporate default risk.

All models consume the same *typed, directed, weighted* company graph:

    message j -> i  with  relation r in {suppliers, customers, group, peers}
                    and   weight w = how much i depends on j (0..1)

Models
  GCN        homogeneous graph convolution, dependency-weighted edges
  GraphSAGE  mean aggregation (unweighted baseline)
  GAT        attention over neighbours; relation + weight fed as edge features
  RGCN       relational GCN with per-relation weights and dependency-weighted
             mean aggregation (custom conv; PyG's RGCNConv cannot take weights)

Everything is full-batch (the graph is small), trained with BCE, early-stopped
on validation PR-AUC, Platt-calibrated on validation so outputs are usable as
probabilities of default, and ensembled over seeds for stability.

Inductive scoring: a company outside the training graph is appended as a new
node with edges from its named counterparties, and the trained network is run
forward. Integrated gradients give per-feature and per-counterparty attributions.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score
from torch_geometric.nn import GATConv, GCNConv, SAGEConv

RELATIONS = ("suppliers", "customers", "group", "peers")
R = len(RELATIONS)


# ----------------------------------------------------------------- graph data
@dataclass
class GraphTensors:
    x: torch.Tensor            # (N, F)
    src: torch.Tensor          # (E,) message source j
    dst: torch.Tensor          # (E,) message target i
    rel: torch.Tensor          # (E,) relation id
    w: torch.Tensor            # (E,) dependency weight
    w_norm: torch.Tensor = field(default=None)  # weight normalised per (target, relation)

    @property
    def edge_index(self):
        return torch.stack([self.src, self.dst])

    @property
    def edge_attr(self):
        return torch.cat([F.one_hot(self.rel, R).float(), self.w[:, None]], dim=1)


def build_tensors(X: np.ndarray, rel_rows: list[tuple[int, int, str, float]]) -> GraphTensors:
    """rel_rows: (focal i, neighbour j, relation, weight) -> message j -> i."""
    rid = {r: k for k, r in enumerate(RELATIONS)}
    dst = torch.tensor([i for i, _, _, _ in rel_rows], dtype=torch.long)
    src = torch.tensor([j for _, j, _, _ in rel_rows], dtype=torch.long)
    rel = torch.tensor([rid[r] for _, _, r, _ in rel_rows], dtype=torch.long)
    w = torch.tensor([float(x) for *_, x in rel_rows], dtype=torch.float32)
    g = GraphTensors(torch.tensor(X, dtype=torch.float32), src, dst, rel, w)
    g.w_norm = normalise(g, X.shape[0])
    return g


def normalise(g: GraphTensors, n: int) -> torch.Tensor:
    key = g.dst * R + g.rel
    tot = torch.zeros(n * R).index_add_(0, key, g.w)
    return g.w / tot[key].clamp_min(1e-9)


# --------------------------------------------------------------------- models
class WeightedRelConv(nn.Module):
    """h_i' = W_0 h_i + sum_r W_r * sum_j w_norm(ij) h_j  (dependency-weighted R-GCN)."""

    def __init__(self, din, dout):
        super().__init__()
        self.root = nn.Linear(din, dout)
        self.rel = nn.Parameter(torch.empty(R, din, dout))
        nn.init.xavier_uniform_(self.rel.view(R * din, dout))

    def forward(self, h, g: GraphTensors):
        out = self.root(h)
        hw = torch.einsum("nf,rfo->rno", h, self.rel)          # transform every node once per relation
        msg = hw[g.rel, g.src] * g.w_norm[:, None]
        return out.index_add(0, g.dst, msg)


class RGCN(nn.Module):
    def __init__(self, din, hidden=16, dropout=0.4):
        super().__init__()
        self.c1, self.c2 = WeightedRelConv(din, hidden), WeightedRelConv(hidden, hidden)
        self.head = nn.Linear(hidden + din, 1)            # skip connection to raw ratios
        self.dropout = dropout

    def forward(self, x, g):
        h = F.dropout(F.relu(self.c1(x, g)), self.dropout, self.training)
        h = F.dropout(F.relu(self.c2(h, g)), self.dropout, self.training)
        return self.head(torch.cat([h, x], 1)).squeeze(-1)


class GCN(nn.Module):
    def __init__(self, din, hidden=16, dropout=0.4):
        super().__init__()
        self.c1, self.c2 = GCNConv(din, hidden), GCNConv(hidden, hidden)
        self.head = nn.Linear(hidden + din, 1)
        self.dropout = dropout

    def forward(self, x, g):
        h = F.dropout(F.relu(self.c1(x, g.edge_index, g.w)), self.dropout, self.training)
        h = F.dropout(F.relu(self.c2(h, g.edge_index, g.w)), self.dropout, self.training)
        return self.head(torch.cat([h, x], 1)).squeeze(-1)


class GraphSAGE(nn.Module):
    def __init__(self, din, hidden=16, dropout=0.4):
        super().__init__()
        self.c1, self.c2 = SAGEConv(din, hidden), SAGEConv(hidden, hidden)
        self.head = nn.Linear(hidden + din, 1)
        self.dropout = dropout

    def forward(self, x, g):
        h = F.dropout(F.relu(self.c1(x, g.edge_index)), self.dropout, self.training)
        h = F.dropout(F.relu(self.c2(h, g.edge_index)), self.dropout, self.training)
        return self.head(torch.cat([h, x], 1)).squeeze(-1)


class GAT(nn.Module):
    """Attention over neighbours, with relation type + dependency weight as edge features."""

    def __init__(self, din, hidden=12, heads=2, dropout=0.4):
        super().__init__()
        self.c1 = GATConv(din, hidden, heads=heads, edge_dim=R + 1, dropout=dropout, add_self_loops=False)
        self.c2 = GATConv(hidden * heads, hidden, heads=1, edge_dim=R + 1, dropout=dropout, add_self_loops=False)
        self.head = nn.Linear(hidden + din, 1)
        self.dropout = dropout

    def forward(self, x, g):
        ea = g.edge_attr
        h = F.dropout(F.elu(self.c1(x, g.edge_index, ea)), self.dropout, self.training)
        h = F.elu(self.c2(h, g.edge_index, ea))
        return self.head(torch.cat([h, x], 1)).squeeze(-1)

    @torch.no_grad()
    def attention(self, x, g):
        self.eval()
        ea = g.edge_attr
        h = F.elu(self.c1(x, g.edge_index, ea))
        _, (ei, att) = self.c2(h, g.edge_index, ea, return_attention_weights=True)
        return ei, att.squeeze(-1)


MODELS = {"rgcn": RGCN, "gcn": GCN, "graphsage": GraphSAGE, "gat": GAT}


# ------------------------------------------------------------------- training
LABEL_DIM = 2 * R


def label_features(g: "GraphTensors", known: torch.Tensor, label: torch.Tensor) -> torch.Tensor:
    """Per relation: dependency-weighted share of *known* counterparties that defaulted,
    plus whether any counterparty in that relation has a known status.

    In credit practice a counterparty's observed default (IBC admission, a D
    rating) is public, so this is information a lender really has. A company
    never sees its own label; unknown counterparties are excluded from the
    share rather than counted as healthy (the "label trick", Wang et al. 2021).
    """
    n = known.shape[0]
    kj = known[g.src].float()
    key = g.dst * R + g.rel
    num = torch.zeros(n * R).index_add_(0, key, g.w * kj * label[g.src])
    den = torch.zeros(n * R).index_add_(0, key, g.w * kj)
    share = (num / den.clamp_min(1e-9)).view(n, R)
    has = (den > 0).float().view(n, R)
    return torch.cat([share * has, has], dim=1)


class GNNEnsemble:
    """Seed ensemble of one architecture + Platt calibration (+ optional label trick)."""

    def __init__(self, arch: str = "rgcn", seeds=(0, 1, 2, 3, 4), epochs=600, lr=0.01, wd=2e-3, patience=80,
                 label_trick: bool = True):
        self.arch, self.seeds, self.epochs, self.lr, self.wd, self.patience = arch, seeds, epochs, lr, wd, patience
        self.label_trick = label_trick
        self.nets: list[nn.Module] = []
        self.calib = None
        self.best_epochs: list[int] = []
        self.known = None          # bool mask of nodes whose labels are visible at inference
        self.label = None

    def inputs(self, x: torch.Tensor, known=None, label=None, g=None) -> torch.Tensor:
        if g is not None:
            self._g = g
        if not self.label_trick:
            return x
        known = self.known if known is None else known
        label = self.label if label is None else label
        n = x.shape[0]
        if known.shape[0] < n:          # appended nodes are unknown unless given
            pad = n - known.shape[0]
            known = torch.cat([known, torch.zeros(pad, dtype=torch.bool)])
            label = torch.cat([label, torch.zeros(pad)])
        return torch.cat([x, label_features(self._g, known, label)], dim=1)

    def fit(self, g: GraphTensors, y: np.ndarray, train_idx, val_idx):
        yt = torch.tensor(y, dtype=torch.float32)
        tr, va = torch.tensor(train_idx), torch.tensor(val_idx)
        n = g.x.shape[0]
        pos = float(yt[tr].sum())
        pos_weight = torch.tensor((len(tr) - pos) / max(pos, 1.0)) ** 0.5    # mild re-weighting
        self.known = torch.zeros(n, dtype=torch.bool)
        self.known[tr] = True                     # at inference: all training labels visible
        self.label = yt * self.known
        self._g = g
        din = g.x.shape[1] + (LABEL_DIM if self.label_trick else 0)
        for seed in self.seeds:
            torch.manual_seed(seed)
            gen = torch.Generator().manual_seed(seed)
            net = MODELS[self.arch](din)
            opt = torch.optim.Adam(net.parameters(), lr=self.lr, weight_decay=self.wd)
            best, best_state, best_ep, wait = -1e9, None, 0, 0
            for ep in range(self.epochs):
                net.train()
                opt.zero_grad()
                if self.label_trick:               # 80% of train labels visible, predict the other 20%
                    perm = tr[torch.randperm(len(tr), generator=gen)]
                    cut = int(len(tr) * 0.8)
                    vis, tgt = perm[:cut], perm[cut:]
                    known = torch.zeros(n, dtype=torch.bool)
                    known[vis] = True
                    logit = net(torch.cat([g.x, label_features(g, known, yt * known)], 1), g)
                else:
                    tgt = tr
                    logit = net(g.x, g)
                loss = F.binary_cross_entropy_with_logits(logit[tgt], yt[tgt], pos_weight=pos_weight)
                loss.backward()
                opt.step()
                if ep % 5 == 0:
                    net.eval()
                    with torch.no_grad():
                        pv = net(self.inputs(g.x, g=g), g)[va].numpy()
                    # early stopping on validation log-loss: far less noisy than PR-AUC
                    # when the validation fold holds only ~20 defaults
                    pv_t = torch.tensor(pv)
                    ap = -float(F.binary_cross_entropy_with_logits(pv_t, yt[va]))
                    if ap > best:
                        best, best_ep, wait = ap, ep, 0
                        best_state = {k: v.clone() for k, v in net.state_dict().items()}
                    else:
                        wait += 5
                        if wait >= self.patience:
                            break
            net.load_state_dict(best_state)
            net.eval()
            self.nets.append(net)
            self.best_epochs.append(best_ep)
        # Platt scaling on validation logits -> calibrated PDs
        z = self.logits(g)[val_idx].reshape(-1, 1)
        self.calib = LogisticRegression(C=10.0).fit(z, y[val_idx])
        return self

    @torch.no_grad()
    def logits(self, g: GraphTensors, known=None, label=None) -> np.ndarray:
        xin = self.inputs(g.x, known, label, g=g)
        return np.mean([net(xin, g).numpy() for net in self.nets], axis=0)

    def proba(self, g: GraphTensors, known=None, label=None) -> np.ndarray:
        return self.calib.predict_proba(self.logits(g, known, label).reshape(-1, 1))[:, 1]

    def logit_torch(self, x, g, known=None, label=None):
        xin = self.inputs(x, known, label, g=g)
        return torch.stack([net(xin, g) for net in self.nets]).mean(0)

    # -------------------------------------------------------- explanation
    def integrated_gradients(self, g: GraphTensors, node: int, baseline: torch.Tensor, steps: int = 24):
        """IG of node's logit w.r.t. every node's features (own row + neighbours' rows)."""
        x0 = g.x
        total = torch.zeros_like(x0)
        for a in torch.linspace(1.0 / steps, 1.0, steps):
            xa = (baseline + a * (x0 - baseline)).requires_grad_(True)
            out = self.logit_torch(xa, g)[node]
            (grad,) = torch.autograd.grad(out, xa)
            total += grad
        return ((x0 - baseline) * total / steps).detach().numpy()

    # -------------------------------------------------------- persistence
    def state(self) -> dict:
        return {"arch": self.arch, "seeds": list(self.seeds), "best_epochs": self.best_epochs,
                "label_trick": self.label_trick, "known": self.known, "label": self.label,
                "nets": [net.state_dict() for net in self.nets],
                "calib": (self.calib.coef_.copy(), self.calib.intercept_.copy())}

    @classmethod
    def from_state(cls, st: dict, din: int) -> "GNNEnsemble":
        ens = cls(st["arch"], tuple(st["seeds"]), label_trick=st.get("label_trick", False))
        ens.known, ens.label = st.get("known"), st.get("label")
        for sd in st["nets"]:
            net = MODELS[st["arch"]](din + (LABEL_DIM if ens.label_trick else 0))
            net.load_state_dict(sd)
            net.eval()
            ens.nets.append(net)
        ens.best_epochs = st["best_epochs"]
        lr = LogisticRegression()
        lr.coef_, lr.intercept_ = st["calib"]
        lr.classes_ = np.array([0, 1])
        ens.calib = lr
        return ens


def append_node(g: GraphTensors, x_new: np.ndarray, links: list[tuple[int, str, float]],
                extra_x: list[np.ndarray] | None = None) -> tuple[GraphTensors, int]:
    """Return a graph with a new node (and optional pseudo-counterparty nodes).

    links: (neighbour index, relation, weight); indices >= N refer to extra_x rows
    in order (pseudo counterparties outside the universe).
    """
    n = g.x.shape[0]
    extra = [] if extra_x is None else extra_x
    x = torch.cat([g.x, torch.tensor(np.array(extra + [x_new]), dtype=torch.float32)]) if extra else \
        torch.cat([g.x, torch.tensor(x_new[None, :], dtype=torch.float32)])
    new = n + len(extra)
    rid = {r: k for k, r in enumerate(RELATIONS)}
    src = torch.cat([g.src, torch.tensor([j for j, _, _ in links], dtype=torch.long)])
    dst = torch.cat([g.dst, torch.full((len(links),), new, dtype=torch.long)])
    rel = torch.cat([g.rel, torch.tensor([rid[r] for _, r, _ in links], dtype=torch.long)])
    w = torch.cat([g.w, torch.tensor([float(v) for *_, v in links], dtype=torch.float32)])
    out = GraphTensors(x, src, dst, rel, w)
    out.w_norm = normalise(out, x.shape[0])
    return out, new


def extend_graph(g: GraphTensors, new_x: np.ndarray, edges: list[tuple[int, int, str, float]]) -> GraphTensors:
    """Append rows `new_x` (indices N..N+k-1) and message edges (src, dst, relation, weight).

    Edge endpoints may refer to existing or new nodes, so a whole workspace of
    user companies (and their external counterparties) can be scored together.
    """
    rid = {r: k for k, r in enumerate(RELATIONS)}
    x = torch.cat([g.x, torch.tensor(np.asarray(new_x, dtype=np.float32))]) if len(new_x) else g.x
    if edges:
        src = torch.cat([g.src, torch.tensor([e[0] for e in edges], dtype=torch.long)])
        dst = torch.cat([g.dst, torch.tensor([e[1] for e in edges], dtype=torch.long)])
        rel = torch.cat([g.rel, torch.tensor([rid[e[2]] for e in edges], dtype=torch.long)])
        w = torch.cat([g.w, torch.tensor([float(e[3]) for e in edges], dtype=torch.float32)])
    else:
        src, dst, rel, w = g.src, g.dst, g.rel, g.w
    out = GraphTensors(x, src, dst, rel, w)
    out.w_norm = normalise(out, x.shape[0])
    return out


@torch.no_grad()
def seed_probas(ens: "GNNEnsemble", g: GraphTensors, known, label) -> np.ndarray:
    """Calibrated PD from each seed network separately (for uncertainty bands)."""
    xin = ens.inputs(g.x, known, label, g=g)
    return np.stack([ens.calib.predict_proba(net(xin, g).numpy().reshape(-1, 1))[:, 1] for net in ens.nets])
