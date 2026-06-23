//! Read-only query command dispatch (tree/outline/find/search/word/read/hot/
//! status, plus a bridge to the MCP nav handlers). Extracted from main.zig so
//! the same rendering code runs both on the cold CLI path and inside the warm
//! daemon (writing to a socket sink) — see cli_proxy.zig.
const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore_mod = @import("explore.zig");
const watcher = @import("watcher.zig");
const mcp_server = @import("mcp.zig");
const telemetry = @import("telemetry.zig");
const release_info = @import("release_info.zig");
const Out = @import("out.zig").Out;
const cli_args = @import("cli_args.zig");
const parseSearchArgs = cli_args.parseSearchArgs;
const parseLineRange = cli_args.parseLineRange;
const hasExtraCliArgs = cli_args.hasExtraCliArgs;

/// Read-only query command dispatch, extracted from mainImpl so the same
/// rendering code can run inside the warm daemon (writing to a socket)
/// without exiting the daemon process. Returns a u8 exit code; the caller
/// is responsible for flushing `out`. Covers: tree, outline, find, search,
/// word, read, hot. Unknown commands return 1.
pub fn runQuery(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, store: *Store, root: []const u8, cmd: []const u8, args: []const []const u8, cmd_args_start: usize, out: *Out, s: sty.Style) u8 {
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
            explorer.searchContentAuto(query, allocator, sa.max_results) catch return 1;
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
                        s.cyan, r.path,     s.reset,
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
                    s.green,                               s.reset,
                    s.bold,                                path,
                    s.reset,                               s.langColor(@tagName(lang)),
                    @tagName(lang),                        s.reset,
                    start,                                 sty.durationColor(s, elapsed),
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
        if (mcp_server.runCliTool(io, allocator, explorer, store, root, cmd, args, cmd_args_start, &nav)) |code| {
            out.p("{s}", .{nav.items});
            return code;
        }
        return 1;
    }
    return 0;
}
