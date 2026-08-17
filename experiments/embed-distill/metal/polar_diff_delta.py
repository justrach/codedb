#!/usr/bin/env python3
"""Polar Diff-Delta Attention — last-layer graft. Not LoRA, not softmax-MHA.

Papers mashed into one 64-d layer on the unit sphere:
  Diff Transformer (Ye et al. 2024, arXiv:2410.05258)  — subtract two softmax maps
  Gated DeltaNet     (Yang et al. 2024, arXiv:2412.06464) — write last-T tokens into S
  Forgetting Attn    (Lin et al. 2025, arXiv:2503.02130)  — data-dependent forget on logits
  Modern Hopfield    (Ramsauer / Masumura 2025)           — retrieve from S

Why this for codedb: BM25 near-misses share tokens with the gold. Differential
attention cancels that common-mode ("gateway"/"bind"). Delta memory keeps the
definition span. Forget gate drops call-site junk. Everything is L2.
"""
from __future__ import annotations

import math

import mlx.core as mx
import mlx.nn as nn


class PolarDiffDelta(nn.Module):
    def __init__(self, d: int = 256, d_lat: int = 64, t: int = 16):
        super().__init__()
        self.d = d
        self.d_lat = d_lat
        self.t = t
        scale = 0.02
        self.W_c = mx.random.normal((d, d_lat)) * scale
        self.W_k = mx.random.normal((d_lat, d_lat)) * scale
        self.W_v = mx.random.normal((d_lat, d_lat)) * scale
        self.W_qp = mx.random.normal((d, d_lat)) * scale
        self.W_qn = mx.random.normal((d, d_lat)) * scale
        self.W_o = mx.random.normal((d_lat, d)) * scale
        self.w_f = mx.random.normal((d_lat,)) * scale
        self.w_a = mx.random.normal((d_lat,)) * scale
        self.w_b = mx.random.normal((d_lat,)) * scale
        self.lam = mx.array(0.5)

    def _l2(self, x: mx.array, axis: int = -1) -> mx.array:
        return x / (mx.sqrt(mx.sum(x * x, axis=axis, keepdims=True)) + 1e-6)

    def __call__(self, pooled: mx.array, tokens: mx.array) -> mx.array:
        # pooled [B,D], tokens [B,T,D]
        c = self._l2(tokens @ self.W_c)  # [B,T,L]
        # FoX forget + gated-delta write, unrolled T (T=16, L=64, L1-resident)
        b, t, lat = c.shape
        s = mx.zeros((b, lat, lat))
        f_log = []
        cum = mx.zeros((b,))
        for i in range(t):
            ci = c[:, i, :]
            f = mx.sigmoid(ci @ self.w_f)
            cum = cum + mx.log(f + 1e-6)
            f_log.append(cum)
            k = self._l2(ci @ self.W_k)
            v = ci @ self.W_v
            alpha = mx.sigmoid(ci @ self.w_a)[:, None, None]
            beta = mx.sigmoid(ci @ self.w_b)[:, None]
            sk = mx.einsum("bij,bj->bi", s, k)
            s = alpha * s + beta[:, :, None] * (v - sk)[:, :, None] * k[:, None, :]
        f_log = mx.stack(f_log, axis=1)  # [B,T]
        qp = self._l2(pooled @ self.W_qp)
        qn = self._l2(pooled @ self.W_qn)
        scale = 1.0 / math.sqrt(lat)
        # Diff Transformer retrieve over tokens, FoX-biased
        logits_p = mx.einsum("bl,btl->bt", qp, c) * scale + f_log
        logits_n = mx.einsum("bl,btl->bt", qn, c) * scale + f_log
        ap = mx.softmax(logits_p, axis=-1)
        an = mx.softmax(logits_n, axis=-1)
        attn = ap - self.lam * an
        tok = mx.einsum("bt,btl->bl", attn, c)
        # Hopfield / delta memory retrieve
        mem = mx.einsum("bij,bj->bi", s, qp) - self.lam * mx.einsum("bij,bj->bi", s, qn)
        r = self._l2(tok + mem)
        return self._l2(pooled + r @ self.W_o)


def infonce(q: mx.array, p: mx.array, n: mx.array, temp: float = 0.07) -> mx.array:
    pos = mx.sum(q * p, axis=-1, keepdims=True) / temp
    neg = mx.einsum("bd,bkd->bk", q, n) / temp
    logits = mx.concatenate([pos, neg], axis=-1)
    return mx.mean(mx.logsumexp(logits, axis=-1) - logits[:, 0])
