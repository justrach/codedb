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

            // r[u] = 0
            r.putAssumeCapacity(u, 0);
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
