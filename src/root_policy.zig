const std = @import("std");
const cio = @import("cio.zig");

pub fn isExactOrChild(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    return path.len == prefix.len or path[prefix.len] == '/';
}

/// Root requests are capabilities, not ambient paths.  Reject relative and
/// dot-dot spellings before opening; callers may retain the canonical path
/// reported by the resulting handle.
pub fn isAbsoluteRootRequest(path: []const u8) bool {
    if (!std.fs.path.isAbsolute(path)) return false;
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
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
    return isIndexableRootWithTempOpt(path, tempIndexingAllowed());
}

/// Pure policy entry point for tests and callers that have already resolved
/// the explicit temp-root opt-in. Keeping environment reads outside the policy
/// avoids process-global environment races between parallel Zig tests.
pub fn isIndexableRootWithTempOpt(path: []const u8, allow_temp: bool) bool {
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
    if (!allow_temp) {
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

/// True when `path` sits under one of the temp/system-volatile roots the
/// default policy refuses (the set CODEDB_ALLOW_TEMP re-enables). /var/home
/// project dirs are NOT temp roots — they are accepted unconditionally above.
pub fn isTempRoot(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "/var/home/")) return false;
    return isExactOrChild(path, "/private/tmp") or
        isExactOrChild(path, "/tmp") or
        isExactOrChild(path, "/private/var") or
        isExactOrChild(path, "/var");
}

/// True only for the bare temp dirs themselves — never bootstrap these, no
/// matter what marker files happen to be lying in them.
fn isBareTempDir(path: []const u8) bool {
    return std.mem.eql(u8, path, "/tmp") or
        std.mem.eql(u8, path, "/private/tmp") or
        std.mem.eql(u8, path, "/var") or
        std.mem.eql(u8, path, "/private/var");
}

/// Files/dirs whose presence at a root strongly indicates a real project
/// checkout rather than a scratch directory. `.git` may be a regular file
/// (worktrees, submodules), so everything is probed with statFile.
const project_markers = [_][]const u8{
    ".git",    "pyproject.toml", "package.json", "Cargo.toml",
    "go.mod",  "build.zig",      "setup.py",     "pom.xml",
    "Gemfile", "composer.json",  "build.gradle", "CMakeLists.txt",
};

pub fn looksLikeProject(io: std.Io, path: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (project_markers) |m| {
        const p = std.fmt.bufPrint(&buf, "{s}/{s}", .{ path, m }) catch return false;
        if (std.Io.Dir.cwd().statFile(io, p, .{})) |_| {
            return true;
        } else |_| {}
    }
    return false;
}

/// Capability-relative project-marker probe.  Use this after opening a root
/// so admission describes the directory object we actually hold, rather than
/// a pathname that may be retargeted between validation and open.
pub fn looksLikeProjectDir(io: std.Io, dir: std.Io.Dir) bool {
    for (project_markers) |marker| {
        if (dir.statFile(io, marker, .{ .follow_symlinks = false })) |_| return true else |_| {}
    }
    return false;
}

/// Out-of-the-box bootstrap exception: a temp root that recognizably holds a
/// project checkout may be indexed on the fly without CODEDB_ALLOW_TEMP.
/// Rationale: agent harnesses hard-fail once on a refused call and never
/// retry the tool for the rest of the session, so refusing a legit /tmp
/// clone silently disables codedb entirely. System prefixes (/usr, /etc, …)
/// and the bare temp dirs stay denied unconditionally.
pub fn isBootstrapableRoot(io: std.Io, path: []const u8) bool {
    if (isIndexableRoot(path)) return false;
    return isTempRoot(path) and !isBareTempDir(path) and looksLikeProject(io, path);
}

/// Canonical admission policy for a real project capability. Normal project
/// roots are accepted directly; recognizable temp checkouts are accepted by
/// the bootstrap exception. Callers must still possess/resolve the root — this
/// does not authorize a cwd fallback when no project capability exists.
pub fn isAdmissibleRoot(io: std.Io, path: []const u8) bool {
    return isIndexableRoot(path) or isBootstrapableRoot(io, path);
}

/// Admission for an already-opened, canonical root capability.  This is the
/// authoritative form used by Explorer.setRoot; it has no check-then-open
/// window and temp-project markers are read through the stable handle.
pub fn isAdmissibleRootDir(io: std.Io, dir: std.Io.Dir, canonical_path: []const u8) bool {
    if (isIndexableRoot(canonical_path)) return true;
    return isTempRoot(canonical_path) and
        !isBareTempDir(canonical_path) and
        looksLikeProjectDir(io, dir);
}

const testing = std.testing;

test "issue-80: normal paths are allowed" {
    try testing.expect(isIndexableRoot("/Users/dev/project"));
    try testing.expect(isIndexableRoot("/home/user/code"));
    try testing.expect(isIndexableRoot("/home/user/code/subdir"));
}

test "isTempRoot classification" {
    try testing.expect(isTempRoot("/tmp"));
    try testing.expect(isTempRoot("/tmp/repo"));
    try testing.expect(isTempRoot("/private/tmp/repo"));
    try testing.expect(isTempRoot("/var/folders/ab/cd/T/build"));
    try testing.expect(isTempRoot("/private/var/folders/ab/cd/T/build"));
    try testing.expect(!isTempRoot("/var/home/user/project"));
    try testing.expect(!isTempRoot("/Users/dev/project"));
    try testing.expect(!isTempRoot("/usr/local"));
}

test "bootstrap: project markers enable temp-root indexing, scratch stays refused" {
    const tio = std.testing.io;
    var name_buf: [128]u8 = undefined;
    const base = std.fmt.bufPrint(&name_buf, "/tmp/codedb-policy-test-{d}", .{cio.milliTimestamp()}) catch unreachable;
    std.Io.Dir.cwd().createDirPath(tio, base) catch return error.SkipZigTest;
    defer std.Io.Dir.cwd().deleteTree(tio, base) catch {};

    // Scratch temp dir: no markers → not bootstrapable.
    try testing.expect(isTempRoot(base));
    try testing.expect(!looksLikeProject(tio, base));
    try testing.expect(!isBootstrapableRoot(tio, base));

    // Drop a project marker → bootstrap on the fly is allowed.
    var dir = try std.Io.Dir.cwd().openDir(tio, base, .{});
    defer dir.close(tio);
    try dir.writeFile(tio, .{ .sub_path = "package.json", .data = "{}\n" });
    try testing.expect(looksLikeProject(tio, base));
    try testing.expect(isBootstrapableRoot(tio, base));
    try testing.expect(isAdmissibleRoot(tio, base));

    // Already-allowed roots are never "bootstrapable" (no fs probe needed).
    try testing.expect(!isBootstrapableRoot(tio, "/Users/dev/project"));
    try testing.expect(isAdmissibleRoot(tio, "/Users/dev/project"));
    // Bare temp dirs stay refused even with the marker file present inside
    // the child we just created.
    try testing.expect(!isBootstrapableRoot(tio, "/tmp"));
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

test "issue-642: /var is denied by default, indexable with explicit temp opt-in" {
    try testing.expect(!isIndexableRootWithTempOpt("/var/tmp", false));
    try testing.expect(!isIndexableRootWithTempOpt("/var/log", false));
    // /var itself (no deeper path) is also denied
    try testing.expect(!isIndexableRootWithTempOpt("/var", false));
    // ...but OSTree home projects under /var/home never need the opt-in (#642)
    try testing.expect(isIndexableRoot("/var/home/xavi/project"));

    // --allow-temp / CODEDB_ALLOW_TEMP=1 unblocks /var the same way it
    // unblocks /tmp (#538): macOS TMPDIR resolves under /private/var/folders
    // and CI workspaces live under /var/lib.
    try testing.expect(isIndexableRootWithTempOpt("/var/tmp", true));
    try testing.expect(isIndexableRootWithTempOpt("/private/var/folders/zz/scratch", true));
    // The opt-in still never unblocks the bare OSTree home dir.
    try testing.expect(!isIndexableRootWithTempOpt("/var/home/xavi", true));
}
