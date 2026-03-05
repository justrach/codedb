// runtime/cascade.zig — Tool cascade (#266)
//
// Extends search.zig:probe() pattern to detect ALL tool categories.
// Determines which shell tools are available: zig* preferred, then rg/sed/grep fallback.
// The result feeds into system prompt assembly — agents get instructions for
// whichever tools are actually on PATH.

const std = @import("std");
const gh  = @import("../gh.zig");

/// Tool tier: which set of tools is available on this machine.
pub const ToolTier = enum {
    zig_tools,   // zigrep, zigread, zigpatch, zigcreate, zigdiff — full suite
    standard,    // rg/grep, cat/head, sed/awk, touch/tee — unix fallback
    minimal,     // only grep + cat + basic shell — bare minimum

    pub fn label(self: ToolTier) []const u8 {
        return switch (self) {
            .zig_tools => "zig_tools",
            .standard  => "standard",
            .minimal   => "minimal",
        };
    }
};

/// Detailed availability of individual tool categories.
pub const ToolAvailability = struct {
    // Search
    has_zigrep: bool = false,
    has_rg: bool = false,
    has_grep: bool = false,

    // Read
    has_zigread: bool = false,

    // Edit
    has_zigpatch: bool = false,

    // Create
    has_zigcreate: bool = false,

    // Diff
    has_zigdiff: bool = false,

    // Codedb (graph tools)
    has_codedb: bool = false,

    pub fn tier(self: ToolAvailability) ToolTier {
        // If we have the core zig tools, it's the full suite
        if (self.has_zigrep and self.has_zigread and self.has_zigpatch)
            return .zig_tools;
        // If we have ripgrep, it's the standard tier
        if (self.has_rg)
            return .standard;
        // Otherwise minimal
        return .minimal;
    }

    pub fn searchCmd(self: ToolAvailability) []const u8 {
        if (self.has_zigrep) return "zigrep";
        if (self.has_rg)     return "rg";
        return "grep -rn";
    }

    pub fn readCmd(self: ToolAvailability) []const u8 {
        if (self.has_zigread) return "zigread";
        return "cat -n";
    }

    pub fn editCmd(self: ToolAvailability) []const u8 {
        if (self.has_zigpatch) return "zigpatch";
        return "sed -i";
    }
};

var g_mu: std.Thread.Mutex = .{};
var g_probed: bool = false;
var g_tools: ToolAvailability = .{};

fn probeCmd(alloc: std.mem.Allocator, argv: []const []const u8) bool {
    const r = gh.run(alloc, argv) catch return false;
    r.deinit(alloc);
    return true;
}

/// Probe the environment for available tools. Cached after first call.
pub fn probe(alloc: std.mem.Allocator) ToolAvailability {
    g_mu.lock();
    defer g_mu.unlock();

    if (g_probed) return g_tools;

    // zig* tools
    g_tools.has_zigrep   = probeCmd(alloc, &.{ "zigrep", "--version" });
    g_tools.has_zigread  = probeCmd(alloc, &.{ "zigread", "--version" });
    g_tools.has_zigpatch = probeCmd(alloc, &.{ "zigpatch", "--version" });
    g_tools.has_zigcreate = probeCmd(alloc, &.{ "zigcreate", "--version" });
    g_tools.has_zigdiff  = probeCmd(alloc, &.{ "zigdiff", "--version" });

    // Standard tools
    g_tools.has_rg   = probeCmd(alloc, &.{ "rg", "--version" });
    g_tools.has_grep = probeCmd(alloc, &.{ "grep", "--version" });

    // Codedb graph tools
    g_tools.has_codedb = probeCmd(alloc, &.{ "codedb", "--version" });

    g_probed = true;
    return g_tools;
}

/// Force re-probe on next call.
pub fn invalidate() void {
    g_mu.lock();
    defer g_mu.unlock();
    g_probed = false;
    g_tools = .{};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "cascade: zig_tools tier when all zig tools present" {
    const t = ToolAvailability{
        .has_zigrep = true, .has_zigread = true, .has_zigpatch = true,
        .has_zigcreate = true, .has_zigdiff = true,
    };
    try std.testing.expectEqual(ToolTier.zig_tools, t.tier());
}

test "cascade: standard tier when rg present but no zig tools" {
    const t = ToolAvailability{ .has_rg = true, .has_grep = true };
    try std.testing.expectEqual(ToolTier.standard, t.tier());
}

test "cascade: minimal tier when only grep" {
    const t = ToolAvailability{ .has_grep = true };
    try std.testing.expectEqual(ToolTier.minimal, t.tier());
}

test "cascade: searchCmd prefers zigrep" {
    const t = ToolAvailability{ .has_zigrep = true, .has_rg = true };
    try std.testing.expectEqualStrings("zigrep", t.searchCmd());
}

test "cascade: searchCmd falls back to rg" {
    const t = ToolAvailability{ .has_rg = true };
    try std.testing.expectEqualStrings("rg", t.searchCmd());
}

test "cascade: searchCmd falls back to grep" {
    const t = ToolAvailability{};
    try std.testing.expectEqualStrings("grep -rn", t.searchCmd());
}

test "cascade: invalidate resets probed state" {
    g_probed = true;
    g_tools = .{ .has_zigrep = true };
    invalidate();
    try std.testing.expect(!g_probed);
    try std.testing.expect(!g_tools.has_zigrep);
}
