//! Startup index/snapshot bootstrap helpers: config + snapshot loading, data
//! dir resolution, trigram/word-index disk loads, the background warmup thread,
//! word-index persistence, and MCP-ready memory compaction. Extracted from
//! mainImpl; shared by main.zig, commands.zig, and background.zig.
const std = @import("std");
const cio = @import("cio.zig");
const Config = @import("config.zig").Config;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const TrigramIndex = @import("index.zig").TrigramIndex;
const MmapTrigramIndex = @import("index.zig").MmapTrigramIndex;
const WordIndex = @import("index.zig").WordIndex;
const snapshot_mod = @import("snapshot.zig");
const git_mod = @import("git.zig");
const warmup_mod = @import("warmup.zig");
const mcp_server = @import("mcp.zig");
const watcher = @import("watcher.zig");
const index_mod = @import("index.zig");
const sty = @import("style.zig");
const Out = @import("out.zig").Out;
const parseSearchArgs = @import("cli_args.zig").parseSearchArgs;
const cliIsQueryCmd = @import("cli_args.zig").cliIsQueryCmd;

/// Cheap freshness probe: true when any indexable source file under abs_root
/// is newer than the snapshot on disk. Agents edit files all session long —
/// serving the pre-edit index hides the agent's OWN new symbols (observed in
/// the DeepSWE bench: `search <just-added-fn>` → 0 results → the model
/// distrusts the tool and reverts to grep/read_file loops, doubling tokens).
/// A walk+stat of the tree is a few ms and early-exits on the first drifted
/// file; conservative (returns not-stale) on any IO error.
fn snapshotIsStale(io: std.Io, abs_root: []const u8, data_dir: []const u8, allocator: std.mem.Allocator) bool {
    // Stat the snapshot that would actually be served — same precedence as
    // loadBestSnapshot: in-repo first, then the central data dir.
    var snap_stat: @TypeOf(std.Io.Dir.cwd().statFile(io, abs_root, .{}) catch unreachable) = undefined;
    var found = false;
    for ([_][]const u8{ abs_root, data_dir }) |base| {
        if (found) break;
        const snap_path = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{base}) catch return false;
        defer allocator.free(snap_path);
        if (std.Io.Dir.cwd().statFile(io, snap_path, .{})) |st| {
            snap_stat = st;
            found = true;
        } else |_| {}
    }
    if (!found) return false;
    var dir = std.Io.Dir.cwd().openDir(io, abs_root, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var walker = watcher.FilteredWalker.init(io, dir, allocator) catch return false;
    defer walker.deinit();
    while (walker.next() catch return false) |entry| {
        // Skip codedb's own writes (snapshot, .codedb data dir) and agent
        // scratch (.graff): they are touched by codedb/the harness itself on
        // every run, so counting them makes the index permanently "stale"
        // and forces a rescan on EVERY call.
        if (std.mem.eql(u8, entry.path, "codedb.snapshot")) continue;
        if (std.mem.startsWith(u8, entry.path, ".codedb/") or
            std.mem.startsWith(u8, entry.path, ".graff/")) continue;
        const st = dir.statFile(io, entry.path, .{}) catch continue;
        if (st.mtime.nanoseconds > snap_stat.mtime.nanoseconds) return true;
    }
    return false;
}

/// Resolve config from the (already-extracted) --config-file path, falling
/// back to $CWD/.codedbrc and then <binary_dir>/.codedbrc. Returns the
/// default Config if nothing is found. Addresses #101, #102.
pub fn loadUserConfig(io: std.Io, alloc: std.mem.Allocator, explicit: ?[]const u8) !Config {
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

pub fn loadBestSnapshot(
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

pub fn getDataDir(io: std.Io, allocator: std.mem.Allocator, abs_root: []const u8) ![]u8 {
    const hash = std.hash.Wyhash.hash(0, abs_root);
    const home_env = cio.homeDir() orelse {
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

pub fn loadTrigramFromDiskIfPresent(io: std.Io, explorer: *Explorer, data_dir: []const u8, allocator: std.mem.Allocator) void {
    explorer.mu.lockShared();
    const disk_backed = explorer.trigram_index != .heap;
    const heap_files = explorer.trigram_index.fileCount();
    const total_files = explorer.outlines.count();
    explorer.mu.unlockShared();
    // Skip only when a disk index is already adopted or the heap index
    // covers the whole project. A PARTIAL heap (snapshot freshness reindex
    // touches a few changed files before this runs) must not block the
    // load — adoptTrigramBase keeps those files as a masking overlay.
    if (disk_backed or (heap_files > 0 and heap_files >= total_files)) return;

    if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.adoptTrigramBase(loaded);
    } else if (heap_files == 0) {
        if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
            explorer.adoptTrigramIndex(.{ .heap = loaded });
        }
    }
}

pub fn loadWordIndexFromDiskIfPresent(
    io: std.Io,
    explorer: *Explorer,
    data_dir: []const u8,
    current_git_head: ?[40]u8,
    allocator: std.mem.Allocator,
) void {
    if (!explorer.wordIndexCanLoadFromDisk()) return;

    // Each disable below logs WHY at debug level: a silent fallback here means
    // the next query pays a full heap rebuild with no breadcrumb, which reads
    // as an unexplained RSS/latency spike when profiling.
    const header = WordIndex.readDiskHeader(io, data_dir, allocator) catch null orelse {
        std.log.debug("word.index disk load skipped: no readable header", .{});
        explorer.disableWordIndexDiskLoad();
        return;
    };

    explorer.mu.lockShared();
    const current_count = @as(u32, @intCast(explorer.outlines.count()));
    explorer.mu.unlockShared();
    if (header.file_count != current_count) {
        std.log.debug("word.index disk load skipped: file_count {d} != indexed {d}", .{ header.file_count, current_count });
        explorer.disableWordIndexDiskLoad();
        return;
    }

    const heads_match = blk: {
        if (current_git_head == null and header.git_head == null) break :blk true;
        if (current_git_head == null or header.git_head == null) break :blk false;
        break :blk std.mem.eql(u8, &current_git_head.?, &header.git_head.?);
    };
    if (!heads_match) {
        std.log.debug("word.index disk load skipped: git head mismatch", .{});
        explorer.disableWordIndexDiskLoad();
        return;
    }

    if (WordIndex.mmapFromDisk(io, data_dir, allocator) orelse WordIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.replaceWordIndex(loaded);
    } else {
        std.log.debug("word.index disk load skipped: mmap and heap read both failed", .{});
        explorer.disableWordIndexDiskLoad();
    }
}

/// Background warmup for the long-lived server modes (#tail-latency): real
/// query logs show the latency tail is lazy work charged to the first query
/// (word-index rebuild after a snapshot fast-load: 50ms–2s), and 62% of
/// calls are exact repeats that the result caches can serve at µs — but only
/// if something fills them. The thread waits for the scan to be ready, then
/// (1) loads-or-rebuilds + persists the word index, and (2) replays the most
/// repeated recent queries from queries.log through the same entry points
/// real codedb_search calls use. CODEDB_NO_WARMUP=1 disables it.
const WarmupCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    explorer: *Explorer,
    data_dir: []u8,
    abs_root: []u8,
    shutdown: *std.atomic.Value(bool),
};

fn warmupThreadMain(ctx: *WarmupCtx) void {
    const allocator = ctx.allocator;
    defer {
        allocator.free(ctx.data_dir);
        allocator.free(ctx.abs_root);
        allocator.destroy(ctx);
    }

    // Deferred MCP scans flip the state back to .ready when indexing is done;
    // serve/cli-daemon never leave .ready. Cap the wait so a wedged scan
    // can't pin this thread forever.
    var waited_ms: u64 = 0;
    while (mcp_server.getScanState() != .ready and waited_ms < 120_000) {
        if (ctx.shutdown.load(.acquire)) return;
        cio.sleepMs(50);
        waited_ms += 50;
    }
    if (ctx.shutdown.load(.acquire) or mcp_server.getScanState() != .ready) return;

    // (1) Index prewarm: pay the word-index load/rebuild here instead of on
    // the first codedb_word/search call, and persist a rebuild so the NEXT
    // process start mmap-loads it.
    const git_head = git_mod.getGitHead(ctx.abs_root, allocator) catch null;
    loadWordIndexFromDiskIfPresent(ctx.io, ctx.explorer, ctx.data_dir, git_head, allocator);
    if (!ctx.explorer.wordIndexIsComplete()) {
        ctx.explorer.rebuildWordIndex() catch {};
        if (ctx.explorer.wordIndexIsComplete()) {
            persistWordIndexToDisk(ctx.io, ctx.explorer, ctx.data_dir, git_head);
        }
    }
    if (ctx.shutdown.load(.acquire)) return;

    // (2) Result-cache warmup: replay the most repeated recent queries. The
    // searches also trigger the lazy ranking builds (symbol index, call
    // graph, co-change) so no real query pays for those either.
    if (cio.posixGetenv("CODEDB_NO_SEARCH_CACHE") != null) return;
    var path_buf: [1024]u8 = undefined;
    const log_path = std.fmt.bufPrint(&path_buf, "{s}/queries.log", .{ctx.data_dir}) catch return;
    const log_bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, log_path, allocator, .limited(warmup_mod.max_log_tail_bytes)) catch return;
    defer allocator.free(log_bytes);
    const queries = warmup_mod.topQueries(allocator, log_bytes, warmup_mod.max_replay_queries) catch return;
    defer warmup_mod.freeQueries(allocator, queries);
    warmup_mod.replay(ctx.explorer, allocator, queries, ctx.shutdown);
}

pub fn spawnWarmup(io: std.Io, allocator: std.mem.Allocator, explorer: *Explorer, data_dir: []const u8, abs_root: []const u8, shutdown: *std.atomic.Value(bool)) void {
    if (cio.posixGetenv("CODEDB_NO_WARMUP") != null) return;
    // Low-memory mode trades latency for RSS everywhere else (see
    // compactMcpReadyMemory); don't pre-pay index builds + caches there.
    if (cio.posixGetenv("CODEDB_LOW_MEMORY") != null) return;
    const ctx = allocator.create(WarmupCtx) catch return;
    const data_dir_copy = allocator.dupe(u8, data_dir) catch {
        allocator.destroy(ctx);
        return;
    };
    const abs_root_copy = allocator.dupe(u8, abs_root) catch {
        allocator.free(data_dir_copy);
        allocator.destroy(ctx);
        return;
    };
    ctx.* = .{
        .io = io,
        .allocator = allocator,
        .explorer = explorer,
        .data_dir = data_dir_copy,
        .abs_root = abs_root_copy,
        .shutdown = shutdown,
    };
    if (std.Thread.spawn(.{}, warmupThreadMain, .{ctx})) |t| {
        t.detach();
    } else |err| {
        std.log.debug("warmup: could not start thread: {s}", .{@errorName(err)});
        allocator.free(ctx.data_dir);
        allocator.free(ctx.abs_root);
        allocator.destroy(ctx);
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

pub fn compactMcpReadyMemory(
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

pub fn persistWordIndexToDisk(io: std.Io, explorer: *Explorer, data_dir: []const u8, git_head: ?[40]u8) void {
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

pub fn wordIndexMatchesOutlines(explorer: *Explorer) bool {
    explorer.mu.lockShared();
    defer explorer.mu.unlockShared();
    return explorer.word_index_complete and
        explorer.word_index.id_to_path.items.len == explorer.outlines.count();
}

pub fn persistWordIndexFromSource(
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

pub fn saveProjectInfo(io: std.Io, allocator: std.mem.Allocator, data_dir: []const u8, abs_root: []const u8) !void {
    const info_path = try std.fmt.allocPrint(allocator, "{s}/project.txt", .{data_dir});
    defer allocator.free(info_path);
    const file = try std.Io.Dir.cwd().createFile(io, info_path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, abs_root);
}

/// Cold-path index bootstrap for the non-mcp commands: load the best snapshot
/// (and warm trigram/word indexes as the command needs), or fall back to a full
/// scan that builds + persists the trigram/word/frequency indexes and a project
/// cache snapshot. No-op for `mcp` (runMcp owns its own deferred/eager load).
/// `freq_table_heap` is owned by the caller (mainImpl) — we only set it so the
/// caller's deferred resetFrequencyTable/destroy runs for the process lifetime.
pub fn coldLoadOrScan(
    io: std.Io,
    allocator: std.mem.Allocator,
    store: *Store,
    explorer: *Explorer,
    out: *Out,
    s: sty.Style,
    cmd: []const u8,
    args: []const []const u8,
    cmd_args_start: usize,
    abs_root: []const u8,
    data_dir: []const u8,
    root: []const u8,
    freq_table_heap: *?*[256][256]u16,
) !void {
    if (std.mem.eql(u8, cmd, "mcp")) return;

    const git_head = git_mod.getGitHead(abs_root, allocator) catch null;

    // Staleness probe BEFORE loading: a query served from a pre-edit snapshot
    // is worse than a 300ms rescan — it silently misses the agent's own edits.
    // On drift, skip the load entirely and fall into the cold rescan branch,
    // which repersists a fresh snapshot so the next call is warm again.
    // CODEDB_NO_AUTO_REFRESH=1 pins the old load-only behavior.
    const stale = cliIsQueryCmd(cmd) and
        cio.posixGetenv("CODEDB_NO_AUTO_REFRESH") == null and
        snapshotIsStale(io, abs_root, data_dir, allocator);

    const snapshot_t0 = cio.nanoTimestamp();
    const snapshot_loaded = !stale and loadBestSnapshot(io, explorer, store, abs_root, data_dir, git_head, allocator);
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
            loadTrigramFromDiskIfPresent(io, explorer, data_dir, allocator);
        }
        if (std.mem.eql(u8, cmd, "search")) {
            // #547: searchContent's Tier 0 recall is the word inverted index,
            // not the trigram. Without it, `search` is blind to identifier
            // terms that `word` surfaces (long / low-frequency names). Cheap
            // mmap load, mirroring the trigram load above; `word`/`mcp`
            // already load it, `search` did not.
            loadWordIndexFromDiskIfPresent(io, explorer, data_dir, git_head, allocator);
        }
        if (std.mem.eql(u8, cmd, "word") or std.mem.eql(u8, cmd, "bench-engine") or std.mem.eql(u8, cmd, "cli-daemon")) {
            loadWordIndexFromDiskIfPresent(io, explorer, data_dir, git_head, allocator);
            // word/bench-engine want a guaranteed-ready index — rebuild + persist
            // if the on-disk one was missing/stale. The cli-daemon stays lean: if
            // the mmap load missed, let the first `word`/`context` query rebuild
            // lazily rather than hold a heap rebuild at startup.
            if (!std.mem.eql(u8, cmd, "cli-daemon") and !explorer.wordIndexIsComplete()) {
                explorer.rebuildWordIndex() catch {};
                persistWordIndexToDisk(io, explorer, data_dir, git_head);
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
            freq_table_heap.* = ft;
            index_mod.setFrequencyTable(ft);
        }

        const index_profile = cio.posixGetenv("CODEDB_INDEX_PROFILE") != null;
        const t_scan = cio.nanoTimestamp();
        var profile_word_persist_ns: i128 = 0;
        var profile_tri_build_ns: i128 = 0;
        var profile_tri_write_ns: i128 = 0;
        var profile_tri_mmap_ns: i128 = 0;
        var profile_freq_ns: i128 = 0;
        var profile_centrality_ns: i128 = 0;
        var profile_snapshot_ns: i128 = 0;
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
        // #546: a multi-word query ranks via BM25, which rebuilds the word index
        // from in-memory outlines/contents — the trigram-only fast scan commits
        // neither, so the first-ever cold multi-word search ranked over an empty
        // index and returned nothing. Route it through the full single-pass scan
        // (outlines + contents + trigrams); single-token and --regex searches
        // keep the trigram-only fast path.
        const search_skips_outlines = blk: {
            if (!is_search) break :blk true;
            const sa = parseSearchArgs(args, cmd_args_start) catch break :blk true;
            break :blk sa.use_regex or std.mem.indexOfScalar(u8, sa.query, ' ') == null;
        };
        if (is_search and !heads_match) {
            const tmp_tri = try watcher.initialScanWithTrigrams(io, store, explorer, root, allocator, std.heap.c_allocator, search_skips_outlines);
            if (tmp_tri) |tri| {
                tri.writeToDisk(io, data_dir, git_head) catch {};
                tri.deinit();
                std.heap.c_allocator.destroy(tri);
                if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                    explorer.adoptTrigramIndex(.{ .mmap = loaded });
                }
            }
        } else {
            try watcher.initialScan(io, store, explorer, root, allocator, true);
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
                    explorer.adoptTrigramIndex(.{ .mmap = loaded });
                } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
                    explorer.adoptTrigramIndex(.{ .heap = loaded });
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
                const t_word_persist: i128 = if (index_profile) cio.nanoTimestamp() else 0;
                persistWordIndexToDisk(io, explorer, data_dir, git_head);
                explorer.markWordIndexAsComplete();
                if (index_profile) profile_word_persist_ns = cio.nanoTimestamp() - t_word_persist;
            }
            const cpu_count = std.Thread.getCpuCount() catch 1;
            const tri_workers: usize = @min(@as(usize, @intCast(cpu_count)), 8);
            const t_tri_build: i128 = if (index_profile) cio.nanoTimestamp() else 0;
            const tmp_tri = watcher.buildTrigramsFromCache(&explorer.contents, allocator, std.heap.c_allocator, tri_workers) catch |err| blk: {
                std.log.warn("could not build trigram index: {}", .{err});
                break :blk null;
            };
            if (index_profile) profile_tri_build_ns = cio.nanoTimestamp() - t_tri_build;
            var trigram_written = false;
            if (tmp_tri) |tri| {
                defer {
                    tri.deinit();
                    std.heap.c_allocator.destroy(tri);
                }
                const t_tri_write: i128 = if (index_profile) cio.nanoTimestamp() else 0;
                write_trigrams: {
                    tri.writeToDisk(io, data_dir, git_head) catch |err| {
                        std.log.warn("could not persist trigram index: {}", .{err});
                        break :write_trigrams;
                    };
                    trigram_written = true;
                }
                if (index_profile) profile_tri_write_ns = cio.nanoTimestamp() - t_tri_write;
            }
            // Load only the index successfully written by this build. If build,
            // persistence, or mmap fails, retain contents for fallback search.
            const t_tri_mmap: i128 = if (index_profile) cio.nanoTimestamp() else 0;
            if (trigram_written) {
                if (MmapTrigramIndex.initFromDisk(io, data_dir, allocator)) |loaded| {
                    explorer.adoptTrigramIndex(.{ .mmap = loaded });
                    release_contents_after_cache = true;
                }
            }
            if (index_profile) profile_tri_mmap_ns = cio.nanoTimestamp() - t_tri_mmap;
        }

        // If no freq table was loaded, build one from indexed content and
        // persist for next run.  Streams file-by-file — zero extra memory.
        if (freq_table_heap.* == null) {
            if (explorer.contents.count() > 0) {
                const t_freq: i128 = if (index_profile) cio.nanoTimestamp() else 0;
                const cpu_count = std.Thread.getCpuCount() catch 1;
                const freq_workers: usize = @min(@as(usize, @intCast(cpu_count)), 8);
                const ft = index_mod.buildFrequencyTableFromMapParallel(&explorer.contents, allocator, freq_workers) catch
                    index_mod.buildFrequencyTableFromMap(&explorer.contents);
                index_mod.writeFrequencyTable(io, &ft, data_dir) catch |err| {
                    std.log.warn("could not persist frequency table: {}", .{err});
                };
                if (index_profile) profile_freq_ns = cio.nanoTimestamp() - t_freq;
            }
        }

        if (!std.mem.eql(u8, cmd, "snapshot")) {
            // Pre-build call-graph centrality so it's persisted in the snapshot
            // and a later load restores it instead of paying the lazy
            // first-query rebuild. Same env gate as the search path.
            if (cio.posixGetenv("CODEDB_NO_CENTRALITY") == null) {
                const t_centrality: i128 = if (index_profile) cio.nanoTimestamp() else 0;
                explorer.buildCallCentrality(allocator);
                if (index_profile) profile_centrality_ns = cio.nanoTimestamp() - t_centrality;
            }
            const t_snapshot: i128 = if (index_profile) cio.nanoTimestamp() else 0;
            snapshot_mod.writeProjectCacheSnapshot(io, explorer, abs_root, allocator) catch |err| {
                std.log.warn("could not persist project-cache snapshot: {}", .{err});
            };
            if (index_profile) profile_snapshot_ns = cio.nanoTimestamp() - t_snapshot;
        }
        if (release_contents_after_cache) {
            explorer.releaseContents();
        }
        if (index_profile) {
            const now = cio.nanoTimestamp();
            const to_ms = struct {
                fn f(ns: i128) f64 {
                    return @as(f64, @floatFromInt(ns)) / 1_000_000.0;
                }
            }.f;
            std.debug.print("[index-profile] cold total={d:.1}ms scan={d:.1}ms word_persist={d:.1}ms tri_build={d:.1}ms tri_write={d:.1}ms tri_mmap={d:.1}ms freq={d:.1}ms centrality={d:.1}ms snapshot={d:.1}ms other={d:.1}ms\n", .{
                to_ms(now - t_scan),
                to_ms(scan_elapsed),
                to_ms(profile_word_persist_ns),
                to_ms(profile_tri_build_ns),
                to_ms(profile_tri_write_ns),
                to_ms(profile_tri_mmap_ns),
                to_ms(profile_freq_ns),
                to_ms(profile_centrality_ns),
                to_ms(profile_snapshot_ns),
                to_ms((now - t_scan) - scan_elapsed - profile_word_persist_ns - profile_tri_build_ns - profile_tri_write_ns - profile_tri_mmap_ns - profile_freq_ns - profile_centrality_ns - profile_snapshot_ns),
            });
        }
    } // end else (no snapshot)
}
