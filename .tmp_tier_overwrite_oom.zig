const std = @import("std");
const tier = @import("src/graph/tier_manager.zig");

pub fn main() !void {
    var idx: usize = 0;
    while (idx < 20) : (idx += 1) {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer {
            const status = gpa.deinit();
            _ = status;
        }
        var failing = std.testing.FailingAllocator.init(gpa.allocator(), .{ .fail_index = idx });
        var tm = tier.TierManager.init(failing.allocator());
        defer tm.deinit();

        const a = tm.registerCold(1, "/repo/a") catch |e| {
            if (e == error.OutOfMemory) continue;
            return e;
        };
        _ = a;

        const b = tm.registerCold(1, "/repo/b") catch |e| {
            if (e == error.OutOfMemory) {
                std.debug.print("fail_index={d}: second register OOM\n", .{idx});
                continue;
            }
            return e;
        };
        _ = b;
    }
}
