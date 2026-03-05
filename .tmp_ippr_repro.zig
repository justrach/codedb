const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var g = graph_mod.CodeGraph.init(alloc);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });
    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 1.0 });

    var full_before = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full_before.deinit();
    var ippr = try ippr_mod.IncrementalPpr.initFromFull(full_before, alloc);
    defer ippr.deinit();

    var g2 = graph_mod.CodeGraph.init(alloc);
    defer g2.deinit();
    try g2.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });

    try ippr.onEdgeRemoved(1, 3);
    try ippr.deltaUpdate(&g2);

    var full_after = try ppr.pprPush(&g2, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full_after.deinit();

    const inc2 = ippr.getScore(2);
    const inc3 = ippr.getScore(3);
    const full2 = full_after.get(2) orelse 0;
    const full3 = full_after.get(3) orelse 0;
    std.debug.print("inc2={d:.6} full2={d:.6} inc3={d:.6} full3={d:.6}\n", .{ inc2, full2, inc3, full3 });
}
