#!/usr/bin/env python3
"""Qwen3-Embedding-8B-4bit (MLX) + fused Metal MoE residual.

Small-active path on Apple Silicon: 4-bit prefill + 5M-active MoE head.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

import mlx.core as mx
import mlx.nn as nn
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
from metal_moe import D, moe_residual, random_weights  # noqa: E402

DEFAULT_MODEL = "mlx-community/Qwen3-Embedding-8B-4bit-DWQ"
INSTRUCT = "Instruct: Retrieve the implementing code span for this question\nQuery:"


def last_token_hidden(hidden: mx.array, attn: mx.array) -> mx.array:
    # hidden [B, T, C], attn [B, T]
    lengths = attn.sum(axis=-1) - 1
    b = hidden.shape[0]
    return hidden[mx.arange(b), lengths.astype(mx.int32)]


def mrl256(vec: mx.array) -> mx.array:
    v = vec[:, :D].astype(mx.float32)
    return v / mx.linalg.norm(v, axis=-1, keepdims=True)


def load_qwen(model_id: str):
    from mlx_lm import load

    model, tokenizer = load(model_id)
    return model, tokenizer


def encode_hidden(model, tokenizer, texts: list[str], max_len: int = 512) -> mx.array:
    inner_tok = getattr(tokenizer, "_tokenizer", tokenizer)
    toks = inner_tok(
        texts,
        return_tensors="np",
        padding=True,
        truncation=True,
        max_length=max_len,
    )
    ids = mx.array(toks["input_ids"])
    mask = mx.array(toks["attention_mask"])
    inner = model.model if hasattr(model, "model") else model
    hidden = inner(ids)
    if isinstance(hidden, (tuple, list)):
        hidden = hidden[0]
    mx.eval(hidden)
    return mrl256(last_token_hidden(hidden, mask))

def encode_last_tokens(model, tokenizer, texts: list[str], max_len: int = 256, t_keep: int = 16) -> tuple:
    """Return (pooled_256 [B,D], tokens_256 [B,t_keep,D]). Right-padded."""
    inner_tok = getattr(tokenizer, "_tokenizer", tokenizer)
    toks = inner_tok(
        texts, return_tensors="np", padding=True, truncation=True, max_length=max_len,
    )
    ids = mx.array(toks["input_ids"])
    mask = np.asarray(toks["attention_mask"])
    inner = model.model if hasattr(model, "model") else model
    hidden = inner(ids)
    if isinstance(hidden, (tuple, list)):
        hidden = hidden[0]
    mx.eval(hidden)
    h = np.asarray(hidden.astype(mx.float32))
    b, t, c = h.shape
    pooled = np.zeros((b, D), np.float32)
    tokens = np.zeros((b, t_keep, D), np.float32)
    for i in range(b):
        n = int(mask[i].sum())
        last = h[i, n - 1, :D]
        pooled[i] = last / (np.linalg.norm(last) + 1e-6)
        start = max(n - t_keep, 0)
        sl = h[i, start:n, :D]
        if sl.shape[0] < t_keep:
            pad = np.zeros((t_keep - sl.shape[0], D), np.float32)
            sl = np.concatenate([pad, sl], 0)
        nrm = np.linalg.norm(sl, axis=-1, keepdims=True) + 1e-6
        tokens[i] = sl / nrm
    return mx.array(pooled), mx.array(tokens)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--skip-qwen", action="store_true", help="bench MoE only")
    ap.add_argument("texts", nargs="*", default=[
        INSTRUCT + "Where does the gateway pick its primary LAN IPv4 address?",
        "export function pickPrimaryLanIPv4(): string | undefined {",
    ])
    args = ap.parse_args()
    rng = np.random.default_rng(0)
    router, up, down = random_weights(rng)

    if args.skip_qwen:
        x = mx.array(rng.normal(0, 1, (len(args.texts), D)).astype(np.float32))
        x = x / mx.linalg.norm(x, axis=-1, keepdims=True)
    else:
        print(f"load {args.model}", flush=True)
        t0 = time.perf_counter()
        model, tokenizer = load_qwen(args.model)
        print(f"  loaded in {time.perf_counter() - t0:.1f}s", flush=True)
        t1 = time.perf_counter()
        x = encode_hidden(model, tokenizer, args.texts)
        print(f"  qwen4bit {x.shape} in {time.perf_counter() - t1:.3f}s", flush=True)

    y = moe_residual(x, router, up, down)
    mx.eval(y)
    print(json.dumps({
        "dim": D,
        "n": int(y.shape[0]),
        "l2": [float(v) for v in np.linalg.norm(np.array(y), axis=-1)],
        "cos_01": float(np.array(y[0] @ y[1])) if y.shape[0] > 1 else None,
    }))


if __name__ == "__main__":
    main()
