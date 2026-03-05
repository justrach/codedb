const std = @import("std");
const ppr = @import("src/graph/ppr.zig");
const ip = @import("src/graph/ppr_incremental.zig");
const graph_mod = @import("src/graph/graph.zig");

pub fn main() !void {
    var g_before = graph_mod.CodeGraph.init(std.heap.page_allocator);
    defer g_before.deinit();
    try g_before.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g_before.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    var full_before = try ppr.pprPush(&g_before, 1, ip.DEFAULT_ALPHA, ip.DEFAULT_EPSILON, std.heap.page_allocator);
    defer full_before.deinit();
    var inc = try ip.IncrementalPpr.initFromFull(full_before, std.heap.page_allocator);
    defer inc.deinit();

    // notify removal 1->3 and run delta against graph with only 1->2
    var g_after = graph_mod.CodeGraph.init(std.heap.page_allocator);
    defer g_after.deinit();
    try g_after.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    try inc.onEdgeRemoved(1, 3);
    try inc.deltaUpdate(&g_after);

    var full_after = try ppr.pprPush(&g_after, 1, ip.DEFAULT_ALPHA, ip.DEFAULT_EPSILON, std.heap.page_allocator);
    defer full_after.deinit();

    std.debug.print("inc {d:.6} {d:.6} {d:.6}\n", .{ inc.getScore(1), inc.getScore(2), inc.getScore(3) });
    std.debug.print("full {d:.6} {d:.6} {d:.6}\n", .{ full_after.get(1) orelse 0, full_after.get(2) orelse 0, full_after.get(3) orelse 0 });
}
