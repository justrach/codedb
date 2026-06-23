//! Remembered linter opt-in preference (trial/graph-based-codedb).
//!
//! The external-linter bridge is opt-in. The user is asked ONCE — at codedb
//! install / `codedb update` time — and the answer is persisted here. The MCP
//! server only READS it; it never prompts (its stdio is the JSON-RPC transport).
//!
//! This is a global, user-level choice, so it lives in a dedicated state file
//! $HOME/.codedb/linter_optin (next to the auto-update stamp), NOT in the
//! per-checkout .codedbrc. Absent or unrecognized => .unset => external linters
//! stay off and codedb uses only the in-process (Tier-0) heuristics.

const std = @import("std");
const cio = @import("cio.zig");

pub const Pref = enum { unset, off, on };

pub const filename = "linter_optin";

/// .on -> run external linters when present; .off/.unset -> heuristics only.
pub fn enabledFromPref(p: Pref) bool {
    return p == .on;
}

/// Pure parse of the file body: "on" -> .on, "off" -> .off, anything else
/// (including empty/garbage) -> .unset. Whitespace/newlines are trimmed.
pub fn parseBody(bytes: []const u8) Pref {
    const body = std.mem.trim(u8, bytes, " \t\r\n");
    if (std.mem.eql(u8, body, "on")) return .on;
    if (std.mem.eql(u8, body, "off")) return .off;
    return .unset;
}

/// $HOME/.codedb/linter_optin, or null when HOME is unset/empty. Caller frees.
pub fn prefPath(allocator: std.mem.Allocator) ?[]u8 {
    const home = cio.homeDir() orelse return null;
    if (home.len == 0) return null;
    return std.fmt.allocPrint(allocator, "{s}/.codedb/{s}", .{ home, filename }) catch null;
}

/// Read the preference from an explicit path. Best-effort: any failure
/// (missing file, read error) yields .unset. Exposed for tests.
pub fn readAt(io: std.Io, path: []const u8) Pref {
    var buf: [16]u8 = undefined;
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch return .unset;
    defer f.close(io);
    const n = f.readPositionalAll(io, &buf, 0) catch return .unset;
    return parseBody(buf[0..n]);
}

/// Write the preference to an explicit path (parent dir must exist). Best-effort;
/// swallows errors. Writing .unset is a no-op. Exposed for tests.
pub fn writeAt(io: std.Io, path: []const u8, p: Pref) void {
    const body: []const u8 = switch (p) {
        .on => "on\n",
        .off => "off\n",
        .unset => return,
    };
    const f = std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true }) catch return;
    defer f.close(io);
    f.writePositionalAll(io, body, 0) catch {};
}

/// Read the persisted preference from the canonical $HOME/.codedb location.
/// The MCP server calls this once at startup to seed LinterSession.enabled.
pub fn read(io: std.Io, allocator: std.mem.Allocator) Pref {
    const path = prefPath(allocator) orelse return .unset;
    defer allocator.free(path);
    return readAt(io, path);
}

/// Persist the preference to $HOME/.codedb, creating the dir if needed.
/// Called by the install / `codedb update` opt-in flow. Best-effort.
pub fn write(io: std.Io, allocator: std.mem.Allocator, p: Pref) void {
    if (p == .unset) return;
    const home = cio.homeDir() orelse return;
    if (home.len == 0) return;
    const dir_path = std.fmt.allocPrint(allocator, "{s}/.codedb", .{home}) catch return;
    defer allocator.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch {};
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch return;
    defer allocator.free(path);
    writeAt(io, path, p);
}
