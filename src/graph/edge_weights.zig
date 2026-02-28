// CodeGraph DB — edge weight computation
//
// Weights determine how strongly two nodes are connected in the code graph.
// Used by PPR to rank relevant symbols for a given query.

const std = @import("std");
const types = @import("types.zig");
pub const Edge = types.Edge;

// ── Constants ───────────────────────────────────────────────────────────────

pub const MODIFIES_BOOST: f32 = 20.0;
pub const DEFAULT_HALF_LIFE_DAYS: f32 = 90.0;

// ── Weight functions ────────────────────────────────────────────────────────

/// Exponential decay: decay = exp(-λ × age_days), where λ = ln(2) / half_life.
/// `last_modified_ms` is a unix timestamp in milliseconds.
pub fn recencyDecay(last_modified_ms: i64, half_life_days: f32) f32 {
    const now_ms: i64 = std.time.milliTimestamp();
    const age_ms: f64 = @floatFromInt(now_ms - last_modified_ms);
    const age_days: f64 = age_ms / (1000.0 * 60.0 * 60.0 * 24.0);
    if (age_days <= 0.0) return 1.0;
    const lambda: f64 = @as(f64, @log(@as(f64, 2.0))) / @as(f64, @floatCast(half_life_days));
    return @floatCast(@exp(-lambda * age_days));
}

/// Recency decay with an explicit "now" timestamp (for deterministic testing).
pub fn recencyDecayAt(last_modified_ms: i64, half_life_days: f32, now_ms: i64) f32 {
    const age_ms: f64 = @floatFromInt(now_ms - last_modified_ms);
    const age_days: f64 = age_ms / (1000.0 * 60.0 * 60.0 * 24.0);
    if (age_days <= 0.0) return 1.0;
    const lambda: f64 = @as(f64, @log(@as(f64, 2.0))) / @as(f64, @floatCast(half_life_days));
    return @floatCast(@exp(-lambda * age_days));
}

/// CALLS weight: frequency × recency × (1 / depth).
pub fn callsWeight(
    call_frequency: u32,
    last_modified_ms: i64,
    depth_in_callstack: u32,
    half_life_days: f32,
) f32 {
    const freq: f32 = @floatFromInt(call_frequency);
    const depth: f32 = @floatFromInt(@max(depth_in_callstack, 1));
    const decay = recencyDecay(last_modified_ms, half_life_days);
    return freq * decay / depth;
}

/// CALLS weight with explicit "now" (for deterministic testing).
pub fn callsWeightAt(
    call_frequency: u32,
    last_modified_ms: i64,
    depth_in_callstack: u32,
    half_life_days: f32,
    now_ms: i64,
) f32 {
    const freq: f32 = @floatFromInt(call_frequency);
    const depth: f32 = @floatFromInt(@max(depth_in_callstack, 1));
    const decay = recencyDecayAt(last_modified_ms, half_life_days, now_ms);
    return freq * decay / depth;
}

/// IMPORTS weight: always 1.0 (structural dependency).
pub fn importsWeight() f32 {
    return 1.0;
}

/// MODIFIES weight: co-change probability = commits_touching_both / total_commits.
pub fn modifiesWeight(commits_touching_both: u32, total_commits: u32) f32 {
    if (total_commits == 0) return 0.0;
    const both: f32 = @floatFromInt(commits_touching_both);
    const total: f32 = @floatFromInt(total_commits);
    return both / total;
}

/// Stanton condition: p > 3(k + √k + 1) · l · q
/// Used to verify edge weight dominance thresholds.
pub fn stantonConditionHolds(p: f32, q: f32, k: u32, l: f32) bool {
    const kf: f64 = @floatFromInt(k);
    const threshold: f64 = 3.0 * (kf + @sqrt(kf) + 1.0) * @as(f64, @floatCast(l)) * @as(f64, @floatCast(q));
    return @as(f64, @floatCast(p)) > threshold;
}

/// Normalise out-edges so their weights sum to 1.0.
/// If all weights are zero, assigns uniform distribution.
pub fn normaliseOutEdges(edges: []Edge) void {
    if (edges.len == 0) return;

    var total: f32 = 0.0;
    for (edges) |e| total += e.weight;

    if (total == 0.0) {
        // Uniform distribution
        const uniform: f32 = 1.0 / @as(f32, @floatFromInt(edges.len));
        for (edges) |*e| e.weight = uniform;
    } else {
        for (edges) |*e| e.weight /= total;
    }
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "importsWeight is always 1.0" {
    try std.testing.expectEqual(@as(f32, 1.0), importsWeight());
}

test "modifiesWeight computes co-change probability" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), modifiesWeight(5, 10), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), modifiesWeight(10, 10), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), modifiesWeight(0, 10), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), modifiesWeight(0, 0), 1e-6);
}

test "recencyDecay at half-life equals 0.5" {
    const half_life: f32 = 90.0;
    const half_life_ms: i64 = 90 * 24 * 60 * 60 * 1000;
    const now: i64 = 1_700_000_000_000;
    const modified = now - half_life_ms;
    const decay = recencyDecayAt(modified, half_life, now);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), decay, 1e-4);
}

test "recencyDecay at zero age equals 1.0" {
    const now: i64 = 1_700_000_000_000;
    const decay = recencyDecayAt(now, 90.0, now);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decay, 1e-6);
}

test "recencyDecay at future timestamp equals 1.0" {
    const now: i64 = 1_700_000_000_000;
    const decay = recencyDecayAt(now + 1_000_000, 90.0, now);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), decay, 1e-6);
}

test "callsWeight combines frequency, recency, depth" {
    const now: i64 = 1_700_000_000_000;
    // freq=4, age=0, depth=2 → 4 * 1.0 / 2 = 2.0
    const w = callsWeightAt(4, now, 2, 90.0, now);
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), w, 1e-6);
}

test "callsWeight depth clamped to 1" {
    const now: i64 = 1_700_000_000_000;
    // freq=3, age=0, depth=0 → should clamp to 1 → 3.0 * 1.0 / 1 = 3.0
    const w = callsWeightAt(3, now, 0, 90.0, now);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), w, 1e-6);
}

test "stantonConditionHolds for known values" {
    // k=2: threshold = 3 * (2 + √2 + 1) * l * q
    //     = 3 * (2 + 1.414 + 1) * 1.0 * 1.0 ≈ 13.24
    try std.testing.expect(stantonConditionHolds(14.0, 1.0, 2, 1.0));
    try std.testing.expect(!stantonConditionHolds(13.0, 1.0, 2, 1.0));

    // k=3: threshold = 3 * (3 + √3 + 1) * 1.0 * 1.0 ≈ 17.196
    try std.testing.expect(stantonConditionHolds(18.0, 1.0, 3, 1.0));
    try std.testing.expect(!stantonConditionHolds(17.0, 1.0, 3, 1.0));

    // k=5: threshold = 3 * (5 + √5 + 1) * 1.0 * 1.0 ≈ 24.708
    try std.testing.expect(stantonConditionHolds(25.0, 1.0, 5, 1.0));
    try std.testing.expect(!stantonConditionHolds(24.0, 1.0, 5, 1.0));

    // k=10: threshold = 3 * (10 + √10 + 1) * 1.0 * 1.0 ≈ 42.487
    try std.testing.expect(stantonConditionHolds(43.0, 1.0, 10, 1.0));
    try std.testing.expect(!stantonConditionHolds(42.0, 1.0, 10, 1.0));
}

test "normaliseOutEdges sums to 1.0" {
    var edges = [_]Edge{
        .{ .src = 1, .dst = 2, .kind = .calls, .weight = 2.0 },
        .{ .src = 1, .dst = 3, .kind = .calls, .weight = 3.0 },
        .{ .src = 1, .dst = 4, .kind = .calls, .weight = 5.0 },
    };
    normaliseOutEdges(&edges);

    try std.testing.expectApproxEqAbs(@as(f32, 0.2), edges[0].weight, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), edges[1].weight, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edges[2].weight, 1e-6);
}

test "normaliseOutEdges zero weights gives uniform" {
    var edges = [_]Edge{
        .{ .src = 1, .dst = 2, .kind = .calls, .weight = 0.0 },
        .{ .src = 1, .dst = 3, .kind = .calls, .weight = 0.0 },
    };
    normaliseOutEdges(&edges);

    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edges[0].weight, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), edges[1].weight, 1e-6);
}

test "normaliseOutEdges empty slice is no-op" {
    var edges = [_]Edge{};
    normaliseOutEdges(&edges);
}

test "constants match spec" {
    try std.testing.expectEqual(@as(f32, 20.0), MODIFIES_BOOST);
    try std.testing.expectEqual(@as(f32, 90.0), DEFAULT_HALF_LIFE_DAYS);
}
