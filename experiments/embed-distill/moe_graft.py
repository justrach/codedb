#!/usr/bin/env python3
"""Full-rank MoE residual on a frozen Qwen3-Embedding vector. Not LoRA.

Qwen3-Embedding-8B (MRL 256) stays frozen. This module is the only trainable
object: 64 experts, top-2, ~5M active. Train on kv.jsonl with InfoNCE.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

try:
    import torch
    import torch.nn as nn
    import torch.nn.functional as F
except ImportError:  # pragma: no cover
    torch = None  # type: ignore
    nn = None  # type: ignore
    F = None  # type: ignore


class MoEResidual(nn.Module if nn is not None else object):
    """out = L2(x + sum_i gate_i * expert_i(x)). Full-rank experts, not LoRA."""

    def __init__(self, dim: int = 256, hidden: int = 512, experts: int = 64, top_k: int = 2):
        if nn is None:
            raise RuntimeError("pip install torch")
        super().__init__()
        self.dim = dim
        self.experts_n = experts
        self.top_k = top_k
        self.router = nn.Linear(dim, experts, bias=False)
        self.up = nn.Parameter(torch.empty(experts, hidden, dim))
        self.down = nn.Parameter(torch.empty(experts, dim, hidden))
        nn.init.kaiming_uniform_(self.up, a=math.sqrt(5))
        nn.init.kaiming_uniform_(self.down, a=math.sqrt(5))

    def forward(self, x: "torch.Tensor") -> "torch.Tensor":
        # x: [B, D] already L2 (Qwen MRL-256)
        logits = self.router(x)
        gates, idx = torch.topk(logits, self.top_k, dim=-1)
        gates = torch.softmax(gates, dim=-1)
        residual = torch.zeros_like(x)
        for slot in range(self.top_k):
            e = idx[:, slot]
            g = gates[:, slot].unsqueeze(-1)
            up = self.up[e]
            down = self.down[e]
            hid = F.gelu(torch.bmm(up, x.unsqueeze(-1)).squeeze(-1))
            residual = residual + g * torch.bmm(down, hid.unsqueeze(-1)).squeeze(-1)
        return F.normalize(x + residual, dim=-1)


def infonce(q: "torch.Tensor", p: "torch.Tensor", n: "torch.Tensor", temp: float = 0.05) -> "torch.Tensor":
    # q,p: [B, D], n: [B, K, D]
    pos = (q * p).sum(-1, keepdim=True) / temp
    neg = torch.einsum("bd,bkd->bk", q, n) / temp
    logits = torch.cat([pos, neg], dim=-1)
    target = torch.zeros(q.size(0), dtype=torch.long, device=q.device)
    return F.cross_entropy(logits, target)


def load_groups(path: Path) -> list[dict]:
    groups: dict[str, dict] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        key = row["k"]
        g = groups.setdefault(key, {"k": key, "pos": None, "negs": []})
        if row.get("label", 0) >= 3:
            g["pos"] = row["v"]
        else:
            g["negs"].append(row["v"])
    return [g for g in groups.values() if g["pos"] and g["negs"]]


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kv", type=Path, default=Path(__file__).with_name("kv.100k.jsonl"))
    ap.add_argument("--dim", type=int, default=256)
    ap.add_argument("--experts", type=int, default=64)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    groups = load_groups(args.kv) if args.kv.exists() else []
    n_neg = sum(len(g["negs"]) for g in groups)
    print(f"groups={len(groups)} negs={n_neg} dim={args.dim} experts={args.experts}")
    if args.dry_run or torch is None:
        print("graft = freeze Qwen3-Embedding-8B (MRL 256) + MoEResidual (not LoRA)")
        return
    model = MoEResidual(dim=args.dim, experts=args.experts)
    params = sum(p.numel() for p in model.parameters())
    print(f"trainable={params} (~{params/1e6:.1f}M stored, top-2 active)")


if __name__ == "__main__":
    main()
