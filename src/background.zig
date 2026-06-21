//! Long-lived server-mode background threads: the agent reaper, the deferred /
//! background index scan, the deferred-roots watcher loop, and the two idle
//! watchdogs (MCP stdin-HUP and cli-daemon timeout). Extracted from mainImpl;
//! driven by commands.zig (serve/mcp/cli-daemon).
const std = @import("std");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const watcher = @import("watcher.zig");
const mcp_server = @import("mcp.zig");
const telemetry = @import("telemetry.zig");
const git_mod = @import("git.zig");
const snapshot_mod = @import("snapshot.zig");
const TrigramIndex = @import("index.zig").TrigramIndex;
const MmapTrigramIndex = @import("index.zig").MmapTrigramIndex;
const bootstrap = @import("bootstrap.zig");
const persistWordIndexToDisk = bootstrap.persistWordIndexToDisk;
const loadBestSnapshot = bootstrap.loadBestSnapshot;
const loadTrigramFromDiskIfPresent = bootstrap.loadTrigramFromDiskIfPresent;
const compactMcpReadyMemory = bootstrap.compactMcpReadyMemory;
const getDataDir = bootstrap.getDataDir;

pub fn reapLoop(agents: *AgentRegistry, shutdown: *std.atomic.Value(bool)) void {
    while (!shutdown.load(.acquire)) {
        // Sleep in 1s increments for responsive shutdown (was 5s)
        for (0..5) |_| {
            if (shutdown.load(.acquire)) return;
            cio.sleepMs(1000);
        }
        agents.reapStale(30_000);
    }
}

pub fn scanBg(io: std.Io, store: *Store, explorer: *Explorer, root: []const u8, allocator: std.mem.Allocator, scan_done: *std.atomic.Value(bool), shutdown: *std.atomic.Value(bool), data_dir: []const u8, abs_root: []const u8, telem: *telemetry.Telemetry, startup_t0: i64) void {
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
                explorer.adoptTrigramIndex(.{ .mmap = loaded });
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
                explorer.adoptTrigramIndex(.{ .heap = loaded });
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
        explorer.adoptTrigramIndex(.{ .mmap = loaded });
    } else if (TrigramIndex.readFromDisk(io, data_dir, allocator)) |loaded| {
        explorer.adoptTrigramIndex(.{ .heap = loaded });
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
pub fn triggerScanFromRoots(ctx: *mcp_server.DeferredScan, abs_root: []const u8) void {
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

pub fn watcherDeferredLoop(ctx: *mcp_server.DeferredScan) void {
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

pub fn idleWatchdog(shutdown: *std.atomic.Value(bool)) void {
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
pub fn cliIdleWatchdog(shutdown: *std.atomic.Value(bool), last_activity_ms: *std.atomic.Value(i64), idle_ms: i64) bool {
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
