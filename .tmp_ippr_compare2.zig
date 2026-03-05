const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

fn buildGraph(with_edge_13: bool, alloc: std.mem.Allocator) !graph_mod.CodeGraph {
    var g = graph_mod.CodeGraph.init(alloc);
    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 10.0 });
    if (with_edge_13) try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 0.1 });
    try g.addEdge(.{ .src = 2, .dst = 4, .kind = .calls, .weight = 1.0 });
    return g;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var g_before = try buildGraph(true, alloc);
    defer g_before.deinit();
    var g_after = try buildGraph(false, alloc);
    defer g_after.deinit();

    var full_before = try ppr.pprPush(&g_before, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full_before.deinit();
    var ippr = try ippr_mod.IncrementalPpr.initFromFull(full_before, alloc);
    defer ippr.deinit();

    try ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g_after);
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        try ippr.deltaUpdate(&g_after);
    }

    var full_after = try ppr.pprPush(&g_after, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full_after.deinit();

    const nodes = [_]u64{ 1, 2, 3, 4 };
    for (nodes) |n| {
        const a = full_after.get(n) orelse 0;
        const b = ippr.getScore(n);
        std.debug.print("node {d}: full={d:.6} incr={d:.6} diff={d:.6}\n", .{ n, a, b, @abs(a - b) });
    }
}
