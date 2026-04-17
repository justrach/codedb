const std = @import("std");
const cio = @import("cio.zig");

fn isExactOrChild(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

pub fn isIndexableRoot(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.eql(u8, path, "/")) return false;
    if (isExactOrChild(path, "/private/tmp")) return false;
    if (isExactOrChild(path, "/tmp")) return false;
    if (isExactOrChild(path, "/var/tmp")) return false;

    // Block home directory itself (not subdirectories) — prevents 17GB RAM spike (#174)
    if (cio.posixGetenv("HOME")) |home| {
        if (home.len > 0 and std.mem.eql(u8, path, home)) return false;
    }
    // Also block common home patterns directly
    if (std.mem.eql(u8, path, "/root")) return false;
    if (std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/Users/")) {
        // /home/user or /Users/user (no deeper path component) = home dir
        const rest = if (std.mem.startsWith(u8, path, "/home/")) path[6..] else path[7..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) return false;
    }

    return true;
}

const testing = std.testing;

test "issue-80: normal paths are allowed" {
    try testing.expect(isIndexableRoot("/Users/dev/project"));
    try testing.expect(isIndexableRoot("/home/user/code"));
    try testing.expect(isIndexableRoot("/home/user/code/subdir"));
}

test "issue-174: home directory itself is denied" {
    try testing.expect(!isIndexableRoot("/root"));
    try testing.expect(!isIndexableRoot("/home/user"));
    try testing.expect(!isIndexableRoot("/Users/dev"));
    // But subdirectories are allowed
    try testing.expect(isIndexableRoot("/home/user/projects"));
    try testing.expect(isIndexableRoot("/Users/dev/code"));
    try testing.expect(isIndexableRoot("/root/projects"));
}
test "issue-80: empty path is denied" {
    try testing.expect(!isIndexableRoot(""));
}

test "issue-80: /tmp is denied" {
    try testing.expect(!isIndexableRoot("/tmp"));
    try testing.expect(!isIndexableRoot("/tmp/foo"));
}

