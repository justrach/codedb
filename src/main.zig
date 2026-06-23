const std = @import("std");
const builtin = @import("builtin");
const cio = @import("cio.zig");
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const sty = @import("style.zig");
const index_mod = @import("index.zig");
const root_policy = @import("root_policy.zig");
const nuke_mod = @import("nuke.zig");
const update_mod = @import("update.zig");
const release_info = @import("release_info.zig");
const Config = @import("config.zig").Config;

/// Buffered stdout wrapper. Formats into a 64KB stack-buffered window and
/// flushes lazily; an explicit `flush()` runs from mainImpl's deferred cleanup.
/// `word` on a high-count term (~2k hits) used to do 2k mallocs + 2k write()
/// syscalls; this collapses that to a handful of batched writes.
const out_mod = @import("out.zig");
const Out = out_mod.Out;
const printUsage = out_mod.printUsage;
const cli_args = @import("cli_args.zig");
// Re-exports so @import("main.zig") (tests, tooling) and the rest of main keep
// the original flat call sites after the cli_args.zig extraction.
pub const ParsedPositional = cli_args.ParsedPositional;
pub const parsePositional = cli_args.parsePositional;
pub const LineRange = cli_args.LineRange;
pub const LineRangeError = cli_args.LineRangeError;
pub const parseLineRange = cli_args.parseLineRange;
pub const SearchArgs = cli_args.SearchArgs;
pub const SearchArgError = cli_args.SearchArgError;
pub const parseSearchArgs = cli_args.parseSearchArgs;
pub const hasExtraCliArgs = cli_args.hasExtraCliArgs;
pub const findGitRoot = cli_args.findGitRoot;
pub const findGitRootFrom = cli_args.findGitRootFrom;
pub const isValidMcpFlag = cli_args.isValidMcpFlag;
pub const resolveRoot = cli_args.resolveRoot;
const cliIsQueryCmd = cli_args.cliIsQueryCmd;
const mcpRootIsImplicitCwd = cli_args.mcpRootIsImplicitCwd;
const mcpRootAcceptsEnv = cli_args.mcpRootAcceptsEnv;
const isHelpRequest = cli_args.isHelpRequest;

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
const query_mod = @import("query.zig");
const runQuery = query_mod.runQuery;

const cli_proxy = @import("cli_proxy.zig");
pub const daemonLockTryAcquire = cli_proxy.daemonLockTryAcquire;
pub const daemonLockAvailable = cli_proxy.daemonLockAvailable;
const cliTryProxy = cli_proxy.cliTryProxy;

const bootstrap = @import("bootstrap.zig");
const loadUserConfig = bootstrap.loadUserConfig;
const getDataDir = bootstrap.getDataDir;

const commands = @import("commands.zig");
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
    if (mcpRootAcceptsEnv(cmd, root)) {
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
    if (mcpRootIsImplicitCwd(cmd, root, root_is_explicit)) {
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
            if (isHelpRequest(a)) {
                out.file = stdout;
                printUsage(&out, s);
                return;
            }
            if (!isValidMcpFlag(a)) {
                out.p("{s}\xe2\x9c\x97{s} unknown flag for {s}mcp{s}: {s}{s}{s}\n  valid: {s}--no-telemetry{s}, {s}--help{s}, {s}--config-file=<path>{s}\n", .{
                    s.red,   s.reset,
                    s.bold,  s.reset,
                    s.bold,  a,
                    s.reset, s.bold,
                    s.reset, s.bold,
                    s.reset, s.bold,
                    s.reset,
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
    if (isHelpRequest(cmd)) {
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
    const mcp_deferred_root = mcpRootIsImplicitCwd(cmd, root, root_is_explicit);
    if (!mcp_deferred_root and !root_policy.isIndexableRoot(abs_root)) {
        out.p("{s}\xe2\x9c\x97{s} refusing to index temporary root: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, abs_root, s.reset,
        });
        out.exitWithFlush(1);
    }

    // #553: `status` must be a cheap, fast-exiting metadata query. It previously
    // fell through to the full index bootstrap below (snapshot mmap, or — with no
    // snapshot — a complete re-index + multi-GB snapshot rewrite) and, being in
    // cliIsQueryCmd, also auto-spawned a warm cli-daemon. Backgrounded as a
    // SessionStart warmup (`codedb . status &`), each call left a multi-GB
    // resident orphan that stacked until the machine OOM'd. Report from on-disk
    // metadata only — no Explorer load, no daemon spawn — and exit immediately.
    if (std.mem.eql(u8, cmd, "status")) {
        const t0 = cio.nanoTimestamp();
        const data_dir = getDataDir(io, allocator, abs_root) catch {
            out.p("{s}\xe2\x9c\x97{s} cannot resolve data dir for {s}{s}{s}\n", .{
                s.red, s.reset, s.bold, abs_root, s.reset,
            });
            out.exitWithFlush(1);
        };
        defer allocator.free(data_dir);
        const meta = index_mod.readStatusMeta(io, data_dir, allocator);
        const elapsed = cio.nanoTimestamp() - t0;
        var dur_buf: [64]u8 = undefined;
        out.p("{s}\xe2\x9c\x93{s} {s}codedb {s}{s}  {s}{s}{s}\n", .{
            s.green,                               s.reset,
            s.bold,                                release_info.semver,
            s.reset,                               sty.durationColor(s, elapsed),
            sty.formatDuration(&dur_buf, elapsed), s.reset,
        });
        out.p("  {s}root{s}      {s}{s}{s}\n", .{ s.dim, s.reset, s.cyan, root, s.reset });
        if (meta.indexed) {
            out.p("  {s}files{s}     {s}{d}{s} indexed\n", .{ s.dim, s.reset, s.bold, meta.file_count, s.reset });
            if (meta.git_head) |h| {
                out.p("  {s}head{s}      {s}{s}{s}\n", .{ s.dim, s.reset, s.cyan, h[0..12], s.reset });
            }
        } else {
            out.p("  {s}files{s}     {s}not indexed{s}  \xe2\x80\x94 run `codedb {s} index`\n", .{ s.dim, s.reset, s.bold, s.reset, root });
        }
        out.p("  {s}data{s}      {s}{s}{s}\n", .{ s.dim, s.reset, s.dim, data_dir, s.reset });
        out.exitWithFlush(0);
    }

    // Thin-client fast path: if a warm daemon (codedb <root> serve / mcp) is
    // already listening for this project, proxy read-only query commands to it
    // and skip the per-invocation snapshot reload entirely. Falls through to
    // the cold in-process path below when no daemon answers. Must run before
    // getDataDir + the load section so the proxied call pays none of that cost.
    // CODEDB_NO_CLI_DAEMON disables the thin client ENTIRELY — proxy and
    // auto-spawn — so benchmarks/tests pin the in-process path. It previously
    // gated only the spawn, so a pre-existing daemon still answered queries
    // despite the variable (observed while profiling #564: a stray cli-daemon
    // served 'search' in 944µs with the variable set).
    if (cliIsQueryCmd(cmd) and cio.posixGetenv("CODEDB_NO_CLI_DAEMON") == null) {
        if (cliTryProxy(io, allocator, abs_root, args, use_color)) |code| {
            out.flush();
            std.process.exit(code);
        }
        // No daemon answered. Auto-spawn a detached cli-daemon so the NEXT call
        // is warm; this call still falls through to the cold path below. The
        // daemon is the SAME binary (resolved via the self-exe path) run as
        // `codedb <abs_root> cli-daemon`, with stdio redirected to /dev/null and
        // no waitpid (fire-and-forget). Skipped for an empty root. cli-daemon is
        // not a query command, so the spawned process won't recurse into this path.
        // #592: also skipped while another daemon holds the per-project spawn
        // lock — concurrent cold calls otherwise fork a daemon EACH, every
        // duplicate rescans the index, and the stampede leaves orphans churning
        // CPU. Losers of this probe simply cold-serve their one call.
        if (abs_root.len > 0) {
            const probe_dir = getDataDir(io, allocator, abs_root) catch null;
            defer if (probe_dir) |d| allocator.free(d);
            const lock_free = if (probe_dir) |d| daemonLockAvailable(d) else true;
            if (lock_free) {
                if (std.process.executablePathAlloc(io, allocator)) |self_exe| {
                    defer allocator.free(self_exe);
                    const daemon_argv = [_][]const u8{ self_exe, abs_root, "cli-daemon" };
                    cio.spawnDetached(allocator, &daemon_argv);
                } else |_| {}
            }
        }
    }

    const data_dir = try getDataDir(io, allocator, abs_root);
    defer allocator.free(data_dir);

    // #592: exactly one cli-daemon per project. Take the per-project flock
    // BEFORE the expensive load below so a duplicate exits without paying a
    // full rescan (or stealing the winner's socket via the stale-path unlink
    // in cliDaemonListen). The fd is held for the process lifetime; the
    // kernel drops the lock on any exit, so a crash never leaves it stale.
    if (std.mem.eql(u8, cmd, "cli-daemon")) {
        if (daemonLockTryAcquire(data_dir) == null) return;
    }

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

    try bootstrap.coldLoadOrScan(io, allocator, &store, &explorer, &out, s, cmd, args, cmd_args_start, abs_root, data_dir, root, &freq_table_heap);
    var ctx = commands.RunCtx{
        .io = io,
        .allocator = allocator,
        .out = &out,
        .s = s,
        .store = &store,
        .explorer = &explorer,
        .cfg = cfg,
        .data_dir = data_dir,
        .abs_root = abs_root,
        .root = root,
        .args = args,
        .cmd_args_start = cmd_args_start,
        .no_telemetry = no_telemetry,
        .mcp_deferred_root = mcp_deferred_root,
    };
    if (cliIsQueryCmd(cmd)) {
        const code = runQuery(io, allocator, &explorer, &store, abs_root, cmd, args, cmd_args_start, &out, s);
        out.flush();
        std.process.exit(code);
    } else if (std.mem.eql(u8, cmd, "bench-engine")) {
        commands.runBenchEngine(&ctx);
    } else if (std.mem.eql(u8, cmd, "snapshot")) {
        commands.runSnapshot(&ctx);
    } else if (std.mem.eql(u8, cmd, "cli-daemon")) {
        try commands.runCliDaemon(&ctx);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        try commands.runServe(&ctx);
    } else if (std.mem.eql(u8, cmd, "mcp")) {
        try commands.runMcp(&ctx);
    } else if (std.mem.eql(u8, cmd, "index")) {
        // #633: `index` is a first-class command. coldLoadOrScan above already
        // scanned + persisted the on-disk index for this cmd; confirm and exit
        // cleanly. It used to fall through to "unknown command: index" + exit 1
        // even though the index had been built.
        explorer.mu.lockShared();
        const file_count = explorer.outlines.count();
        explorer.mu.unlockShared();
        out.p("{s}\xe2\x9c\x93{s} {s}index ready{s}  {s}{d} files{s}\n", .{
            s.green, s.reset, s.bold, s.reset, s.dim, file_count, s.reset,
        });
        out.flush();
        std.process.exit(0);
    } else {
        out.p("{s}\xe2\x9c\x97{s} unknown command: {s}{s}{s}\n", .{
            s.red, s.reset, s.bold, cmd, s.reset,
        });
        // #578: flush before exit — std.process.exit skips buffered output, so
        // the 'unknown command' line was silently lost (observed as exit 1
        // with no output at all).
        out.flush();
        std.process.exit(1);
    }
}
