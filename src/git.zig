const std = @import("std");

/// Run `git rev-parse HEAD` in `root` and return the 40-char hex SHA.
/// Returns null if `root` is not a git repo, git is unavailable, or HEAD
/// has no commit yet (fresh repo).
pub fn getGitHead(root: []const u8, allocator: std.mem.Allocator) !?[40]u8 {
    var child = std.process.Child.init(&.{ "git", "rev-parse", "HEAD" }, allocator);
    child.cwd = root;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 256);
    defer allocator.free(stdout);

    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    const trimmed = std.mem.trim(u8, stdout, &std.ascii.whitespace);
    if (trimmed.len != 40) return null;
    // Verify it looks like a hex SHA (all hex digits)
    for (trimmed) |c| {
        if (!std.ascii.isHex(c)) return null;
    }

    var result: [40]u8 = undefined;
    @memcpy(&result, trimmed[0..40]);
    return result;
}
