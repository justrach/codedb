const std = @import("std");
const ppr = @import("src/graph/ppr.zig");
const ip = @import("src/graph/ppr_incremental.zig");
const graph_mod = @import("src/graph/graph.zig");

pub fn main() !void {
    var g = graph_mod.CodeGraph.init(std.heap.page_allocator);
    defer g.deinit();

    try g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    var full0 = try ppr.pprPush(&g, 1, ip.DEFAULT_ALPHA, ip.DEFAULT_EPSILON, std.heap.page_allocator);
    defer full0.deinit();
    var inc = try ip.IncrementalPpr.initFromFull(full0, std.heap.page_allocator);
    defer inc.deinit();

    try g.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });
    try inc.onEdgeAdded(1, 3, 1.0);
    try inc.deltaUpdate(&g);

    var full1 = try ppr.pprPush(&g, 1, ip.DEFAULT_ALPHA, ip.DEFAULT_EPSILON, std.heap.page_allocator);
    defer full1.deinit();

    std.debug.print("inc {d:.6} {d:.6} {d:.6}\n", .{ inc.getScore(1), inc.getScore(2), inc.getScore(3) });
    std.debug.print("full {d:.6} {d:.6} {d:.6}\n", .{ full1.get(1) orelse 0, full1.get(2) orelse 0, full1.get(3) orelse 0 });
}
