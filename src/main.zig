const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
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
    file: cio.File,
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
pub fn main(init: std.process.Init.Minimal) !void {
    cio.setProcessArgs(init.args.vector);
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
    // Use c_allocator (libc malloc) — better page reclamation than GPA
    const allocator = std.heap.c_allocator;

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

    const args = try cio.argsAlloc(allocator);
    defer cio.argsFree(allocator, args);

    var root: []const u8 = undefined;
    var cmd: []const u8 = undefined;
    var cmd_args_start: usize = undefined;
    var root_is_explicit: bool = false;

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
        root_is_explicit = true;
    } else {
        printUsage(out, s);
        std.process.exit(1);
    }

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

    // MCP stdio reserves stdout for JSON-RPC — route status/error output to
    // stderr so startup/failure paths don't corrupt the protocol stream.
    // See #304.
    if (std.mem.eql(u8, cmd, "mcp")) {
        out.file = cio.File.stderr();
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
        std.process.exit(1);
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
        std.process.exit(1);
    }

    const data_dir = try getDataDir(io, allocator, abs_root);
    defer allocator.free(data_dir);

    var store = Store.init(allocator);
    defer store.deinit();

    const data_log_path = try std.fmt.allocPrint(allocator, "{s}/data.log", .{data_dir});
    defer allocator.free(data_log_path);
    store.openDataLog(io, data_log_path) catch |err| {
        std.log.warn("could not open data log at {s}: {}", .{ data_log_path, err });
    };

    var explorer = Explorer.init(allocator);
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

        const needs_word_index = std.mem.eql(u8, cmd, "word");
        if (snapshot_loaded) {
            if (std.mem.eql(u8, cmd, "search")) {
                loadTrigramFromDiskIfPresent(io, &explorer, data_dir, allocator);
            } else if (std.mem.eql(u8, cmd, "word")) {
                loadWordIndexFromDiskIfPresent(io, &explorer, data_dir, git_head, allocator);
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
                snapshot_mod.writeProjectCacheSnapshot(io, &explorer, abs_root, allocator) catch |err| {
                    std.log.warn("could not persist project-cache snapshot: {}", .{err});
                };
            }
            if (release_contents_after_cache) {
                explorer.releaseContents();
            }
        } // end else (no snapshot)
    }

    if (std.mem.eql(u8, cmd, "tree")) {
        const t0 = cio.nanoTimestamp();
        const tree = try explorer.getTree(allocator, use_color);
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
            std.process.exit(1);
        };
        const t0 = cio.nanoTimestamp();
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
            std.process.exit(1);
        };
        const t0 = cio.nanoTimestamp();
        if (try explorer.findSymbol(name, allocator)) |r| {
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
        const t0 = cio.nanoTimestamp();
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
        const elapsed = cio.nanoTimestamp() - t0;
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
        const t0 = cio.nanoTimestamp();
        const hits = try explorer.searchWord(word, allocator);
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
    } else if (std.mem.eql(u8, cmd, "hot")) {
        const t0 = cio.nanoTimestamp();
        const hot = try explorer.getHotFiles(&store, allocator, 10);
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
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        const t0 = cio.nanoTimestamp();
        const output = if (args.len > cmd_args_start) args[cmd_args_start] else "codedb.snapshot";
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
        var telemetry_disabled = false;
        for (args[cmd_args_start..]) |arg| {
            if (std.mem.eql(u8, arg, "--no-telemetry")) {
                telemetry_disabled = true;
                break;
            }
        }

        var telem = telemetry.Telemetry.init(io, data_dir, allocator, telemetry_disabled);
        defer telem.deinit();
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

        mcp_server.run(io, allocator, &store, &explorer, &agents, abs_root, &telem, maybe_deferred);

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
fn isCommand(arg: []const u8) bool {
    const commands = [_][]const u8{ "tree", "outline", "find", "search", "word", "hot", "snapshot", "serve", "mcp", "update", "nuke" };
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

    if (WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
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
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
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
                snapshot_mod.writeSnapshotDual(io, explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
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

    snapshot_mod.writeSnapshotDual(io, explorer, abs_root, "codedb.snapshot", allocator) catch |err| {
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
    var fallback_attempted = false;
    while (!ctx.scan_done.load(.acquire) and !ctx.shutdown.load(.acquire)) {
        cio.sleepMs(50);
        if (!fallback_attempted and cio.milliTimestamp() - t0 >= fallback_after_ms) {
            fallback_attempted = true;
            // Client never sent indexable roots — fall back to cwd so the
            // server doesn't sit in loading_snapshot forever.
            const empty_roots: []const mcp_server.Root = &.{};
            _ = mcp_server.triggerDeferredScanWithFallback(ctx, empty_roots, ctx.fallback_cwd);
        }
    }
    if (ctx.shutdown.load(.acquire)) return;
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
