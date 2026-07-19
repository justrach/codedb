//! Non-query command handlers (bench-engine / snapshot / cli-daemon / serve /
//! mcp). Extracted from mainImpl: each takes a RunCtx bundling the warm
//! Store/Explorer plus the parsed invocation state, so mainImpl stays a thin
//! dispatcher. The resources RunCtx points at (out/store/explorer/...) are
//! owned by mainImpl and outlive every handler call.
const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore_mod = @import("explore.zig");
const AgentRegistry = @import("agent.zig").AgentRegistry;
const watcher = @import("watcher.zig");
const server = @import("server.zig");
const mcp_server = @import("mcp.zig");
const telemetry = @import("telemetry.zig");
const git_mod = @import("git.zig");
const snapshot_mod = @import("snapshot.zig");
const update_mod = @import("update.zig");
const index_mod = @import("index.zig");
const Config = @import("config.zig").Config;
const Out = @import("out.zig").Out;
const cli_proxy = @import("cli_proxy.zig");
const cliDaemonListen = cli_proxy.cliDaemonListen;
const cliSocketPath = cli_proxy.cliSocketPath;
const bootstrap = @import("bootstrap.zig");
const loadWordIndexFromDiskIfPresent = bootstrap.loadWordIndexFromDiskIfPresent;
const wordIndexMatchesOutlines = bootstrap.wordIndexMatchesOutlines;
const persistWordIndexFromSource = bootstrap.persistWordIndexFromSource;
const persistWordIndexToDisk = bootstrap.persistWordIndexToDisk;
const loadBestSnapshot = bootstrap.loadBestSnapshot;
const loadTrigramFromDiskIfPresent = bootstrap.loadTrigramFromDiskIfPresent;
const compactMcpReadyMemory = bootstrap.compactMcpReadyMemory;
const saveProjectInfo = bootstrap.saveProjectInfo;
const spawnWarmup = bootstrap.spawnWarmup;
const background = @import("background.zig");
const reapLoop = background.reapLoop;
const scanBg = background.scanBg;
const triggerScanFromRoots = background.triggerScanFromRoots;
const watcherDeferredLoop = background.watcherDeferredLoop;
const idleWatchdog = background.idleWatchdog;
const cliIdleWatchdog = background.cliIdleWatchdog;

/// Shared invocation state for the command handlers. `out`/`store`/`explorer`
/// are pointers into mainImpl's stack frame, which lives for the whole process,
/// so handlers may spawn threads that capture them.
pub const RunCtx = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    out: *Out,
    s: sty.Style,
    store: *Store,
    explorer: *Explorer,
    cfg: Config,
    data_dir: []const u8,
    abs_root: []const u8,
    root: []const u8,
    args: []const []const u8,
    cmd_args_start: usize,
    no_telemetry: bool,
    mcp_deferred_root: bool,
};

pub fn runBenchEngine(ctx: *RunCtx) void {
    const allocator = ctx.allocator;
    const args = ctx.args;
    const cmd_args_start = ctx.cmd_args_start;
    const explorer = ctx.explorer;
    const out = ctx.out;
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
            for (warm) |r| {
                allocator.free(r.path);
                allocator.free(r.line_text);
            }
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
            for (r) |item| {
                allocator.free(item.path);
                allocator.free(item.line_text);
            }
            allocator.free(r);
        } else if (std.mem.eql(u8, op, "search-fmt")) {
            const r = explorer.searchContent(query, allocator, 50) catch &[_]explore_mod.SearchResult{};
            hits_seen = r.len;
            defer {
                for (r) |item| {
                    allocator.free(item.path);
                    allocator.free(item.line_text);
                }
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
                for (r) |item| {
                    allocator.free(item.path);
                    allocator.free(item.line_text);
                }
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
}

pub fn runSnapshot(ctx: *RunCtx) void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    const args = ctx.args;
    const cmd_args_start = ctx.cmd_args_start;
    const abs_root = ctx.abs_root;
    const data_dir = ctx.data_dir;
    const explorer = ctx.explorer;
    const out = ctx.out;
    const s = ctx.s;
    const t0 = cio.nanoTimestamp();
    const output = if (args.len > cmd_args_start) args[cmd_args_start] else blk: {
        break :blk std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{abs_root}) catch "codedb.snapshot";
    };
    defer if (args.len <= cmd_args_start and output.len > "codedb.snapshot".len) allocator.free(output);
    snapshot_mod.writeSnapshotDual(io, explorer, abs_root, output, allocator) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} snapshot failed: {}\n", .{ s.red, s.reset, err });
        std.process.exit(1);
    };
    const git_head = git_mod.getGitHead(abs_root, allocator) catch null;
    loadWordIndexFromDiskIfPresent(io, explorer, data_dir, git_head, allocator);
    if (!wordIndexMatchesOutlines(explorer)) {
        persistWordIndexFromSource(io, explorer, abs_root, data_dir, git_head, allocator) catch |err| {
            out.p("{s}\xe2\x9c\x97{s} word index persist failed: {}\n", .{ s.red, s.reset, err });
            std.process.exit(1);
        };
    } else {
        persistWordIndexToDisk(io, explorer, data_dir, git_head);
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
}

pub fn runCliDaemon(ctx: *RunCtx) !void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    const abs_root = ctx.abs_root;
    const data_dir = ctx.data_dir;
    const root = ctx.root;
    const store = ctx.store;
    const explorer = ctx.explorer;
    const out = ctx.out;
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
    const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, store, explorer, queue, root, &shutdown, &scan_already_done });
    watch_thread.detach();

    std.log.info("cli-daemon: {d} files indexed, idle_timeout={d}ms", .{ store.currentSeq(), idle_ms });

    // CLI socket listener. Pass the REAL shutdown flag: if another daemon
    // already owns the socket (we lost the bind race), cliDaemonListen sets
    // shutdown and the watchdog below returns at once, so the redundant
    // daemon exits instead of lingering idle.
    if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, explorer, store, abs_root, data_dir, &last_activity_ms, &shutdown, false })) |cli_t| {
        cli_t.detach();
    } else |err| {
        std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
        return;
    }

    // Warm the word index + result caches in the background so the first
    // proxied CLI queries hit a fully warm explorer (the daemon used to
    // stay lean and charge the first `word`/`context` query the rebuild).
    const warmup_thread = spawnWarmup(io, allocator, explorer, data_dir, abs_root, &shutdown);

    // Block here until idle (or a bind-race shutdown). On return the process
    // exits immediately — std.process.exit reclaims everything and avoids
    // racing the detached listener thread against freed explorer/store.
    const idle_exit = cliIdleWatchdog(&shutdown, &last_activity_ms, idle_ms);
    shutdown.store(true, .release);
    if (warmup_thread) |t| t.join();
    // If WE owned the socket (exited on idle, not a bind-race loss), unlink
    // it on the way out. The listener thread's own `defer unlink` never runs
    // because std.process.exit kills it mid-accept; do it here so we don't
    // leave a stale node behind. On a bind-race loss the socket belongs to
    // the winning daemon, so idle_exit is false and we leave it alone.
    if (idle_exit) {
        var sock_buf: [128]u8 = undefined;
        if (cliSocketPath(&sock_buf, abs_root)) |sock_path| {
            var sock_z_buf: [128]u8 = undefined;
            if (cio.bufPrintZ(&sock_z_buf, "{s}", .{sock_path})) |sock_z| {
                _ = std.c.unlink(sock_z.ptr);
            } else |_| {}
        }
    }
    out.flush();
    std.process.exit(0);
}

pub fn runServe(ctx: *RunCtx) !void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    const abs_root = ctx.abs_root;
    const data_dir = ctx.data_dir;
    const root = ctx.root;
    const store = ctx.store;
    const explorer = ctx.explorer;
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
    const watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, store, explorer, queue, root, &shutdown, &scan_already_done });
    defer {
        shutdown.store(true, .release);
        watch_thread.join();
    }

    const reap_thread = try std.Thread.spawn(.{}, reapLoop, .{ &agents, &shutdown });
    defer {
        shutdown.store(true, .release);
        reap_thread.join();
    }

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
    if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, explorer, store, abs_root, data_dir, &cli_activity, &cli_listener_dead, true })) |cli_t| {
        cli_t.detach();
    } else |err| {
        std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
    }
    const warmup_thread = spawnWarmup(io, allocator, explorer, data_dir, abs_root, &shutdown);
    defer {
        shutdown.store(true, .release);
        if (warmup_thread) |t| t.join();
    }
    try server.serve(io, allocator, store, &agents, explorer, queue, port);
}

pub fn runMcp(ctx: *RunCtx) !void {
    const io = ctx.io;
    const allocator = ctx.allocator;
    const abs_root = ctx.abs_root;
    const data_dir = ctx.data_dir;
    const root = ctx.root;
    const store = ctx.store;
    const explorer = ctx.explorer;
    const cfg = ctx.cfg;
    const no_telemetry = ctx.no_telemetry;
    const mcp_deferred_root = ctx.mcp_deferred_root;
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
            .store = store,
            .explorer = explorer,
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
        const snapshot_loaded = loadBestSnapshot(io, explorer, store, abs_root, data_dir, git_head, allocator);
        var scan_done = std.atomic.Value(bool).init(snapshot_loaded);
        if (!snapshot_loaded) {
            mcp_server.setScanState(.walking);
            scan_thread = try std.Thread.spawn(.{}, scanBg, .{ io, store, explorer, root, allocator, &scan_done, &shutdown, data_dir, abs_root, &telem, startup_t0 });
        } else {
            const startup_time_ms: u64 = @intCast(@max(cio.milliTimestamp() - startup_t0, 0));
            loadTrigramFromDiskIfPresent(io, explorer, data_dir, git_head, allocator);
            telem.recordCodebaseStats(explorer, startup_time_ms);
            compactMcpReadyMemory(io, explorer, data_dir, git_head, allocator);
            mcp_server.setScanState(.ready);
        }
        watch_thread = try std.Thread.spawn(.{}, watcher.incrementalLoop, .{ io, store, explorer, queue, root, &shutdown, &scan_done });
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
    if (std.Thread.spawn(.{}, cliDaemonListen, .{ io, allocator, explorer, store, abs_root, data_dir, &cli_activity, &cli_listener_dead, true })) |cli_t| {
        cli_t.detach();
    } else |err| {
        std.log.warn("cli-proxy: could not start listener: {s}", .{@errorName(err)});
    }
    const warmup_thread = spawnWarmup(io, allocator, explorer, data_dir, abs_root, &shutdown);
    mcp_server.run(io, allocator, store, explorer, &agents, abs_root, cfg.max_cached, &telem, maybe_deferred, &shutdown);

    shutdown.store(true, .release);
    if (warmup_thread) |t| t.join();
    if (scan_thread) |st| st.join();
    if (maybe_deferred) |d| {
        if (d.scan_thread) |st| st.join();
    }
    watch_thread.join();
    idle_thread.join();
}
