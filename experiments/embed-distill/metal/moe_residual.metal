// Fused MoE residual on a 256-d Qwen MRL slice.
// 1 threadgroup / row, 256 threads. Working set fits L1.
// out = L2(x + sum_{k=0}^{1} gate_k * down_k(gelu(up_k(x))))
// Specialized: D=256 H=512 E=64 TOPK=2. Not LoRA.

#include <metal_stdlib>
using namespace metal;

constant int D = 256;
constant int H = 512;
constant int E = 64;
constant int TOPK = 2;
constant float GELU_C = 0.7978845608028654f; // sqrt(2/pi)
constant float EPS = 1e-6f;

inline float gelu(float x) {
    float x3 = x * x * x;
    return 0.5f * x * (1.f + precise::tanh(GELU_C * (x + 0.044715f * x3)));
}

kernel void moe_residual(
    device const float* x,
    device const float* router,
    device const float* up,
    device const float* down,
    device float* y,
    uint tid [[thread_position_in_threadgroup]],
    uint row [[threadgroup_position_in_grid]],
    uint tpg [[threads_per_threadgroup]])
{
    threadgroup float xs[256];
    threadgroup float hid[512];
    threadgroup float logits[64];
    threadgroup int eidx[2];
    threadgroup float gates[2];
    threadgroup float residual[256];
    threadgroup float red[8];

    const device float* xr = x + row * D;
    if (tid < D) {
        xs[tid] = xr[tid];
        residual[tid] = 0.f;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // router: 64 experts, one thread per expert, full 256-d dot
    if (tid < E) {
        const device float* w = router + tid * D;
        float acc = 0.f;
        for (int i = 0; i < D; i++) acc += xs[i] * w[i];
        logits[tid] = acc;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    if (tid == 0) {
        int i0 = 0, i1 = 1;
        float v0 = logits[0], v1 = logits[1];
        if (v1 > v0) { float t = v0; v0 = v1; v1 = t; int s = i0; i0 = i1; i1 = s; }
        for (int e = 2; e < E; e++) {
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

    for (int k = 0; k < TOPK; k++) {
        int e = eidx[k];
        float g = gates[k];
        const device float* up_e = up + (e * H * D);
        // up: 512 hidden, 256 threads × 2 rows
        for (int extra = 0; extra < 2; extra++) {
            int h = tid + extra * D;
            const device float* row_w = up_e + h * D;
            float acc = 0.f;
            for (int i = 0; i < D; i++) acc += xs[i] * row_w[i];
            hid[h] = gelu(acc);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        const device float* down_e = down + (e * D * H);
        if (tid < D) {
            const device float* row_w = down_e + tid * H;
            float acc = 0.f;
            for (int i = 0; i < H; i++) acc += hid[i] * row_w[i];
            residual[tid] += g * acc;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // L2(x + residual) with simd_sum
    float local = 0.f;
    if (tid < D) {
        float v = xs[tid] + residual[tid];
        residual[tid] = v;
        local = v * v;
    }
    local = simd_sum(local);
    if (tid % 32 == 0) red[tid / 32] = local;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid < 8) {
        float s = red[tid];
        s = simd_sum(s);
        if (tid == 0) red[0] = s;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = rsqrt(red[0] + EPS);
    if (tid < D) y[row * D + tid] = residual[tid] * inv;
}
