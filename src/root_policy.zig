const std = @import("std");
const builtin = @import("builtin");

fn isExactOrChild(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len == prefix.len) return true;
    const sep = path[prefix.len];
    return sep == '/' or sep == '\\';
}

fn isExactOrChildCaseInsensitive(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    for (path[0..prefix.len], prefix) |a, b| {
        if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
    }
    if (path.len == prefix.len) return true;
    const sep = path[prefix.len];
    return sep == '/' or sep == '\\';
}

pub fn isIndexableRoot(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.eql(u8, path, "/")) return false;
    // POSIX temp directories
    if (isExactOrChild(path, "/private/tmp")) return false;
    if (isExactOrChild(path, "/tmp")) return false;
    if (isExactOrChild(path, "/var/tmp")) return false;

    // Block home directory itself (not subdirectories) — prevents 17GB RAM spike (#174)
    if (std.posix.getenv("HOME")) |home| {
        if (home.len > 0 and std.mem.eql(u8, path, home)) return false;
    }
    // Also block common home patterns directly
    if (std.mem.eql(u8, path, "/root")) return false;
    if (std.mem.startsWith(u8, path, "/home/") or std.mem.startsWith(u8, path, "/Users/")) {
        // /home/user or /Users/user (no deeper path component) = home dir
        const rest = if (std.mem.startsWith(u8, path, "/home/")) path[6..] else path[7..];
        if (std.mem.indexOfScalar(u8, rest, '/') == null and rest.len > 0) return false;
    }

    // Windows temp directories (case-insensitive)
    if (builtin.os.tag == .windows) {
        if (isExactOrChildCaseInsensitive(path, "C:\\Windows\\Temp")) return false;
        if (std.ascii.indexOfIgnoreCase(path, "\\AppData\\Local\\Temp")) |pos| {
            const end = pos + "\\AppData\\Local\\Temp".len;
            if (end == path.len or path[end] == '\\' or path[end] == '/') return false;
        }
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

test "issue-80: Windows temp paths are denied" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try testing.expect(!isIndexableRoot("C:\\Windows\\Temp"));
    try testing.expect(!isIndexableRoot("C:\\Windows\\Temp\\codedb-test"));
    try testing.expect(!isIndexableRoot("C:\\Users\\dev\\AppData\\Local\\Temp"));
    try testing.expect(!isIndexableRoot("C:\\Users\\dev\\AppData\\Local\\Temp\\project"));
    try testing.expect(isIndexableRoot("C:\\Users\\dev\\AppData\\Local\\TempProject"));
    try testing.expect(isIndexableRoot("C:\\Users\\dev\\Projects\\myapp"));
    try testing.expect(isIndexableRoot("D:\\GitHub\\codedb"));
}
