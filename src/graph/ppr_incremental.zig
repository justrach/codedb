// CodeGraph DB — Incremental Personalized PageRank
//
// Maintains a cached PPR result and updates it incrementally when edges
// change, avoiding full recomputation. Uses local push operations to
// propagate score changes from affected nodes.
//
// On edge addition: injects residual at the source node proportional to
// its current score and the new edge weight.
//
// On edge removal: marks affected nodes dirty and redistributes their
// scores via local pushes.
//
// On file invalidation: marks all symbols in the file as dirty so that
// the next deltaUpdate recomputes their local neighbourhoods.

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

pub const IncrementalPpr = struct {
    scores: std.AutoHashMap(u64, f32),
    residuals: std.AutoHashMap(u64, f32),
    dirty_nodes: std.AutoHashMap(u64, void),
    alpha: f32,
    epsilon: f32,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) IncrementalPpr {
        return .{
            .scores = std.AutoHashMap(u64, f32).init(alloc),
            .residuals = std.AutoHashMap(u64, f32).init(alloc),
            .dirty_nodes = std.AutoHashMap(u64, void).init(alloc),
            .alpha = DEFAULT_ALPHA,
            .epsilon = DEFAULT_EPSILON,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *IncrementalPpr) void {
        self.scores.deinit();
        self.residuals.deinit();
        self.dirty_nodes.deinit();
    }

    /// Initialize from a previously computed full PPR result.
    /// Takes ownership-style copy of the scores map contents.
    pub fn initFromFull(
        full_scores: std.AutoHashMap(u64, f32),
        alloc: std.mem.Allocator,
    ) !IncrementalPpr {
        var result = init(alloc);
        errdefer result.deinit();

        var it = full_scores.iterator();
        while (it.next()) |entry| {
            try result.scores.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        return result;
    }

    // ── Incremental update notifications ─────────────────────────────

    /// Notify that an edge was added from src to dst with the given weight.
    /// Injects residual at the source node so the next deltaUpdate propagates
    /// the score change through the new edge.
    pub fn onEdgeAdded(self: *IncrementalPpr, src: u64, dst: u64, weight: f32) void {
        _ = dst;
        // The source node's outgoing weight distribution changed, so its
        // current score needs to be partially redistributed. We inject
        // residual proportional to the source's current score and the
        // weight of the new edge, scaled by (1-alpha).
        const src_score = self.scores.get(src) orelse 0;
        const injection = (1.0 - self.alpha) * src_score * weight;

        if (injection > 0) {
            const entry = self.residuals.getOrPut(src) catch return;
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += injection;
        }

        // Mark source as dirty regardless (edge topology changed)
        self.dirty_nodes.put(src, {}) catch {};
    }

    /// Notify that an edge from src to dst was removed.
    /// Marks the source node dirty so deltaUpdate can recompute its local
    /// neighbourhood. Also redistributes the score that was flowing through
    /// the removed edge back as residual on the source.
    pub fn onEdgeRemoved(self: *IncrementalPpr, src: u64, dst: u64) void {
        // The score that was flowing to dst through this edge needs to be
        // reclaimed. We approximate by marking both nodes dirty and injecting
        // residual at the source.
        const src_score = self.scores.get(src) orelse 0;
        const dst_score = self.scores.get(dst) orelse 0;

        // Inject residual at source proportional to its score
        if (src_score > 0) {
            const entry = self.residuals.getOrPut(src) catch return;
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += (1.0 - self.alpha) * src_score;
        }

        // Reduce dst score (it was partially derived from the removed edge)
        // and convert to residual for redistribution
        if (dst_score > 0) {
            const reduction = dst_score * 0.5; // conservative estimate
            if (self.scores.getPtr(dst)) |ptr| {
                ptr.* -= reduction;
                if (ptr.* < 0) ptr.* = 0;
            }
            const dst_entry = self.residuals.getOrPut(dst) catch return;
            if (!dst_entry.found_existing) dst_entry.value_ptr.* = 0;
            dst_entry.value_ptr.* += reduction;
        }

        self.dirty_nodes.put(src, {}) catch {};
        self.dirty_nodes.put(dst, {}) catch {};
    }

    /// Notify that a file was invalidated (e.g. modified on disk).
    /// All symbols belonging to that file are marked dirty with residual
    /// injected based on their current scores.
    pub fn onFileInvalidated(self: *IncrementalPpr, symbol_ids: []const u64) void {
        for (symbol_ids) |id| {
            self.dirty_nodes.put(id, {}) catch {};

            // Inject residual so scores get recomputed
            const score = self.scores.get(id) orelse 0;
            if (score > 0) {
                const entry = self.residuals.getOrPut(id) catch continue;
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += score;
            }
        }
    }

    /// Apply all pending incremental updates using local push operations.
    /// This is much cheaper than a full PPR recomputation because it only
    /// processes nodes with significant residual, starting from dirty nodes.
    pub fn deltaUpdate(self: *IncrementalPpr, graph: *const CodeGraph) !void {
        // For dirty nodes that have no residual yet, seed them with a
        // small residual based on their current score to ensure they
        // get processed.
        var dirty_it = self.dirty_nodes.iterator();
        while (dirty_it.next()) |entry| {
            const node = entry.key_ptr.*;
            if (self.residuals.get(node) == null) {
                const score = self.scores.get(node) orelse 0;
                if (score > 0) {
                    try self.residuals.put(node, score * self.alpha);
                }
            }
        }

        // Run local push operations until convergence (same algorithm as
        // full PPR but starting from residuals rather than a single seed).
        var changed = true;
        while (changed) {
            changed = false;

            // Collect nodes that need pushing
            var to_push: std.ArrayList(u64) = .empty;
            defer to_push.deinit(self.alloc);

            var rit = self.residuals.iterator();
            while (rit.next()) |entry| {
                const u = entry.key_ptr.*;
                const r_u = entry.value_ptr.*;
                const deg = graph.outDegree(u);
                const threshold = if (deg > 0)
                    self.epsilon * @as(f32, @floatFromInt(deg))
                else
                    self.epsilon;
                if (r_u > threshold) {
                    try to_push.append(self.alloc, u);
                }
            }

            for (to_push.items) |u| {
                const r_u = self.residuals.get(u) orelse continue;
                if (r_u <= 0) continue;

                changed = true;

                // p[u] += alpha * r[u]
                const p_entry = try self.scores.getOrPut(u);
                if (!p_entry.found_existing) p_entry.value_ptr.* = 0;
                p_entry.value_ptr.* += self.alpha * r_u;

                // Distribute residual to out-neighbours
                const edges = graph.outEdges(u);
                if (edges.len > 0) {
                    var w_total: f32 = 0;
                    for (edges) |e| w_total += e.weight;

                    if (w_total > 0) {
                        for (edges) |e| {
                            const share = (1.0 - self.alpha) * r_u * e.weight / w_total;
                            const r_entry = try self.residuals.getOrPut(e.dst);
                            if (!r_entry.found_existing) r_entry.value_ptr.* = 0;
                            r_entry.value_ptr.* += share;
                        }
                    }
                }

                // r[u] = 0
                self.residuals.putAssumeCapacity(u, 0);
            }
        }

        // Clear dirty set after update
        self.dirty_nodes.clearAndFree();
    }

    // ── Queries ──────────────────────────────────────────────────────

    /// Get the current PPR score for a node, or 0 if not scored.
    pub fn getScore(self: *const IncrementalPpr, node_id: u64) f32 {
        return self.scores.get(node_id) orelse 0;
    }

    /// Return the top-K scored nodes in descending order of score.
    pub fn topK(self: *const IncrementalPpr, k: usize, alloc: std.mem.Allocator) ![]ScoredNode {
        var items: std.ArrayList(ScoredNode) = .empty;
        defer items.deinit(alloc);

        var it = self.scores.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* > 0) {
                try items.append(alloc, .{
                    .id = entry.key_ptr.*,
                    .score = entry.value_ptr.*,
                });
            }
        }

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

    /// Returns how many nodes are currently marked dirty.
    pub fn dirtyCount(self: *const IncrementalPpr) usize {
        return self.dirty_nodes.count();
    }
};

// ── Tests ───────────────────────────────────────────────────────────────────

fn makeTestGraph(alloc: std.mem.Allocator) CodeGraph {
    return CodeGraph.init(alloc);
}

test "init and deinit with no leaks" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(1));
}

test "initFromFull copies scores" {
    // Build a full PPR result
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var full_scores = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full_scores.deinit();

    var ippr = try IncrementalPpr.initFromFull(full_scores, std.testing.allocator);
    defer ippr.deinit();

    // Scores should match the full computation
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
    try std.testing.expect(ippr.getScore(3) > 0);
    try std.testing.expectApproxEqAbs(full_scores.get(1).?, ippr.getScore(1), 1e-6);
    try std.testing.expectApproxEqAbs(full_scores.get(2).?, ippr.getScore(2), 1e-6);
}

test "onEdgeAdded marks source dirty and injects residual" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Seed a score for node 1
    try ippr.scores.put(1, 0.5);

    ippr.onEdgeAdded(1, 2, 1.0);

    try std.testing.expectEqual(@as(usize, 1), ippr.dirtyCount());
    // Residual should be injected at source
    const r = ippr.residuals.get(1) orelse 0;
    try std.testing.expect(r > 0);
}

test "onEdgeRemoved marks both nodes dirty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    ippr.onEdgeRemoved(1, 2);

    try std.testing.expectEqual(@as(usize, 2), ippr.dirtyCount());
    // Residual should exist at source
    try std.testing.expect((ippr.residuals.get(1) orelse 0) > 0);
}

test "onFileInvalidated marks all symbols dirty" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(10, 0.2);
    try ippr.scores.put(11, 0.3);
    try ippr.scores.put(12, 0.1);

    const ids = [_]u64{ 10, 11, 12 };
    ippr.onFileInvalidated(&ids);

    try std.testing.expectEqual(@as(usize, 3), ippr.dirtyCount());
}

test "deltaUpdate propagates residuals through edges" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // Inject residual at node 1 (simulating initial seed)
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});

    try ippr.deltaUpdate(&g);

    // After update, scores should propagate through the chain
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
    try std.testing.expect(ippr.getScore(3) > 0);
    // Node 1 should have highest score (closest to seed)
    try std.testing.expect(ippr.getScore(1) > ippr.getScore(2));
    try std.testing.expect(ippr.getScore(2) > ippr.getScore(3));
    // Dirty set should be cleared
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
}

test "deltaUpdate after edge addition increases downstream scores" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Initial graph: 1 -> 2
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    // Compute full PPR
    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    var ippr = try IncrementalPpr.initFromFull(full, std.testing.allocator);
    defer ippr.deinit();

    const score_2_before = ippr.getScore(2);

    // Add new edge: 1 -> 3
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
    ippr.onEdgeAdded(1, 3, 1.0);
    try ippr.deltaUpdate(&g);

    // Node 3 should now have a positive score
    try std.testing.expect(ippr.getScore(3) > 0);
    // Node 2's score may decrease slightly since out-weight is shared
    // but both should remain positive
    try std.testing.expect(ippr.getScore(2) > 0);
    _ = score_2_before;
}

test "deltaUpdate after edge removal adjusts scores" {
    const ppr_mod = @import("ppr.zig");
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    // Initial graph: 1 -> 2, 1 -> 3
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    var full = try ppr_mod.pprPush(&g, 1, DEFAULT_ALPHA, DEFAULT_EPSILON, std.testing.allocator);
    defer full.deinit();

    var ippr = try IncrementalPpr.initFromFull(full, std.testing.allocator);
    defer ippr.deinit();

    // Notify edge removal (we don't actually remove from graph for this test,
    // just check that the incremental update processes dirty nodes)
    ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g);

    // After update, dirty set should be cleared
    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    // Scores should still be positive (push propagates)
    try std.testing.expect(ippr.getScore(1) > 0);
    try std.testing.expect(ippr.getScore(2) > 0);
}

test "topK returns correct descending order" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);
    try ippr.scores.put(3, 0.8);
    try ippr.scores.put(4, 0.1);

    const top = try ippr.topK(3, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 3), top.len);
    // Should be descending
    try std.testing.expect(top[0].score >= top[1].score);
    try std.testing.expect(top[1].score >= top[2].score);
    // Top node should be node 3 with score 0.8
    try std.testing.expectEqual(@as(u64, 3), top[0].id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), top[0].score, 1e-6);
}

test "topK with k larger than available" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.scores.put(1, 0.5);
    try ippr.scores.put(2, 0.3);

    const top = try ippr.topK(100, std.testing.allocator);
    defer std.testing.allocator.free(top);

    try std.testing.expectEqual(@as(usize, 2), top.len);
}

test "deltaUpdate on empty graph is no-op" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    try ippr.deltaUpdate(&g);

    try std.testing.expectEqual(@as(usize, 0), ippr.dirtyCount());
    try std.testing.expectEqual(@as(f32, 0), ippr.getScore(1));
}

test "onFileInvalidated with no prior scores is safe" {
    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    const ids = [_]u64{ 100, 200, 300 };
    ippr.onFileInvalidated(&ids);

    try std.testing.expectEqual(@as(usize, 3), ippr.dirtyCount());
    // No residual since scores are 0
    try std.testing.expectEqual(@as(?f32, null), ippr.residuals.get(100));
}

test "multiple deltaUpdates converge" {
    var g = makeTestGraph(std.testing.allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g.addEdge(.{ .src = 2, .dst = 3, .kind = .calls });

    var ippr = IncrementalPpr.init(std.testing.allocator);
    defer ippr.deinit();

    // First update: seed at node 1
    try ippr.residuals.put(1, 1.0);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    const s1_first = ippr.getScore(1);

    // Second update with small perturbation
    try ippr.residuals.put(1, 0.01);
    try ippr.dirty_nodes.put(1, {});
    try ippr.deltaUpdate(&g);

    const s1_second = ippr.getScore(1);

    // Score should increase slightly but not dramatically
    try std.testing.expect(s1_second >= s1_first);
    try std.testing.expect(s1_second - s1_first < 0.1);
}
