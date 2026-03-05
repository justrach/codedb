const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var g = graph_mod.CodeGraph.init(alloc);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls, .weight = 1.0 });

    var full0 = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full0.deinit();

    var ippr = try ippr_mod.IncrementalPpr.initFromFull(full0, alloc);
    defer ippr.deinit();

    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls, .weight = 1.0 });

    try ippr.onEdgeAdded(1, 3, 1.0);
    try ippr.deltaUpdate(&g);

    var full1 = try ppr.pprPush(&g, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, alloc);
    defer full1.deinit();

    const ip_node2 = ippr.getScore(2);
    const ip_node3 = ippr.getScore(3);
    const full_node2 = full1.get(2) orelse 0;
    const full_node3 = full1.get(3) orelse 0;

    std.debug.print("ippr n2={d:.6} n3={d:.6}\n", .{ ip_node2, ip_node3 });
    std.debug.print("full n2={d:.6} n3={d:.6}\n", .{ full_node2, full_node3 });
    std.debug.print("abs diff n2={d:.6} n3={d:.6}\n", .{ @abs(ip_node2 - full_node2), @abs(ip_node3 - full_node3) });
}
