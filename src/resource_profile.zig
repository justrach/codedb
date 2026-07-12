const std = @import("std");
const cio = @import("cio.zig");

/// Runtime resource policy for constrained devices. The default profile keeps
/// desktop/server cache and worker budgets unchanged. `pi` is intentionally
/// opt-in so generic aarch64 Linux hosts do not silently lose cache capacity.
pub const Profile = enum {
    default,
    pi,
};

pub const CacheLimits = struct {
    line_offset_bytes: usize,
    search_entries: usize,
    search_bytes: usize,
    plain_render_entries: usize,
    plain_render_bytes: usize,
    fuzzy_entries: usize,
    tree_entry_bytes: usize,
    outline_entries: usize,
    outline_bytes: usize,
    outline_entry_bytes: usize,
    snapshot_bytes: usize,
    project_entries: usize,
};

const mib: usize = 1024 * 1024;

pub fn parseProfile(raw: ?[]const u8) Profile {
    const value = raw orelse return .default;
    if (std.ascii.eqlIgnoreCase(value, "pi") or
        std.ascii.eqlIgnoreCase(value, "raspberry-pi") or
        std.ascii.eqlIgnoreCase(value, "low-memory"))
    {
        return .pi;
    }
    return .default;
}

pub fn current() Profile {
    return parseProfile(cio.posixGetenv("CODEDB_RESOURCE_PROFILE"));
}

pub fn lowMemoryEnabled() bool {
    return current() == .pi or cio.posixGetenv("CODEDB_LOW_MEMORY") != null;
}

pub fn cacheLimits(profile: Profile) CacheLimits {
    return switch (profile) {
        .default => .{
            .line_offset_bytes = 16 * mib,
            .search_entries = 64,
            .search_bytes = 4 * mib,
            .plain_render_entries = 64,
            .plain_render_bytes = 4 * mib,
            .fuzzy_entries = 32,
            .tree_entry_bytes = 16 * mib,
            .outline_entries = 32,
            .outline_bytes = 16 * mib,
            .outline_entry_bytes = 4 * mib,
            .snapshot_bytes = 16 * mib,
            .project_entries = 5,
        },
        .pi => .{
            .line_offset_bytes = 4 * mib,
            .search_entries = 16,
            .search_bytes = 1 * mib,
            .plain_render_entries = 16,
            .plain_render_bytes = 1 * mib,
            .fuzzy_entries = 8,
            .tree_entry_bytes = 4 * mib,
            .outline_entries = 16,
            .outline_bytes = 4 * mib,
            .outline_entry_bytes = 1 * mib,
            .snapshot_bytes = 4 * mib,
            .project_entries = 2,
        },
    };
}

pub fn principalCacheCeiling(limits: CacheLimits) usize {
    return limits.line_offset_bytes +
        2 * limits.search_bytes +
        limits.plain_render_bytes +
        2 * limits.tree_entry_bytes +
        2 * limits.outline_bytes +
        limits.snapshot_bytes;
}

pub fn profileWorkerCap(profile: Profile, phase_max: usize) usize {
    return switch (profile) {
        .default => phase_max,
        .pi => @min(phase_max, 2),
    };
}

/// Bound parallel phases without changing their minimum of one worker.
/// CODEDB_WORKER_LIMIT overrides the profile cap when it contains a positive
/// integer; phase-specific caps still apply.
pub fn workerCount(cpu_count: usize, phase_max: usize) usize {
    var cap = profileWorkerCap(current(), phase_max);
    if (cio.posixGetenv("CODEDB_WORKER_LIMIT")) |raw| {
        const parsed = std.fmt.parseInt(usize, raw, 10) catch 0;
        if (parsed > 0) cap = @min(phase_max, parsed);
    }
    return @max(@as(usize, 1), @min(cpu_count, cap));
}

test "resource profile aliases and cache budgets" {
    try std.testing.expectEqual(Profile.default, parseProfile(null));
    try std.testing.expectEqual(Profile.default, parseProfile("server"));
    try std.testing.expectEqual(Profile.pi, parseProfile("pi"));
    try std.testing.expectEqual(Profile.pi, parseProfile("Raspberry-Pi"));
    try std.testing.expectEqual(Profile.pi, parseProfile("LOW-MEMORY"));

    const desktop = cacheLimits(.default);
    const pi = cacheLimits(.pi);
    try std.testing.expect(pi.line_offset_bytes < desktop.line_offset_bytes);
    try std.testing.expect(pi.search_bytes < desktop.search_bytes);
    try std.testing.expect(pi.tree_entry_bytes < desktop.tree_entry_bytes);
    try std.testing.expect(pi.snapshot_bytes < desktop.snapshot_bytes);
    try std.testing.expect(pi.project_entries < desktop.project_entries);
    try std.testing.expectEqual(@as(usize, 108 * mib), principalCacheCeiling(desktop));
    try std.testing.expectEqual(@as(usize, 27 * mib), principalCacheCeiling(pi));
    try std.testing.expectEqual(@as(usize, 8), profileWorkerCap(.default, 8));
    try std.testing.expectEqual(@as(usize, 2), profileWorkerCap(.pi, 8));
    try std.testing.expectEqual(@as(usize, 1), profileWorkerCap(.pi, 1));
}
