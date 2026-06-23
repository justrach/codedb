//! Pure CLI argument parsing — root/command resolution, line-range and search
//! flag parsing, git-root discovery, and the read-only query-command table.
//! Extracted from main.zig; all functions here are side-effect-free (no
//! Explorer/Store/IO state) so they are trivially unit-testable.
const std = @import("std");

/// The read-only query commands — single source of truth (#578 grew from
/// three hand-maintained copies drifting: cliIsQueryCmd, isCommand, and the
/// runQuery dispatch chain in mainImpl). isCommand appends the non-query
/// commands; the dispatch chain calls cliIsQueryCmd directly.
pub const cli_query_cmds = [_][]const u8{ "tree", "outline", "find", "search", "word", "read", "hot", "status", "symbol", "callers", "callpath", "deps", "glob", "ls", "file", "context", "changes" };

/// Editors that don't expand the placeholder pass the literal token as the
/// root. #639: normalized here (not in mainImpl) so it lands before the
/// root == "." / !root_is_explicit gates.
pub const workspace_placeholder = "${workspaceFolder}";

/// True for the read-only query commands the daemon will serve / the client
/// will proxy. Everything else (serve, mcp, snapshot, index, ...) is handled
/// only by the cold path.
pub fn cliIsQueryCmd(cmd: []const u8) bool {
    for (cli_query_cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

pub const ParsedPositional = struct {
    root: []const u8,
    cmd: []const u8,
    cmd_args_start: usize,
    root_is_explicit: bool,
    usage_exit: bool = false,
};

/// Parse positional args into root/cmd. Pure, side-effect-free — caller is
/// responsible for printUsage()/exit when `usage_exit` is set.
///
/// Special cases:
///   - `codedb mcp <path>` is honored as `codedb <path> mcp` (issue #503).
///     The wrong arg order is a frequent typo from users who think `mcp` is
///     a normal subcommand. Treating the path as root prevents the deferred
///     scan from hanging forever waiting for a `roots/list` that never comes.
///   - `codedb mcp --help` (or `-h`/`help`) prints usage instead of starting
///     the MCP server (issue #502).
pub fn parsePositional(args: []const []const u8) ParsedPositional {
    if (args.len < 2) {
        return .{ .root = "", .cmd = "", .cmd_args_start = 0, .root_is_explicit = false, .usage_exit = true };
    }
    const a1 = args[1];
    if (std.mem.eql(u8, a1, "--mcp")) {
        return .{ .root = ".", .cmd = "mcp", .cmd_args_start = 2, .root_is_explicit = false };
    }
    if (std.mem.eql(u8, a1, "--version") or std.mem.eql(u8, a1, "-v")) {
        return .{ .root = ".", .cmd = "--version", .cmd_args_start = 2, .root_is_explicit = false };
    }
    if (std.mem.eql(u8, a1, "--help") or std.mem.eql(u8, a1, "-h") or std.mem.eql(u8, a1, "help")) {
        return .{ .root = ".", .cmd = a1, .cmd_args_start = 2, .root_is_explicit = false };
    }
    if (isCommand(a1)) {
        // `codedb mcp --help` → print help, do not start server. #502.
        if (std.mem.eql(u8, a1, "mcp") and args.len >= 3) {
            const a2 = args[2];
            if (std.mem.eql(u8, a2, "--help") or std.mem.eql(u8, a2, "-h") or std.mem.eql(u8, a2, "help")) {
                return .{ .root = ".", .cmd = "--help", .cmd_args_start = 3, .root_is_explicit = false };
            }
            // `codedb mcp <path>` → honor path as root. #503.
            // Only when args[2] doesn't look like a flag; otherwise it's a
            // legitimate command-arg that the mcp subcommand may consume.
            if (a2.len > 0 and a2[0] != '-') {
                // #639: `codedb mcp ${workspaceFolder}` (unexpanded) → cwd, non-explicit.
                if (std.mem.eql(u8, a2, workspace_placeholder))
                    return .{ .root = ".", .cmd = "mcp", .cmd_args_start = 3, .root_is_explicit = false };
                return .{ .root = a2, .cmd = "mcp", .cmd_args_start = 3, .root_is_explicit = true };
            }
        }
        return .{ .root = ".", .cmd = a1, .cmd_args_start = 2, .root_is_explicit = false };
    }
    if (args.len >= 3) {
        // #639: unexpanded ${workspaceFolder} → cwd, non-explicit, so the
        // CODEDB_ROOT fallback, #502 git-root walk-up, and mcp deferred-scan
        // (all gated on root == "." / !root_is_explicit) apply.
        if (std.mem.eql(u8, a1, workspace_placeholder))
            return .{ .root = ".", .cmd = args[2], .cmd_args_start = 3, .root_is_explicit = false };
        return .{ .root = a1, .cmd = args[2], .cmd_args_start = 3, .root_is_explicit = true };
    }
    return .{ .root = "", .cmd = "", .cmd_args_start = 0, .root_is_explicit = false, .usage_exit = true };
}

/// True when an `mcp` root points at cwd and was left implicit — a bare
/// `codedb mcp` or a normalized ${workspaceFolder}. Single source of truth for
/// the #502 git-root walk-up AND the deferred-scan handshake; both used to be
/// hand-written inline in mainImpl and drifted out of sync, which is how #639
/// hid (a placeholder arrived with root_is_explicit set and silently disabled
/// both paths).
pub fn mcpRootIsImplicitCwd(cmd: []const u8, root: []const u8, root_is_explicit: bool) bool {
    return std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".") and !root_is_explicit;
}

/// True when an `mcp` root points at cwd and is therefore eligible for the
/// CODEDB_ROOT env fallback (which pins the root, explicit or not).
pub fn mcpRootAcceptsEnv(cmd: []const u8, root: []const u8) bool {
    return std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".");
}

/// A 1-based inclusive line range as accepted by `read -L FROM-TO`. `end` is
/// `std.math.maxInt(u32)` when the spec used `$`/`end` (read to end-of-file).
pub const LineRange = struct { start: u32, end: u32 };

pub const LineRangeError = error{ MissingDash, BadStart, BadEnd, ZeroLine, Reversed };

/// True when positional args remain after the command name. Used by arity-zero
/// CLI commands (tree/hot/status) so typos like `codedb tree typo` exit 1
/// instead of silently ignoring the extra token. See issue #528 (item 13).
pub fn hasExtraCliArgs(args: []const []const u8, cmd_args_start: usize) bool {
    return args.len > cmd_args_start;
}

/// Parse a `FROM-TO` line-range spec (the argument to `read -L`). `TO` may be
/// `$` or `end` for end-of-file. Rejects malformed, non-numeric, zero-based,
/// and reversed ranges so the CLI surfaces a clear error instead of silently
/// defaulting (`abc-10` → 1) or printing empty output (`20-1`). Mirrors the
/// MCP read validation. See issue #528 (items 3, 4, 7).
pub fn parseLineRange(spec: []const u8) LineRangeError!LineRange {
    const dash = std.mem.indexOfScalar(u8, spec, '-') orelse return error.MissingDash;
    const start = std.fmt.parseInt(u32, spec[0..dash], 10) catch return error.BadStart;
    if (start < 1) return error.ZeroLine;
    const end_str = spec[dash + 1 ..];
    const end: u32 = if (std.mem.eql(u8, end_str, "$") or std.mem.eql(u8, end_str, "end"))
        std.math.maxInt(u32)
    else blk: {
        const e = std.fmt.parseInt(u32, end_str, 10) catch return error.BadEnd;
        if (e < 1) return error.ZeroLine;
        break :blk e;
    };
    if (end != std.math.maxInt(u32) and start > end) return error.Reversed;
    return .{ .start = start, .end = end };
}

/// Parsed `search` invocation. `max_results` defaults to 50 (the prior
/// hard-coded cap) and is clamped to 1..200.
pub const SearchArgs = struct {
    query: []const u8,
    use_regex: bool = false,
    paths_only: bool = false,
    max_results: usize = 50,
};

pub const SearchArgError = error{ UnknownFlag, MissingMaxResults, BadMaxResults, MissingQuery, EmptyQuery, ExtraArg };

/// Parse `search` args. Flags (`--regex`, `--paths-only`, `--max-results N`)
/// may appear before or after the query, in any order. Unknown `--flags` are
/// rejected rather than silently treated as the query text (`--max-results 1
/// foo` used to search for the literal "--max-results"), and an empty/missing
/// query is a usage error. A bare `--` ends flag parsing so a literal
/// `--`-prefixed string can still be searched. See issue #528 (item 9).
pub fn parseSearchArgs(args: []const []const u8, start: usize) SearchArgError!SearchArgs {
    var result: SearchArgs = .{ .query = "" };
    var query: ?[]const u8 = null;
    var flags_done = false;
    var i = start;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!flags_done and std.mem.eql(u8, a, "--")) {
            flags_done = true;
        } else if (!flags_done and std.mem.eql(u8, a, "--regex")) {
            result.use_regex = true;
        } else if (!flags_done and std.mem.eql(u8, a, "--paths-only")) {
            result.paths_only = true;
        } else if (!flags_done and std.mem.eql(u8, a, "--max-results")) {
            if (i + 1 >= args.len) return error.MissingMaxResults;
            i += 1;
            const n = std.fmt.parseInt(usize, args[i], 10) catch return error.BadMaxResults;
            if (n < 1) return error.BadMaxResults;
            result.max_results = @min(n, 200);
        } else if (!flags_done and a.len > 1 and a[0] == '-' and a[1] == '-') {
            return error.UnknownFlag;
        } else if (query == null) {
            query = a;
        } else {
            return error.ExtraArg;
        }
    }
    result.query = query orelse return error.MissingQuery;
    if (result.query.len == 0) return error.EmptyQuery;
    return result;
}

/// Walk up from cwd looking for a `.git` directory or file (git worktree).
/// Returns a slice into `buf` containing the absolute path, or null if no
/// repo root is found before reaching the filesystem root. Used to make
/// `codedb mcp` from inside a subdir of a git repo Just Work (#502).
pub fn findGitRoot(io: std.Io, buf: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    const cwd_len = std.Io.Dir.cwd().realPathFile(io, ".", buf) catch return null;
    return findGitRootFrom(io, buf, cwd_len);
}

/// Test-friendly variant: walk up from `buf[0..start_len]` (must already be
/// an absolute path) looking for `.git`. Mutates buf in place. Returns slice
/// or null. Kept separate so tests can hand in synthetic absolute paths
/// without chdir'ing the process.
pub fn findGitRootFrom(io: std.Io, buf: *[std.fs.max_path_bytes]u8, start_len: usize) ?[]const u8 {
    var len = start_len;
    var probe_buf: [std.fs.max_path_bytes]u8 = undefined;
    while (len > 0) {
        const here = buf[0..len];
        const probe = std.fmt.bufPrint(&probe_buf, "{s}/.git", .{here}) catch return null;
        if (std.Io.Dir.cwd().statFile(io, probe, .{})) |_| {
            return here;
        } else |_| {}
        if (std.mem.lastIndexOfScalar(u8, here, '/')) |slash| {
            if (slash == 0) {
                // Reached "/<dir>"; one more step to filesystem root, no match.
                return null;
            }
            len = slash;
        } else {
            return null;
        }
    }
    return null;
}

/// Whitelist of post-command flags accepted by `codedb mcp`. Anything else
/// starting with `-` is rejected at startup (#502). `--config-file=<path>`
/// is stripped before positional parsing and never reaches this whitelist;
/// `--help`/`-h`/`help` are rewritten by parsePositional and also never
/// reach here as a command arg.
pub fn isValidMcpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--no-telemetry");
}

fn isCommand(arg: []const u8) bool {
    // cli_query_cmds is the shared query-command table (see its doc); only the
    // non-query commands are listed here.
    const commands = cli_query_cmds ++ [_][]const u8{ "snapshot", "serve", "mcp", "update", "nuke", "cli-daemon", "index" };
    for (commands) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

pub fn resolveRoot(io: std.Io, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const sub = if (std.mem.eql(u8, root, ".")) "." else root;
    const n = std.Io.Dir.cwd().realPathFile(io, sub, buf) catch return error.ResolveFailed;
    return buf[0..n];
}
