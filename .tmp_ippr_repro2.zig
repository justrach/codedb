const std = @import("std");
const graph = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var g = graph.CodeGraph.init(alloc);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });

    var full = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full.deinit();
    var ip = try ippr_mod.IncrementalPpr.initFromFull(full, alloc);
    defer ip.deinit();

    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 100.0 });
    try ip.onEdgeAdded(1, 3, 100.0);
    try ip.deltaUpdate(&g);

    var full2 = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full2.deinit();

    const n2_full = full2.get(2) orelse 0;
    const n2_inc = ip.getScore(2);
    const n3_full = full2.get(3) orelse 0;
    const n3_inc = ip.getScore(3);
    const n1_full = full2.get(1) orelse 0;
    const n1_inc = ip.getScore(1);

    std.debug.print("n1 full={d:.6} inc={d:.6}\n", .{ n1_full, n1_inc });
    std.debug.print("n2 full={d:.6} inc={d:.6}\n", .{ n2_full, n2_inc });
    std.debug.print("n3 full={d:.6} inc={d:.6}\n", .{ n3_full, n3_inc });
}
