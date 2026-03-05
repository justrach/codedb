const std = @import("std");
const tier = @import("src/graph/tier_manager.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var idx: usize = 0;
    while (idx < 128) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(gpa.allocator(), .{ .fail_index = idx });
        var tm = tier.TierManager.init(failing.allocator());

        const first = tm.registerCold(1, "/a");
        if (first) |_| {
            const second = tm.registerCold(1, "/b");
            if (second) |_| {
                tm.deinit();
                continue;
            } else |_| {
                tm.deinit();
                std.debug.print("second failed at idx={d}\n", .{idx});
                return;
            }
        } else |_| {
            tm.deinit();
        }
    }
    std.debug.print("no second-call failure observed\n", .{});
}
