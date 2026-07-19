const std = @import("std");

pub fn isSafeIndexedPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, 0) != null or
        std.mem.indexOfScalar(u8, path, '\\') != null or isSensitivePath(path)) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

pub fn isSensitivePath(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    var rest = path;
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const component = rest[0..end];
        if (std.mem.eql(u8, component, ".engram") or
            std.mem.eql(u8, component, ".graff") or
            std.mem.eql(u8, component, ".harness") or
            std.mem.eql(u8, component, ".ssh") or
            std.mem.eql(u8, component, ".gnupg") or
            std.mem.eql(u8, component, ".aws")) return true;
        if (end == rest.len) break;
        rest = rest[end + 1 ..];
    }
    if (std.mem.endsWith(u8, basename, ".session.json")) return true;
    if (std.mem.startsWith(u8, basename, "harness.") and std.mem.endsWith(u8, basename, ".jsonl")) return true;
    if (basename.len >= 4 and std.mem.eql(u8, basename[0..4], ".env") and
        (basename.len == 4 or basename[4] == '.' or basename[4] == '-' or basename[4] == '_')) return true;
    const sensitive_names = [_][]const u8{
        ".dev.vars",        ".npmrc",               ".pypirc",      ".netrc",
        "credentials.json", "service-account.json", "secrets.json", "secrets.yaml",
        "secrets.yml",      "id_rsa",               "id_ed25519",   ".git-credentials",
        "id_ecdsa",         "id_dsa",               "id_ecdsa_sk",  "id_ed25519_sk",
    };
    for (sensitive_names) |name| if (std.mem.eql(u8, basename, name)) return true;
    return std.mem.endsWith(u8, basename, ".env") or
        std.mem.endsWith(u8, basename, ".pem") or
        std.mem.endsWith(u8, basename, ".key") or
        std.mem.endsWith(u8, basename, ".p12") or
        std.mem.endsWith(u8, basename, ".pfx") or
        std.mem.endsWith(u8, basename, ".jks");
}

test "indexed path policy rejects traversal secrets and agent artifacts" {
    const testing = std.testing;
    try testing.expect(isSafeIndexedPath("src/main.zig"));
    try testing.expect(!isSafeIndexedPath("../outside.zig"));
    try testing.expect(!isSafeIndexedPath("src//main.zig"));
    try testing.expect(!isSafeIndexedPath("/absolute.zig"));
    try testing.expect(!isSafeIndexedPath(".env.production"));
    try testing.expect(!isSafeIndexedPath("config/id_ed25519"));
    try testing.expect(!isSafeIndexedPath("run/session-1.session.json"));
    try testing.expect(!isSafeIndexedPath("bench/harness.trace.jsonl"));
    try testing.expect(!isSafeIndexedPath(".engram/context.md"));
    try testing.expect(!isSafeIndexedPath("nested/.aws/credentials"));
}
