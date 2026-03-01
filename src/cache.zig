// gitagent-mcp — Session cache
//
// Prefetches labels and milestones once per MCP session and keeps them available
// to all handlers for quicker, deterministic behavior.

const std = @import("std");
const gh = @import("gh.zig");

const BootstrapLabel = struct {
    name: []const u8,
    color: []const u8,
    description: []const u8,
};

const default_labels = [_]BootstrapLabel{
    .{ .name = "status:backlog", .color = "f6f8fa", .description = "Work item has not been started" },
    .{ .name = "status:blocked", .color = "db6d28", .description = "Work item is blocked by dependency" },
    .{ .name = "status:in-progress", .color = "fbca04", .description = "Work item is actively being worked on" },
    .{ .name = "status:in-review", .color = "1d76db", .description = "Work item has an open PR" },
    .{ .name = "status:done", .color = "0e8a16", .description = "Work item is complete" },
    .{ .name = "priority:p0", .color = "b60205", .description = "Highest priority" },
    .{ .name = "priority:p1", .color = "d93f0b", .description = "High priority" },
    .{ .name = "priority:p2", .color = "fbca04", .description = "Medium priority" },
    .{ .name = "priority:p3", .color = "0e8a16", .description = "Low priority" },
};

pub const Label = struct {
    name: []const u8,
    color: []const u8,
    description: []const u8,
};

pub const Milestone = struct {
    number: u32,
    title: []const u8,
    state: []const u8,
};

var g_mu: std.Thread.Mutex = .{};
var g_ready: bool = false;
var g_has_data: bool = false;
var g_labels: std.ArrayList(Label) = .empty;
var g_milestones: std.ArrayList(Milestone) = .empty;
var g_alloc: std.mem.Allocator = undefined;

fn clearCachedData() void {
    for (g_labels.items) |lbl| {
        g_alloc.free(lbl.name);
        g_alloc.free(lbl.color);
        g_alloc.free(lbl.description);
    }
    g_labels.clearAndFree(g_alloc);

    for (g_milestones.items) |ms| {
        g_alloc.free(ms.title);
        g_alloc.free(ms.state);
    }
    g_milestones.clearAndFree(g_alloc);
}

fn labelExists(name: []const u8) bool {
    for (g_labels.items) |lbl| {
        if (std.mem.eql(u8, lbl.name, name)) return true;
    }
    return false;
}

fn milestoneExists(title: []const u8) bool {
    for (g_milestones.items) |ms| {
        if (std.mem.eql(u8, ms.title, title)) return true;
    }
    return false;
}

fn createMissingLabels(alloc: std.mem.Allocator) void {
    for (default_labels) |label| {
        if (labelExists(label.name)) continue;

        const create_r = gh.run(alloc, &.{
            "gh", "label", "create", label.name,
            "--color", label.color,
            "--description", label.description,
        }) catch null;
        if (create_r == null) continue;

        defer create_r.?.deinit(alloc);
        appendLabel(alloc, label.name, label.color, label.description);
    }
}

fn appendLabel(alloc: std.mem.Allocator, name: []const u8, color: []const u8, description: []const u8) void {
    const name_owned = alloc.dupe(u8, name) catch return;
    errdefer alloc.free(name_owned);

    const color_owned = alloc.dupe(u8, color) catch return;
    errdefer alloc.free(color_owned);

    const desc_owned = alloc.dupe(u8, description) catch return;
    errdefer alloc.free(desc_owned);

    g_labels.append(alloc, .{
        .name = name_owned,
        .color = color_owned,
        .description = desc_owned,
    }) catch {
        alloc.free(name_owned);
        alloc.free(color_owned);
        alloc.free(desc_owned);
    };
}

fn appendMilestone(alloc: std.mem.Allocator, number: u32, title: []const u8, state: []const u8) void {
    const title_owned = alloc.dupe(u8, title) catch return;
    errdefer alloc.free(title_owned);

    const state_owned = alloc.dupe(u8, state) catch return;
    errdefer alloc.free(state_owned);

    g_milestones.append(alloc, .{
        .number = number,
        .title = title_owned,
        .state = state_owned,
    }) catch {
        alloc.free(title_owned);
        alloc.free(state_owned);
    };
}

/// Called once on notifications/initialized. Fetches labels + milestones.
/// Subsequent calls are no-ops (guarded by g_ready).
pub fn prefetch(alloc: std.mem.Allocator) void {
    g_mu.lock();
    defer g_mu.unlock();

    if (g_ready) return;
    g_alloc = alloc;

    var labels_ok = false;
    const labels_r = gh.run(alloc, &.{
        "gh", "label", "list",
        "--json", "name,color,description",
        "--limit", "100",
    }) catch null;
    if (labels_r) |r| {
        defer r.deinit(alloc);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, r.stdout, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .array) {
                for (p.value.array.items) |item| {
                    if (item != .object) continue;

                    const name = if (item.object.get("name")) |v| if (v == .string) v.string else continue else continue;
                    const color = if (item.object.get("color")) |v| if (v == .string) v.string else "" else "";
                    const desc = if (item.object.get("description")) |v| if (v == .string) v.string else "" else "";
                    appendLabel(alloc, name, color, desc);
                }
            }
        }

        createMissingLabels(alloc);
        labels_ok = true;
    }

    var milestones_ok = false;
    const milestones_r = gh.run(alloc, &.{
        "gh", "milestone", "list",
        "--json", "number,title,state",
        "--state", "all",
    }) catch null;
    if (milestones_r) |r| {
        defer r.deinit(alloc);
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, r.stdout, .{}) catch null;
        if (parsed) |p| {
            defer p.deinit();
            if (p.value == .array) {
                for (p.value.array.items) |item| {
                    if (item != .object) continue;

                    const number: u32 = blk: {
                        const val = item.object.get("number") orelse continue;
                        break :blk switch (val) {
                            .integer => |i| if (i <= 0) continue else @as(u32, @intCast(i)),
                            else => continue,
                        };
                    };
                    const title = blk: {
                        const val = item.object.get("title") orelse continue;
                        break :blk switch (val) {
                            .string => val.string,
                            else => continue,
                        };
                    };
                    const state = blk: {
                        const val = item.object.get("state") orelse continue;
                        break :blk switch (val) {
                            .string => val.string,
                            else => "",
                        };
                    };

                    if (milestoneExists(title)) continue;
                    appendMilestone(alloc, number, title, state);
                }
            }
        }
        milestones_ok = true;
    }

    if (!labels_ok or !milestones_ok) {
        clearCachedData();
        g_ready = false;
        g_has_data = false;
        return;
    }

    g_ready = true;
    g_has_data = true;
}

/// Look up a label by name. Returns null if not in cache or cache not ready.
pub fn getLabel(name: []const u8) ?Label {
    g_mu.lock();
    defer g_mu.unlock();

    if (!g_ready) return null;
    for (g_labels.items) |lbl| {
        if (std.mem.eql(u8, lbl.name, name)) return lbl;
    }
    return null;
}

/// Look up a milestone by title. Returns null if not found.
pub fn getMilestone(title: []const u8) ?Milestone {
    g_mu.lock();
    defer g_mu.unlock();

    if (!g_ready) return null;
    for (g_milestones.items) |ms| {
        if (std.mem.eql(u8, ms.title, title)) return ms;
    }
    return null;
}

/// Whether the cache has been populated.
pub fn isReady() bool {
    g_mu.lock();
    defer g_mu.unlock();
    return g_ready;
}

/// Force a refresh (e.g. after creating a new label).
pub fn invalidate() void {
    g_mu.lock();
    defer g_mu.unlock();

    g_ready = false;
    if (!g_has_data) return;

    clearCachedData();

    g_has_data = false;
}
