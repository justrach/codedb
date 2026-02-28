// CodeGraph DB — Personalized PageRank (push algorithm)
//
// Andersen-Chung-Lang push approximation for PPR.
// Given a query node, computes relevance scores for all reachable nodes.
//
// Push rule: if r[u] > ε × deg(u), push u:
//   p[u] += α × r[u]
//   r[v] += (1-α) × r[u] × W(u,v) / W_out(u)  for each out-neighbour v
//   r[u] = 0
//
// Complexity: O(1/ε) pushes.

const std = @import("std");
const graph_mod = @import("graph.zig");
const CodeGraph = graph_mod.CodeGraph;
const Edge = graph_mod.Edge;

pub const DEFAULT_ALPHA: f32 = 0.15;
pub const DEFAULT_EPSILON: f32 = 1e-4;

pub const ScoredNode = struct {
    id: u64,
    score: f32,
};

/// Andersen-Chung-Lang PPR push algorithm.
///
/// Returns a map of node_id → PPR score for all nodes with non-zero score.
/// `alpha` is the teleport probability (typically 0.15).
/// `epsilon` is the convergence threshold per unit of degree.
pub fn pprPush(
    g: *const CodeGraph,
    query_node: u64,
    alpha: f32,
    epsilon: f32,
    alloc: std.mem.Allocator,
) !std.AutoHashMap(u64, f32) {
    var p = std.AutoHashMap(u64, f32).init(alloc);
    errdefer p.deinit();
    var r = std.AutoHashMap(u64, f32).init(alloc);
    defer r.deinit();

    // Initialise residual: r[query] = 1.0
    try r.put(query_node, 1.0);

    // Iterative push until no node exceeds threshold
    var changed = true;
    while (changed) {
        changed = false;

        // Collect nodes that need pushing in this iteration.
        // We can't mutate the map while iterating, so collect keys first.
        var to_push: std.ArrayList(u64) = .empty;
        defer to_push.deinit(alloc);

        var it = r.iterator();
        while (it.next()) |entry| {
            const u = entry.key_ptr.*;
            const r_u = entry.value_ptr.*;
            const deg = g.outDegree(u);
            const threshold = if (deg > 0)
                epsilon * @as(f32, @floatFromInt(deg))
            else
                epsilon;
            if (r_u > threshold) {
                try to_push.append(alloc, u);
            }
        }

        for (to_push.items) |u| {
            const r_u = r.get(u) orelse continue;
            if (r_u <= 0) continue;

            changed = true;

            // p[u] += α × r[u]
            const p_entry = try p.getOrPut(u);
            if (!p_entry.found_existing) p_entry.value_ptr.* = 0;
            p_entry.value_ptr.* += alpha * r_u;

            // Zero r[u] BEFORE distributing to neighbours.
            // This is critical for correctness with self-loops: if u has
            // an edge to itself, the distributed share must accumulate on
            // top of 0, not be wiped out by a later zeroing.
            r.putAssumeCapacity(u, 0);

            // Distribute residual to out-neighbours
            const edges = g.outEdges(u);
            if (edges.len > 0) {
                // Compute total out-weight for normalisation
                var w_total: f32 = 0;
                for (edges) |e| w_total += e.weight;

                if (w_total > 0) {
                    for (edges) |e| {
                        const share = (1.0 - alpha) * r_u * e.weight / w_total;
                        const r_entry = try r.getOrPut(e.dst);
                        if (!r_entry.found_existing) r_entry.value_ptr.* = 0;
                        r_entry.value_ptr.* += share;
                    }
                }
            }
        }
    }

    return p;
}

/// Returns the top-K scored nodes in descending order.
/// Optionally excludes a node (typically the query node itself).
pub fn topK(
    scores: *const std.AutoHashMap(u64, f32),
    k: usize,
    exclude: ?u64,
    alloc: std.mem.Allocator,
) ![]ScoredNode {
    // Collect all entries
    var items: std.ArrayList(ScoredNode) = .empty;
    defer items.deinit(alloc);

    var it = scores.iterator();
    while (it.next()) |entry| {
        if (exclude) |ex| {
            if (entry.key_ptr.* == ex) continue;
        }
        try items.append(alloc, .{ .id = entry.key_ptr.*, .score = entry.value_ptr.* });
    }

    // Sort descending by score
    std.mem.sort(ScoredNode, items.items, {}, struct {
        fn cmp(_: void, a: ScoredNode, b: ScoredNode) bool {
            return a.score > b.score;
        }
    }.cmp);

    const n = @min(k, items.items.len);
    const result = try alloc.alloc(ScoredNode, n);
    @memcpy(result, items.items[0..n]);
    return result;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn makeTestGraph(alloc: std.mem.Allocator) CodeGraph {
    return CodeGraph.init(alloc);
}

test "single node graph — PPR is alpha on itself" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addSymbol(.{ .id = 1, .name = "a", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });
    // No edges — isolated node

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const s = scores.get(1).?;
    // With no out-edges, only the initial push happens: p[1] = α × 1.0 = 0.15
    try std.testing.expectApproxEqAbs(DEFAULT_ALPHA, s, 1e-4);
}

test "star graph — hub distributes to spokes" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Hub (1) → spokes (2, 3, 4)
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 4, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Hub should have highest score
    const hub_score = scores.get(1).?;
    const spoke2 = scores.get(2) orelse 0;
    const spoke3 = scores.get(3) orelse 0;
    const spoke4 = scores.get(4) orelse 0;

    try std.testing.expect(hub_score > spoke2);
    // All spokes should get equal score (uniform weight)
    try std.testing.expectApproxEqAbs(spoke2, spoke3, 1e-4);
    try std.testing.expectApproxEqAbs(spoke3, spoke4, 1e-4);
    // Spokes should have positive score
    try std.testing.expect(spoke2 > 0);
}

test "cycle graph — all nodes get score" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 → 2 → 3 → 1 (cycle)
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 3, .dst = 1, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // All nodes should have positive score
    try std.testing.expect((scores.get(1) orelse 0) > 0);
    try std.testing.expect((scores.get(2) orelse 0) > 0);
    try std.testing.expect((scores.get(3) orelse 0) > 0);

    // Query node should have highest score due to teleport bias
    const s1 = scores.get(1).?;
    const s2 = scores.get(2).?;
    const s3 = scores.get(3).?;
    try std.testing.expect(s1 > s2);
    try std.testing.expect(s1 > s3);
}

test "disconnected graph — unreachable nodes get no score" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Component A: 1 → 2
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    // Component B: 3 → 4 (disconnected)
    try g.addEdge(.{ .src = 3, .dst = 4, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Reachable from 1
    try std.testing.expect((scores.get(1) orelse 0) > 0);
    try std.testing.expect((scores.get(2) orelse 0) > 0);
    // Unreachable from 1
    try std.testing.expectEqual(@as(?f32, null), scores.get(3));
    try std.testing.expectEqual(@as(?f32, null), scores.get(4));
}

test "topK returns correct descending order" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 → 2, 1 → 3, 1 → 4 with different weights
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 3.0 });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 1.0 });
    try g.addEdge(.{ .src = 1, .dst = 4, .kind = .calls, .weight = 2.0 });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const top = try topK(&scores, 3, 1, std.testing.allocator); // exclude query node
    defer std.testing.allocator.free(top);

    // Should be descending
    try std.testing.expect(top.len >= 2);
    for (0..top.len - 1) |i| {
        try std.testing.expect(top[i].score >= top[i + 1].score);
    }
    // Node 2 should be top (highest weight edge)
    try std.testing.expectEqual(@as(u64, 2), top[0].id);
}

test "topK with k larger than available" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const top = try topK(&scores, 100, null, std.testing.allocator);
    defer std.testing.allocator.free(top);

    // Should return all available nodes (≤ 100)
    try std.testing.expect(top.len <= 100);
    try std.testing.expect(top.len >= 1);
}

test "empty graph returns empty scores" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    var scores = try pprPush(&g, 999, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Query node still gets α from the initial push
    const s = scores.get(999).?;
    try std.testing.expectApproxEqAbs(DEFAULT_ALPHA, s, 1e-4);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "PPR on graph with self-loop" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Node 1 points to itself
    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .references });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Self-loop: all residual stays on node 1
    // Score should converge to 1.0 (all probability mass stays on node 1)
    const s = scores.get(1).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s, 1e-2);
    // Should only have node 1 in scores
    try std.testing.expectEqual(@as(u32, 1), scores.count());
}

test "PPR with alpha=1 — all score stays on query node" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var scores = try pprPush(&g, 1, 1.0, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // With alpha=1.0, teleport probability is 100% — no distribution to neighbours
    // p[1] = 1.0 * r[1] = 1.0, and (1-alpha) * r[1] = 0 so nothing flows out
    const s1 = scores.get(1).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), s1, 1e-4);
    // Neighbours should get no score (or null)
    const s2 = scores.get(2) orelse 0.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s2, 1e-6);
}

test "PPR with alpha=0 — all score distributed to neighbours" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 → 2 (single edge, no cycles)
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var scores = try pprPush(&g, 1, 0.0, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // alpha=0 means p[u] += 0 * r[u] = 0 for the query node on first push
    // but all residual flows to node 2: r[2] += (1-0) * 1.0 = 1.0
    // Then node 2 has no out-edges, so p[2] += 0 * 1.0 = 0
    // Actually: p[u] += alpha * r[u] = 0, so no node gets any p score!
    const s1 = scores.get(1) orelse 0.0;
    const s2 = scores.get(2) orelse 0.0;
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s1, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), s2, 1e-6);
}

test "PPR with very small epsilon converges more precisely" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 → 2 → 3 → 1 (cycle)
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 3, .dst = 1, .kind = .calls });

    // Run with smaller epsilon for tighter convergence
    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, 1e-6, std.testing.allocator);
    defer scores.deinit();

    // All nodes should have positive score
    const s1 = scores.get(1).?;
    const s2 = scores.get(2).?;
    const s3 = scores.get(3).?;
    try std.testing.expect(s1 > 0);
    try std.testing.expect(s2 > 0);
    try std.testing.expect(s3 > 0);

    // Total score should be close to 1.0 for well-converged PPR
    const total = s1 + s2 + s3;
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), total, 0.01);
}

test "PPR on larger disconnected graph — only reachable component scored" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Component A: 1 → 2 → 3
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    // Component B: 10 → 11 → 12
    try g.addEdge(.{ .src = 10, .dst = 11, .kind = .calls });
    try g.addEdge(.{ .src = 11, .dst = 12, .kind = .calls });
    // Isolated node: 20
    try g.addSymbol(.{ .id = 20, .name = "isolated", .kind = .function, .file_id = 0, .line = 1, .col = 0, .scope = "" });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Component A reachable
    try std.testing.expect((scores.get(1) orelse 0) > 0);
    try std.testing.expect((scores.get(2) orelse 0) > 0);
    try std.testing.expect((scores.get(3) orelse 0) > 0);
    // Component B unreachable
    try std.testing.expectEqual(@as(?f32, null), scores.get(10));
    try std.testing.expectEqual(@as(?f32, null), scores.get(11));
    try std.testing.expectEqual(@as(?f32, null), scores.get(12));
    // Isolated node unreachable
    try std.testing.expectEqual(@as(?f32, null), scores.get(20));
}

test "PPR on graph with multiple self-loops" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // 1 → 1 (self), 1 → 2, 2 → 2 (self)
    try g.addEdge(.{ .src = 1, .dst = 1, .kind = .references });
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 2, .kind = .references });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Both nodes should have positive scores
    const s1 = scores.get(1) orelse 0.0;
    const s2 = scores.get(2) orelse 0.0;
    try std.testing.expect(s1 > 0);
    try std.testing.expect(s2 > 0);
    // Node 2 has a self-loop that retains 100% of its residual, while node 1
    // splits its residual 50/50 between self and node 2. So node 2 may
    // accumulate more score than node 1. We just verify both are scored.
    try std.testing.expect(s1 + s2 > 0.5);
}

test "topK with k=0 returns empty slice" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const top = try topK(&scores, 0, null, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 0), top.len);
}

test "topK with exclude matching all nodes returns empty" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Single node, no edges — only query node gets a score
    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    // Exclude the only node that has a score
    const top = try topK(&scores, 10, 1, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 0), top.len);
}

test "topK on empty scores map returns empty" {
    var scores = std.AutoHashMap(u64, f32).init(std.testing.allocator);
    defer scores.deinit();

    const top = try topK(&scores, 10, null, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 0), top.len);
}

test "topK with k=1 returns highest scorer" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 10.0 });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const top = try topK(&scores, 1, 1, std.testing.allocator); // exclude query
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 1), top.len);
    // Node 3 should be ranked highest (higher weight edge)
    try std.testing.expectEqual(@as(u64, 3), top[0].id);
}

test "PPR scores are all non-negative" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Build a small complex graph
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 3, .dst = 4, .kind = .calls });
    try g.addEdge(.{ .src = 4, .dst = 1, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .imports });
    try g.addEdge(.{ .src = 2, .dst = 4, .kind = .references });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    var it = scores.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(entry.value_ptr.* >= 0.0);
    }
}

test "PPR with weighted edges distributes proportionally" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Node 1 → 2 with weight 9, Node 1 → 3 with weight 1
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 9.0 });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 1.0 });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const s2 = scores.get(2) orelse 0.0;
    const s3 = scores.get(3) orelse 0.0;
    // Node 2 should get ~9x the score of node 3
    try std.testing.expect(s2 > s3);
    // Rough proportionality check: s2/s3 should be close to 9
    if (s3 > 1e-10) {
        const ratio = s2 / s3;
        try std.testing.expect(ratio > 5.0); // generous tolerance
        try std.testing.expect(ratio < 15.0);
    }
}

test "PPR on long chain — scores decrease with distance" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Chain: 1 → 2 → 3 → 4 → 5
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });
    try g.addEdge(.{ .src = 3, .dst = 4, .kind = .calls });
    try g.addEdge(.{ .src = 4, .dst = 5, .kind = .calls });

    var scores = try pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer scores.deinit();

    const s1 = scores.get(1) orelse 0.0;
    const s2 = scores.get(2) orelse 0.0;
    const s3 = scores.get(3) orelse 0.0;
    const s4 = scores.get(4) orelse 0.0;
    const s5 = scores.get(5) orelse 0.0;

    // Scores should monotonically decrease along the chain
    try std.testing.expect(s1 > s2);
    try std.testing.expect(s2 > s3);
    try std.testing.expect(s3 > s4);
    try std.testing.expect(s4 > s5);
    try std.testing.expect(s5 > 0);
}

test "PPR constants have expected values" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.15), DEFAULT_ALPHA, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1e-4), DEFAULT_EPSILON, 1e-10);
}

test "topK preserves score values" {
    var scores = std.AutoHashMap(u64, f32).init(std.testing.allocator);
    defer scores.deinit();

    try scores.put(1, 0.5);
    try scores.put(2, 0.3);
    try scores.put(3, 0.2);

    const top = try topK(&scores, 3, null, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 3), top.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), top[0].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), top[1].score, 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), top[2].score, 1e-6);
}
