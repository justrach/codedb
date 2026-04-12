const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const Store = @import("store.zig").Store;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const Explorer = @import("explore.zig").Explorer;
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

/// Thin wrapper: format + write to a File via allocator.
const Out = struct {
    file: std.fs.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

/// The real entry point.  In Debug builds, Zig may merge all command-branch
/// stack frames into one producing a frame that overflows the default OS stack,
/// so we trampoline through a thread with an explicit 64 MB stack.
/// In optimised builds the merged frame is ~190 KB, so 8 MB is ample and
/// avoids triggering Rosetta 2's 64 MB stack allocation bug on x86_64-macos.
pub fn main() !void {
    const stack_size: usize = if (builtin.mode == .Debug) 64 * 1024 * 1024 else 8 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, mainInner, .{});
    thread.join();
}

fn mainInner() void {
    mainImpl() catch |err| {
        std.debug.print("fatal: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn mainImpl() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = std.fs.File.stdout();
    const use_color = stdout.isTty();
    const s = sty.style(use_color);
    const out = Out{ .file = stdout, .alloc = allocator };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var root: []const u8 = undefined;
    var cmd: []const u8 = undefined;
    var cmd_args_start: usize = undefined;

    if (args.len >= 2 and std.mem.eql(u8, args[1], "--mcp")) {
        root = ".";
        cmd = "mcp";
        cmd_args_start = 2;
    } else if (args.len >= 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        root = ".";
        cmd = "--version";
        cmd_args_start = 2;
    } else if (args.len >= 2 and
        (std.mem.eql(u8, args[1], "--help") or
            std.mem.eql(u8, args[1], "-h") or
            std.mem.eql(u8, args[1], "help")))
    {
        root = ".";
        cmd = args[1];
        cmd_args_start = 2;
    } else if (args.len < 2) {
        printUsage(out, s);
        std.process.exit(1);
    } else if (isCommand(args[1])) {
        root = ".";
        cmd = args[1];
        cmd_args_start = 2;
    } else if (args.len >= 3) {
        root = args[1];
        cmd = args[2];
        cmd_args_start = 3;
    } else {
        printUsage(out, s);
        std.process.exit(1);
    }

    // Handle --version early (no root needed)
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        out.p("codedb {s}\n", .{release_info.semver});
        return;
    }

    // Handle --help early (no root needed)
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printUsage(out, s);
        return;
    }

    // Handle update command early — before root resolution so it works from anywhere.
    if (std.mem.eql(u8, cmd, "update")) {
        update_mod.run(stdout, s, allocator);
        return;
    }

    // Handle nuke command early — before root resolution so it works from anywhere
    if (std.mem.eql(u8, cmd, "nuke")) {
        nuke_mod.run(stdout, s, allocator);
        return;
    }

    if (std.mem.eql(u8, cmd, "mcp") and std.mem.eql(u8, root, "${workspaceFolder}")) {
        root = ".";
    }

    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const abs_root = resolveRoot(root, &root_buf) catch {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, root, s.reset,
        });
        std.process.exit(1);
    };
    if (!root_policy.isIndexableRoot(abs_root)) {
        out.p("{s}\xe2\x9c\x97{s} refusing to index temporary root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, abs_root, s.reset,
        });
        std.process.exit(1);
    }

    const data_dir = try getDataDir(allocator, abs_root);
    defer allocator.free(data_dir);

    var store = Store.init(allocator);
    defer store.deinit();

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator);
    explorer.setRoot(root);
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

        // Try loading from codedb.snapshot if it exists and git HEAD matches.
        const snapshot_path = "codedb.snapshot";
        const snapshot_t0 = std.time.nanoTimestamp();
        const snapshot_loaded = blk: {
            const snap_head = snapshot_mod.readSnapshotGitHead(snapshot_path) orelse {
                // No git HEAD in snapshot (non-git project or missing) — load if current project also has no git
                if (git_head != null) break :blk false;
                break :blk snapshot_mod.loadSnapshot(snapshot_path, &explorer, &store, allocator);
            };
            const cur_head = git_head orelse break :blk false;
            if (!std.mem.eql(u8, &snap_head, &cur_head)) break :blk false;
            break :blk snapshot_mod.loadSnapshot(snapshot_path, &explorer, &store, allocator);
        };
        const snapshot_elapsed = std.time.nanoTimestamp() - snapshot_t0;

        if (snapshot_loaded) {
            if (std.mem.eql(u8, cmd, "search")) {
                loadTrigramFromDiskIfPresent(&explorer, data_dir, allocator);
            } else if (std.mem.eql(u8, cmd, "word")) {
                loadWordIndexFromDiskIfPresent(&explorer, data_dir, git_head, allocator);
            }
            var dur_buf: [64]u8 = undefined;
            out.p("{s}\xe2\x9c\x93{s} {s}loaded snapshot{s}  {s}{d} files{s}  {s}{s}{s}\n", .{
                s.green,                                        s.reset,
                s.bold,                                         s.reset,
                s.dim,                                          explorer.outlines.count(),
                s.reset,                                        sty.durationColor(s, snapshot_elapsed),
                sty.formatDuration(&dur_buf, snapshot_elapsed), s.reset,
            });
        } else {
            const disk_hdr = TrigramIndex.readDiskHeader(data_dir, allocator) catch null;
            const heads_match = blk2: {
                const a = git_head orelse break :blk2 false;
                const b = (disk_hdr orelse break :blk2 false).git_head orelse break :blk2 false;
                break :blk2 std.mem.eql(u8, &a, &b);
            };
            // Load per-project freq table before scan so pairWeight is project-aware.
            if (index_mod.readFrequencyTable(data_dir, allocator) catch null) |ft| {
                freq_table_heap = ft;
                index_mod.setFrequencyTable(ft);
            }

            const t_scan = std.time.nanoTimestamp();
            try watcher.initialScan(&store, &explorer, root, allocator, heads_match);
            const scan_elapsed = std.time.nanoTimestamp() - t_scan;
            var dur_buf: [64]u8 = undefined;
            out.p("{s}\xe2\x9c\x93{s} {s}indexed{s}  {s}{s}{s}\n", .{
                s.green,                            s.reset,
                s.dim,                              s.reset,
                sty.durationColor(s, scan_elapsed), sty.formatDuration(&dur_buf, scan_elapsed),
                s.reset,
            });

            if (heads_match) {
                // Verify file count then load trigram from disk via mmap
                const current_count = @as(u32, @intCast(explorer.outlines.count()));
                if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
                    if (MmapTrigramIndex.initFromDisk(data_dir, allocator)) |loaded| {
                        explorer.mu.lock();
                        explorer.trigram_index.deinit();
                        explorer.trigram_index = .{ .mmap = loaded };
                        explorer.mu.unlock();
                    } else if (TrigramIndex.readFromDisk(data_dir, allocator)) |loaded| {
                        explorer.mu.lock();
                        explorer.trigram_index.deinit();
                        explorer.trigram_index = .{ .heap = loaded };
                        explorer.mu.unlock();
                    } else {
                        explorer.rebuildTrigrams() catch {};
                        explorer.trigram_index.writeToDisk(data_dir, git_head) catch |err| {
                            std.log.warn("could not persist trigram index: {}", .{err});
                        };
                    }
                } else {
                    explorer.rebuildTrigrams() catch {};
                    explorer.trigram_index.writeToDisk(data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                    };
                }
            } else {
                // Persist trigram index to disk for fast future startup
                explorer.trigram_index.writeToDisk(data_dir, git_head) catch |err| {
                    std.log.warn("could not persist trigram index: {}", .{err});
                };
            }

            // If no freq table was loaded, build one from indexed content and
            // persist for next run.  Streams file-by-file — zero extra memory.
            if (freq_table_heap == null) {
                if (explorer.contents.count() > 0) {
                    const ft = index_mod.buildFrequencyTableFromMap(&explorer.contents);
                    index_mod.writeFrequencyTable(&ft, data_dir) catch |err| {
                        std.log.warn("could not persist frequency table: {}", .{err});
                    };
                }
            }
        } // end else (no snapshot)
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        const t0 = std.time.nanoTimestamp();
        const tree = try explorer.getTree(allocator, use_color);
        defer allocator.free(tree);
        const elapsed = std.time.nanoTimestamp() - t0;
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
            std.process.exit(1);
        };
        const t0 = std.time.nanoTimestamp();
        var outline = explorer.getOutline(path, allocator) catch {
            out.p("{s}\xe2\x9c\x97{s} {s}{s}{s} \xe2\x80\x94 failed to load outline\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            std.process.exit(1);
        } orelse {
            out.p("{s}\xe2\x9c\x97{s} not indexed: {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, path, s.reset,
            });
            return;
        };
        defer outline.deinit();
        const elapsed = std.time.nanoTimestamp() - t0;
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
            std.process.exit(1);
        };
        const t0 = std.time.nanoTimestamp();
        if (try explorer.findSymbol(name, allocator)) |r| {
            defer {
                allocator.free(r.path);
                allocator.free(r.symbol.name);
                if (r.symbol.detail) |d| allocator.free(d);
            }
            const elapsed = std.time.nanoTimestamp() - t0;
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
        var use_regex = false;
        var query_arg_start = cmd_args_start;
        if (args.len > cmd_args_start and std.mem.eql(u8, args[cmd_args_start], "--regex")) {
            use_regex = true;
            query_arg_start = cmd_args_start + 1;
        }
        const query = if (args.len > query_arg_start) args[query_arg_start] else {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] search [--regex] {s}<query>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            std.process.exit(1);
        };
        const t0 = std.time.nanoTimestamp();
        const results = if (use_regex)
            try explorer.searchContentRegex(query, allocator, 50)
        else
            try explorer.searchContent(query, allocator, 50);
        defer {
            for (results) |r| {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
            allocator.free(results);
        }
        const elapsed = std.time.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        if (results.len == 0) {
            out.p("{s}\xe2\x9c\x97{s} no results for {s}\"{s}\"{s}\n", .{
                s.yellow, s.reset, s.bold, query, s.reset,
            });
        } else {
            const mode_label: []const u8 = if (use_regex) " (regex)" else "";
            out.p("{s}\xe2\x9c\x93{s} {s}{d}{s} results for {s}\"{s}\"{s}{s}  {s}{s}{s}\n", .{
                s.green,                               s.reset,
                s.bold,                                results.len,
                s.reset,                               s.bold,
                query,                                 s.reset,
                mode_label,                            sty.durationColor(s, elapsed),
                sty.formatDuration(&dur_buf, elapsed), s.reset,
            });
            for (results) |r| {
                out.p("  {s}{s}{s}:{s}{d}{s}  {s}\n", .{
                    s.cyan,      r.path,     s.reset,
                    s.dim,       r.line_num, s.reset,
                    r.line_text,
                });
            }
        }
    } else if (std.mem.eql(u8, cmd, "word")) {
        const word = if (args.len > cmd_args_start) args[cmd_args_start] else {
            out.p("{s}\xe2\x9c\x97{s} usage: codedb [root] word {s}<identifier>{s}\n", .{
                s.red, s.reset, s.cyan, s.reset,
            });
            std.process.exit(1);
        };
        const t0 = std.time.nanoTimestamp();
        const hits = try explorer.searchWord(word, allocator);
        defer allocator.free(hits);
        const elapsed = std.time.nanoTimestamp() - t0;
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
            for (hits) |h| {
                out.p("  {s}{s}{s}:{s}{d}{s}\n", .{
                    s.cyan, h.path,     s.reset,
                    s.dim,  h.line_num, s.reset,
                });
            }
        }
    } else if (std.mem.eql(u8, cmd, "hot")) {
        const t0 = std.time.nanoTimestamp();
        const hot = try explorer.getHotFiles(&store, allocator, 10);
        defer {
            for (hot) |path| allocator.free(path);
            allocator.free(hot);
        }
        const elapsed = std.time.nanoTimestamp() - t0;
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
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        const t0 = std.time.nanoTimestamp();
        const output = if (args.len > cmd_args_start) args[cmd_args_start] else "codedb.snapshot";
        snapshot_mod.writeSnapshotDual(&explorer, abs_root, output, allocator) catch |err| {
            out.p("{s}\xe2\x9c\x97{s} snapshot failed: {}\n", .{ s.red, s.reset, err });
            std.process.exit(1);
        };
        const git_head = git_mod.getGitHead(abs_root, allocator) catch null;
        loadWordIndexFromDiskIfPresent(&explorer, data_dir, git_head, allocator);
        if (!explorer.wordIndexIsComplete()) {
            explorer.rebuildWordIndex() catch |err| {
                out.p("{s}\xe2\x9c\x97{s} word index rebuild failed: {}\n", .{ s.red, s.reset, err });
                std.process.exit(1);
            };
        }
        persistWordIndexToDisk(&explorer, data_dir, git_head);
        const elapsed = std.time.nanoTimestamp() - t0;
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
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const port: u16 = 7719;
        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        var shutdown = std.atomic.Value(bool).init(false);
        defer shutdown.store(true, .release);
        var scan_already_done = std.atomic.Value(bool).init(true);

        const queue = try allocator.create(watcher.EventQueue);
        defer allocator.destroy(queue);
        queue.* = watcher.EventQueue{};
        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ &store, &explorer, queue, root, &shutdown, &scan_already_done });
        defer watch_thread.join();

        const reap_thread = try std.Thread.spawn(.{}, reapLoop, .{ &agents, &shutdown });
        defer reap_thread.join();

        std.log.info("codedb: {d} files indexed, listening on :{d}", .{ store.currentSeq(), port });
        try server.serve(allocator, &store, &agents, &explorer, queue, port);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        var agents = AgentRegistry.init(allocator);
        defer agents.deinit();
        _ = try agents.register("__filesystem__");

        saveProjectInfo(allocator, data_dir, abs_root) catch {};

        // Set up query tracking WAL
        const query_log = std.fmt.allocPrint(allocator, "{s}/queries.log", .{data_dir}) catch null;
        if (query_log) |ql| mcp_server.setQueryLogPath(ql);

        const git_head = git_mod.getGitHead(abs_root, allocator) catch null;
        const startup_t0 = std.time.milliTimestamp();
        const snapshot_loaded = blk: {
            const snap_head = snapshot_mod.readSnapshotGitHead("codedb.snapshot") orelse {
                if (git_head != null) break :blk false;
                break :blk snapshot_mod.loadSnapshot("codedb.snapshot", &explorer, &store, allocator);
            };
            const cur_head = git_head orelse break :blk false;
            if (!std.mem.eql(u8, &snap_head, &cur_head)) break :blk false;
            break :blk snapshot_mod.loadSnapshot("codedb.snapshot", &explorer, &store, allocator);
        };
        var telemetry_disabled = false;
        for (args[cmd_args_start..]) |arg| {
            if (std.mem.eql(u8, arg, "--no-telemetry")) {
                telemetry_disabled = true;
                break;
            }
        }

        var telem = telemetry.Telemetry.init(data_dir, allocator, telemetry_disabled);
        defer telem.deinit();
        telem.recordSessionStart();

        var shutdown = std.atomic.Value(bool).init(false);
        var scan_done = std.atomic.Value(bool).init(snapshot_loaded);

        const queue = try allocator.create(watcher.EventQueue);
        defer allocator.destroy(queue);
        queue.* = watcher.EventQueue{};
        var scan_thread: ?std.Thread = null;
        if (!snapshot_loaded) {
            scan_thread = try std.Thread.spawn(.{}, scanBg, .{ &store, &explorer, root, allocator, &scan_done, &shutdown, data_dir, abs_root, &telem, startup_t0 });
        } else {
            const startup_time_ms: u64 = @intCast(@max(std.time.milliTimestamp() - startup_t0, 0));
            loadTrigramFromDiskIfPresent(&explorer, data_dir, allocator);
            telem.recordCodebaseStats(&explorer, startup_time_ms);
        }

        const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ &store, &explorer, queue, root, &shutdown, &scan_done });
        const idle_thread = try std.Thread.spawn(.{}, idleWatchdog, .{&shutdown});

        std.log.info("codedb mcp: root={s} files={d} data={s}", .{ abs_root, store.currentSeq(), data_dir });

        mcp_server.run(allocator, &store, &explorer, &agents, abs_root, &telem);

        shutdown.store(true, .release);
        if (scan_thread) |st| st.join();
        watch_thread.join();
        idle_thread.join();
    } else {
        out.p("{s}\xe2\x9c\x97{s} unknown command: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, cmd, s.reset,
        });
        std.process.exit(1);
    }
}
fn isCommand(arg: []const u8) bool {
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "hot", "snapshot", "serve", "mcp", "update", "nuke" };
    for (commands) |c| {
        if (std.mem.eql(u8, arg, c)) return true;
    }
    return false;
}

fn resolveRoot(root: []const u8, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    if (std.mem.eql(u8, root, ".")) {
        return std.fs.cwd().realpath(".", buf) catch return error.ResolveFailed;
    }
    return std.fs.cwd().realpath(root, buf) catch return error.ResolveFailed;
}

fn getDataDir(allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, abs_root);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        return std.fmt.allocPrint(allocator, "{s}/.codedb", .{abs_root});
    };
    defer allocator.free(home);
    const dir = try std.fmt.allocPrint(allocator, "{s}/.codedb/projects/{x}", .{ home, hash });
    compat.makePath(std.fs.cwd(), dir) catch |err| {
        std.log.warn("could not create data dir {s}: {}", .{ dir, err });
    };
    return dir;
}

fn loadTrigramFromDiskIfPresent(explorer: *Explorer, data_dir: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const already_loaded = explorer.trigram_index.fileCount() > 0;
    explorer.mu.unlockShared();
    if (already_loaded) return;

    if (MmapTrigramIndex.initFromDisk(data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
    } else if (TrigramIndex.readFromDisk(data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        defer explorer.mu.unlock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
    }
}

fn loadWordIndexFromDiskIfPresent(
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    const header = WordIndex.readDiskHeader(data_dir, allocator) catch null orelse {
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

    if (WordIndex.readFromDisk(data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        explorer.disableWordIndexDiskLoad();
    }
}

fn persistWordIndexToDisk(explorer: *Explorer, data_dir: []const u8, git_head: ?[40]u8) void {
    const generation = explorer.wordIndexGenerationToPersist() orelse return;

    explorer.mu.lockShared();
    explorer.word_index.writeToDisk(data_dir, git_head) catch |err| {
        explorer.mu.unlockShared();
        std.log.warn("could not persist word index: {}", .{err});
        return;
    };
    explorer.mu.unlockShared();
    explorer.markWordIndexPersisted(generation);
}

fn saveProjectInfo(allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) !void {
    const info_path = try std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir});
    defer allocator.free(info_path);
    const file = try std.fs.cwd().createFile(info_path, .{});
    defer file.close();
    try file.writeAll(abs_root);
}

fn printUsage(out: Out, s: sty.Style) void {
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
    });
    out.p(
        \\    {s}hot{s}                       recently modified files
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
    });
    out.p(
        \\  {s}options:{s}
        \\    {s}--no-telemetry{s}             disable usage telemetry (or set CODEDB_NO_TELEMETRY)
        \\
        \\  If root is omitted, uses current working directory.
        \\  Data stored in {s}~/.codedb/projects/<hash>/{s}
        \\
        \\
    , .{
        s.dim,  s.reset,
        s.cyan, s.reset,
        s.dim,  s.reset,
    });
}

fn reapLoop(agents: *AgentRegistry, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        // Sleep in 1s increments for responsive shutdown (was 5s)
        for (0..5) |_| {
            if (shutdown.load(.acquire)) return;
            std.Thread.sleep(std.time.ns_per_s);
        }
        agents.reapStale(30_000);
    }
}

fn scanBg(store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, scan_done: *std.atomic.Value(bool), shutdown: *std.atomic.Value(bool), data_dir: []const u8, abs_root: []const u8, telem: *telemetry.Telemetry, startup_t0: i64) void {
    const git_head = git_mod.getGitHead(root, allocator) catch null;
    const disk_hdr = TrigramIndex.readDiskHeader(data_dir, allocator) catch null;
    const heads_match = blk: {
        const a = git_head orelse break :blk false;
        const b = (disk_hdr orelse break :blk false).git_head orelse break :blk false;
        break :blk std.mem.eql(u8, &a, &b);
    };

    watcher.initialScan(store, explorer, root, allocator, heads_match) catch |err| {
        std.log.warn("background scan failed: {}", .{err});
    };

    // Phase gate: bail if shutting down after initial scan
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        return;
    }
    persistWordIndexToDisk(explorer, data_dir, git_head);

    if (heads_match) {
        const current_count = @as(u32, @intCast(explorer.outlines.count()));
        if (disk_hdr != null and current_count == disk_hdr.?.file_count) {
            if (MmapTrigramIndex.initFromDisk(data_dir, allocator)) |loaded| {
                explorer.mu.lock();
                explorer.trigram_index.deinit();
                explorer.trigram_index = .{ .mmap = loaded };
                explorer.mu.unlock();
                scan_done.store(true, .release);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(std.time.milliTimestamp() - startup_t0, 0)));
                snapshot_mod.writeSnapshotDual(explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or std.process.hasEnvVarConstant("CODEDB_LOW_MEMORY")) {
                    explorer.releaseContents();
                    explorer.releaseSecondaryIndexes();
                }
                return;
            }
            if (TrigramIndex.readFromDisk(data_dir, allocator)) |loaded| {
                explorer.mu.lock();
                explorer.trigram_index.deinit();
                explorer.trigram_index = .{ .heap = loaded };
                explorer.mu.unlock();
                scan_done.store(true, .release);
                if (shutdown.load(.acquire)) return;
                telem.recordCodebaseStats(explorer, @intCast(@max(std.time.milliTimestamp() - startup_t0, 0)));
                snapshot_mod.writeSnapshotDual(explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
                    std.log.warn("could not auto-write snapshot: {}", .{err});
                };
                const fc = explorer.outlines.count();
                if (fc > 1000 or std.process.hasEnvVarConstant("CODEDB_LOW_MEMORY")) {
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
        return;
    }

    explorer.trigram_index.writeToDisk(data_dir, git_head) catch |err| {
        std.log.warn("could not persist trigram index: {}", .{err});
    };

    // Phase gate: bail before mmap swap if shutting down
    if (shutdown.load(.acquire)) {
        scan_done.store(true, .release);
        return;
    }

    // Compact: swap heap index for mmap — zero RSS, data lives in OS page cache.
    if (MmapTrigramIndex.initFromDisk(data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .mmap = loaded };
        explorer.mu.unlock();
    } else if (TrigramIndex.readFromDisk(data_dir, allocator)) |loaded| {
        explorer.mu.lock();
        explorer.trigram_index.deinit();
        explorer.trigram_index = .{ .heap = loaded };
        explorer.mu.unlock();
    }

    scan_done.store(true, .release);

    if (shutdown.load(.acquire)) return;

    telem.recordCodebaseStats(explorer, @intCast(@max(std.time.milliTimestamp() - startup_t0, 0)));

    snapshot_mod.writeSnapshotDual(explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
        std.log.warn("could not auto-write snapshot: {}", .{err});
    };
    const file_count = explorer.outlines.count();
    if (file_count > 1000 or std.process.hasEnvVarConstant("CODEDB_LOW_MEMORY")) {
        explorer.releaseContents();
        explorer.releaseSecondaryIndexes();
    }
}
fn idleWatchdog(shutdown: *std.atomic.Value(bool)) void {
    const mcp = @import("mcp.zig");
    while (!shutdown.load(.acquire)) {
        // Sleep in 1s increments for responsive shutdown
        for (0..10) |_| {
            if (shutdown.load(.acquire)) return;
            std.Thread.sleep(std.time.ns_per_s);
        }

        // Quick liveness check: poll stdin for POLLHUP (client disconnected)
        const stdin = std.fs.File.stdin();
        var poll_fds = [_]std.posix.pollfd{.{
            .fd = stdin.handle,
            .events = std.posix.POLL.IN | std.posix.POLL.HUP,
            .revents = 0,
        }};
        const poll_result = std.posix.poll(&poll_fds, 0) catch 0;
        if (poll_result > 0 and (poll_fds[0].revents & std.posix.POLL.HUP) != 0) {
            std.log.info("stdin closed (client disconnected), exiting", .{});
            stdin.close();
            shutdown.store(true, .release);
            return;
        }

        // Fallback: idle timeout
        const last = mcp.last_activity.load(.acquire);
        if (last == 0) continue;
        const now = std.time.milliTimestamp();
        if (now - last > mcp.idle_timeout_ms) {
            std.log.info("idle for {d}s, exiting", .{@divTrunc(now - last, 1000)});
            stdin.close();
            shutdown.store(true, .release);
            return;
        }
    }
}
