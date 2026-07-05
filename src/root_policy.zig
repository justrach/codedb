const std = @import("std");
const cio = @import("cio.zig");

pub fn isExactOrChild(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}
/// Temp-root indexing is an opt-in escape hatch for CI / SWE-bench harnesses
/// that clone throwaway checkouts under /tmp. Off by default (footgun guard,
/// #80/#346). Enabled by CODEDB_ALLOW_TEMP=1; the `--allow-temp` CLI flag sets
/// that env so both opt-ins share one switch. See #538.
pub fn tempIndexingAllowed() bool {
    const v = cio.posixGetenv("CODEDB_ALLOW_TEMP") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

pub fn isIndexableRoot(path: []const u8) bool {
    if (path.len == 0) return false;
    if (std.mem.eql(u8, path, "/")) return false;

    // OSTree distros (Fedora Silverblue/CoreOS/Nobara) bind-mount /home onto
    // /var/home, so /var/home/<user>/<project> is a real project path, not a
    // system dir — and realPathFile canonicalizes /home/<user>/<project> to it
    // (same as #406/#407 fold /etc→/private/etc, /var→/private/var). Accept it
    // before the /var checks below, mirroring the /home + /Users home-dir
    // rule: allow project subdirs, deny the bare home. No opt-in. (#642)
    if (std.mem.startsWith(u8, path, "/var/home/")) {
        const rest = path["/var/home/".len..];
        // "user" (bare home) → deny; "user/project…" → allow.
        return std.mem.indexOfScalar(u8, rest, '/') != null;
    }

    // /tmp, /private/tmp, /var, and /private/var are refused by default
    // (footgun guard) but allowed when temp indexing is opted in (#538, #642)
    // — CI/SWE-bench harnesses clone into /tmp, and macOS TMPDIR resolves
    // under /private/var/folders.
    if (!tempIndexingAllowed()) {
        if (isExactOrChild(path, "/private/tmp")) return false;
        if (isExactOrChild(path, "/tmp")) return false;
        if (isExactOrChild(path, "/private/var")) return false;
        if (isExactOrChild(path, "/var")) return false;
    }

    const system_prefixes = [_][]const u8{
        "/Applications",
        "/System",
        "/Library",
        "/usr",
        "/opt",
        "/bin",
        "/sbin",
        "/etc",
        "/private/etc",
        "/dev",
        "/proc",
        "/sys",
        "/snap",
        "/nix",
    };
    for (system_prefixes) |pfx| {
        if (isExactOrChild(path, pfx)) return false;
    }

    // Block home directory itself (not subdirectories) — prevents 17GB RAM spike (#174)
    if (cio.homeDir()) |home| {
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

test "issue-642: /var is denied by default, indexable with CODEDB_ALLOW_TEMP" {
    try testing.expect(!isIndexableRoot("/var/tmp"));
    try testing.expect(!isIndexableRoot("/var/log"));
    // /var itself (no deeper path) is also denied
    try testing.expect(!isIndexableRoot("/var"));
    // ...but OSTree home projects under /var/home never need the opt-in (#642)
    try testing.expect(isIndexableRoot("/var/home/xavi/project"));

    // --allow-temp / CODEDB_ALLOW_TEMP=1 unblocks /var the same way it
    // unblocks /tmp (#538): macOS TMPDIR resolves under /private/var/folders
    // and CI workspaces live under /var/lib.
    cio.posixSetenv("CODEDB_ALLOW_TEMP", "1");
    defer cio.posixUnsetenv("CODEDB_ALLOW_TEMP");
    try testing.expect(isIndexableRoot("/var/tmp"));
    try testing.expect(isIndexableRoot("/private/var/folders/zz/scratch"));
    // The opt-in still never unblocks the bare OSTree home dir.
    try testing.expect(!isIndexableRoot("/var/home/xavi"));
}
