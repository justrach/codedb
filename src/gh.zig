// gitagent-mcp — gh CLI executor
//
// All GitHub operations go through gh.run() or gh.runJson().
//
// CRITICAL: gh issue list on a large repo can return >64KB of JSON.
// macOS/Linux pipe buffers are 64KB — synchronous read after write = deadlock.
// Solution: drainer threads spawned BEFORE child.wait().
// See zig-dev skill: "Pipe deadlock" and "Drainer thread pattern".

const std = @import("std");

// ── Result type ───────────────────────────────────────────────────────────────

pub const GhResult = struct {
    stdout: []u8, // caller owns — free with alloc.free()
    exit_code: u8,

    pub fn deinit(self: GhResult, alloc: std.mem.Allocator) void {
        alloc.free(self.stdout);
    }
};

pub const GhError = error{
    AuthRequired,     // gh not logged in
    NotFound,         // resource does not exist
    RateLimited,      // GitHub API rate limit hit
    PermissionDenied,
    MalformedOutput,  // JSON parse failed
    SpawnFailed,      // could not spawn gh process
    OutOfMemory,
    Unexpected,
};

// ── Drainer context ───────────────────────────────────────────────────────────

const DrainerCtx = struct {
    alloc: std.mem.Allocator,
    buf:   std.ArrayList(u8) = .empty,
    oom:   bool = false,
};

// Runs in a dedicated thread to drain one pipe end.
// Heap-allocates the read chunk: drainer threads have limited stack (zig-dev skill).
fn drainThread(ctx: *DrainerCtx, file: std.fs.File) void {
    // Do NOT close file here — child.wait() → cleanupStreams() owns the handle.
    // >64KB stack chunk = stack overflow risk in threads — heap-allocate (zig-dev skill)
    const chunk = ctx.alloc.alloc(u8, 65536) catch {
        ctx.oom = true;
        return;
    };
    defer ctx.alloc.free(chunk);

    while (true) {
        const n = file.read(chunk) catch break;
        if (n == 0) break;
        ctx.buf.appendSlice(ctx.alloc, chunk[0..n]) catch {
            ctx.oom = true; // flag it — don't silently drop (zig-dev skill)
            break;
        };
    }
}

// ── Core executor ─────────────────────────────────────────────────────────────

/// Spawn a gh subprocess, drain stdout+stderr concurrently, return result.
/// argv[0] should be "gh" (found via PATH) or an absolute path.
pub fn run(alloc: std.mem.Allocator, argv: []const []const u8) GhError!GhResult {
    var child = std.process.Child.init(argv, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    child.stdin_behavior  = .Close; // never inherit the MCP stdio pipe

    child.spawn() catch return GhError.SpawnFailed;

    const stdout_file = child.stdout orelse return GhError.SpawnFailed;
    const stderr_file = child.stderr orelse return GhError.SpawnFailed;

    var stdout_ctx = DrainerCtx{ .alloc = alloc };
    var stderr_ctx = DrainerCtx{ .alloc = alloc };

    // Spawn drainer threads BEFORE child.wait() to prevent pipe deadlock.
    const t_out = std.Thread.spawn(.{}, drainThread, .{ &stdout_ctx, stdout_file }) catch blk: {
        drainThread(&stdout_ctx, stdout_file);
        break :blk null;
    };
    const t_err = std.Thread.spawn(.{}, drainThread, .{ &stderr_ctx, stderr_file }) catch blk: {
        drainThread(&stderr_ctx, stderr_file);
        break :blk null;
    };

    // Join BEFORE child.wait(). Drainers reach EOF naturally when the child
    // exits and closes its write ends. child.wait() → cleanupStreams() then
    // closes the read ends — drainThread must NOT close them (no defer file.close()).
    // Joining after child.wait() caused a double-close BADF panic (issue #58).
    if (t_out) |t| t.join();
    if (t_err) |t| t.join();

    const term = child.wait() catch {
        stdout_ctx.buf.deinit(alloc);
        stderr_ctx.buf.deinit(alloc);
        return GhError.Unexpected;
    };

    defer stderr_ctx.buf.deinit(alloc);

    if (stdout_ctx.oom or stderr_ctx.oom) {
        stdout_ctx.buf.deinit(alloc);
        return GhError.OutOfMemory;
    }

    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else    => 1,
    };

    if (exit_code != 0) {
        const err = classifyError(stderr_ctx.buf.items);
        stdout_ctx.buf.deinit(alloc);
        return err;
    }

    return GhResult{
        .stdout    = stdout_ctx.buf.toOwnedSlice(alloc) catch return GhError.OutOfMemory,
        .exit_code = exit_code,
    };
}

/// Run gh and parse stdout as JSON. Caller must call parsed.deinit().
pub fn runJson(
    alloc: std.mem.Allocator,
    argv: []const []const u8,
) GhError!std.json.Parsed(std.json.Value) {
    const result = try run(alloc, argv);
    defer result.deinit(alloc);
    return std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch
        return GhError.MalformedOutput;
}

// ── Error classifier ──────────────────────────────────────────────────────────

fn classifyError(stderr: []const u8) GhError {
    if (containsAny(stderr, &.{ "not logged in", "authentication", "GITHUB_TOKEN" }))
        return GhError.AuthRequired;
    if (containsAny(stderr, &.{ "not found", "Could not resolve", "No such" }))
        return GhError.NotFound;
    if (containsAny(stderr, &.{ "rate limit", "429", "secondary rate" }))
        return GhError.RateLimited;
    if (containsAny(stderr, &.{ "403", "permission", "forbidden" }))
        return GhError.PermissionDenied;
    return GhError.Unexpected;
}

fn containsAny(haystack: []const u8, needles: []const []const u8) bool {
    for (needles) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

/// Human-readable message for a GhError.
pub fn errorMessage(err: GhError) []const u8 {
    return switch (err) {
        GhError.AuthRequired     => "GitHub auth required. Run: gh auth login",
        GhError.NotFound         => "Resource not found on GitHub",
        GhError.RateLimited      => "GitHub API rate limit exceeded. Try again in a few minutes.",
        GhError.PermissionDenied => "Permission denied. Check repo access.",
        GhError.MalformedOutput  => "gh returned unexpected output format",
        GhError.SpawnFailed      => "Could not spawn gh. Is it installed and on PATH?",
        GhError.OutOfMemory      => "Out of memory reading gh output",
        GhError.Unexpected       => "Unexpected gh error",
    };
}
