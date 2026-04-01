const std = @import("std");

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
    return true;
}

const testing = std.testing;

test "issue-80: root / is denied" {
    try testing.expect(!isIndexableRoot("/"));
}

test "issue-80: empty path is denied" {
    try testing.expect(!isIndexableRoot(""));
}

test "issue-80: /tmp is denied" {
    try testing.expect(!isIndexableRoot("/tmp"));
    try testing.expect(!isIndexableRoot("/tmp/foo"));
}

test "issue-80: normal paths are allowed" {
    try testing.expect(isIndexableRoot("/Users/dev/project"));
    try testing.expect(isIndexableRoot("/home/user/code"));
}
