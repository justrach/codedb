const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Out = @import("out.zig").Out;
const release_info = @import("release_info.zig");
const index_mod = @import("index.zig");
const bootstrap = @import("bootstrap.zig");
const cli_args = @import("cli_args.zig");

/// Stable delimiters for the managed policy block. The begin marker carries the
/// codedb version that wrote it so `install` can replace an older block in place
/// and `verify` can report "outdated" instead of silently passing.
pub const begin_marker_prefix = "<!-- codedb:begin v";
pub const begin_marker_suffix = " -->";
pub const end_marker = "<!-- codedb:end -->";

/// Opt-out marker written by `codedb codex uninstall`. Deleting it re-enables
/// `codedb codex install`.
pub const opt_out_marker_rel = ".codedb/no-codex-policy";
pub const opt_out_env = "CODEDB_NO_CODEX_POLICY";

pub const agents_file_name = "AGENTS.md";

/// Routing policy handed to Codex agents. Same tool ordering as mcp.zig's
/// mcp_instructions — structural tools first, search as a fallback, native
/// editor for edits — extended with the index-recovery path.
pub const policy_body =
    \\## codedb — code intelligence policy
    \\
    \\codedb is a code-intelligence and context tool — not your editor. Reach for the
    \\codedb MCP tools FIRST, before shell search or bulk file reads:
    \\
    \\- `codedb_context` to orient on a new task before reading anything else.
    \\- `codedb_symbol` for a definition, `codedb_callers` for usages, `codedb_outline`
    \\  for a file's structure before `codedb_read`, `codedb_deps` for relationships.
    \\- `codedb_search` only for substrings or phrases when you do NOT know the exact
    \\  symbol name — it is a fallback, not the default.
    \\- Make edits with your own native editor tools. codedb is the navigation layer,
    \\  not the editor.
    \\- If codedb reports no index or a stale one, run `codedb <root> index` and fall
    \\  back to `rg`/`cat` until it completes.
    \\
    \\Managed by `codedb codex install` — edits inside this block are overwritten.
    \\Remove it with `codedb codex uninstall`.
;

/// The full delimited block for the running codedb version. Caller owns it.
pub fn buildPolicyBlock(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}\n{s}\n{s}", .{
        begin_marker_prefix,
        release_info.semver,
        begin_marker_suffix,
        policy_body,
        end_marker,
    });
}

pub const BlockSpan = struct { start: usize, end: usize };

/// Byte range of the managed block in `content`, for ANY version, or null.
pub fn findPolicyBlock(content: []const u8) ?BlockSpan {
    const start = std.mem.indexOf(u8, content, begin_marker_prefix) orelse return null;
    const close = std.mem.indexOfPos(u8, content, start + begin_marker_prefix.len, end_marker) orelse return null;
    return .{ .start = start, .end = close + end_marker.len };
}

/// Version recorded in the begin marker, borrowed from `content`, or null.
pub fn policyBlockVersion(content: []const u8) ?[]const u8 {
    const span = findPolicyBlock(content) orelse return null;
    const tail = content[span.start + begin_marker_prefix.len .. span.end];
    const close = std.mem.indexOf(u8, tail, begin_marker_suffix) orelse return null;
    if (close == 0) return null;
    return tail[0..close];
}

/// Insert or refresh the managed block. Returns null when `content` already
/// holds exactly `block` (nothing to write) — the same null-means-unchanged
/// contract as nuke.removeCodexMcpServerBlock. An existing codedb block of any
/// version is replaced in place; otherwise the block is appended after a blank
/// line so it never runs into the user's own prose.
pub fn upsertPolicyBlock(allocator: std.mem.Allocator, content: []const u8, block: []const u8) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    if (findPolicyBlock(content)) |span| {
        if (std.mem.eql(u8, content[span.start..span.end], block)) return null;
        try out.appendSlice(allocator, content[0..span.start]);
        try out.appendSlice(allocator, block);
        try out.appendSlice(allocator, content[span.end..]);
        return try out.toOwnedSlice(allocator);
    }

    const head = std.mem.trimEnd(u8, content, " \t\r\n");
    if (head.len > 0) {
        try out.appendSlice(allocator, head);
        try out.appendSlice(allocator, "\n\n");
    }
    try out.appendSlice(allocator, block);
    try out.append(allocator, '\n');
    return try out.toOwnedSlice(allocator);
}

/// Strip the managed block plus its blank-line separator. Returns null when no
/// block is present, so callers skip the rewrite entirely.
pub fn removePolicyBlock(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    const span = findPolicyBlock(content) orelse return null;

    var remove_end = span.end;
    if (remove_end < content.len and content[remove_end] == '\r') remove_end += 1;
    if (remove_end < content.len and content[remove_end] == '\n') remove_end += 1;

    var remove_start = span.start;
    while (remove_start > 0 and (content[remove_start - 1] == ' ' or content[remove_start - 1] == '\t')) : (remove_start -= 1) {}
    while (remove_start >= 2 and content[remove_start - 1] == '\n' and content[remove_start - 2] == '\n') : (remove_start -= 1) {}

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, content[0..remove_start]);
    try out.appendSlice(allocator, content[remove_end..]);
    return try out.toOwnedSlice(allocator);
}

/// True when `content` declares the given TOML table header, ignoring
/// indentation and trailing comments.
pub fn hasTomlHeader(content: []const u8, header: []const u8) bool {
    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        if (std.mem.eql(u8, trimTomlLine(content[line_start..line_end]), header)) return true;
        line_start = if (line_end < content.len) line_end + 1 else content.len;
    }
    return false;
}

fn trimTomlLine(line: []const u8) []const u8 {
    const no_cr = std.mem.trimEnd(u8, line, "\r");
    const trimmed = std.mem.trim(u8, no_cr, " \t");
    const comment_start = std.mem.indexOfScalar(u8, trimmed, '#') orelse return trimmed;
    return std.mem.trimEnd(u8, trimmed[0..comment_start], " \t");
}

/// The 40-char HEAD sha of the repo at `root`, read straight off disk — no
/// `git` subprocess, so it still answers when git is missing. Handles linked
/// worktrees (`.git` as a gitdir pointer file) and packed refs.
pub fn resolveGitHead(io: std.Io, allocator: std.mem.Allocator, root: []const u8) ?[40]u8 {
    return resolveGitHeadInner(io, allocator, root) catch null;
}

fn resolveGitHeadInner(io: std.Io, allocator: std.mem.Allocator, root: []const u8) !?[40]u8 {
    const dot_git = try std.fmt.allocPrint(allocator, "{s}/.git", .{root});
    defer allocator.free(dot_git);

    var git_dir: []u8 = undefined;
    if (std.Io.Dir.cwd().openDir(io, dot_git, .{})) |opened| {
        var dir = opened;
        dir.close(io);
        git_dir = try allocator.dupe(u8, dot_git);
    } else |_| {
        const txt = (try readOptionalFile(io, allocator, dot_git)) orelse return null;
        defer allocator.free(txt);
        const trimmed = std.mem.trim(u8, txt, " \t\r\n");
        if (!std.mem.startsWith(u8, trimmed, "gitdir:")) return null;
        const rel = std.mem.trim(u8, trimmed["gitdir:".len..], " \t\r\n");
        if (rel.len == 0) return null;
        git_dir = try joinMaybeRelative(allocator, root, rel);
    }
    defer allocator.free(git_dir);

    // Linked worktrees keep refs/ and packed-refs in the common dir.
    const common_dir: []u8 = blk: {
        const path = try std.fmt.allocPrint(allocator, "{s}/commondir", .{git_dir});
        defer allocator.free(path);
        const txt = (try readOptionalFile(io, allocator, path)) orelse break :blk try allocator.dupe(u8, git_dir);
        defer allocator.free(txt);
        const trimmed = std.mem.trim(u8, txt, " \t\r\n");
        if (trimmed.len == 0) break :blk try allocator.dupe(u8, git_dir);
        break :blk try joinMaybeRelative(allocator, git_dir, trimmed);
    };
    defer allocator.free(common_dir);

    const head_txt = (try readFirstExisting(io, allocator, git_dir, common_dir, "HEAD")) orelse return null;
    defer allocator.free(head_txt);
    const head = std.mem.trim(u8, head_txt, " \t\r\n");
    if (parseSha(head)) |sha| return sha;
    if (!std.mem.startsWith(u8, head, "ref:")) return null;
    const ref = std.mem.trim(u8, head["ref:".len..], " \t\r\n");
    if (ref.len == 0) return null;

    if (try readFirstExisting(io, allocator, git_dir, common_dir, ref)) |ref_txt| {
        defer allocator.free(ref_txt);
        if (parseSha(std.mem.trim(u8, ref_txt, " \t\r\n"))) |sha| return sha;
    }
    if (try readFirstExisting(io, allocator, git_dir, common_dir, "packed-refs")) |packed_txt| {
        defer allocator.free(packed_txt);
        return lookupPackedRef(packed_txt, ref);
    }
    return null;
}

/// Find `ref` in a packed-refs file and return its sha.
pub fn lookupPackedRef(content: []const u8, ref: []const u8) ?[40]u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line[sp + 1 ..], " \t"), ref)) continue;
        return parseSha(line[0..sp]);
    }
    return null;
}

fn parseSha(text: []const u8) ?[40]u8 {
    if (text.len != 40) return null;
    for (text) |c| {
        if (!std.ascii.isHex(c)) return null;
    }
    var out: [40]u8 = undefined;
    @memcpy(&out, text[0..40]);
    return out;
}

fn joinMaybeRelative(allocator: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (path.len > 0 and (path[0] == '/' or path[0] == '\\')) return allocator.dupe(u8, path);
    if (path.len > 1 and path[1] == ':') return allocator.dupe(u8, path); // C:\...
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, path });
}

fn readFirstExisting(io: std.Io, allocator: std.mem.Allocator, a: []const u8, b: []const u8, rel: []const u8) !?[]u8 {
    const first = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ a, rel });
    defer allocator.free(first);
    if (readOptionalFile(io, allocator, first) catch null) |txt| return txt;
    if (std.mem.eql(u8, a, b)) return null;
    const second = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ b, rel });
    defer allocator.free(second);
    return readOptionalFile(io, allocator, second) catch null;
}

fn readOptionalFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

/// Atomic write via a sibling temp file + rename, matching nuke.rewriteConfigFile.
fn writeFileAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
    {
        const file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, content);
        try file.sync(io);
    }
    try std.Io.Dir.rename(std.Io.Dir.cwd(), tmp_path, std.Io.Dir.cwd(), path, io);
}

/// Same as writeFileAtomic, except an all-whitespace result deletes the file
/// instead of leaving an empty stub behind.
fn rewriteOrDelete(io: std.Io, allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        std.Io.Dir.cwd().deleteFile(io, path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }
    try writeFileAtomic(io, allocator, path, content);
}

/// Drop the policy block from a Codex AGENTS.md. Used by `codedb codex
/// uninstall` and by `codedb nuke`, so uninstalling leaves no codedb text
/// behind. Returns true when the file was rewritten.
pub fn deregisterCodexPolicyFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !bool {
    const content = (try readOptionalFile(io, allocator, path)) orelse return false;
    defer allocator.free(content);

    const rewritten = try removePolicyBlock(allocator, content) orelse return false;
    defer allocator.free(rewritten);
    try rewriteOrDelete(io, allocator, path, rewritten);
    return true;
}

// ── CLI ──────────────────────────────────────────────────────

const Scope = enum { global, repo };

const Target = struct {
    scope: Scope,
    /// Repo root for .repo scope; unused for .global.
    repo: []const u8 = ".",
};

pub fn run(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        printCodexUsage(out, s);
        out.exitWithFlush(1);
    }
    const sub = args[0];
    if (std.mem.eql(u8, sub, "--help") or std.mem.eql(u8, sub, "-h") or std.mem.eql(u8, sub, "help")) {
        printCodexUsage(out, s);
        out.exitWithFlush(0);
    }
    if (std.mem.eql(u8, sub, "install")) runInstall(io, out, s, allocator, args[1..]);
    if (std.mem.eql(u8, sub, "uninstall")) runUninstall(io, out, s, allocator, args[1..]);
    if (std.mem.eql(u8, sub, "verify")) runVerify(io, out, s, allocator, args[1..]);

    out.p("{s}\xe2\x9c\x97{s} unknown subcommand for {s}codex{s}: {s}{s}{s}\n", .{
        s.red, s.reset, s.bold, s.reset, s.bold, sub, s.reset,
    });
    printCodexUsage(out, s);
    out.exitWithFlush(1);
}

fn parseTarget(out: *Out, s: sty.Style, args: []const []const u8) Target {
    var target = Target{ .scope = .global };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--global")) {
            target = .{ .scope = .global };
            continue;
        }
        if (std.mem.startsWith(u8, a, "--repo=")) {
            target = .{ .scope = .repo, .repo = a["--repo=".len..] };
            continue;
        }
        if (std.mem.eql(u8, a, "--repo")) {
            if (i + 1 < args.len and args[i + 1].len > 0 and args[i + 1][0] != '-') {
                target = .{ .scope = .repo, .repo = args[i + 1] };
                i += 1;
            } else {
                target = .{ .scope = .repo, .repo = "." };
            }
            continue;
        }
        out.p("{s}\xe2\x9c\x97{s} unknown flag: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, a, s.reset });
        printCodexUsage(out, s);
        out.exitWithFlush(1);
    }
    return target;
}

fn homeOrExit(out: *Out, s: sty.Style, allocator: std.mem.Allocator) []u8 {
    const home_env = cio.homeDir() orelse {
        out.p("{s}\xe2\x9c\x97{s} cannot determine home directory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
    return allocator.dupe(u8, home_env) catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
}

fn agentsPath(out: *Out, s: sty.Style, allocator: std.mem.Allocator, home: []const u8, target: Target) []u8 {
    const built = switch (target.scope) {
        .global => std.fmt.allocPrint(allocator, "{s}/.codex/{s}", .{ home, agents_file_name }),
        .repo => std.fmt.allocPrint(allocator, "{s}/{s}", .{ std.mem.trimEnd(u8, target.repo, "/"), agents_file_name }),
    };
    return built catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
}

fn optOutMarkerPath(allocator: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, opt_out_marker_rel });
}

/// True when the user has opted out of the managed policy, via the env var or
/// the marker `codedb codex uninstall` leaves behind.
fn optedOut(io: std.Io, allocator: std.mem.Allocator, home: []const u8) bool {
    if (cio.posixGetenv(opt_out_env)) |v| {
        if (v.len > 0 and !std.mem.eql(u8, v, "0")) return true;
    }
    const path = optOutMarkerPath(allocator, home) catch return false;
    defer allocator.free(path);
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn runInstall(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, args: []const []const u8) noreturn {
    const target = parseTarget(out, s, args);
    const home = homeOrExit(out, s, allocator);
    defer allocator.free(home);

    if (optedOut(io, allocator, home)) {
        out.p("{s}\xe2\x97\x8b{s} codedb codex policy is opted out \xe2\x80\x94 nothing written\n", .{ s.yellow, s.reset });
        out.p("  re-enable by deleting {s}{s}/{s}{s} (and unsetting {s}{s}{s})\n", .{
            s.dim, home, opt_out_marker_rel, s.reset, s.dim, opt_out_env, s.reset,
        });
        out.exitWithFlush(0);
    }

    const path = agentsPath(out, s, allocator, home, target);
    defer allocator.free(path);

    const block = buildPolicyBlock(allocator) catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
    defer allocator.free(block);

    const existing = readOptionalFile(io, allocator, path) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot read {s}{s}{s}: {s}\n", .{ s.red, s.reset, s.bold, path, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    defer if (existing) |e| allocator.free(e);

    const updated = upsertPolicyBlock(allocator, existing orelse "", block) catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
    if (updated == null) {
        out.p("{s}\xe2\x9c\x93{s} codedb policy already current ({s}v{s}{s}) in {s}{s}{s}\n", .{
            s.green, s.reset, s.bold, release_info.semver, s.reset, s.cyan, path, s.reset,
        });
        out.exitWithFlush(0);
    }
    defer allocator.free(updated.?);

    if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(io, path[0..slash]) catch {};
    }
    writeFileAtomic(io, allocator, path, updated.?) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot write {s}{s}{s}: {s}\n", .{ s.red, s.reset, s.bold, path, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };

    const scope_label: []const u8 = if (target.scope == .global) "global (every Codex session)" else "repo";
    out.p("{s}\xe2\x9c\x93{s} codedb policy {s}v{s}{s} \xe2\x86\x92 {s}{s}{s}\n", .{
        s.green, s.reset, s.bold, release_info.semver, s.reset, s.cyan, path, s.reset,
    });
    out.p("  {s}scope{s}     {s}\n", .{ s.dim, s.reset, scope_label });
    out.p("  {s}verify{s}    codedb codex verify\n", .{ s.dim, s.reset });
    out.exitWithFlush(0);
}

fn runUninstall(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, args: []const []const u8) noreturn {
    const target = parseTarget(out, s, args);
    const home = homeOrExit(out, s, allocator);
    defer allocator.free(home);

    const path = agentsPath(out, s, allocator, home, target);
    defer allocator.free(path);

    const removed = deregisterCodexPolicyFile(io, allocator, path) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot rewrite {s}{s}{s}: {s}\n", .{ s.red, s.reset, s.bold, path, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    if (removed) {
        out.p("{s}\xe2\x9c\x93{s} removed codedb policy from {s}{s}{s}\n", .{ s.green, s.reset, s.cyan, path, s.reset });
    } else {
        out.p("{s}\xe2\x97\x8b{s} no codedb policy block in {s}{s}{s}\n", .{ s.dim, s.reset, s.cyan, path, s.reset });
    }

    // The marker makes the opt-out stick: a later `install` (including one run
    // by an installer script) refuses instead of writing the block back.
    const marker = optOutMarkerPath(allocator, home) catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
    defer allocator.free(marker);
    if (std.mem.lastIndexOfScalar(u8, marker, '/')) |slash| {
        if (slash > 0) std.Io.Dir.cwd().createDirPath(io, marker[0..slash]) catch {};
    }
    writeFileAtomic(io, allocator, marker, "codedb codex policy disabled by `codedb codex uninstall`\ndelete this file to re-enable `codedb codex install`\n") catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot write {s}{s}{s}: {s}\n", .{ s.red, s.reset, s.bold, marker, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    out.p("  {s}opt-out{s}   {s}{s}{s}  (delete to re-enable install)\n", .{ s.dim, s.reset, s.dim, marker, s.reset });
    out.exitWithFlush(0);
}

fn runVerify(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, args: []const []const u8) noreturn {
    var root_arg: []const u8 = ".";
    var repo_given = false;
    for (args) |a| {
        if (a.len > 0 and a[0] == '-') {
            out.p("{s}\xe2\x9c\x97{s} unknown flag: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, a, s.reset });
            printCodexUsage(out, s);
            out.exitWithFlush(1);
        }
        root_arg = a;
        repo_given = true;
    }

    const home = homeOrExit(out, s, allocator);
    defer allocator.free(home);

    var ok = true;
    out.p("{s}codedb codex verify{s}  {s}v{s}{s}\n", .{ s.bold, s.reset, s.dim, release_info.semver, s.reset });

    // 1. MCP registration in the Codex config.
    const config_path = std.fmt.allocPrint(allocator, "{s}/.codex/config.toml", .{home}) catch {
        out.p("{s}\xe2\x9c\x97{s} out of memory\n", .{ s.red, s.reset });
        out.exitWithFlush(1);
    };
    defer allocator.free(config_path);
    const config = readOptionalFile(io, allocator, config_path) catch null;
    defer if (config) |c| allocator.free(c);
    if (config != null and hasTomlHeader(config.?, "[mcp_servers.codedb]")) {
        out.p("  {s}\xe2\x9c\x93{s} mcp       [mcp_servers.codedb] in {s}{s}{s}\n", .{ s.green, s.reset, s.dim, config_path, s.reset });
    } else {
        ok = false;
        out.p("  {s}\xe2\x9c\x97{s} mcp       [mcp_servers.codedb] missing from {s}{s}{s}\n", .{ s.red, s.reset, s.dim, config_path, s.reset });
        out.p("            register it with {s}curl -fsSL https://codedb.codegraff.com/install.sh | bash{s}\n", .{ s.cyan, s.reset });
    }

    // 2. Policy block — global, plus the repo copy when a path was given.
    const global_agents = agentsPath(out, s, allocator, home, .{ .scope = .global });
    defer allocator.free(global_agents);
    var policy_ok = reportPolicy(io, out, s, allocator, "policy    global", global_agents) == .current;
    if (repo_given) {
        const repo_agents = agentsPath(out, s, allocator, home, .{ .scope = .repo, .repo = root_arg });
        defer allocator.free(repo_agents);
        if (reportPolicy(io, out, s, allocator, "policy    repo  ", repo_agents) == .current) policy_ok = true;
    }
    if (!policy_ok) {
        ok = false;
        out.p("            run {s}codedb codex install{s} to write the current policy\n", .{ s.cyan, s.reset });
    }

    // 3. Index presence + staleness against the repo's real HEAD.
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = cli_args.resolveRoot(io, root_arg, &root_buf) catch {
        out.p("  {s}\xe2\x9c\x97{s} index     cannot resolve root {s}{s}{s}\n", .{ s.red, s.reset, s.bold, root_arg, s.reset });
        out.exitWithFlush(1);
    };
    const data_dir = bootstrap.getDataDir(io, allocator, abs_root) catch {
        out.p("  {s}\xe2\x9c\x97{s} index     cannot resolve data dir for {s}{s}{s}\n", .{ s.red, s.reset, s.bold, abs_root, s.reset });
        out.exitWithFlush(1);
    };
    defer allocator.free(data_dir);
    const meta = index_mod.readStatusMeta(io, data_dir, allocator);
    const head = resolveGitHead(io, allocator, abs_root);

    var head_short: [12]u8 = "unknown     ".*;
    var meta_short: [12]u8 = "unknown     ".*;
    if (head) |h| @memcpy(&head_short, h[0..12]);
    if (meta.git_head) |m| @memcpy(&meta_short, m[0..12]);
    const stale = blk: {
        const h = head orelse break :blk false;
        const m = meta.git_head orelse break :blk false;
        break :blk !std.mem.eql(u8, &h, &m);
    };

    if (!meta.indexed) {
        ok = false;
        out.p("  {s}\xe2\x9c\x97{s} index     not indexed\n", .{ s.red, s.reset });
        out.p("            run {s}codedb {s} index{s}\n", .{ s.cyan, root_arg, s.reset });
    } else if (stale) {
        ok = false;
        out.p("  {s}\xe2\x9c\x97{s} index     stale \xe2\x80\x94 indexed at {s}{s}{s}, HEAD is {s}{s}{s}\n", .{
            s.red,  s.reset,      s.bold, &meta_short, s.reset,
            s.bold, &head_short,  s.reset,
        });
        out.p("            run {s}codedb {s} index{s}\n", .{ s.cyan, root_arg, s.reset });
    } else {
        out.p("  {s}\xe2\x9c\x93{s} index     {s}{d}{s} files at {s}{s}{s}\n", .{
            s.green, s.reset,  s.bold, meta.file_count, s.reset,
            s.dim,   abs_root, s.reset,
        });
    }

    out.exitWithFlush(if (ok) 0 else 1);
}

const PolicyState = enum { current, outdated, missing };

fn reportPolicy(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, label: []const u8, path: []const u8) PolicyState {
    const content = readOptionalFile(io, allocator, path) catch null;
    defer if (content) |c| allocator.free(c);
    if (content) |c| {
        if (policyBlockVersion(c)) |v| {
            if (std.mem.eql(u8, v, release_info.semver)) {
                out.p("  {s}\xe2\x9c\x93{s} {s}  v{s} in {s}{s}{s}\n", .{ s.green, s.reset, label, v, s.dim, path, s.reset });
                return .current;
            }
            out.p("  {s}\xe2\x9c\x97{s} {s}  v{s} outdated, current is v{s} \xe2\x80\x94 {s}{s}{s}\n", .{
                s.yellow, s.reset, label, v, release_info.semver, s.dim, path, s.reset,
            });
            return .outdated;
        }
    }
    out.p("  {s}\xe2\x9c\x97{s} {s}  no codedb block in {s}{s}{s}\n", .{ s.red, s.reset, label, s.dim, path, s.reset });
    return .missing;
}

fn printCodexUsage(out: *Out, s: sty.Style) void {
    out.p(
        \\
        \\{s}codedb codex{s}  CodeDB-first setup for Codex
        \\
        \\  {s}usage:{s} codedb codex <install|uninstall|verify> [args...]
        \\
        \\  {s}install{s}   [--repo <path>]   write the codedb policy block into AGENTS.md
        \\                              (default: global {s}~/.codex/AGENTS.md{s})
        \\  {s}uninstall{s} [--repo <path>]   remove the policy block and opt out
        \\  {s}verify{s}    [path]            report MCP registration, policy, index state
        \\
        \\  Re-running install refreshes an older policy block in place.
        \\  uninstall also writes {s}~/.codedb/no-codex-policy{s}; delete that file (and
        \\  unset {s}CODEDB_NO_CODEX_POLICY{s}) to let install write the policy again.
        \\
        \\  exit codes: verify returns 0 only when MCP, policy, and index all check out.
        \\
    , .{
        s.bold,  s.reset,
        s.dim,   s.reset,
        s.cyan,  s.reset,
        s.dim,   s.reset,
        s.cyan,  s.reset,
        s.cyan,  s.reset,
        s.dim,   s.reset,
        s.dim,   s.reset,
    });
}
