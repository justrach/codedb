// gitagent-mcp — Session cache
//
// Prefetches labels and milestones once per session (2 gh calls on startup).
// All tool handlers read from this cache — no repeated gh calls for static data.
// Issue reads (get_project_state) use a 60s TTL cache entry.
//
// Populated in main.zig on notifications/initialized — after MCP handshake.
// See issue #3 for full implementation.

const std = @import("std");
const gh  = @import("gh.zig");

// ── Types ─────────────────────────────────────────────────────────────────────

pub const Label = struct {
    name:        []const u8,
    color:       []const u8,
    description: []const u8,
};

pub const Milestone = struct {
    number: u32,
    title:  []const u8,
    state:  []const u8,
};

// ── Global session state ──────────────────────────────────────────────────────
// Single instance per server process. Guarded by a simple mutex for the
// prefetch path (called once, from the MCP notification handler thread).

var g_mu:         std.Thread.Mutex  = .{};
var g_ready:      bool              = false;
var g_labels:     std.ArrayList(Label)     = .empty;
var g_milestones: std.ArrayList(Milestone) = .empty;
var g_alloc:      std.mem.Allocator = undefined;

// ── Public API ────────────────────────────────────────────────────────────────

/// Called once on notifications/initialized. Fetches labels + milestones.
/// Subsequent calls are no-ops (guarded by g_ready).
pub fn prefetch(alloc: std.mem.Allocator) void {
    g_mu.lock();
    defer g_mu.unlock();
    if (g_ready) return;
    g_alloc = alloc;

    // gh label list — ignore failure (e.g. no auth), tools degrade gracefully
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
                    const name  = if (item.object.get("name"))        |v| (if (v == .string) v.string else continue) else continue;
                    const color = if (item.object.get("color"))       |v| (if (v == .string) v.string else "") else "";
                    const desc  = if (item.object.get("description")) |v| (if (v == .string) v.string else "") else "";
                    g_labels.append(alloc, .{
                        .name        = alloc.dupe(u8, name)  catch continue,
                        .color       = alloc.dupe(u8, color) catch continue,
                        .description = alloc.dupe(u8, desc)  catch continue,
                    }) catch {};
                }
            }
        }
    }

    g_ready = true;
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
    // Labels and milestones freed when alloc arena is reset — not done here.
    // Full re-implementation in issue #3.
}
