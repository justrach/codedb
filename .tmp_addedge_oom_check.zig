const std = @import("std");
const graph_mod = @import("src/graph/graph.zig");

fn tryFail(idx: usize) !bool {
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = idx });
    var g = graph_mod.CodeGraph.init(failing.allocator());
    defer g.deinit();

    const res = g.addEdge(.{ .src = 1, .dst = 2, .kind = .calls });
    if (res) |_| {
        return false;
    } else |err| {
        if (err != error.OutOfMemory) return false;
        const out_len = g.outEdges(1).len;
        const in_len = g.inEdges(2).len;
        if (out_len != in_len) {
            std.debug.print("mismatch at fail_index={d}, out={d}, in={d}\n", .{ idx, out_len, in_len });
            return true;
        }
        return false;
    }
}

test "find mismatch" {
    var found = false;
    for (0..64) |i| {
        if (try tryFail(i)) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
