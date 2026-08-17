#!/usr/bin/env python3
"""Fused Metal MoE residual on M-series. 1 TG / row, 256 threads, L1-resident.

Specialized D=256 H=512 E=64 top-2. math_mode=fast. Not LoRA.
"""
from __future__ import annotations

import time
from pathlib import Path

import mlx.core as mx
import numpy as np

D, H, E, TOPK = 256, 512, 64, 2
HERE = Path(__file__).resolve().parent

HEADER = r"""
#include <metal_stdlib>
using namespace metal;
constant int D = 256;
constant int H = 512;
constant int E = 64;
constant int TOPK = 2;
constant float GELU_C = 0.7978845608028654f;
constant float EPS = 1.e-6f;
inline float gelu_fast(float x) {
    float x3 = x * x * x;
    return 0.5f * x * (1.f + precise::tanh(GELU_C * (x + 0.044715f * x3)));
}
"""

SOURCE = r"""
    uint tid = thread_position_in_threadgroup.x;
    uint row = threadgroup_position_in_grid.x;
    threadgroup float xs[256];
    threadgroup float hid[512];
    threadgroup float logits[64];
    threadgroup int eidx[2];
    threadgroup float gates[2];
    threadgroup float residual[256];
    threadgroup float red[8];

    const device float* xr = x + row * D;
    if (tid < D) { xs[tid] = xr[tid]; residual[tid] = 0.f; }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid < E) {
        const device float* w = router + tid * D;
        float acc = 0.f;
        for (int i = 0; i < D; ++i) acc += xs[i] * w[i];
        logits[tid] = acc;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        int i0 = 0, i1 = 1;
        float v0 = logits[0], v1 = logits[1];
        if (v1 > v0) { float t = v0; v0 = v1; v1 = t; int s = i0; i0 = i1; i1 = s; }
        for (int e = 2; e < E; ++e) {
            float v = logits[e];
            if (v > v0) { v1 = v0; i1 = i0; v0 = v; i0 = e; }
            else if (v > v1) { v1 = v; i1 = e; }
        }
        float m = v0 > v1 ? v0 : v1;
        float e0 = metal::exp(v0 - m);
        float e1 = metal::exp(v1 - m);
        float z = e0 + e1;
        eidx[0] = i0; eidx[1] = i1;
        gates[0] = e0 / z; gates[1] = e1 / z;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (int k = 0; k < TOPK; ++k) {
        int e = eidx[k];
        float g = gates[k];
        const device float* up_e = up + (e * H * D);
        for (int extra = 0; extra < 2; ++extra) {
            int h = tid + extra * D;
            const device float* row_w = up_e + h * D;
            float acc = 0.f;
            for (int i = 0; i < D; ++i) acc += xs[i] * row_w[i];
            hid[h] = gelu_fast(acc);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        const device float* down_e = down + (e * D * H);
        if (tid < D) {
            const device float* row_w = down_e + tid * H;
            float acc = 0.f;
            for (int i = 0; i < H; ++i) acc += hid[i] * row_w[i];
            residual[tid] += g * acc;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    float local = 0.f;
    if (tid < D) {
        float v = xs[tid] + residual[tid];
        residual[tid] = v;
        local = v * v;
    }
    local = simd_sum(local);
    if ((tid & 31u) == 0u) red[tid / 32] = local;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < 8) {
        float s = red[tid];
        s = simd_sum(s);
        if (tid == 0) red[0] = s;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = rsqrt(red[0] + EPS);
    if (tid < D) y[row * D + tid] = residual[tid] * inv;
"""

_KERNEL = None


def _kernel():
    global _KERNEL
    if _KERNEL is None:
        _KERNEL = mx.fast.metal_kernel(
            name="moe_residual",
            input_names=["x", "router", "up", "down"],
            output_names=["y"],
            source=SOURCE,
            header=HEADER,
            compile_options={"math_mode": "fast"},
        )
    return _KERNEL


def moe_residual(x: mx.array, router: mx.array, up: mx.array, down: mx.array) -> mx.array:
    x = mx.contiguous(x.astype(mx.float32))
    b = int(x.shape[0])
    out = _kernel()(
        inputs=[x, router.astype(mx.float32), up.astype(mx.float32), down.astype(mx.float32)],
        grid=(b * 256, 1, 1),
        threadgroup=(256, 1, 1),
        output_shapes=[(b, D)],
        output_dtypes=[mx.float32],
    )[0]
    return out


def gelu_np(x: np.ndarray) -> np.ndarray:
    return 0.5 * x * (1.0 + np.tanh(0.7978845608028654 * (x + 0.044715 * x**3)))


def reference(x, router, up, down) -> np.ndarray:
    x = np.asarray(x, np.float32)
    router = np.asarray(router, np.float32)
    up = np.asarray(up, np.float32)
    down = np.asarray(down, np.float32)
    logits = x @ router.T
    idx = np.argpartition(-logits, TOPK, axis=-1)[:, :TOPK]
    # order the two by value
    rows = np.arange(x.shape[0])[:, None]
    vals = np.take_along_axis(logits, idx, axis=-1)
    order = np.argsort(-vals, axis=-1)
    idx = np.take_along_axis(idx, order, axis=-1)
    vals = np.take_along_axis(vals, order, axis=-1)
    vals = vals - vals.max(axis=-1, keepdims=True)
    g = np.exp(vals)
    g = g / g.sum(axis=-1, keepdims=True)
    residual = np.zeros_like(x)
    for k in range(TOPK):
        e = idx[:, k]
        gk = g[:, k][:, None]
        # batched expert
        hid = gelu_np(np.einsum("bd,bhd->bh", x, up[e]))
        residual += gk * np.einsum("bh,bdh->bd", hid, down[e])
    out = x + residual
    out /= np.linalg.norm(out, axis=-1, keepdims=True) + 1e-6
    return out


def random_weights(rng: np.random.Generator):
    router = rng.normal(0, 0.05, (E, D)).astype(np.float32)
    up = rng.normal(0, 0.05, (E, H, D)).astype(np.float32)
    down = rng.normal(0, 0.05, (E, D, H)).astype(np.float32)
    return mx.array(router), mx.array(up), mx.array(down)


def main() -> None:
    rng = np.random.default_rng(7)
    router, up, down = random_weights(rng)
    x = mx.array(rng.normal(0, 1, (8, D)).astype(np.float32))
    x = x / mx.linalg.norm(x, axis=-1, keepdims=True)
    y = moe_residual(x, router, up, down)
    mx.eval(y)
    ref = reference(np.array(x), np.array(router), np.array(up), np.array(down))
    err = float(np.max(np.abs(np.array(y) - ref)))
    print(f"max_abs_err={err:.6e}")

    # warmup + bench
    xb = mx.array(rng.normal(0, 1, (256, D)).astype(np.float32))
    xb = xb / mx.linalg.norm(xb, axis=-1, keepdims=True)
    for _ in range(5):
        mx.eval(moe_residual(xb, router, up, down))
    t0 = time.perf_counter()
    iters = 50
    for _ in range(iters):
        mx.eval(moe_residual(xb, router, up, down))
    dt = (time.perf_counter() - t0) / iters
    print(f"batch=256  {dt*1e6:.1f} us  {256/dt:.0f} vec/s  active~5M")


if __name__ == "__main__":
    main()
