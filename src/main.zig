const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
const explore_mod = @import("explore.zig");
const watcher = @import("watcher.zig");
const server = @import("server.zig");
const mcp_server = @import("mcp.zig");
const sty = @import("style.zig");
const git_mod = @import("git.zig");
const TrigramIndex = @import("index.zig").TrigramIndex;
const MmapTrigramIndex = @import("index.zig").MmapTrigramIndex;
const AnyTrigramIndex = @import("index.zig").AnyTrigramIndex;
const WordIndex = @import("index.zig").WordIndex;
const index_mod = @import("index.zig");
const snapshot_mod = @import("snapshot.zig");
const telemetry = @import("telemetry.zig");
const root_policy = @import("root_policy.zig");
const nuke_mod = @import("nuke.zig");
const update_mod = @import("update.zig");
const release_info = @import("release_info.zig");
const Config = @import("config.zig").Config;

/// Buffered stdout wrapper. Formats into a 64KB stack-buffered window and
/// flushes lazily; an explicit `flush()` runs from mainImpl's deferred cleanup.
/// `word` on a high-count term (~2k hits) used to do 2k mallocs + 2k write()
/// syscalls; this collapses that to a handful of batched writes.
const Out = struct {
    file: cio.File,
    alloc: std.mem.Allocator,
    buf: [65536]u8 = undefined,
    used: usize = 0,
    // When set, flush() appends here instead of writing to `file`. Lets a warm
    // daemon capture a command's full rendered output (run via runQuery) and frame
    // it back to a CLI client over a socket — reusing the exact rendering the cold
    // CLI uses. null for the normal stdout path.
    sink: ?*std.ArrayList(u8) = null,

    fn p(self: *Out, comptime fmt: []const u8, args: anytype) void {
        // Fast path: format directly into the remaining buffer window.
        const remaining = self.buf[self.used..];
        if (std.fmt.bufPrint(remaining, fmt, args)) |s| {
            self.used += s.len;
            return;
        } else |_| {}
        // Either doesn't fit OR remaining is too small. Flush, retry from start.
        self.flush();
        if (std.fmt.bufPrint(&self.buf, fmt, args)) |s| {
            self.used = s.len;
            return;
        } else |_| {}
        // Single message larger than 64KB — fall back to one-shot heap alloc.
        const big = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(big);
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, big) catch {};
        } else {
            self.file.writeAll(big) catch {};
        }
    }

    fn flush(self: *Out) void {
        if (self.used == 0) return;
        if (self.sink) |snk| {
            snk.appendSlice(self.alloc, self.buf[0..self.used]) catch {};
        } else {
            self.file.writeAll(self.buf[0..self.used]) catch {};
        }
        self.used = 0;
    }

    /// Print + flush + exit. `std.process.exit(_)` skips the deferred
    /// `out.flush()`, which used to silently swallow usage and error
    /// messages on any failure path — `codedb` with no args printed
    /// nothing and just exited 1 (#504). Use this anywhere we'd
    /// otherwise call exit() directly after writing user-facing output.
    fn exitWithFlush(self: *Out, code: u8) noreturn {
        self.flush();
        std.process.exit(code);
    }
};

/// The real entry point.  In Debug builds, Zig may merge all command-branch
/// stack frames into one producing a frame that overflows the default OS stack,
/// so we trampoline through a thread with an explicit 64 MB stack.
/// In optimised builds the merged frame is ~190 KB, so 8 MB is ample and
/// avoids triggering Rosetta 2's 64 MB stack allocation bug on x86_64-macos.
///
/// #504: must have a non-error-union return type. A Zig binary with
/// `pub fn main(...) !void` ad-hoc-signed and run via Rosetta (or, in the
/// user-reported case, on a native macOS Intel build that ends up with a
/// similar startup-path tripwire) segfaults BEFORE main runs — the runtime's
/// error-handling wrapper is what crashes. Verified with a minimal repro:
/// `pub fn main(init) void { ... }` works; `!void` does not. Same crash
/// happens if the entry point spawns a thread before writing to stderr.
/// So we keep the entry point synchronous + infallible, and push any
/// fallible work into mainImpl which runs after we've already had a chance
/// to surface usage / --version output via the fast path.
pub fn main(init: std.process.Init.Minimal) void {
    cio.setProcessArgs(init.args.vector);
    if (handleFastPath(init.args.vector)) return;
    mainTrampoline() catch |err| {
        // Surface the failure on stderr so users see something even if the
        // worker thread crashes during startup.
        var buf: [256]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "codedb: fatal startup error: {s}\n", .{@errorName(err)})) |msg| {
            _ = std.c.write(2, msg.ptr, msg.len);
        } else |_| {}
        std.process.exit(1);
    };
}

fn mainTrampoline() !void {
    const stack_size: usize = if (builtin.mode == .Debug) 64 * 1024 * 1024 else 8 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, mainInner, .{});
    thread.join();
}

/// Returns true if the invocation was handled and `main` should exit.
/// Designed to be the cheapest possible path — uses raw stdout writes
/// instead of any of the heavier init machinery in mainImpl, so a bug
/// further down the stack can't take out plain `codedb` / `--help` /
/// `--version` invocations.
fn handleFastPath(argv: []const [*:0]const u8) bool {
    const stdout_fd: c_int = 1;
    const stderr_fd: c_int = 2;

    if (argv.len < 2) {
        const msg =
            "codedb  code intelligence server\n\n" ++
            "  usage: codedb [root] <command> [args...]\n\n" ++
            "  run `codedb --help` for the full command list.\n";
        _ = std.c.write(stderr_fd, msg.ptr, msg.len);
        std.process.exit(1);
    }

    const a1 = std.mem.span(argv[1]);
    if (std.mem.eql(u8, a1, "--version") or std.mem.eql(u8, a1, "-v") or std.mem.eql(u8, a1, "version")) {
        var buf: [128]u8 = undefined;
        const out = std.fmt.bufPrint(&buf, "codedb {s}\n", .{release_info.semver}) catch {
            std.process.exit(0);
        };
        _ = std.c.write(stdout_fd, out.ptr, out.len);
        std.process.exit(0);
    }

    return false;
}

fn mainInner() void {
    mainImpl() catch |err| {
        std.debug.print("fatal: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}
/// Read-only query command dispatch, extracted from mainImpl so the same
/// rendering code can run inside the warm daemon (writing to a socket)
/// without exiting the daemon process. Returns a u8 exit code; the caller
/// is responsible for flushing `out`. Covers: tree, outline, find, search,
/// word, read, hot. Unknown commands return 1.
fn runQuery(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, root: []const u8, cmd: []const u8, args: []const []const u8, cmd_args_start: usize, out: *Out, s: sty.Style) u8 {
    const use_color = s.reset.len != 0;
    if (std.mem.eql(u8, cmd, "tree")) {
        if (hasExtraCliArgs(args, cmd_args_start)) {
            out.p("{s}\xe2\x9c\x97{s} unexpected extra argument: {s}{s}{s}  (usage: codedb [root] {s}tree{s})\n", .{
                s.red, s.reset, s.bold, args[cmd_args_start], s.reset, s.cyan, s.reset,
            });
            return 1;
        }
        const t0 = cio.nanoTimestamp();
        const tree = explorer.getTree(allocator, use_color) catch return 1;
        defer allocator.free(tree);
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        out.p("{s}", .{tree});
        out.p("{s}{s}{s}\n", .{
            sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed), s.reset,
        });
    } else if (std.mem.eql(u8, cmd, "outline")) {
        const path = if (args.len > cmd_args_start) args[cmd_args_start] else {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] outline {s}<path>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            return 1;
        };
        const t0 = cio.nanoTimestamp();
        var outline = explorer.getOutline(path, allocator) catch {
            out.p("{s}\xe2\x9c\x97{s} {s}{s}{s} \xe2\x80\x94 failed to load outline\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            return 1;
        } orelse {
            out.p("{s}\xe2\x9c\x97{s} not indexed: {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            return 0;
        };
        defer outline.deinit();
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        const lang = @tagName(outline.language);
        out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  {s}{d} lines{s}  {s}{s}{s}\n", .{
            s.green,                               s.reset,
            s.bold,                                path,
            s.reset,                               s.langColor(lang),
            lang,                                  s.reset,
            s.dim,                                 outline.line_count,
            s.reset,                               sty.durationColor(s, elapsed),
            sty.formatDuration(&dur_buf, elapsed), s.reset,
        });
        for (outline.symbols.items) |sym| {
            const kind = @tagName(sym.kind);
            out.p("  {s}L{d:<5}{s}  {s}{s:<14}{s}  {s}{s}{s}", .{
                s.dim,             sym.line_start, s.reset,
                s.kindColor(kind), kind,           s.reset,
                s.bold,            sym.name,       s.reset,
            });
            if (sym.detail) |d| {
                out.p("  {s}{s}{s}", .{ s.dim, d, s.reset });
            }
            out.p("\n", .{});
        }
    } else if (std.mem.eql(u8, cmd, "find")) {
        const name = if (args.len > cmd_args_start) args[cmd_args_start] else {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] find {s}<symbol>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            return 1;
        };
        const t0 = cio.nanoTimestamp();
        if (explorer.findSymbol(name, allocator) catch return 1) |r| {
            defer {
                allocator.free(r.path);
                allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| allocator.free(d);
            }
            const elapsed = cio.nanoTimestamp() - t0;
            var dur_buf: [64]u8 = undefined;
            const kind = @tagName(r.symbol.kind);
            out.p("{s}\xe2\x9c\x93{s} {s}{s}{s} {s}{s}{s}  {s}{s}{s}:{s}{d}{s}  {s}{s}{s}\n", .{
                s.green,                       s.reset,
                s.kindColor(kind),             kind,
                s.reset,                       s.bold,
                name,                          s.reset,
                s.dim,                         r.path,
                s.reset,                       s.cyan,
                r.symbol.line_start,           s.reset,
                sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
                s.reset,
            });
            if (r.symbol.detail) |d| {
                out.p("  {s}{s}{s}\n", .{ s.dim, d, s.reset });
            }
        } else {
            out.p("{s}\xe2\x9c\x97{s} not found: {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, name, s.reset,
            });
        }
    } else if (std.mem.eql(u8, cmd, "search")) {
        const sa = parseSearchArgs(args, cmd_args_start) catch |e| {
            switch (e) {
                error.UnknownFlag => out.p("{s}\xe2\x9c\x97{s} unknown flag for {s}search{s}  (valid: {s}--regex{s}, {s}--paths-only{s}, {s}--max-results N{s})\n", .{
                    s.red, s.reset, s.bold, s.reset, s.cyan, s.reset, s.cyan, s.reset, s.cyan, s.reset,
                }),
                error.MissingMaxResults, error.BadMaxResults => out.p("{s}\xe2\x9c\x97{s} {s}--max-results{s} requires a positive integer\n", .{
                    s.red, s.reset, s.cyan, s.reset,
                }),
                error.ExtraArg => out.p("{s}\xe2\x9c\x97{s} unexpected extra argument (quote multi-word queries: {s}search \"foo bar\"{s})\n", .{
                    s.red, s.reset, s.cyan, s.reset,
                }),
                error.MissingQuery, error.EmptyQuery => out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] search [--regex] [--paths-only] [--max-results N] {s}<query>{s}\n", .{
                    s.red, s.reset, s.cyan, s.reset,
                }),
            }
            return 1;
        };
        const query = sa.query;
        const use_regex = sa.use_regex;
        const paths_only = sa.paths_only;
        const t0 = cio.nanoTimestamp();
        const results = if (use_regex)
            explorer.searchContentRegex(query, allocator, sa.max_results) catch |e| {
                if (e == error.InvalidRegex) {
                    out.p("{s}\xe2\x9c\x97{s} invalid regex: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, query, s.reset });
                } else {
                    out.p("{s}\xe2\x9c\x97{s} search failed\n", .{ s.red, s.reset });
                }
                return 1;
            }
        else
            explorer.searchContent(query, allocator, sa.max_results) catch return 1;
        defer {
            for (results) |r| {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
            allocator.free(results);
        }
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        const quiet = cio.posixGetenv("CODEDB_QUIET") != null;
        if (results.len == 0) {
            if (!quiet) {
                out.p("{s}\xe2\x9c\x97{s} no results for {s}\"{s}\"{s}\n", .{
                    s.yellow, s.reset, s.bold, query, s.reset,
                });
            }
        } else {
            if (!quiet) {
                const mode_label: []const u8 = if (use_regex) " (regex)" else "";
                out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} results for {s}\"{s}\"{s}{s}  {s}{s}{s}\n", .{
                    s.green,                               s.reset,
                    s.bold,                                results.len,
                    s.reset,                               s.bold,
                    query,                                 s.reset,
                    mode_label,                            sty.durationColor(s, elapsed),
                    sty.formatDuration(&dur_buf, elapsed), s.reset,
                });
            }
            for (results) |r| {
                if (paths_only) {
                    out.p("  {s}{s}{s}:{s}{d}{s}\n", .{
                        s.cyan, r.path, s.reset,
                        s.dim,  r.line_num, s.reset,
                    });
                } else {
                    out.p("  {s}{s}{s}:{s}{d}{s}  {s}\n", .{
                        s.cyan,      r.path,     s.reset,
                        s.dim,       r.line_num, s.reset,
                        r.line_text,
                    });
                }
            }
        }
    } else if (std.mem.eql(u8, cmd, "word")) {
        const word = if (args.len > cmd_args_start) args[cmd_args_start] else {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] word {s}<identifier>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            return 1;
        };
        const t0 = cio.nanoTimestamp();
        const hits = explorer.searchWord(word, allocator) catch return 1;
        defer allocator.free(hits);
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        if (hits.len == 0) {
            out.p("{s}\xe2\x9c\x97{s} no hits for {s}'{s}'{s}\n", .{
                s.yellow, s.reset, s.bold, word, s.reset,
            });
        } else {
            out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} hits for {s}'{s}'{s}  {s}{s}{s}\n", .{
                s.green,                       s.reset,
                s.bold,                        hits.len,
                s.reset,                       s.bold,
                word,                          s.reset,
                sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
                s.reset,
            });
            explorer.mu.lockShared();
            defer explorer.mu.unlockShared();
            for (hits) |h| {
                out.p("  {s}{s}{s}:{s}{d}{s}\n", .{
                    s.cyan, explorer.word_index.hitPath(h), s.reset,
                    s.dim,  h.line_num,                     s.reset,
                });
            }
        }
    } else if (std.mem.eql(u8, cmd, "read")) {
        // CLI counterpart of codedb_read MCP tool. Closes the agentic-eval
        // gap where the CLI surface lacked a file-read primitive — agents
        // restricted to `codedb` CLI had to reconstruct file bodies from
        // 20+ `search` invocations.
        var line_start: ?u32 = null;
        var line_end: ?u32 = null;
        var compact = false;
        var path_opt: ?[]const u8 = null;
        var arg_idx = cmd_args_start;
        // Flags (`-L FROM-TO`, `--compact`) may appear before or after the path
        // (#528 item 8). Unknown flags and a second positional are rejected so
        // typos surface instead of silently dumping the whole file.
        while (args.len > arg_idx) : (arg_idx += 1) {
            const a = args[arg_idx];
            if (std.mem.eql(u8, a, "--compact") or std.mem.eql(u8, a, "-c")) {
                compact = true;
            } else if (std.mem.eql(u8, a, "-L") or std.mem.eql(u8, a, "--lines")) {
                if (arg_idx + 1 >= args.len) {
                    out.p("{s}\xe2\x9c\x97{s} {s}-L{s} requires a {s}FROM-TO{s} range\n", .{
                        s.red, s.reset, s.cyan, s.reset, s.cyan, s.reset,
                    });
                    return 1;
                }
                const range = args[arg_idx + 1];
                arg_idx += 1;
                const lr = parseLineRange(range) catch {
                    out.p("{s}\xe2\x9c\x97{s} invalid line range: {s}{s}{s}  (expected {s}FROM-TO{s}, 1-based, FROM \xe2\x89\xa4 TO; TO may be {s}${s})\n", .{
                        s.red, s.reset, s.bold, range, s.reset, s.cyan, s.reset, s.cyan, s.reset,
                    });
                    return 1;
                };
                line_start = lr.start;
                line_end = lr.end;
            } else if (a.len > 0 and a[0] == '-') {
                out.p("{s}\xe2\x9c\x97{s} unknown flag for {s}read{s}: {s}{s}{s}  (valid: {s}-L FROM-TO{s}, {s}--compact{s})\n", .{
                    s.red, s.reset, s.bold, s.reset, s.bold, a, s.reset, s.cyan, s.reset, s.cyan, s.reset,
                });
                return 1;
            } else if (path_opt == null) {
                path_opt = a;
            } else {
                out.p("{s}\xe2\x9c\x97{s} unexpected extra argument: {s}{s}{s}\n", .{
                    s.red, s.reset, s.bold, a, s.reset,
                });
                return 1;
            }
        }
        const path = path_opt orelse {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] read [-L FROM-TO] [--compact] {s}<path>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            return 1;
        };
        // Same safety guards as codedb_read MCP — path must be project-relative
        // (no leading `/`, no `..` traversal, no null bytes / backslashes) and
        // must not target sensitive files like .env / id_rsa / .ssh/*. Without
        // these guards the CLI happily reads /etc/passwd, secrets, or any file
        // the codedb process can see.
        if (!mcp_server.isPathSafe(path)) {
            out.p("{s}\xe2\x9c\x97{s} path must be relative to the project root (no leading `/`, no `..` traversal): {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            return 1;
        }
        if (watcher.isSensitivePath(path)) {
            out.p("{s}\xe2\x9c\x97{s} access to sensitive file blocked: {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            return 1;
        }
        const t0 = cio.nanoTimestamp();
        // Prefer indexed content (matches the indexed view), fall back to disk
        // reads anchored at the resolved project root — NOT cwd. Pre-fix, an
        // explicit `codedb /path/to/proj read foo.zig` would read `./foo.zig`
        // from wherever the user happened to invoke it.
        const cached = explorer.getContent(path, allocator) catch null;
        const content_owned = if (cached) |c| c else blk: {
            var root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch {
                out.p("{s}\xe2\x9c\x97{s} cannot open project root: {s}{s}{s}\n", .{
                    s.red, s.reset, s.bold, root, s.reset,
                });
                return 1;
            };
            defer root_dir.close(io);
            break :blk root_dir.readFileAlloc(io, path, allocator, .limited(10 * 1024 * 1024)) catch {
                out.p("{s}\xe2\x9c\x97{s} not indexed and disk read failed: {s}{s}{s}\n", .{
                    s.red, s.reset, s.bold, path, s.reset,
                });
                return 1;
            };
        };
        defer allocator.free(content_owned);
        // Binary detection (NUL byte in first 8KB) — stub instead of dumping raw bytes
        const probe_len = @min(content_owned.len, 8 * 1024);
        if (std.mem.indexOfScalar(u8, content_owned[0..probe_len], 0) != null) {
            out.p("{s}\xe2\x9c\x97{s} binary file: {d} bytes\n", .{ s.yellow, s.reset, content_owned.len });
            return 0;
        }
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        const has_range = line_start != null or line_end != null;
        const lang = explore_mod.detectLanguage(path);
        if (has_range or compact) {
            const start: u32 = line_start orelse 1;
            const end: u32 = line_end orelse std.math.maxInt(u32);
            const extracted = explore_mod.extractLines(content_owned, start, end, true, compact, lang, allocator) catch {
                out.p("{s}\xe2\x9c\x97{s} line extraction failed\n", .{ s.red, s.reset });
                return 1;
            };
            defer allocator.free(extracted);
            const unbounded = end == std.math.maxInt(u32);
            if (unbounded) {
                out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  L{d}-EOF  {s}{s}{s}\n", .{
                    s.green,                       s.reset,
                    s.bold,                        path,
                    s.reset,                       s.langColor(@tagName(lang)),
                    @tagName(lang),                s.reset,
                    start,                         sty.durationColor(s, elapsed),
                    sty.formatDuration(&dur_buf, elapsed), s.reset,
                });
            } else {
                out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  L{d}-{d}  {s}{s}{s}\n", .{
                    s.green,                       s.reset,
                    s.bold,                        path,
                    s.reset,                       s.langColor(@tagName(lang)),
                    @tagName(lang),                s.reset,
                    start,                         end,
                    sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
                    s.reset,
                });
            }
            out.p("{s}", .{extracted});
        } else {
            out.p("{s}\xe2\x9c\x93{s} {s}{s}{s}  {s}{s}{s}  {s}{s}{s}\n", .{
                s.green,                       s.reset,
                s.bold,                        path,
                s.reset,                       s.langColor(@tagName(lang)),
                @tagName(lang),                s.reset,
                sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
                s.reset,
            });
            var line_num: u32 = 0;
            var lines = std.mem.splitScalar(u8, content_owned, '\n');
            while (lines.next()) |line| {
                line_num += 1;
                out.p("{d:>5} | {s}\n", .{ line_num, line });
            }
        }
    } else if (std.mem.eql(u8, cmd, "hot")) {
        if (hasExtraCliArgs(args, cmd_args_start)) {
            out.p("{s}\xe2\x9c\x97{s} unexpected extra argument: {s}{s}{s}  (usage: codedb [root] {s}hot{s})\n", .{
                s.red, s.reset, s.bold, args[cmd_args_start], s.reset, s.cyan, s.reset,
            });
            return 1;
        }
        const t0 = cio.nanoTimestamp();
        const hot = explorer.getHotFiles(store, allocator, 10) catch return 1;
        defer {
            for (hot) |path| allocator.free(path);
            allocator.free(hot);
        }
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        out.p("{s}\xe2\x9c\x93{s} {s}recently modified{s}  {s}{s}{s}\n", .{
            s.green,                       s.reset,
            s.bold,                        s.reset,
            sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
            s.reset,
        });
        for (hot, 1..) |path, i| {
            out.p("  {s}{d}{s}  {s}{s}{s}\n", .{
                s.dim,  i,    s.reset,
                s.cyan, path, s.reset,
            });
        }
    } else if (std.mem.eql(u8, cmd, "status")) {
        // #528 item 1: read-only CLI status mirroring codedb_status, so
        // `codedb status` works without going through the MCP surface.
        if (hasExtraCliArgs(args, cmd_args_start)) {
            out.p("{s}\xe2\x9c\x97{s} unexpected extra argument: {s}{s}{s}  (usage: codedb [root] {s}status{s})\n", .{
                s.red, s.reset, s.bold, args[cmd_args_start], s.reset, s.cyan, s.reset,
            });
            return 1;
        }
        const t0 = cio.nanoTimestamp();
        store.mu.lock();
        const file_count = store.files.count();
        const seq = store.seq;
        store.mu.unlock();
        explorer.mu.lockShared();
        const outline_count = explorer.outlines.count();
        const trigram_files = explorer.trigram_index.fileCount();
        const trigram_type: []const u8 = switch (explorer.trigram_index) {
            .heap => "heap",
            .mmap => "mmap",
            .mmap_overlay => "mmap+overlay",
        };
        explorer.mu.unlockShared();
        const index_kb = telemetry.approxIndexSizeBytes(explorer) / 1024;
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        out.p("{s}\xe2\x9c\x93{s} {s}codedb {s}{s}  {s}{s}{s}\n", .{
            s.green,                               s.reset,
            s.bold,                                release_info.semver,
            s.reset,                               sty.durationColor(s, elapsed),
            sty.formatDuration(&dur_buf, elapsed), s.reset,
        });
        out.p("  {s}root{s}      {s}{s}{s}\n", .{ s.dim, s.reset, s.cyan, root, s.reset });
        out.p("  {s}files{s}     {s}{d}{s} indexed\n", .{ s.dim, s.reset, s.bold, file_count, s.reset });
        out.p("  {s}seq{s}       {s}{d}{s}\n", .{ s.dim, s.reset, s.bold, seq, s.reset });
        out.p("  {s}outlines{s}  {s}{d}{s}\n", .{ s.dim, s.reset, s.bold, outline_count, s.reset });
        out.p("  {s}index{s}     {s}{s}{s}  {d} files, {d}KB\n", .{ s.dim, s.reset, s.cyan, trigram_type, s.reset, trigram_files, index_kb });
    } else {
        // Not a natively-rendered command — bridge to the MCP navigation
        // handlers (symbol/callers/deps/glob/ls/file/context) so the CLI can
        // reach the same warm tools the MCP surface exposes.
        var nav: std.ArrayList(u8) = .empty;
        defer nav.deinit(allocator);
        if (mcp_server.runCliTool(io, allocator, explorer, root, cmd, args, cmd_args_start, &nav)) |code| {
            out.p("{s}", .{nav.items});
            return code;
        }
        return 1;
    }
    return 0;
}

// ── Thin CLI client → warm daemon ──────────────────────────────────────────
// When a `codedb <root> serve` or `codedb <root> mcp` daemon is already running
// for a project, a fresh `codedb <root> <query>` invocation can skip the
// per-process snapshot reload by proxying the command to that daemon over a
// per-project Unix-domain socket. The daemon runs the exact same `runQuery`
// rendering against its already-warm Explorer/Store and streams the rendered
// bytes back. If no daemon is listening, the client transparently falls back to
// the cold in-process path.
//
// Transport: blocking std.c (libc) Unix sockets. std.posix dropped the socket
// syscalls in 0.16 and the std.Io.net UnixAddress Reader/Writer surface is
// awkward for a tiny framed request/response, so we go straight to libc here.
// runQuery itself still receives the daemon's real `io` (it reads files through
// it); only the socket bytes move over libc.
//
// Wire protocol (little-endian, length-framed):
//   request  (client→daemon): [u8 color][u32 blob_len][blob]
//       blob = argv[1..] NUL-joined, e.g. "/proj\0find\0foo"
//   response (daemon→client): [u8 exit_code][u32 out_len][out_bytes]
const cli_blob_max: u32 = 64 * 1024;

/// Build the per-project socket path into `buf`. Stays well under sun_path
/// (104 bytes on macOS / 108 on Linux): "/tmp/codedb-<uid>-<hash16>.sock" is
/// at most ~40 bytes. Returns null only if formatting somehow overflows `buf`.
fn cliSocketPath(buf: []u8, abs_root: []const u8) ?[]const u8 {
    const uid = std.c.getuid();
    const hash = std.hash.Wyhash.hash(0xc0de, abs_root);
    return std.fmt.bufPrint(buf, "/tmp/codedb-{d}-{x:0>16}.sock", .{ uid, hash }) catch null;
}

/// Fill a sockaddr.un for `path` (which must be NUL-terminatable into sun_path).
/// Returns the struct plus the byte length to pass to bind/connect. Path is
/// guaranteed short by cliSocketPath, but we guard the copy regardless.
fn cliFillSockaddr(path: []const u8) ?struct { addr: std.c.sockaddr.un, len: std.c.socklen_t } {
    var addr: std.c.sockaddr.un = .{ .family = std.c.AF.UNIX, .path = undefined };
    if (path.len + 1 > addr.path.len) return null;
    @memcpy(addr.path[0..path.len], path);
    addr.path[path.len] = 0;
    // sun_len/sun_family + the NUL-terminated path. sizeof works on every
    // platform we ship; the extra trailing bytes are harmless for AF_UNIX.
    const len: std.c.socklen_t = @intCast(@sizeOf(std.c.sockaddr.un));
    return .{ .addr = addr, .len = len };
}

/// Read exactly `buf.len` bytes from a blocking fd, looping over short reads.
/// Returns false on EOF-before-full or a hard error (EINTR is retried).
fn cliReadFull(fd: c_int, buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = std.c.read(fd, buf.ptr + off, buf.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n == 0) return false; // peer closed early
        if (std.c.errno(n) == .INTR) continue;
        return false;
    }
    return true;
}

/// Write all of `data` to a blocking fd, looping over short/partial writes.
/// Returns false on a hard error (EINTR is retried).
fn cliWriteFull(fd: c_int, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n > 0) {
            off += @intCast(n);
            continue;
        }
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        return false;
    }
    return true;
}

/// True for the read-only query commands the daemon will serve / the client
/// will proxy. Everything else (serve, mcp, snapshot, index, ...) is handled
/// only by the cold path.
fn cliIsQueryCmd(cmd: []const u8) bool {
    const cmds = [_][]const u8{ "tree", "outline", "find", "search", "word", "read", "hot", "status", "symbol", "callers", "callpath", "deps", "glob", "ls", "file", "context" };
    for (cmds) |c| {
        if (std.mem.eql(u8, cmd, c)) return true;
    }
    return false;
}

/// Daemon side. Bind a per-project Unix socket and serve framed query requests
/// against the warm `explorer`/`store`. Runs on its own detached thread so it
/// never blocks the daemon's primary loop. Connections are handled sequentially
/// (CLI calls are infrequent and runQuery already tolerates concurrent reads
/// from the watcher). On a fatal bind failure it logs and returns — the daemon
/// keeps working and clients simply fall back to the cold path.
/// Daemon side. Bind a per-project Unix socket and serve framed query requests
/// against the warm `explorer`/`store`. Runs on its own detached thread so it
/// never blocks the daemon's primary loop. Connections are handled sequentially
/// (CLI calls are infrequent and runQuery already tolerates concurrent reads
/// from the watcher).
///
/// `last_activity_ms` is bumped to the current ms timestamp at the start of
/// every accepted connection so a time-based idle watchdog (cli-daemon) can
/// tell when the socket has gone quiet. `shutdown` is set to true on a fatal
/// bind/listen failure: this lets an auto-spawned cli-daemon that lost the bind
/// race to an already-running daemon exit promptly instead of lingering. The
/// long-lived serve/mcp daemons pass a `shutdown` flag they never watch, so for
/// them a bind failure simply disables the proxy (clients fall back to cold).
fn cliDaemonListen(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, last_activity_ms: *std.atomic.Value(i64), shutdown: *std.atomic.Value(bool)) void {
    var path_buf: [128]u8 = undefined;
    const sock_path = cliSocketPath(&path_buf, abs_root) orelse {
        std.log.warn("cli-proxy: could not build socket path", .{});
        shutdown.store(true, .release);
        return;
    };
    var path_z_buf: [128]u8 = undefined;
    const sock_path_z = std.fmt.bufPrintZ(&path_z_buf, "{s}", .{sock_path}) catch {
        shutdown.store(true, .release);
        return;
    };

    const sa = cliFillSockaddr(sock_path) orelse {
        shutdown.store(true, .release);
        return;
    };

    // Try to bind; if the path is stale (a dead daemon left it behind) unlink
    // and retry once. listenfd is owned for the lifetime of the daemon.
    var listenfd: c_int = -1;
    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
        if (fd < 0) {
            std.log.warn("cli-proxy: socket() failed", .{});
            shutdown.store(true, .release);
            return;
        }
        var sa_mut = sa;
        const rc = std.c.bind(fd, @ptrCast(&sa_mut.addr), sa_mut.len);
        if (rc == 0) {
            listenfd = fd;
            break;
        }
        _ = std.c.close(fd);
        if (attempt == 0) {
            // Stale socket from a previous (now dead) daemon — clear and retry.
            _ = std.c.unlink(sock_path_z.ptr);
            continue;
        }
        // A live daemon already owns this socket (lost the bind race). Signal
        // shutdown so a duplicate auto-spawned cli-daemon exits promptly.
        std.log.warn("cli-proxy: bind {s} failed — proxy disabled", .{sock_path});
        shutdown.store(true, .release);
        return;
    }
    if (listenfd < 0) {
        shutdown.store(true, .release);
        return;
    }
    defer {
        _ = std.c.close(listenfd);
        _ = std.c.unlink(sock_path_z.ptr);
    }

    // Owner-only perms on the socket (0600). Must chmod the path, not fchmod the
    // fd: Darwin ignores fchmod() on a socket fd, leaving the node world-rwx.
    // Safe to do before listen() — no client can connect+use it yet. Non-fatal.
    _ = std.c.chmod(sock_path_z.ptr, 0o600);

    if (std.c.listen(listenfd, 16) != 0) {
        std.log.warn("cli-proxy: listen failed — proxy disabled", .{});
        shutdown.store(true, .release);
        return;
    }
    std.log.info("cli-proxy: listening on {s}", .{sock_path});

    while (true) {
        const conn = std.c.accept(listenfd, null, null);
        if (conn < 0) {
            if (std.c.errno(conn) == .INTR) continue;
            // Listener went bad; stop the loop (daemon still serves its main API).
            return;
        }
        // Record activity for the cli-daemon idle watchdog before serving.
        last_activity_ms.store(cio.milliTimestamp(), .release);
        cliServeConn(io, allocator, explorer, store, abs_root, conn);
        _ = std.c.close(conn);
    }
}

/// Handle one client connection: read the framed request, run the query into a
/// sink buffer via runQuery, and write the framed response.
fn cliServeConn(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, abs_root: []const u8, conn: c_int) void {
    // Header: [u8 color][u32 blob_len]
    var hdr: [5]u8 = undefined;
    if (!cliReadFull(conn, &hdr)) return;
    const color = hdr[0] != 0;
    const blob_len = std.mem.readInt(u32, hdr[1..5], .little);
    if (blob_len == 0 or blob_len > cli_blob_max) {
        cliRespond(conn, 1, "");
        return;
    }

    const blob = allocator.alloc(u8, blob_len) catch {
        cliRespond(conn, 1, "");
        return;
    };
    defer allocator.free(blob);
    if (!cliReadFull(conn, blob)) return;

    // Rebuild argv = ["codedb"] ++ split(blob, '\0'), skipping empty fields.
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, "codedb") catch {
        cliRespond(conn, 1, "");
        return;
    };
    var it = std.mem.splitScalar(u8, blob, 0);
    while (it.next()) |field| {
        if (field.len == 0) continue;
        argv.append(allocator, field) catch {
            cliRespond(conn, 1, "");
            return;
        };
    }

    const parsed = parsePositional(argv.items);
    if (parsed.usage_exit or !cliIsQueryCmd(parsed.cmd)) {
        cliRespond(conn, 1, "");
        return;
    }

    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    var out = Out{ .file = cio.File.stdout(), .alloc = allocator, .sink = &sink };
    const s = sty.style(color);
    const code = runQuery(io, allocator, explorer, store, abs_root, parsed.cmd, argv.items, parsed.cmd_args_start, &out, s);
    out.flush();

    cliRespond(conn, code, sink.items);
}

/// Write the framed response [u8 code][u32 out_len][out_bytes] to `conn`.
fn cliRespond(conn: c_int, code: u8, out_bytes: []const u8) void {
    var hdr: [5]u8 = undefined;
    hdr[0] = code;
    std.mem.writeInt(u32, hdr[1..5], @intCast(out_bytes.len), .little);
    if (!cliWriteFull(conn, &hdr)) return;
    if (out_bytes.len > 0) _ = cliWriteFull(conn, out_bytes);
}

/// Client side. If a daemon is listening for this project, proxy the command to
/// it and stream the rendered output to stdout, returning the daemon's exit
/// code. On ANY failure (no daemon, connect refused, short read, oversized
/// response) returns null so the caller falls back to the cold in-process path.
/// `args` is mainImpl's filtered argv (args[0] = program name); we send args[1..].
fn cliTryProxy(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8, args: []const []const u8, color: bool) ?u8 {
    _ = io;
    if (args.len < 2) return null;

    var path_buf: [128]u8 = undefined;
    const sock_path = cliSocketPath(&path_buf, abs_root) orelse return null;
    const sa = cliFillSockaddr(sock_path) orelse return null;

    const fd = std.c.socket(std.c.AF.UNIX, std.c.SOCK.STREAM, 0);
    if (fd < 0) return null;
    defer _ = std.c.close(fd);

    var sa_mut = sa;
    if (std.c.connect(fd, @ptrCast(&sa_mut.addr), sa_mut.len) != 0) return null;

    // Build the NUL-joined blob from args[1..].
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(allocator);
    for (args[1..], 0..) |a, i| {
        if (i != 0) blob.append(allocator, 0) catch return null;
        blob.appendSlice(allocator, a) catch return null;
    }
    if (blob.items.len == 0 or blob.items.len > cli_blob_max) return null;

    // Request header: [u8 color][u32 blob_len]
    var hdr: [5]u8 = undefined;
    hdr[0] = if (color) 1 else 0;
    std.mem.writeInt(u32, hdr[1..5], @intCast(blob.items.len), .little);
    if (!cliWriteFull(fd, &hdr)) return null;
    if (!cliWriteFull(fd, blob.items)) return null;

    // Response header: [u8 code][u32 out_len]
    var resp_hdr: [5]u8 = undefined;
    if (!cliReadFull(fd, &resp_hdr)) return null;
    const code = resp_hdr[0];
    const out_len = std.mem.readInt(u32, resp_hdr[1..5], .little);

    if (out_len > 0) {
        const out_bytes = allocator.alloc(u8, out_len) catch return null;
        defer allocator.free(out_bytes);
        if (!cliReadFull(fd, out_bytes)) return null;
        cio.File.stdout().writeAll(out_bytes) catch {};
    }
    return code;
}
fn mainImpl() !void {
    // Use c_allocator (libc malloc) — better page reclamation than GPA
    const allocator = std.heap.c_allocator;
    cio.ignoreSigpipe();

    // 0.16: single Threaded I/O instance passed down through every subsystem
    // that touches fs/subprocess. See issue #282. `io` flows into mcp.run,
    // update.run, nuke.run, watcher.initialScan, server.serve, Store, Explorer.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const stdout = cio.File.stdout();
    const use_color = stdout.isTty();
    const s = sty.style(use_color);
    var out = Out{ .file = stdout, .alloc = allocator };
    defer out.flush();

    const raw_args = try cio.argsAlloc(allocator);
    defer cio.argsFree(allocator, raw_args);

    // Extract --config-file=<path> / --config-file <path> before positional
    // arg parsing so a leading `--config-file=X` isn't misread as the root.
    // See #101, #102.
    var explicit_config: ?[]const u8 = null;
    var no_telemetry = false;
    const args = blk: {
        var filtered: std.ArrayList([]const u8) = .empty;
        errdefer filtered.deinit(allocator);
        try filtered.append(allocator, raw_args[0]);
        var i: usize = 1;
        while (i < raw_args.len) : (i += 1) {
            const a = raw_args[i];
            if (std.mem.startsWith(u8, a, "--config-file=")) {
                explicit_config = a["--config-file=".len..];
                continue;
            } else if (std.mem.eql(u8, a, "--config-file") and i + 1 < raw_args.len) {
                explicit_config = raw_args[i + 1];
                i += 1;
                continue;
            } else if (std.mem.eql(u8, a, "--no-telemetry")) {
                // #528 item 12: --no-telemetry is documented as a global option,
                // so strip it before positional parsing (like --config-file)
                // instead of only honoring it after `mcp`. Telemetry.init also
                // honors CODEDB_NO_TELEMETRY.
                no_telemetry = true;
                continue;
            } else if (std.mem.eql(u8, a, "--allow-temp")) {
                // #538: opt-in to indexing temp roots (/tmp, /private/tmp). Sets
                // CODEDB_ALLOW_TEMP so root_policy.tempIndexingAllowed (and any
                // daemon this CLI spawns) honors it; the env var alone works too —
                // the flag just flips it. Lets SWE-bench/CI harnesses index /tmp.
                cio.posixSetenv("CODEDB_ALLOW_TEMP", "1");
                continue;
            }
            try filtered.append(allocator, a);
        }
        break :blk try filtered.toOwnedSlice(allocator);
    };
    defer allocator.free(args);

    var root: []const u8 = undefined;
    var cmd: []const u8 = undefined;
    var cmd_args_start: usize = undefined;
    var root_is_explicit: bool = false;

    const parsed = parsePositional(args);
    if (parsed.usage_exit) {
        printUsage(&out, s);
        out.exitWithFlush(1);
    }
    root = parsed.root;
    cmd = parsed.cmd;
    cmd_args_start = parsed.cmd_args_start;
    root_is_explicit = parsed.root_is_explicit;

    // CODEDB_ROOT env var lets clients (Claude Code MCP, shell scripts) pin
    // the root without needing to pass a positional arg. Treated as explicit
    // so the MCP scan kicks off at startup instead of waiting for a roots
    // handshake — without this, every fresh `codedb mcp` call against a
    // client that doesn't send roots/list_changed sees an empty index.
    if (std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".")) {
        if (cio.posixGetenv("CODEDB_ROOT")) |env_root| {
            if (env_root.len > 0) {
                root = env_root;
                root_is_explicit = true;
            }
        }
    }

    // #502: when `codedb mcp` is launched from a subdirectory of a git
    // repo (e.g. opencode/Zed spawning from the buffer's directory), walk
    // up to the repo root so the user gets the whole project indexed
    // rather than the subdir they happen to be in. Skipped if the env var
    // or a positional arg already pinned the root, or if no .git is found.
    var git_root_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".") and !root_is_explicit) {
        if (findGitRoot(io, &git_root_buf)) |git_root| {
            root = git_root;
            root_is_explicit = true;
        }
    }

    // MCP stdio reserves stdout for JSON-RPC — route status/error output to
    // stderr so startup/failure paths don't corrupt the protocol stream.
    // See #304.
    if (std.mem.eql(u8, cmd, "mcp")) {
        out.file = cio.File.stderr();
        // #502: reject unknown flags after `mcp` (e.g. `codedb mcp --snapshot`
        // was previously consumed silently and the server started anyway,
        // hiding the typo). Whitelist via isValidMcpFlag.
        // Handle `--help` here too — parsePositional only catches it when it
        // sits immediately after `mcp`; combos like `mcp --no-telemetry --help`
        // need their own bypass.
        for (args[cmd_args_start..]) |a| {
            if (a.len == 0 or a[0] != '-') continue;
            if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "help")) {
                out.file = stdout;
                printUsage(&out, s);
                return;
            }
            if (!isValidMcpFlag(a)) {
                out.p("{s}\xe2\x9c\x97{s} unknown flag for {s}mcp{s}: {s}{s}{s}\n  valid: {s}--no-telemetry{s}, {s}--help{s}, {s}--config-file=<path>{s}\n", .{
                    s.red,  s.reset,
                    s.bold, s.reset,
                    s.bold, a,      s.reset,
                    s.bold, s.reset,
                    s.bold, s.reset,
                    s.bold, s.reset,
                });
                out.exitWithFlush(1);
            }
        }
    }

    // Handle --version early (no root needed)
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        out.p("codedb {s}\n", .{release_info.semver});
        return;
    }

    // Handle --help early (no root needed)
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printUsage(&out, s);
        return;
    }

    // Handle update command early — before root resolution so it works from anywhere.
    if (std.mem.eql(u8, cmd, "update")) {
        update_mod.run(io, stdout, s, allocator);
        return;
    }

    // Handle nuke command early — before root resolution so it works from anywhere
    if (std.mem.eql(u8, cmd, "nuke")) {
        nuke_mod.run(io, stdout, s, allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, "${workspaceFolder}")) {
        root = ".";
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = resolveRoot(io, root, &root_buf) catch {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, root, s.reset,
        });
        out.exitWithFlush(1);
    };
    // For `codedb mcp` from cwd, always go through deferred mode: we need the
    // initialize handshake first to know whether the client is going to send
    // workspace roots. If we eager-load here we'd race the client's roots/list
    // reply and silently ignore an editor's actual workspace path. The trigger
    // path is fast (snapshot load happens in-process when the trigger fires),
    // and clients that don't advertise the roots capability fire the trigger
    // immediately on notifications/initialized — see handleSession.
    const mcp_deferred_root = std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, ".") and !root_is_explicit;
    if (!mcp_deferred_root and !root_policy.isIndexableRoot(abs_root)) {
        out.p("{s}\xe2\x9c\x97{s} refusing to index temporary root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, abs_root, s.reset,
        });
        out.exitWithFlush(1);
    }

    // Thin-client fast path: if a warm daemon (codedb <root> serve / mcp) is
    // already listening for this project, proxy read-only query commands to it
    // and skip the per-invocation snapshot reload entirely. Falls through to
    // the cold in-process path below when no daemon answers. Must run before
    // getDataDir + the load section so the proxied call pays none of that cost.
    if (cliIsQueryCmd(cmd)) {
        if (cliTryProxy(io, allocator, abs_root, args, use_color)) |code| {
            out.flush();
            std.process.exit(code);
        }
        // No daemon answered. Auto-spawn a detached cli-daemon so the NEXT call
        // is warm; this call still falls through to the cold path below. The
        // daemon is the SAME binary (resolved via the self-exe path) run as
        // `codedb <abs_root> cli-daemon`, with stdio redirected to /dev/null and
        // no waitpid (fire-and-forget). Gated by CODEDB_NO_CLI_DAEMON and skipped
        // for an empty root. cli-daemon is not a query command, so the spawned
        // process won't recurse into this path.
        if (cio.posixGetenv("CODEDB_NO_CLI_DAEMON") == null and abs_root.len > 0) {
            if (std.process.executablePathAlloc(io, allocator)) |self_exe| {
                defer allocator.free(self_exe);
                const daemon_argv = [_][]const u8{ self_exe, abs_root, "cli-daemon" };
                cio.spawnDetached(allocator, &daemon_argv);
            } else |_| {}
        }
    }

    const data_dir = try getDataDir(io, allocator, abs_root);
    defer allocator.free(data_dir);

    // Load user config (.codedbrc). Resolution: --config-file=<path>, then
    // $CWD/.codedbrc, then <binary_dir>/.codedbrc. Silently falls back to
    // defaults if nothing is found. See #101, #102.
    const cfg = loadUserConfig(io, allocator, explicit_config) catch |err| blk: {
        std.log.warn("config load failed ({s}) — using defaults", .{@errorName(err)});
        break :blk Config.default;
    };

    var store = Store.init(allocator);
    store.max_versions = cfg.max_versions;
    defer store.deinit();

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(io, data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator, cfg.max_cached);

    const rerank_trace_path: ?[]u8 = if (cfg.rerank_trace)
        (std.fmt.allocPrint(allocator, "{s}/rerank-traces.jsonl", .{data_dir}) catch null)
    else
        null;
    defer if (rerank_trace_path) |p| allocator.free(p);
    if (rerank_trace_path) |p| explorer.rerank_trace_path = p;

    explorer.setRoot(io, root);
    defer explorer.deinit();

    // Per-project frequency table for sparse n-gram boundary selection.
    // Loaded from disk (if present) before the initial scan so pairWeight
    // uses project-specific frequencies.  Freed and reset at process exit.
    var freq_table_heap: ?*[256][256]u16 = null;
    defer if (freq_table_heap) |ft| {
        index_mod.resetFrequencyTable();
        allocator.destroy(ft);
    };

    if (!std.mem.eql(u8, cmd, "mcp")) {
        const git_head = git_mod.getGitHead(abs_root, allocator) catch null;

        const snapshot_t0 = cio.nanoTimestamp();
        const snapshot_loaded = loadBestSnapshot(io, &explorer, &store, abs_root, data_dir, git_head, allocator);
        const snapshot_elapsed = cio.nanoTimestamp() - snapshot_t0;

        // The word index powers codedb_word and BM25 ranked search. It must be
        // built + persisted for `index` (so a later `mcp` can load it) and for
        // `mcp` itself (so ranked/NL search works in the running server).
        const needs_word_index = std.mem.eql(u8, cmd, "word") or std.mem.eql(u8, cmd, "bench-engine") or
            std.mem.eql(u8, cmd, "index") or std.mem.eql(u8, cmd, "mcp");
        if (snapshot_loaded) {
            if (std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "bench-engine") or std.mem.eql(u8, cmd, "cli-daemon")) {
                // The cli-daemon serves proxied `search`/`callers`; warm the
                // trigram up front (mmap-backed — cheap RSS) so it doesn't scan
                // all content per query. Matches the serve/mcp daemon.
                loadTrigramFromDiskIfPresent(io, &explorer, data_dir, allocator);
            }
            if (std.mem.eql(u8, cmd, "word") or std.mem.eql(u8, cmd, "bench-engine") or std.mem.eql(u8, cmd, "cli-daemon")) {
                loadWordIndexFromDiskIfPresent(io, &explorer, data_dir, git_head, allocator);
                // word/bench-engine want a guaranteed-ready index — rebuild + persist
                // if the on-disk one was missing/stale. The cli-daemon stays lean: if
                // the mmap load missed, let the first `word`/`context` query rebuild
                // lazily rather than hold a heap rebuild at startup.
                if (!std.mem.eql(u8, cmd, "cli-daemon") and !explorer.wordIndexIsComplete()) {
                    explorer.rebuildWordIndex() catch {};
                    persistWordIndexToDisk(io, &explorer, data_dir, git_head);
                }
            }
            if (cio.posixGetenv("CODEDB_QUIET") == null) {
                var dur_buf: [64]u8 = undefined;
                out.p("{s}\xe2\x9c\x93{s} {s}loaded snapshot{s}  {s}{d} files{s}  {s}{s}{s}\n", .{
                    s.green,                                        s.reset,
                    s.bold,                                         s.reset,
                    s.dim,                                          explorer.outlines.count(),
                    s.reset,                                        sty.durationColor(s, snapshot_elapsed),
                    sty.formatDuration(&dur_buf, snapshot_elapsed), s.reset,
                });
            }
        } else {
            const disk_hdr = TrigramIndex.readDiskHeader(io, data_dir, allocator) catch null;
            const heads_match = blk2: {
                const a = git_head orelse break :blk2 false;
                const b = (disk_hdr orelse break :blk2 false).git_head orelse break :blk2 false;
                break :blk2 std.mem.eql(u8, &a, &b);
            };
            // Load per-project freq table before scan so pairWeight is project-aware.
            if (index_mod.readFrequencyTable(io, data_dir, allocator) catch null) |ft| {
                freq_table_heap = ft;
                index_mod.setFrequencyTable(ft);
            }

            const t_scan = cio.nanoTimestamp();
            // Use page_allocator for word index during scan — freed pages
            // return to OS immediately instead of c_allocator retention.
            explorer.mu.lock();
            explorer.word_index.deinit();
            explorer.word_index = WordIndex.init(std.heap.c_allocator);
            explorer.mu.unlock();
            // Skip file_words tracking during bulk scan — saves ~450MB.
            // Only needed for removeFile (incremental re-indexing), not initial scan.
            explorer.word_index.skip_file_words = true;
            if (!needs_word_index) explorer.word_index.enabled = false;
            // For search: single-pass scan + trigram build (no re-reading files).
            // For other commands: outline-only scan, trigrams from disk or rebuild.
            const is_search = std.mem.eql(u8, cmd, "search");
            if (is_search and !heads_match) {
                const tmp_tri = try watcher.initialScanWithTrigrams(io, &store, &explorer, root, allocator, std.heap.c_allocator, true);
                if (tmp_tri) |tri| {
                    tri.writeToDisk(io, data_dir, git_head) catch {};
                    tri.deinit();
                    std.heap.c_allocator.destroy(tri);
                    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.mu.lock();
                        explorer.trigram_index.deinit();
                        explorer.trigram_index = .{ .mmap = loaded };
                        explorer.mu.unlock();
                    }
                }
            } else {
                try watcher.initialScan(io, &store, &explorer, root, allocator, true);
            }
            const scan_elapsed = cio.nanoTimestamp() - t_scan;
            var dur_buf: [64]u8 = undefined;
            out.p("{s}\xe2\x9c\x93{s} {s}indexed{s}  {s}{s}{s}\n", .{
                s.green,                            s.reset,
                s.dim,                              s.reset,
                sty.durationColor(s, scan_elapsed), sty.formatDuration(&dur_buf, scan_elapsed),
                s.reset,
            });

            var release_contents_after_cache = false;
            if (heads_match) {
                // Verify file count then load trigram from disk via mmap
                const current_count = @as(u32, @intCast(explorer.outlines.count()));
                if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
                    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.mu.lock();
                        explorer.trigram_index.deinit();
                        explorer.trigram_index = .{ .mmap = loaded };
                        explorer.mu.unlock();
                    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
                        explorer.mu.lock();
                        explorer.trigram_index.deinit();
                        explorer.trigram_index = .{ .heap = loaded };
                        explorer.mu.unlock();
                    } else {
                        explorer.rebuildTrigrams() catch {};
                        explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
                            std.log.warn("could not persist trigram index: {}", .{err});
                        };
                    }
                } else {
                    explorer.rebuildTrigrams() catch {};
                    explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                    };
                }
            } else if (!is_search) {
                // Cold run (non-search): persist word index, then build trigrams
                // in parallel from the content already cached in Explorer.contents
                // — no second pass over the filesystem.
                if (needs_word_index) {
                    persistWordIndexToDisk(io, &explorer, data_dir, git_head);
                    explorer.markWordIndexAsComplete();
                }
                const cpu_count = std.Thread.getCpuCount() catch 1;
                const tri_workers: usize = @min(@as(usize, @intCast(cpu_count)), 8);
                const tmp_tri = watcher.buildTrigramsFromCache(&explorer.contents, allocator, std.heap.c_allocator, tri_workers) catch null;
                if (tmp_tri) |tri| {
                    defer {
                        tri.deinit();
                        std.heap.c_allocator.destroy(tri);
                    }
                    tri.writeToDisk(io, data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                    };
                }
                // Load trigrams as mmap (zero heap cost); then we can safely
                // release file contents since mmap serves future searches.
                if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                    explorer.mu.lock();
                    explorer.trigram_index.deinit();
                    explorer.trigram_index = .{ .mmap = loaded };
                    explorer.mu.unlock();
                }
                release_contents_after_cache = true;
            }

            // If no freq table was loaded, build one from indexed content and
            // persist for next run.  Streams file-by-file — zero extra memory.
            if (freq_table_heap == null) {
                if (explorer.contents.count() > 0) {
                    const ft = index_mod.buildFrequencyTableFromMap(&explorer.contents);
                    index_mod.writeFrequencyTable(io, &ft, data_dir) catch |err| {
                        std.log.warn("could not persist frequency table: {}", .{err});
                    };
                }
            }

            if (!std.mem.eql(u8, cmd, "snapshot")) {
                // Pre-build call-graph centrality so it's persisted in the snapshot
                // and a later load restores it instead of paying the lazy
                // first-query rebuild. Same env gate as the search path.
                if (cio.posixGetenv("CODEDB_NO_CENTRALITY") == null) {
                    explorer.buildCallCentrality(allocator);
                }
                snapshot_mod.writeProjectCacheSnapshot(io, &explorer, abs_root, allocator) catch |err| {
                    std.log.warn("could not persist project-cache snapshot: {}", .{err});
                };
            }
            if (release_contents_after_cache) {
                explorer.releaseContents();
            }
        } // end else (no snapshot)
    }
    if (std.mem.eql(u8, cmd, "tree") or std.mem.eql(u8, cmd, "outline") or std.mem.eql(u8, cmd, "find") or
        std.mem.eql(u8, cmd, "search") or std.mem.eql(u8, cmd, "word") or std.mem.eql(u8, cmd, "read") or
        std.mem.eql(u8, cmd, "hot") or std.mem.eql(u8, cmd, "symbol") or std.mem.eql(u8, cmd, "callers") or
        std.mem.eql(u8, cmd, "callpath") or std.mem.eql(u8, cmd, "deps") or std.mem.eql(u8, cmd, "glob") or
        std.mem.eql(u8, cmd, "ls") or std.mem.eql(u8, cmd, "file") or std.mem.eql(u8, cmd, "context") or
        std.mem.eql(u8, cmd, "status"))
    {
        const code = runQuery(io, allocator, &explorer, &store, abs_root, cmd, args, cmd_args_start, &out, s);
        out.flush();
        std.process.exit(code);
    } else if (std.mem.eql(u8, cmd, "bench-engine")) {
        // Engine-vs-engine microbenchmark — bypasses MCP envelope, response
        // formatting, and most of the CLI display path. Lets us compare
        // codedb's pure engine cost against SQLite FTS5 head-to-head.
        //
        // Usage: codedb [root] bench-engine <op> <query> [iters]
        //   op: word | word-fmt | search | search-fmt
        //   iters defaults to 100.
        //
        // Output: a single line of JSON to stdout, e.g.
        //   {"op":"word","query":"useState","iters":100,"hits":50,"p50_ns":1234,"p99_ns":5678}
        if (args.len < cmd_args_start + 2) {
            out.p("usage: codedb [root] bench-engine <word|word-fmt|search|search-fmt|search-paths> <query> [iters]\n", .{});
            std.process.exit(1);
        }
        const op = args[cmd_args_start];
        const query = args[cmd_args_start + 1];
        const iters: usize = if (args.len > cmd_args_start + 2)
            std.fmt.parseInt(usize, args[cmd_args_start + 2], 10) catch 100
        else
            100;

        // Warm once (mirrors how the Python bench harness measures latency).
        if (std.mem.eql(u8, op, "word") or std.mem.eql(u8, op, "word-fmt")) {
            const warm = explorer.searchWord(query, allocator) catch &[_]index_mod.WordHit{};
            allocator.free(warm);
        } else if (std.mem.eql(u8, op, "search") or std.mem.eql(u8, op, "search-fmt")) {
            const warm = explorer.searchContent(query, allocator, 50) catch &[_]explore_mod.SearchResult{};
            defer {
                for (warm) |r| { allocator.free(r.path); allocator.free(r.line_text); }
                allocator.free(warm);
            }
        }

        var times = allocator.alloc(u64, iters) catch {
            out.p("error: alloc failed\n", .{});
            std.process.exit(1);
        };
        defer allocator.free(times);

        var hits_seen: usize = 0;

        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const t0 = cio.nanoTimestamp();

            if (std.mem.eql(u8, op, "word")) {
                const hits = explorer.searchWord(query, allocator) catch &[_]index_mod.WordHit{};
                hits_seen = hits.len;
                allocator.free(hits);
            } else if (std.mem.eql(u8, op, "word-fmt")) {
                const hits = explorer.searchWord(query, allocator) catch &[_]index_mod.WordHit{};
                hits_seen = hits.len;
                defer allocator.free(hits);
                // Mimic the MCP handleWord format loop into a scratch buffer
                // so we measure the same work the agent pays for.
                var scratch: std.ArrayList(u8) = .empty;
                defer scratch.deinit(allocator);
                scratch.ensureTotalCapacity(allocator, 256 + hits.len * 80) catch {};
                const w = cio.listWriter(&scratch, allocator);
                w.print("{d} hits for '{s}':\n", .{ hits.len, query }) catch {};
                explorer.mu.lockShared();
                for (hits) |h| {
                    w.print("  {s}:{d}\n", .{ explorer.word_index.hitPath(h), h.line_num }) catch {};
                }
                explorer.mu.unlockShared();
            } else if (std.mem.eql(u8, op, "search")) {
                const r = explorer.searchContent(query, allocator, 50) catch &[_]explore_mod.SearchResult{};
                hits_seen = r.len;
                for (r) |item| { allocator.free(item.path); allocator.free(item.line_text); }
                allocator.free(r);
            } else if (std.mem.eql(u8, op, "search-fmt")) {
                const r = explorer.searchContent(query, allocator, 50) catch &[_]explore_mod.SearchResult{};
                hits_seen = r.len;
                defer {
                    for (r) |item| { allocator.free(item.path); allocator.free(item.line_text); }
                    allocator.free(r);
                }
                var scratch: std.ArrayList(u8) = .empty;
                defer scratch.deinit(allocator);
                scratch.ensureTotalCapacity(allocator, 256 + r.len * 120) catch {};
                const w = cio.listWriter(&scratch, allocator);
                w.print("{d} results for '{s}':\n", .{ r.len, query }) catch {};
                for (r) |item| {
                    w.print("  {s}:{d}: {s}\n", .{ item.path, item.line_num, item.line_text }) catch {};
                }
            } else if (std.mem.eql(u8, op, "search-paths")) {
                // Matched-shape benchmark op: produce a deduped path set
                // for the query — same shape FTS5 `SELECT path` returns,
                // letting us compare engines on identical work.
                const r = explorer.searchContent(query, allocator, 50) catch &[_]explore_mod.SearchResult{};
                hits_seen = r.len;
                defer {
                    for (r) |item| { allocator.free(item.path); allocator.free(item.line_text); }
                    allocator.free(r);
                }
                var seen = std.StringHashMap(void).init(allocator);
                defer seen.deinit();
                var scratch: std.ArrayList(u8) = .empty;
                defer scratch.deinit(allocator);
                scratch.ensureTotalCapacity(allocator, 256 + r.len * 80) catch {};
                const w = cio.listWriter(&scratch, allocator);
                for (r) |item| {
                    const gop = seen.getOrPut(item.path) catch continue;
                    if (gop.found_existing) continue;
                    w.print("{s}\n", .{item.path}) catch {};
                }
            } else {
                out.p("error: unknown op '{s}' — use one of word|word-fmt|search|search-fmt|search-paths\n", .{op});
                std.process.exit(1);
            }

            const elapsed_i128: i128 = cio.nanoTimestamp() - t0;
            times[i] = if (elapsed_i128 > 0) @intCast(elapsed_i128) else 0;
        }

        std.mem.sort(u64, times, {}, std.sort.asc(u64));
        const p50 = times[iters / 2];
        const p99 = times[@min(iters - 1, (iters * 99) / 100)];
        const p_min = times[0];
        out.p(
            "{{\"op\":\"{s}\",\"query\":\"{s}\",\"iters\":{d},\"hits\":{d},\"min_ns\":{d},\"p50_ns\":{d},\"p99_ns\":{d}}}\n",
            .{ op, query, iters, hits_seen, p_min, p50, p99 },
        );
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        const t0 = cio.nanoTimestamp();
        const output = if (args.len > cmd_args_start) args[cmd_args_start] else blk: {
            break :blk std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch "codedb.snapshot";
        };
        defer if (args.len <= cmd_args_start and output.len > "codedb.snapshot".len) allocator.free(output);
        snapshot_mod.writeSnapshotDual(io, &explorer, abs_root, output, allocator) catch |err| {
            out.p("{s}\xe2\x9c\x97{s} snapshot failed: {}\n", .{ s.red, s.reset, err });
            std.process.exit(1);
        };
        const git_head = git_mod.getGitHead(abs_root, allocator) catch null;
        loadWordIndexFromDiskIfPresent(io, &explorer, data_dir, git_head, allocator);
        if (!wordIndexMatchesOutlines(&explorer)) {
            persistWordIndexFromSource(io, &explorer, abs_root, data_dir, git_head, allocator) catch |err| {
                out.p("{s}\xe2\x9c\x97{s} word index persist failed: {}\n", .{ s.red, s.reset, err });
                std.process.exit(1);
            };
        } else {
            persistWordIndexToDisk(io, &explorer, data_dir, git_head);
        }
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        out.p("{s}\xe2\x9c\x93{s} {s}snapshot{s}  {s}{s}{s}  {s}{d} files{s}  {s}{s}{s}\n", .{
            s.green,                       s.reset,
            s.bold,                        s.reset,
            s.cyan,                        output,
            s.reset,                       s.dim,
            explorer.outlines.count(),     s.reset,
            sty.durationColor(s, elapsed), sty.formatDuration(&dur_buf, elapsed),
            s.reset,
        });
    } else if (std.mem.eql(u8, cmd, "cli-daemon")) {
        // Hidden command: a lightweight warm daemon spawned by a cold CLI query
        // so the NEXT query is fast. It is `serve` minus the TCP server, agent
        // registry, and reaper — just the warm explorer/store (loaded by the
        // section above), an incremental watcher to keep the index fresh, the
        // per-project CLI socket listener, and a time-based idle watchdog that
        // exits the process once the socket has been quiet for a while. We do
        // NOT auto-spawn `serve` here because two `serve` daemons would fight
        // over the fixed TCP port; the CLI socket is per-project and conflict-free.

        // Detach from the controlling terminal so we outlive the spawning CLI
        // and never touch its stdio. (spawnDetached already pointed 0/1/2 at
        // /dev/null; this also starts a fresh session.)
        cio.detachFromTerminal();

        const idle_ms: i64 = blk: {
            const raw = cio.posixGetenv("CODEDB_CLI_DAEMON_IDLE_MS") orelse break :blk 5 * 60 * 1000;
            break :blk std.fmt.parseInt(i64, raw, 10) catch (5 * 60 * 1000);
        };

        var shutdown = std.atomic.Value(bool).init(false);
        defer shutdown.store(true, .release);
        // The load section above already loaded/scanned the index, so the
        // watcher starts in the "scan done" state and only does incremental
        // upkeep from here.
        var scan_already_done = std.atomic.Value(bool).init(true);

        // Grace period: treat startup as activity so a freshly-spawned daemon
        // gets the full idle window before the watchdog can fire.
        var last_activity_ms = std.atomic.Value(i64).init(cio.milliTimestamp());

        const queue = try allocator.create(watcher.EventQueue);
        defer allocator.destroy(queue);
        queue.* = watcher.EventQueue{};
        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, &store, &explorer, queue, root, &shutdown, &scan_already_done });
        watch_thread.detach();

        std.log.info("cli-daemon: {d} files indexed, idle_timeout={d}ms", .{ store.currentSeq(), idle_ms });

        // CLI socket listener. Pass the REAL shutdown flag: if another daemon
        // already owns the socket (we lost the bind race), cliDaemonListen sets
        // shutdown and the watchdog below returns at once, so the redundant
        // daemon exits instead of lingering idle.
        if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, &explorer, &store, abs_root, &last_activity_ms, &shutdown })) |cli_t| {
            cli_t.detach();
        } else |err| {
            std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
            return;
        }

        // Block here until idle (or a bind-race shutdown). On return the process
        // exits immediately — std.process.exit reclaims everything and avoids
        // racing the detached listener thread against freed explorer/store.
        const idle_exit = cliIdleWatchdog(&shutdown, &last_activity_ms, idle_ms);
        shutdown.store(true, .release);
        // If WE owned the socket (exited on idle, not a bind-race loss), unlink
        // it on the way out. The listener thread's own `defer unlink` never runs
        // because std.process.exit kills it mid-accept; do it here so we don't
        // leave a stale node behind. On a bind-race loss the socket belongs to
        // the winning daemon, so idle_exit is false and we leave it alone.
        if (idle_exit) {
            var sock_buf: [128]u8 = undefined;
            if (cliSocketPath(&sock_buf, abs_root)) |sock_path| {
                var sock_z_buf: [128]u8 = undefined;
                if (std.fmt.bufPrintZ(&sock_z_buf, "{s}", .{sock_path})) |sock_z| {
                    _ = std.c.unlink(sock_z.ptr);
                } else |_| {}
            }
        }
        out.flush();
        std.process.exit(0);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const port: u16 = blk: {
            const raw = cio.posixGetenv("CODEDB_PORT") orelse break :blk 6767;
            break :blk std.fmt.parseInt(u16, raw, 10) catch 6767;
        };
        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        var shutdown = std.atomic.Value(bool).init(false);
        defer shutdown.store(true, .release);
        var scan_already_done = std.atomic.Value(bool).init(true);

        const queue = try allocator.create(watcher.EventQueue);
        defer allocator.destroy(queue);
        queue.* = watcher.EventQueue{};
        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, &store, &explorer, queue, root, &shutdown, &scan_already_done });
        defer watch_thread.join();

        const reap_thread = try std.Thread.spawn(.{}, reapLoop, .{ &agents, &shutdown });
        defer reap_thread.join();

        std.log.info("codedb: {d} files indexed, listening on :{d}", .{ store.currentSeq(), port });

        // Thin-CLI proxy listener: lets `codedb <root> <query>` invocations
        // reuse this warm explorer/store over a per-project Unix socket instead
        // of paying a cold snapshot reload. Detached so it never blocks serve().
        // serve has no idle timeout: it passes throwaway activity/shutdown
        // atomics that nobody watches (a bind failure just disables the proxy).
        // These outlive the detached thread because server.serve() below blocks
        // on this same stack frame for the whole process lifetime.
        var cli_activity = std.atomic.Value(i64).init(cio.milliTimestamp());
        var cli_listener_dead = std.atomic.Value(bool).init(false);
        if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, &explorer, &store, abs_root, &cli_activity, &cli_listener_dead })) |cli_t| {
            cli_t.detach();
        } else |err| {
            std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
        }
        try server.serve(io, allocator, &store, &agents, &explorer, queue, port);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        // Background auto-update check (no-op when CODEDB_NO_AUTO_UPDATE is set
        // or when the last check was within the last 24h). Detached thread, so
        // this doesn't block server startup.
        update_mod.maybeAutoUpdate(io, allocator);

        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        const root_from_cwd = mcp_deferred_root;

        saveProjectInfo(io, allocator, data_dir, abs_root) catch {};

        // Set up query tracking WAL
        const query_log = std.fmt.allocPrint(allocator, "{s}/queries.log", .{data_dir}) catch null;
        if (query_log) |ql| mcp_server.setQueryLogPath(ql);

        const startup_t0 = cio.milliTimestamp();
        // --no-telemetry is stripped globally above (#528 item 12); honor it
        // here alongside CODEDB_NO_TELEMETRY (checked inside Telemetry.init).
        const telemetry_disabled = no_telemetry;

        var telem = telemetry.Telemetry.init(io, data_dir, allocator, telemetry_disabled);
        defer telem.deinit();
        telem.startSyncThread();
        telem.recordSessionStart();

        var shutdown = std.atomic.Value(bool).init(false);

        const queue = try allocator.create(watcher.EventQueue);
        defer allocator.destroy(queue);
        queue.* = watcher.EventQueue{};

        var scan_thread: ?std.Thread = null;
        var watch_thread: std.Thread = undefined;

        var deferred: mcp_server.DeferredScan = undefined;
        var maybe_deferred: ?*mcp_server.DeferredScan = null;

        if (root_from_cwd) {
            deferred = .{
                .io = io,
                .allocator = allocator,
                .store = &store,
                .explorer = &explorer,
                .scan_done = try allocator.create(std.atomic.Value(bool)),
                .shutdown = &shutdown,
                .telem = &telem,
                .queue = queue,
                .startup_t0 = startup_t0,
                .fallback_cwd = abs_root,
                .triggerFn = triggerScanFromRoots,
            };
            deferred.scan_done.* = std.atomic.Value(bool).init(false);
            maybe_deferred = &deferred;
            mcp_server.setScanState(.loading_snapshot);
            watch_thread = try std.Thread.spawn(.{}, watcherDeferredLoop, .{&deferred});
        } else {
            const git_head = git_mod.getGitHead(abs_root, allocator) catch null;
            mcp_server.setScanState(.loading_snapshot);
            const snapshot_loaded = loadBestSnapshot(io, &explorer, &store, abs_root, data_dir, git_head, allocator);
            var scan_done = std.atomic.Value(bool).init(snapshot_loaded);
            if (!snapshot_loaded) {
                mcp_server.setScanState(.walking);
                scan_thread = try std.Thread.spawn(.{}, scanBg, .{ io, &store, &explorer, root, allocator, &scan_done, &shutdown, data_dir, abs_root, &telem, startup_t0 });
            } else {
                const startup_time_ms: u64 = @intCast(@max(cio.milliTimestamp() - startup_t0, 0));
                loadTrigramFromDiskIfPresent(io, &explorer, data_dir, allocator);
                telem.recordCodebaseStats(&explorer, startup_time_ms);
                compactMcpReadyMemory(io, &explorer, data_dir, git_head, allocator);
                mcp_server.setScanState(.ready);
            }
            watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, &store, &explorer, queue, root, &shutdown, &scan_done });
        }

        const idle_thread = try std.Thread.spawn(.{}, idleWatchdog, .{&shutdown});

        std.log.info("codedb mcp: root={s} files={d} data={s} scan={s}", .{ abs_root, store.currentSeq(), data_dir, mcp_server.getScanState().name() });

        // Thin-CLI proxy listener (same as the serve branch): serve read-only
        // query commands from this warm explorer/store over a per-project Unix
        // socket so plain `codedb <root> <query>` calls skip a cold reload.
        // Detached so it never blocks mcp_server.run(). Like serve, mcp has no
        // idle timeout — throwaway activity/shutdown atomics that nobody watches.
        // They outlive the detached thread because mcp_server.run() below blocks
        // on this same stack frame for the whole process lifetime.
        var cli_activity = std.atomic.Value(i64).init(cio.milliTimestamp());
        var cli_listener_dead = std.atomic.Value(bool).init(false);
        if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, &explorer, &store, abs_root, &cli_activity, &cli_listener_dead })) |cli_t| {
            cli_t.detach();
        } else |err| {
            std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
        }
        mcp_server.run(io, allocator, &store, &explorer, &agents, abs_root, cfg.max_cached, &telem, maybe_deferred, &shutdown);

        shutdown.store(true, .release);
        if (scan_thread) |st| st.join();
        if (maybe_deferred) |d| {
            if (d.scan_thread) |st| st.join();
        }
        watch_thread.join();
        idle_thread.join();
    } else {
        out.p("{s}\xe2\x9c\x97{s} unknown command: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, cmd, s.reset,
        });
        std.process.exit(1);
    }
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
                return .{ .root = a2, .cmd = "mcp", .cmd_args_start = 3, .root_is_explicit = true };
            }
        }
        return .{ .root = ".", .cmd = a1, .cmd_args_start = 2, .root_is_explicit = false };
    }
    if (args.len >= 3) {
        return .{ .root = a1, .cmd = args[2], .cmd_args_start = 3, .root_is_explicit = true };
    }
    return .{ .root = "", .cmd = "", .cmd_args_start = 0, .root_is_explicit = false, .usage_exit = true };
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
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "read", "hot", "status", "symbol", "callers", "callpath", "deps", "glob", "ls", "file", "context", "snapshot", "serve", "mcp", "update", "nuke", "cli-daemon" };
    for (commands) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

fn resolveRoot(io: std.Io, root: []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    const sub = if (std.mem.eql(u8, root, ".")) "." else root;
    const n = std.Io.Dir.cwd().realPathFile(io, sub, buf) catch return error.ResolveFailed;
    return buf[0..n];
}

/// Resolve config from the (already-extracted) --config-file path, falling
/// back to $CWD/.codedbrc and then <binary_dir>/.codedbrc. Returns the
/// default Config if nothing is found. Addresses #101, #102.
fn loadUserConfig(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) !Config {
    const self_exe: ?[:0]u8 = std.process.executablePathAlloc(io, alloc) catch null;
    defer if (self_exe) |p| alloc.free(p);
    const bin_dir: ?[]const u8 = if (self_exe) |p| blk: {
        const last_slash = std.mem.lastIndexOfScalar(u8, p, '/') orelse break :blk null;
        break :blk p[0..last_slash];
    } else null;

    return try Config.loadDefault(io, alloc, explicit, bin_dir);
}

fn loadSnapshotIfHeadMatches(
    io: std.Io,
    snapshot_path: []const u8,
    explorer: *Explorer,
    store: *Store,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const snap_head = snapshot_mod.readSnapshotGitHead(io, snapshot_path) orelse {
        // No git HEAD in snapshot (non-git project or legacy snapshot) — load
        // only when the current project also has no git HEAD.
        if (current_git_head != null) return false;
        return snapshot_mod.loadSnapshot(io, snapshot_path, explorer, store, allocator);
    };
    const cur_head = current_git_head orelse return false;
    if (!std.mem.eql(u8, &snap_head, &cur_head)) return false;
    return snapshot_mod.loadSnapshot(io, snapshot_path, explorer, store, allocator);
}

fn loadBestSnapshot(
    io: std.Io,
    explorer: *Explorer,
    store: *Store,
    abs_root: []const u8,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const root_snapshot = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch null;
    defer if (root_snapshot) |p| allocator.free(p);
    const first_snapshot = root_snapshot orelse "codedb.snapshot";
    if (loadSnapshotIfHeadMatches(io, first_snapshot, explorer, store, current_git_head, allocator)) {
        return true;
    }

    const central_snapshot = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{data_dir}) catch return false;
    defer allocator.free(central_snapshot);
    return loadSnapshotIfHeadMatches(io, central_snapshot, explorer, store, current_git_head, allocator);
}

fn getDataDir(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, abs_root);
    const home_env = cio.posixGetenv("HOME") orelse {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{abs_root});
    };
    const home = try allocator.dupe(u8, home_env);
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash });
    std.Io.Dir.cwd().createDirPath(io, dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    return dir;
}

fn loadTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, data_dir: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const already_loaded = explorer.trigram_index.fileCount() > 0;
    explorer.mu.unlockShared();
    if (already_loaded) return;

    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
    }
}

fn loadWordIndexFromDiskIfPresent(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const header = WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse {
        explorer.disableWordIndexDiskLoad();
        return;
    };

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    const heads_match = blk: {
        if (current_git_head == null and header.git_head == null) break :blk true;
        if (current_git_head == null or header.git_head == null) break :blk false;
        break :blk std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
    };
    if (!heads_match) {
        explorer.disableWordIndexDiskLoad();
        return;
    }

    if (WordIndex.mmapFromDisk(io, data_dir, allocator) orelse WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn wordIndexDiskMatches(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) bool {
    const header = WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse return false;

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) return false;

    if (current_git_head == null and header.git_head == null) return true;
    if (current_git_head == null or header.git_head == null) return false;
    return std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
}

fn compactMcpReadyMemory(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    explorer.mu.lockShared();
    const file_count = explorer.outlines.count();
    explorer.mu.unlockShared();

    if (file_count <= 1000 and cio.posixGetenv("CODEDB_LOW_MEMORY") == null) return;

    const can_release_contents =
        explorer.wordIndexIsComplete() or
        (explorer.wordIndexCanLoadFromDisk() and wordIndexDiskMatches(io, explorer, data_dir, current_git_head, allocator));

    if (can_release_contents) {
        explorer.releaseContents();
    }
    explorer.releaseSecondaryIndexes();

    // Shrink index allocations to reclaim ArrayList over-allocation.
    if (explorer.trigram_index.asHeap()) |heap| heap.shrinkPostingLists();
    explorer.word_index.shrinkAllocations();
}

fn persistWordIndexToDisk(io: std.Io, explorer: *Explorer, data_dir: []const u8, git_head: ?[40]u8) void {
    const generation = explorer.wordIndexGenerationToPersist() orelse return;

    explorer.mu.lockShared();
    explorer.word_index.writeToDisk(io, data_dir, git_head) catch |err| {
        explorer.mu.unlockShared();
        std.log.warn("could not persist word index: {}", .{err});
        return;
    };
    explorer.mu.unlockShared();
    explorer.markWordIndexPersisted(generation);
}

fn wordIndexMatchesOutlines(explorer: *Explorer) bool {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    return explorer.word_index_complete and
        explorer.word_index.id_to_path.items.len == explorer.outlines.count();
}

fn persistWordIndexFromSource(
    io: std.Io,
    explorer: *Explorer,
    root_path: []const u8,
    data_dir: []const u8,
    git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(allocator);

    {
        explorer.mu.lockShared();
        defer explorer.mu.unlockShared();
        try paths.ensureTotalCapacity(allocator, explorer.outlines.count());
        var path_iter = explorer.outlines.keyIterator();
        while (path_iter.next()) |path_ptr| {
            paths.appendAssumeCapacity(path_ptr.*);
        }
    }

    var root_dir = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root_dir.close(io);

    var word_index = WordIndex.init(allocator);
    defer word_index.deinit();
    word_index.skip_file_words = true;

    for (paths.items) |path| {
        const content = root_dir.readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024)) catch continue;
        errdefer allocator.free(content);
        try word_index.indexFile(path, content);
        allocator.free(content);
    }

    if (word_index.id_to_path.items.len == 0 and paths.items.len != 0) return error.NoWordIndexData;
    try word_index.writeToDisk(io, data_dir, git_head);
}

fn saveProjectInfo(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) !void {
    const info_path = try std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir});
    defer allocator.free(info_path);
    const file = try std.Io.Dir.cwd().createFile(io, info_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, abs_root);
}

fn printUsage(out: *Out, s: sty.Style) void {
    out.p(
        \\
        \\{s}codedb{s}  code intelligence server
        \\
        \\  {s}usage:{s} codedb [root] <command> [args...]
        \\
        \\  {s}commands:{s}
        \\    {s}tree{s}                      show file tree with language and symbol counts
        \\    {s}outline{s} {s}<path>{s}         list all symbols in a file
        \\    {s}find{s}    {s}<name>{s}         find where a symbol is defined
        \\    {s}search{s}  {s}<query>{s}        full-text search (trigram, case-insensitive)
        \\    {s}word{s}    {s}<identifier>{s}   exact word lookup via inverted index
        \\    {s}read{s}    {s}<path>{s}         file contents (optionally -L FROM-TO, --compact)
        \\
    , .{
        s.bold, s.reset,
        s.dim,  s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
    out.p(
        \\    {s}hot{s}                       recently modified files
        \\    {s}status{s}                    index size, store seq, and index state
        \\    {s}symbol{s}  <name>            where a symbol is defined (all matches; --body for source)
        \\    {s}callers{s}  <name>           every call site of a symbol
        \\    {s}deps{s}  <path>              dependency graph (--depends-on, --transitive, --max-depth N)
        \\    {s}glob{s}  <pattern>           match indexed paths by glob
        \\    {s}ls{s}  [path]                list a directory's indexed children
        \\    {s}file{s}  <fuzzy-name>        fuzzy file-name search
        \\    {s}context{s}  <task...>        task-shaped orientation bundle
        \\    {s}serve{s}                     HTTP daemon on :7719
        \\    {s}mcp{s}                       JSON-RPC/MCP server over stdio
        \\    {s}update{s}                    self-update to the latest verified release
        \\    {s}nuke{s}                      uninstall codedb, clear caches, and deregister integrations
        \\
    , .{
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
    });
    out.p(
        \\  {s}options:{s}
        \\    {s}--no-telemetry{s}             disable usage telemetry (or set CODEDB_NO_TELEMETRY)
        \\    {s}--config-file <path>{s}       load config overrides from <path> (default: ./.codedbrc)
        \\
        \\  If root is omitted, uses current working directory.
        \\  Data stored in {s}~/.codedb/projects/<hash>/{s}
        \\
        \\  exit codes: 0 = success (incl. a valid query that finds nothing),
        \\              1 = usage error, invalid input, or operational failure.
        \\
        \\
    , .{
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
}

fn reapLoop(agents: *AgentRegistry, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        // Sleep in 1s increments for responsive shutdown (was 5s)
        for (0..5) |_| {
            if (shutdown.load(.acquire)) return;
            cio.sleepMs(1000);
        }
        agents.reapStale(30_000);
    }
}

fn scanBg(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, scan_done: *std.atomic.Value(bool), shutdown: *std.atomic.Value(bool), data_dir: []const u8, abs_root: []const u8, telem: *telemetry.Telemetry, startup_t0: i64) void {
    const git_head = git_mod.getGitHead(root, allocator) catch null;
    const disk_hdr = TrigramIndex.readDiskHeader(io, data_dir, allocator) catch null;
    const heads_match = blk: {
        const a = git_head orelse break :blk false;
        const b = (disk_hdr orelse break :blk false).git_head orelse break :blk false;
        break :blk std.mem.eql(u8, &a, &b);
    };

    mcp_server.setScanState(.walking);
    watcher.initialScan(io, store, explorer, root, allocator, heads_match) catch |err| {
        std.log.warn("background scan failed: {}", .{err});
    };

    // Phase gate: bail if shutting down after initial scan
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }
    mcp_server.setScanState(.indexing);
    persistWordIndexToDisk(io, explorer, data_dir, git_head);

    if (heads_match) {
        const current_count = @as(u32, @intCast(explorer.outlines.count()));
        if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
            if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                explorer.mu.lock();
                explorer.trigram_index.deinit();
                explorer.trigram_index = .{ .mmap = loaded };
                explorer.mu.unlock();
                scan_done.store(true, .release);
                mcp_server.setScanState(.ready);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));
                const snap_path_1 = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch null;
                defer if (snap_path_1) |p| allocator.free(p);
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, snap_path_1 orelse "codedb.snapshot", allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
                    explorer.releaseContents();
                    explorer.releaseSecondaryIndexes();
                }
                // Shrink index allocations to reclaim ArrayList over-allocation
                if (explorer.trigram_index.asHeap()) |heap| heap.shrinkPostingLists();
                explorer.word_index.shrinkAllocations();
                return;
            }
            if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
                explorer.mu.lock();
                explorer.trigram_index.deinit();
                explorer.trigram_index = .{ .heap = loaded };
                explorer.mu.unlock();
                scan_done.store(true, .release);
                mcp_server.setScanState(.ready);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));
                const snap_path_2 = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch null;
                defer if (snap_path_2) |p| allocator.free(p);
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, snap_path_2 orelse "codedb.snapshot", allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
                    explorer.releaseContents();
                    explorer.releaseSecondaryIndexes();
                }
                return;
            }
        }
        explorer.rebuildTrigrams() catch {};
    }

    // Phase gate: bail before disk write if shutting down
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }

    explorer.trigram_index.writeToDisk(io, data_dir, git_head) catch |err| {
        std.log.warn("could not persist trigram index: {}", .{err});
    };

    // Phase gate: bail before mmap swap if shutting down
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        mcp_server.setScanState(.ready);
        return;
    }

    // Compact: swap heap index for mmap — zero RSS, data lives in OS page cache.
    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
        explorer.mu.unlock();
    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
        explorer.mu.unlock();
    }

    scan_done.store(true, .release);
    mcp_server.setScanState(.ready);

    if (shutdown.load(.acquire)) return;

    telem.recordCodebaseStats(explorer, @intCast(@max(cio.milliTimestamp() - startup_t0, 0)));

    const snap_path_3 = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch null;
    defer if (snap_path_3) |p| allocator.free(p);
    snapshot_mod.writeSnapshotDual(io, explorer, abs_root, snap_path_3 orelse "codedb.snapshot", allocator) catch |err| {
        std.log.warn("could not auto-write snapshot: {}", .{err});
    };
    const file_count = explorer.outlines.count();
    if (file_count > 1000 or cio.posixGetenv("CODEDB_LOW_MEMORY") != null) {
        explorer.releaseContents();
        explorer.releaseSecondaryIndexes();
    }
}
fn triggerScanFromRoots(ctx: *mcp_server.DeferredScan, abs_root: []const u8) void {
    const data_dir = getDataDir(ctx.io, ctx.allocator, abs_root) catch {
        ctx.triggered.store(false, .release);
        return;
    };
    defer ctx.allocator.free(data_dir);
    const git_head = git_mod.getGitHead(abs_root, ctx.allocator) catch null;
    mcp_server.setScanState(.loading_snapshot);
    const snapshot_loaded = loadBestSnapshot(ctx.io, ctx.explorer, ctx.store, abs_root, data_dir, git_head, ctx.allocator);
    ctx.resolved_root = abs_root;
    ctx.explorer.setRoot(ctx.io, abs_root);
    ctx.scan_done.store(snapshot_loaded, .release);
    if (!snapshot_loaded) {
        mcp_server.setScanState(.walking);
        const scan_thread = std.Thread.spawn(.{}, scanBg, .{ ctx.io, ctx.store, ctx.explorer, abs_root, ctx.allocator, ctx.scan_done, ctx.shutdown, data_dir, abs_root, ctx.telem, ctx.startup_t0 }) catch return;
        ctx.scan_thread = scan_thread;
    } else {
        const startup_time_ms: u64 = @intCast(@max(cio.milliTimestamp() - ctx.startup_t0, 0));
        loadTrigramFromDiskIfPresent(ctx.io, ctx.explorer, data_dir, ctx.allocator);
        ctx.telem.recordCodebaseStats(ctx.explorer, startup_time_ms);
        compactMcpReadyMemory(ctx.io, ctx.explorer, data_dir, git_head, ctx.allocator);
        mcp_server.setScanState(.ready);
    }
}

fn watcherDeferredLoop(ctx: *mcp_server.DeferredScan) void {
    const t0 = cio.milliTimestamp();
    const fallback_after_ms: i64 = 3000;
    // #502: after the 3s fallback fires, give the cwd-policy check a
    // little more time, then unblock. Previously, when fallback_cwd was
    // non-indexable (e.g. `/`, `/tmp`, or any other path that fails
    // isIndexableRoot), `triggerDeferredScanWithFallback` would return
    // false, leave `triggered=false`, leave `scan_done=false`, and this
    // loop would poll forever — tool calls saw scan=loading_snapshot
    // indefinitely and the server hung from the user's POV.
    const give_up_after_ms: i64 = 13000;
    var fallback_attempted = false;
    while (!ctx.scan_done.load(.acquire) and !ctx.shutdown.load(.acquire)) {
        cio.sleepMs(50);
        const elapsed = cio.milliTimestamp() - t0;
        if (!fallback_attempted and elapsed >= fallback_after_ms) {
            fallback_attempted = true;
            // Client never sent indexable roots — fall back to cwd so the
            // server doesn't sit in loading_snapshot forever.
            const empty_roots: []const mcp_server.Root = &.{};
            _ = mcp_server.triggerDeferredScanWithFallback(ctx, empty_roots, ctx.fallback_cwd);
        }
        if (fallback_attempted and elapsed >= give_up_after_ms and !ctx.triggered.load(.acquire)) {
            std.log.warn("codedb mcp: no indexable root found after {d}ms — exiting deferred mode with empty index. set CODEDB_ROOT or pass `codedb <path> mcp` to fix.", .{give_up_after_ms});
            ctx.scan_done.store(true, .release);
            return;
        }
    }
    if (ctx.shutdown.load(.acquire)) return;
    // If we exited the loop without ever triggering a scan (give-up path),
    // resolved_root is empty — skip incrementalLoop so we don't crash.
    if (!ctx.triggered.load(.acquire)) return;
    watcher.incrementalLoop(ctx.io, ctx.store, ctx.explorer, ctx.queue, ctx.resolved_root, ctx.shutdown, ctx.scan_done);
}

fn idleWatchdog(shutdown: *std.atomic.Value(bool)) void {
    const mcp = @import("mcp.zig");
    const stdin = cio.File.stdin();
    while (!shutdown.load(.acquire)) {
        // Quick liveness check: poll stdin for POLLHUP (client disconnected).
        // Do not close a healthy stdio transport just because it is idle:
        // MCP stdio sessions are not resumable, and hosts such as Codex do
        // not necessarily respawn a dead server inside an existing chat.
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const poll_result = std.posix.poll(&poll_fds, 0) catch 0;
        if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.HUP) != 0) {
            std.log.info("stdin closed (client disconnected), exiting", .{});
            _ = std.c.close(stdin.handle);
            shutdown.store(true, .release);
            return;
        }

        cio.sleepMs(mcp.dead_client_poll_ms);
    }
}

/// Time-based idle watchdog for the `cli-daemon` background process. Unlike
/// `idleWatchdog` (which watches stdin for POLLHUP on an MCP stdio transport),
/// this exits the daemon after `idle_ms` elapse with no CLI socket activity.
/// "Activity" is the last_activity_ms timestamp bumped by cliDaemonListen at
/// the start of each accepted connection. It also returns promptly if
/// `shutdown` is set externally — e.g. cliDaemonListen sets it when this daemon
/// lost the bind race to an already-running daemon, so the redundant daemon
/// tears down immediately instead of idling for the full timeout.
///
/// Returns true when it exited because the idle window elapsed (this daemon
/// owned the socket and the caller should clean it up), or false when it
/// returned because `shutdown` was already set by someone else (a bind-race
/// loss — the socket belongs to the winning daemon, so the caller must NOT
/// unlink it).
fn cliIdleWatchdog(shutdown: *std.atomic.Value(bool), last_activity_ms: *std.atomic.Value(i64), idle_ms: i64) bool {
    while (!shutdown.load(.acquire)) {
        // Poll in 250ms slices so a bind-race shutdown (set by cliDaemonListen)
        // is honored quickly rather than after a full idle window.
        cio.sleepMs(250);
        if (shutdown.load(.acquire)) return false;
        const idle = cio.milliTimestamp() - last_activity_ms.load(.acquire);
        if (idle >= idle_ms) {
            std.log.info("cli-daemon: idle {d}ms >= {d}ms — exiting", .{ idle, idle_ms });
            shutdown.store(true, .release);
            return true;
        }
    }
    return false;
}
