const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");
const ppr = @import("src/graph/ppr.zig");
const ippr_mod = @import("src/graph/ppr_incremental.zig");

test "incremental edge addition vs full recompute" {
    var g_before = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g_before.deinit();
    try g_before.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    var full_before = try ppr.pprPush(&g_before, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.testing.allocator);
    defer full_before.deinit();

    var ip = try ippr_mod.IncrementalPpr.initFromFull(full_before, std.testing.allocator);
    defer ip.deinit();

    // mutate graph for both incremental and full recompute target
    try g_before.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    try ip.onEdgeAdded(1, 3, 1.0);
    try ip.deltaUpdate(&g_before);

    var full_after = try ppr.pprPush(&g_before, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.testing.allocator);
    defer full_after.deinit();

    const ip2 = ip.getScore(2);
    const ip3 = ip.getScore(3);
    const full2 = full_after.get(2) orelse 0;
    const full3 = full_after.get(3) orelse 0;

    std.debug.print("add: ip2={d:.6} full2={d:.6} ip3={d:.6} full3={d:.6}\n", .{ ip2, full2, ip3, full3 });

    try std.testing.expect(@abs(ip2 - full2) < 0.05);
    try std.testing.expect(@abs(ip3 - full3) < 0.05);
}

test "incremental edge removal vs full recompute" {
    var g_before = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g_before.deinit();
    try g_before.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    try g_before.addEdge(.{ .src = 1, .dst = 3, .kind = .calls });

    var full_before = try ppr.pprPush(&g_before, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.testing.allocator);
    defer full_before.deinit();

    var ip = try ippr_mod.IncrementalPpr.initFromFull(full_before, std.testing.allocator);
    defer ip.deinit();

    var g_after = graph_mod.CodeGraph.init(std.testing.allocator);
    defer g_after.deinit();
    try g_after.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });

    try ip.onEdgeRemoved(1, 3);
    try ip.deltaUpdate(&g_after);

    var full_after = try ppr.pprPush(&g_after, 1, ppr.DEFAULT_ALPHA, ppr.DEFAULT_EPSILON, std.testing.allocator);
    defer full_after.deinit();

    const ip1 = ip.getScore(1);
    const ip2 = ip.getScore(2);
    const ip3 = ip.getScore(3);

    const full1 = full_after.get(1) orelse 0;
    const full2 = full_after.get(2) orelse 0;
    const full3 = full_after.get(3) orelse 0;

    std.debug.print("remove: ip(1,2,3)=({d:.6},{d:.6},{d:.6}) full=({d:.6},{d:.6},{d:.6})\n", .{ ip1, ip2, ip3, full1, full2, full3 });

    try std.testing.expect(@abs(ip1 - full1) < 0.05);
    try std.testing.expect(@abs(ip2 - full2) < 0.05);
    try std.testing.expect(@abs(ip3 - full3) < 0.05);
}
