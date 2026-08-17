#!/usr/bin/env python3
"""Train Polar Diff-Delta on mined KV pairs. Compare MRR to frozen Qwen MRL-256."""
from __future__ import annotations

import argparse
import json
import sys
import time
from collections import defaultdict
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from polar_diff_delta import PolarDiffDelta, infonce  # noqa: E402
from serve_mlx import INSTRUCT, encode_last_tokens, load_qwen  # noqa: E402


def load_groups(path: Path, limit: int) -> list[dict]:
    g: dict[str, dict] = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        row = json.loads(line)
        rec = g.setdefault(row["k"], {"k": row["k"], "pos": None, "negs": []})
        if int(row.get("label", 0)) >= 3:
            rec["pos"] = row["v"]
        else:
            rec["negs"].append(row["v"])
        if len(g) >= limit and rec["pos"] and rec["negs"]:
            break
    out = [x for x in g.values() if x["pos"] and x["negs"]]
    return out[:limit]


def embed_side(model, tok, texts: list[str], bs: int):
    pools, toks = [], []
    for i in range(0, len(texts), bs):
        p, t = encode_last_tokens(model, tok, texts[i : i + bs])
        pools.append(np.array(p))
        toks.append(np.array(t))
        print(f"  embed {min(i+bs,len(texts))}/{len(texts)}", flush=True)
    return np.concatenate(pools), np.concatenate(toks)


def mrr(q, cand) -> float:
    # q [D], cand [K+1, D] with gold at 0
    s = cand @ q
    order = np.argsort(-s)
    rank = int(np.where(order == 0)[0][0]) + 1
    return 1.0 / rank


def eval_mrr(q_p, q_t, p_p, p_t, n_p, n_t, layer=None) -> float:
    scores = []
    n = q_p.shape[0]
    for i in range(n):
        if layer is None:
            qp = q_p[i]
            pos = p_p[i]
            negs = n_p[i]
        else:
            qp = np.array(layer(mx.array(q_p[i : i + 1]), mx.array(q_t[i : i + 1])))[0]
            pos = np.array(layer(mx.array(p_p[i : i + 1]), mx.array(p_t[i : i + 1])))[0]
            k = n_p.shape[1]
            negs = np.array(layer(mx.array(n_p[i]), mx.array(n_t[i])))
        cand = np.concatenate([pos[None], negs], 0)
        scores.append(mrr(qp, cand))
    return float(np.mean(scores))


def save_layer(layer: PolarDiffDelta, path: Path) -> None:
    keys = ["W_c", "W_k", "W_v", "W_qp", "W_qn", "W_o", "w_f", "w_a", "w_b", "lam"]
    np.savez(path, **{k: np.array(getattr(layer, k)) for k in keys})
    print(f"saved {path}", flush=True)


def load_layer(layer: PolarDiffDelta, path: Path) -> None:
    z = np.load(path)
    for k in z.files:
        setattr(layer, k, mx.array(z[k]))
    mx.eval(layer.parameters())
    print(f"loaded weights {path}", flush=True)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--kv", type=Path, default=HERE.parent / "kv.100k.jsonl")
    ap.add_argument("--cache", type=Path, default=HERE / "pdd_cache.npz")
    ap.add_argument("--groups", type=int, default=128)
    ap.add_argument("--steps", type=int, default=80)
    ap.add_argument("--bs", type=int, default=8)
    ap.add_argument("--embed-bs", type=int, default=8)
    ap.add_argument("--save", type=Path, default=HERE / "pdd_weights.npz")
    ap.add_argument("--load", type=Path, default=None)
    ap.add_argument("--eval-cache", type=Path, default=None, help="hold-out cache")
    ap.add_argument("--skip-train", action="store_true")
    args = ap.parse_args()

    if not args.cache.exists():
        groups = load_groups(args.kv, args.groups)
        print(f"groups={len(groups)} building cache", flush=True)
        model, tok = load_qwen("mlx-community/Qwen3-Embedding-8B-4bit-DWQ")
        q_txt = [INSTRUCT + g["k"] for g in groups]
        p_txt = [g["pos"] for g in groups]
        n_txt = []
        n_counts = []
        for g in groups:
            negs = g["negs"][:8]
            n_counts.append(len(negs))
            n_txt.extend(negs)
        q_p, q_t = embed_side(model, tok, q_txt, args.embed_bs)
        p_p, p_t = embed_side(model, tok, p_txt, args.embed_bs)
        n_p_all, n_t_all = embed_side(model, tok, n_txt, args.embed_bs)
        # pack negs to [N,8,D] / [N,8,T,D]
        n_p = np.zeros((len(groups), 8, q_p.shape[-1]), np.float32)
        n_t = np.zeros((len(groups), 8, q_t.shape[1], q_t.shape[-1]), np.float32)
        off = 0
        for i, c in enumerate(n_counts):
            n_p[i, :c] = n_p_all[off : off + c]
            n_t[i, :c] = n_t_all[off : off + c]
            if c < 8:
                n_p[i, c:] = n_p[i, :1]
                n_t[i, c:] = n_t[i, :1]
            off += c
        np.savez(args.cache, q_p=q_p, q_t=q_t, p_p=p_p, p_t=p_t, n_p=n_p, n_t=n_t)
        print(f"wrote {args.cache}", flush=True)
    else:
        z = np.load(args.cache)
        q_p, q_t, p_p, p_t, n_p, n_t = z["q_p"], z["q_t"], z["p_p"], z["p_t"], z["n_p"], z["n_t"]
        print(f"loaded cache n={q_p.shape[0]}", flush=True)

    base = eval_mrr(q_p, q_t, p_p, p_t, n_p, n_t, layer=None)
    print(f"baseline Qwen-MRL-256 MRR={base:.4f}", flush=True)

    layer = PolarDiffDelta()
    mx.eval(layer.parameters())
    if args.load and Path(args.load).exists():
        load_layer(layer, Path(args.load))

    if not args.skip_train:
        opt = optim.Adam(learning_rate=3e-3)

        def loss_fn(layer, qb, qtb, pb, ptb, nb, ntb):
            q = layer(qb, qtb)
            p = layer(pb, ptb)
            b, k, d = nb.shape
            t = ntb.shape[2]
            n = layer(nb.reshape((b * k, d)), ntb.reshape((b * k, t, d))).reshape((b, k, -1))
            return infonce(q, p, n)

        loss_and_grad = nn.value_and_grad(layer, loss_fn)
        n = q_p.shape[0]
        t0 = time.perf_counter()
        for step in range(1, args.steps + 1):
            idx = np.random.randint(0, n, size=args.bs)
            qb, qtb = mx.array(q_p[idx]), mx.array(q_t[idx])
            pb, ptb = mx.array(p_p[idx]), mx.array(p_t[idx])
            nb, ntb = mx.array(n_p[idx]), mx.array(n_t[idx])
            loss, grads = loss_and_grad(layer, qb, qtb, pb, ptb, nb, ntb)
            opt.update(layer, grads)
            mx.eval(layer.parameters(), opt.state)
            if step % 10 == 0 or step == 1:
                print(f"  step {step}/{args.steps} loss={float(loss):.4f}", flush=True)
        print(f"train {time.perf_counter()-t0:.1f}s", flush=True)
        save_layer(layer, args.save)

    trained = eval_mrr(q_p, q_t, p_p, p_t, n_p, n_t, layer=layer)
    print(
        f"train-set Polar Diff-Delta MRR={trained:.4f}  baseline={base:.4f}  "
        f"delta={trained-base:+.4f}",
        flush=True,
    )
    if args.eval_cache and Path(args.eval_cache).exists():
        z = np.load(args.eval_cache)
        eq = z["q_p"], z["q_t"], z["p_p"], z["p_t"], z["n_p"], z["n_t"]
        h_base = eval_mrr(*eq, layer=None)
        h_pdd = eval_mrr(*eq, layer=layer)
        print(
            f"hold-out Qwen-MRL-256 MRR={h_base:.4f}  Polar Diff-Delta MRR={h_pdd:.4f}  "
            f"delta={h_pdd-h_base:+.4f}  n={eq[0].shape[0]}",
            flush=True,
        )


if __name__ == "__main__":
    main()
