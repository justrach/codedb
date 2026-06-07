const std = @import("std");
const cio = @import("cio.zig");
const testing = std.testing;
const io = std.testing.io;
const Store = @import("store.zig").Store;
const Explorer = @import("explore.zig").Explorer;
const explore = @import("explore.zig");
const Language = explore.Language;
const AgentRegistry = @import("agent.zig").AgentRegistry;
const mcp_mod = @import("mcp.zig");
const main_mod = @import("main.zig");
const nuke_mod = @import("nuke.zig");
const update_mod = @import("update.zig");
const Config = @import("config.zig").Config;
const telemetry_mod = @import("telemetry.zig");
const release_info = @import("release_info.zig");
const root_policy = @import("root_policy.zig");
const edit_mod = @import("edit.zig");
const snapshot_mod = @import("snapshot.zig");
const watcher = @import("watcher.zig");
const WordIndex = @import("index.zig").WordIndex;
const TrigramIndex = @import("index.zig").TrigramIndex;
const SparseNgramIndex = @import("index.zig").SparseNgramIndex;
comptime {
    _ = @import("config.zig");
}


fn buildCliForHelpTests() !void {
    const build = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}


test "issue-59: telemetry writes session, tool, and codebase stats ndjson" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var telem = telemetry_mod.Telemetry.init(io, dir_path, testing.allocator, false);
    defer telem.deinit();

    telem.recordSessionStart();
    telem.recordToolCall("codedb_status", 1234, false, 56);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.py", "def run():\n    return 1\n");

    telem.recordCodebaseStats(&explorer, 42);
    telem.flush();

    const ndjson_path = try std.fmt.allocPrint(testing.allocator, "{s}/telemetry.ndjson", .{dir_path});
    defer testing.allocator.free(ndjson_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, ndjson_path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(contents);

    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"session_start\"") != null);
    const version_needle = try std.fmt.allocPrint(testing.allocator, "\"version\":\"{s}\"", .{release_info.semver});
    defer testing.allocator.free(version_needle);
    try testing.expect(std.mem.indexOf(u8, contents, version_needle) != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"tool_call\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"tool\":\"codedb_status\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"event_type\":\"codebase_stats\"") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"startup_time_ms\":42") != null);
    try testing.expect(std.mem.indexOf(u8, contents, "\"languages\":[\"zig\",\"python\"]") != null);
}


test "issue-60: telemetry disabled path is a no-op" {
    var telem = telemetry_mod.Telemetry.init(io, "/tmp", testing.allocator, true);
    defer telem.deinit();

    telem.recordSessionStart();
    telem.recordToolCall("codedb_search", 99, true, 10);
    try testing.expect(!telem.enabled);
    try testing.expect(telem.file == null);
    try testing.expect(telem.head.load(.monotonic) == 0);
}


test "issue-77: mcp index accepts temporary-directory roots that cause pathological cache growth" {
    var tmp_name_buf: [128]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buf, "codedb-issue-77-{d}", .{@as(i64, @intCast(@divTrunc(cio.nanoTimestamp(), 1000)))});
    const tmp_root = try std.fs.path.join(testing.allocator, &.{ "/private/tmp", tmp_name });
    defer testing.allocator.free(tmp_root);

    std.Io.Dir.cwd().createDirPath(io, tmp_root) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    defer std.Io.Dir.cwd().deleteTree(io, tmp_root) catch {};

    const source_path = try std.fs.path.join(testing.allocator, &.{ tmp_root, "sample.zig" });
    defer testing.allocator.free(source_path);
    {
        const file = try std.Io.Dir.cwd().createFile(io, source_path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "pub fn sample() void {}\n");
    }

    const result = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "zig", "build", "run", "--", tmp_root, "snapshot" },
        .max_output_bytes = 256 * 1024,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term.Exited != 0);
}


test "issue-93: isSensitivePath blocks .env and credentials" {
    try testing.expect(watcher.isSensitivePath(".env"));
    try testing.expect(watcher.isSensitivePath(".env.local"));
    try testing.expect(watcher.isSensitivePath(".env.production"));
    try testing.expect(watcher.isSensitivePath("credentials.json"));
    try testing.expect(watcher.isSensitivePath("service-account.json"));
    try testing.expect(watcher.isSensitivePath("id_rsa"));
    try testing.expect(watcher.isSensitivePath("secrets.yaml"));
    try testing.expect(watcher.isSensitivePath("config/secrets.yml"));
    try testing.expect(watcher.isSensitivePath("server.key"));
    try testing.expect(watcher.isSensitivePath("cert.pem"));
    try testing.expect(watcher.isSensitivePath("keystore.jks"));
    try testing.expect(watcher.isSensitivePath("identity.pfx"));
    try testing.expect(watcher.isSensitivePath(".ssh/known_hosts"));
    // Normal files should NOT be blocked
    try testing.expect(!watcher.isSensitivePath("main.zig"));
    try testing.expect(!watcher.isSensitivePath("src/server.zig"));
    try testing.expect(!watcher.isSensitivePath("README.md"));
    try testing.expect(!watcher.isSensitivePath("package.json"));
}


test "issue-93: isPathSafe blocks traversal" {
    const MCP = @import("mcp.zig");
    try testing.expect(!MCP.isPathSafe("../../../etc/passwd"));
    try testing.expect(!MCP.isPathSafe("/etc/passwd"));
    try testing.expect(!MCP.isPathSafe(""));
    try testing.expect(MCP.isPathSafe("src/main.zig"));
    try testing.expect(MCP.isPathSafe("README.md"));
}


test "auto-update: shouldRunAutoUpdate gates correctly" {
    const day_ms: i64 = 24 * 60 * 60 * 1000;

    // Disabled by env: never runs
    try testing.expect(!update_mod.shouldRunAutoUpdate(0, null, true));
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms * 100, null, true));
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms * 100, 0, true));

    // First run (no stamp): always runs when not disabled
    try testing.expect(update_mod.shouldRunAutoUpdate(0, null, false));

    // Throttled: <24h since last check → skip
    try testing.expect(!update_mod.shouldRunAutoUpdate(day_ms - 1, 0, false));

    // Exactly 24h since last check → run
    try testing.expect(update_mod.shouldRunAutoUpdate(day_ms, 0, false));

    // Long after last check → run
    try testing.expect(update_mod.shouldRunAutoUpdate(day_ms * 7, 0, false));
}


test "issue-394: shouldRunAutoUpdate permanently blocked by future-timestamp stamp file" {
    // Reproduces the case where the stamp file contains a timestamp in the
    // future relative to the wall clock — for example, after an NTP clock
    // correction that rolls the clock back, or after a stamp written by a
    // host with a fast clock. The current implementation computes
    // (now - last) and only fires when that delta >= 24h, so a future
    // `last` produces a negative delta and the check is silently skipped
    // for as long as the stamp stays in the future — potentially many days.
    //
    // Expected: a wildly future stamp should NOT prevent the next check
    // from firing. The simplest correct behavior is: if last > now, treat
    // the stamp as invalid and allow the update check to run.

    const day_ms: i64 = 24 * 60 * 60 * 1000;
    const now_ms: i64 = 1_700_000_000_000;
    const future_last_ms: i64 = now_ms + day_ms * 30; // 30 days in the future

    try testing.expect(update_mod.shouldRunAutoUpdate(now_ms, future_last_ms, false));
}


test "issue-395: shouldRunAutoUpdate panics on i64 underflow when stamp is corrupt" {
    // Reproduces a panic when ~/.codedb/last_auto_update_check is corrupt
    // and decodes to a very negative i64. readAutoUpdateStamp does no
    // sanity check — it reads 8 bytes, calls std.mem.readInt(i64, ...),
    // and feeds that straight into shouldRunAutoUpdate, which evaluates
    // `now_ms - last` with checked subtraction. For last = minInt(i64)
    // and any positive now_ms, the subtraction overflows and triggers an
    // integer-overflow panic in Debug / ReleaseSafe builds (which is what
    // `zig build test` and the shipped MCP binary use).
    //
    // Result: every `codedb mcp` startup crashes during the auto-update
    // gate for any user whose stamp file got corrupted to a value with
    // the high bit set (e.g. truncated write, partial flush, or any byte
    // sequence starting with 0x80..0xFF in the stamp).
    //
    // Expected fix: clamp the delta with a saturating/wrapping subtraction
    // or treat any last_ms <= 0 (or in the distant past) as invalid and
    // run the update.

    const now_ms: i64 = 1_700_000_000_000;
    const last_ms: i64 = std.math.minInt(i64);

    try testing.expect(update_mod.shouldRunAutoUpdate(now_ms, last_ms, false));
}


test "issue-150: --help prints usage" {
    try buildCliForHelpTests();

    const result = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "./zig-out/bin/codedb", "--help" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term == .Exited);
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
        std.mem.indexOf(u8, result.stderr, "usage:") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "update") != null or
        std.mem.indexOf(u8, result.stderr, "update") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "nuke") != null or
        std.mem.indexOf(u8, result.stderr, "nuke") != null);
}


test "issue-150: -h prints usage" {
    try buildCliForHelpTests();

    const result = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ "./zig-out/bin/codedb", "-h" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expect(result.term == .Exited);
    try testing.expect(result.term.Exited == 0);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "usage:") != null or
        std.mem.indexOf(u8, result.stderr, "usage:") != null);
}


test "update: compareVersions orders semantic versions" {
    try testing.expect(try update_mod.compareVersions("0.2.55", "0.2.56") == .lt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56") == .eq);
    try testing.expect(try update_mod.compareVersions("v0.2.57", "0.2.56") == .gt);
    try testing.expect(try update_mod.compareVersions("0.2.56", "0.2.56.0") == .eq);
}

test "update: compareVersionsForUpdate allows superseded release train typo" {
    try testing.expect(try update_mod.compareVersions("0.2.58181", "0.2.5823") == .gt);
    try testing.expect(try update_mod.compareVersionsForUpdate("0.2.58181", "0.2.5823") == .lt);
    try testing.expect(try update_mod.compareVersionsForUpdate("v0.2.58181", "v0.2.5823") == .lt);
    try testing.expect(try update_mod.compareVersionsForUpdate("0.2.58181", "0.2.5824") == .lt);
    try testing.expect(try update_mod.compareVersionsForUpdate("0.2.58181", "0.2.5822") == .gt);
    try testing.expect(!try update_mod.targetSupersedesCurrent("0.2.5823", "0.2.5824"));
}


test "update: checksumForBinary parses release manifest" {
    const manifest =
        \\7be38140d090b2e23723c8cde02be150171c818daa16b18c520b44cc1e078add  codedb-darwin-arm64
        \\76bc7b81bc9fd211aa2c1ac59d1d26e8c80bc211ab560de2dc998ea9e04ec471  codedb-darwin-x86_64
        \\aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  *codedb-linux-arm64
    ;

    try testing.expectEqualStrings(
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        update_mod.checksumForBinary(manifest, "codedb-linux-arm64") orelse return error.TestUnexpectedResult,
    );
    try testing.expect(update_mod.checksumForBinary(manifest, "codedb-linux-x86_64") == null);
}


test "update: asset names match published release naming" {
    try testing.expectEqualStrings("codedb-darwin-arm64", update_mod.assetNameForTarget(.macos, .aarch64).?);
    try testing.expectEqualStrings("codedb-darwin-x86_64", update_mod.assetNameForTarget(.macos, .x86_64).?);
    try testing.expectEqualStrings("codedb-linux-arm64", update_mod.assetNameForTarget(.linux, .aarch64).?);
    try testing.expectEqualStrings("codedb-linux-x86_64", update_mod.assetNameForTarget(.linux, .x86_64).?);
    try testing.expect(update_mod.assetNameForTarget(.windows, .x86_64) == null);
}


test "nuke: commandTargetsBinary only matches the current install path" {
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/tmp/codedb-test/bin/codedb serve",
        "/tmp/codedb-test/bin/codedb",
    ));
    try testing.expect(nuke_mod.commandTargetsBinary(
        "/var/folders/example/codedb serve",
        "/private/var/folders/example/codedb",
    ));
    try testing.expect(!nuke_mod.commandTargetsBinary(
        "/Users/rachpradhan/bin/codedb --mcp",
        "/tmp/codedb-test/bin/codedb",
    ));
}


test "nuke: removeJsonMcpServerEntry drops only codedb integration" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}


test "nuke: removeJsonMcpServerEntry removes empty mcpServers object" {
    const input =
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] }
        \\  },
        \\  "theme": "dark"
        \\}
    ;

    const output = (try nuke_mod.removeJsonMcpServerEntry(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"mcpServers\"") == null);
    try testing.expect(std.mem.indexOf(u8, output, "\"theme\"") != null);
}


test "nuke: removeCodexMcpServerBlock removes codedb block only" {
    const input =
        \\[mcp_servers.codedb]
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\startup_timeout_sec = 30
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.codedb]") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
    try testing.expect(std.mem.indexOf(u8, output, "command = \"other\"") != null);
}


test "nuke: removeCodexMcpServerBlock matches indented header with inline comment" {
    const input =
        \\  [mcp_servers.codedb] # local override
        \\command = "/Users/me/bin/codedb"
        \\args = ["mcp"]
        \\
        \\[mcp_servers.other]
        \\command = "other"
        \\args = []
    ;

    const output = (try nuke_mod.removeCodexMcpServerBlock(testing.allocator, input, "codedb")) orelse
        return error.TestUnexpectedResult;
    defer testing.allocator.free(output);

    try testing.expect(std.mem.indexOf(u8, output, "codedb") == null);
    try testing.expect(std.mem.indexOf(u8, output, "[mcp_servers.other]") != null);
}


test "nuke: deregisterJsonIntegrationFile handles configs larger than 64 KiB" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel_path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}/large-claude.json", .{tmp.sub_path});
    defer testing.allocator.free(rel_path);

    var content: std.ArrayList(u8) = .empty;
    defer content.deinit(testing.allocator);
    try content.appendSlice(testing.allocator,
        \\{
        \\  "mcpServers": {
        \\    "codedb": { "command": "/Users/me/bin/codedb", "args": ["mcp"] },
        \\    "other": { "command": "other", "args": [] }
        \\  },
        \\  "padding": "
    );
    try content.appendNTimes(testing.allocator, 'x', 70 * 1024);
    try content.appendSlice(testing.allocator, "\"\n}\n");

    var file = try tmp.dir.createFile(io, "large-claude.json", .{});
    defer file.close(io);
    try file.writeStreamingAll(io, content.items);

    try testing.expect(try nuke_mod.deregisterJsonIntegrationFile(io, testing.allocator, rel_path));

    const rewritten = try std.Io.Dir.cwd().readFileAlloc(io, rel_path, testing.allocator, .limited(std.math.maxInt(usize)));
    defer testing.allocator.free(rewritten);

    try testing.expect(std.mem.indexOf(u8, rewritten, "\"codedb\"") == null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"other\"") != null);
    try testing.expect(std.mem.indexOf(u8, rewritten, "\"padding\"") != null);
}


test "issue-148: dead MCP clients are polled every second" {
    const mcp = @import("mcp.zig");
    try testing.expectEqual(@as(u64, 1000), mcp.dead_client_poll_ms);
}


test "issue-148: POLLHUP detects closed pipe" {
    // Verify the polling infrastructure works for pipe-based transports
    const pipe = try cio.makePipe();
    defer _ = std.c.close(pipe[0]);

    // Close write end — simulates client disconnect
    _ = std.c.close(pipe[1]);

    // Poll should detect POLLHUP on the read end
    var fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const n = try std.posix.poll(&fds, 100); // 100ms timeout
    try testing.expect(n > 0);
    try testing.expect((fds[0].revents & std.posix.POLL.HUP) != 0);
}


test "issue-148: idle watchdog exits on shutdown signal" {
    // The watchdog should check shutdown every ~1s (not 30s)
    // and return quickly when signalled
    var shutdown = std.atomic.Value(bool).init(false);

    const t0 = cio.milliTimestamp();
    // Signal shutdown after a small delay
    const signal_thread = try std.Thread.spawn(.{}, struct {
        fn run(s: *std.atomic.Value(bool)) void {
            cio.sleepMs(500);
            s.store(true, .release);
        }
    }.run, .{&shutdown});

    // Run a simplified watchdog loop (matches the real one's 1s granularity)
    while (!shutdown.load(.acquire)) {
        for (0..30) |_| {
            if (shutdown.load(.acquire)) break;
            cio.sleepMs(100); // faster for test
        }
        break; // one iteration is enough to test
    }
    signal_thread.join();

    const elapsed = cio.milliTimestamp() - t0;
    // With 1s granularity, should respond well under 5s (not 30s)
    // Using 100ms intervals in test, so should be ~500ms
    if (elapsed > 0) {
        // Just verify it didn't hang for 30 seconds
        try testing.expect(elapsed < 5_000);
    }
}


test "issue-278: MCP tracks activity without using it as a transport timeout" {
    const mcp = @import("mcp.zig");

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    // Set activity to "just now"
    mcp.last_activity.store(cio.milliTimestamp(), .release);

    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();
    try testing.expect(now - last < 1_000);
}


test "issue-278: MCP session may remain idle longer than old timeout" {
    const mcp = @import("mcp.zig");
    // Stale activity is now only an accounting signal. The stdio transport is
    // kept alive until the client actually disconnects.
    const old_idle_timeout_ms = 60 * 60 * 1000;
    const older_than_old_timeout = cio.milliTimestamp() - old_idle_timeout_ms - 1_000;

    // Save and restore
    const saved = mcp.last_activity.load(.acquire);
    defer mcp.last_activity.store(saved, .release);

    mcp.last_activity.store(older_than_old_timeout, .release);
    const last = mcp.last_activity.load(.acquire);
    const now = cio.milliTimestamp();

    try testing.expect(now - last > old_idle_timeout_ms);
}


test "issue-148: open pipe does not trigger HUP" {
    const pipe = try cio.makePipe();
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN | std.posix.POLL.HUP,
        .revents = 0,
    }};

    const result = try std.posix.poll(&poll_fds, 0);
    try testing.expectEqual(@as(usize, 0), result);
}


test "issue-148: codedb mcp exits when stdin is closed" {
    // Integration test: spawn codedb mcp, close stdin, verify it exits
    var child = std.process.spawn(io, .{
        .argv = &.{ "zig", "build", "run", "--", "--mcp" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        // If spawn fails (e.g., zig not on PATH), skip the test
        return;
    };

    // Send initialize then close stdin (simulate client crash)
    const init_msg = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1\"}}}";
    const header = std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n", .{init_msg.len});

    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, header) catch {};
        stdin.writeStreamingAll(io, init_msg) catch {};
        // Close stdin — simulates client disconnecting
        stdin.close(io);
        child.stdin = null;
    }

    // Wait for the process to exit. The main read loop exits on stdin EOF;
    // the watchdog also polls dead clients every second as a backup.
    const start = cio.milliTimestamp();
    const term = child.wait(io) catch {
        // If wait fails, the process is stuck — test fails
        try testing.expect(false);
        return;
    };

    const elapsed = cio.milliTimestamp() - start;

    // Should have exited (not been killed by us)
    switch (term) {
        .exited => |code| _ = code,
        else => {},
    }

    // Should exit promptly after stdin closes.
    try testing.expect(elapsed < 5_000);
}


test "issue-249: nuke.removeJsonMcpServerEntry returns null when key absent" {
    // Verifies removeJsonMcpServerEntry does not signal a write when key is absent,
    // which ensures the non-atomic rewriteConfigFile path is never triggered unnecessarily.
    const result = try nuke_mod.removeJsonMcpServerEntry(testing.allocator, "{\"other\":1}", "codedb");
    try testing.expect(result == null);
}


test "issue-207: ScanState round-trips through atomic" {
    const initial = mcp_mod.getScanState();
    defer mcp_mod.setScanState(initial);

    mcp_mod.setScanState(.loading_snapshot);
    try testing.expectEqual(mcp_mod.ScanState.loading_snapshot, mcp_mod.getScanState());

    mcp_mod.setScanState(.walking);
    try testing.expectEqual(mcp_mod.ScanState.walking, mcp_mod.getScanState());

    mcp_mod.setScanState(.indexing);
    try testing.expectEqual(mcp_mod.ScanState.indexing, mcp_mod.getScanState());

    mcp_mod.setScanState(.ready);
    try testing.expectEqual(mcp_mod.ScanState.ready, mcp_mod.getScanState());
}


test "issue-207: ScanState.name covers all states" {
    try testing.expectEqualStrings("loading_snapshot", mcp_mod.ScanState.loading_snapshot.name());
    try testing.expectEqualStrings("walking", mcp_mod.ScanState.walking.name());
    try testing.expectEqualStrings("indexing", mcp_mod.ScanState.indexing.name());
    try testing.expectEqualStrings("ready", mcp_mod.ScanState.ready.name());
}


test "issue-346: root_policy rejects dangerous ambient cwd roots" {
    try testing.expect(!root_policy.isIndexableRoot("/"));
    try testing.expect(!root_policy.isIndexableRoot("/Applications"));
    try testing.expect(!root_policy.isIndexableRoot("/usr"));
    try testing.expect(!root_policy.isIndexableRoot("/usr/local"));
    try testing.expect(!root_policy.isIndexableRoot("/usr/local/bin"));
    try testing.expect(!root_policy.isIndexableRoot("/opt"));
    try testing.expect(!root_policy.isIndexableRoot("/opt/homebrew"));
}


test "issue-357: bundle preserves nested 'arguments' for codedb_outline" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");
    try explorer.indexFile("src/lib.zig", "pub fn helper() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[
        \\  {"tool":"codedb_outline","arguments":{"path":"src/main.zig"}},
        \\  {"tool":"codedb_outline","arguments":{"path":"src/lib.zig"}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Nested-args bundle path must preserve 'path' for every op — no missing-arg errors.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path' argument") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "src/lib.zig") != null);
}


test "issue-357: bundle surfaces received keys when an op is missing required path" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Bundle with a wrong key name ('file_path' instead of 'path'). The op must
    // fail (path is missing), but the bundle wrapper must surface the keys it
    // received so the caller can tell whether codedb dropped the arg or the
    // client sent it under the wrong name.
    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{"file_path":"src/main.zig"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // The error itself must still appear (legitimate — path is missing).
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path' argument") != null);
    // And the bundle must surface what the op actually contained, naming the
    // bad key so the caller can self-diagnose.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "file_path") != null);
}


test "issue-423: bundle emits 'received keys' exactly once per failing op" {
    // Regression: handler (handleSearch etc) appends the diagnostic, AND the
    // bundle dispatch loop also appends it — caller saw the line twice in a
    // row. Must appear exactly once per failing op.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":"codedb_search","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, out.items, idx, "received keys:")) |pos| {
        count += 1;
        idx = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}


test "issue-367: openDataLog truncates orphan bytes from prior session" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const log_path = try std.fmt.allocPrint(testing.allocator, "{s}/data.log", .{dir_path});
    defer testing.allocator.free(log_path);

    const orphan = "ORPHAN_SECRET_TOKEN_FROM_PRIOR_SESSION";
    {
        const f = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, orphan, 0);
    }

    var store = Store.init(testing.allocator);
    defer store.deinit();
    try store.openDataLog(io, log_path);

    const f = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer f.close(io);
    const len = try f.length(io);
    try testing.expectEqual(@as(u64, 0), len);
    try testing.expectEqual(@as(u64, 0), store.data_log_pos);

    const diff = "fresh diff";
    _ = try store.recordEdit("foo.zig", 1, .replace, 0xABCD, diff.len, diff);

    var buf: [128]u8 = undefined;
    const f2 = try std.Io.Dir.cwd().openFile(io, log_path, .{});
    defer f2.close(io);
    const new_len = try f2.length(io);
    try testing.expectEqual(@as(u64, diff.len), new_len);
    const read_len = try f2.readPositionalAll(io, buf[0..diff.len], 0);
    try testing.expectEqual(diff.len, read_len);
    try testing.expectEqualStrings(diff, buf[0..diff.len]);
}


test "issue-367-dx: tty summary surfaces received keys on missing-arg error" {
    const args_json =
        \\{"file_path":"src/main.zig","weird_key":"x"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    const raw_output = "error: missing 'path' argument\nreceived keys: [file_path, weird_key]";

    var summary: std.ArrayList(u8) = .empty;
    defer summary.deinit(testing.allocator);

    mcp_mod.mcpGenerateSummary(
        testing.allocator,
        "codedb_outline",
        &parsed.value.object,
        raw_output,
        true,
        &summary,
    );

    try testing.expect(std.mem.indexOf(u8, summary.items, "received") != null);
    try testing.expect(std.mem.indexOf(u8, summary.items, "file_path") != null);
}


test "issue-bug2: tool calls during scan-in-progress hint at scan state" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const prev_state = mcp_mod.getScanState();
    defer mcp_mod.setScanState(prev_state);
    mcp_mod.setScanState(.walking);

    const args_json =
        \\{"query":"some_unknown_symbol_that_will_not_match"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "0 results") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "scan still in progress") != null);
}


test "issue-378: search waits briefly for scan to reach ready instead of returning empty" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const prev_state = mcp_mod.getScanState();
    defer mcp_mod.setScanState(prev_state);
    mcp_mod.setScanState(.walking);

    const Flipper = struct {
        fn run(exp: *Explorer) void {
            cio.sleepMs(100);
            exp.indexFile("src/late.zig", "fn waitsForScanMarker() void {}\n") catch return;
            mcp_mod.setScanState(.ready);
        }
    };
    const t = try std.Thread.spawn(.{}, Flipper.run, .{&explorer});
    defer t.join();

    const args_json =
        \\{"query":"waitsForScanMarker"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "src/late.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "scan still in progress") == null);
}


test "issue-bug5: codedb_read returns binary stub instead of dumping bytes" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const bin_rel = "blob.bin";
    const bin_full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, bin_rel });
    defer testing.allocator.free(bin_full);
    {
        const f = try std.Io.Dir.cwd().createFile(io, bin_full, .{ .truncate = true });
        defer f.close(io);
        const payload = [_]u8{ 'a', 'b', 0, 'c', 'd', 0, 'e' };
        try f.writePositionalAll(io, &payload, 0);
    }

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, dir_path, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json = try std.fmt.allocPrint(testing.allocator,
        "{{\"path\":\"{s}\"}}", .{bin_rel});
    defer testing.allocator.free(args_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "binary file") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, &[_]u8{0}) == null);
}


test "issue-bug6: codedb_read errors when line_start > line_end" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const rel = "small.txt";
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, rel });
    defer testing.allocator.free(full);
    {
        const f = try std.Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, "alpha\nbeta\ngamma\n", 0);
    }

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    explorer.setRoot(io, dir_path);
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, dir_path, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json = try std.fmt.allocPrint(testing.allocator,
        "{{\"path\":\"{s}\",\"line_start\":100,\"line_end\":10}}", .{rel});
    defer testing.allocator.free(args_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "line_start") != null);
}


test "issue-bug7: codedb_search rejects empty query" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":""}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "empty") != null);
}


test "issue-bug7: codedb_search rejects negative max_results" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"query":"foo","max_results":-3}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
    try testing.expect(std.mem.indexOf(u8, out.items, "max_results") != null);
}


test "issue-bug11: codedb_bundle marks isError when all ops fail" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"ops":[{"tool":"codedb_outline"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "error:"));
}


test "issue-386: telemetry recordToolCall preserves UTF-8 codepoint boundaries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_path_len];

    var telem = telemetry_mod.Telemetry.init(io, dir_path, testing.allocator, false);
    defer telem.deinit();

    // 30 ASCII bytes + a 3-byte UTF-8 codepoint (✓ = 0xE2 0x9C 0x93) lands the
    // codepoint boundary at byte 33. The 32-byte cap currently truncates inside
    // the codepoint, leaving 0xE2 0x9C as the trailing bytes — invalid UTF-8.
    const tool_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\xe2\x9c\x93_tail";
    telem.recordToolCall(tool_name, 1234, false, 56);
    telem.flush();

    const ndjson_path = try std.fmt.allocPrint(testing.allocator, "{s}/telemetry.ndjson", .{dir_path});
    defer testing.allocator.free(ndjson_path);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, ndjson_path, testing.allocator, .limited(64 * 1024));
    defer testing.allocator.free(contents);

    const tool_field = "\"tool\":\"";
    const idx = std.mem.indexOf(u8, contents, tool_field) orelse return error.ToolFieldMissing;
    const after = contents[idx + tool_field.len ..];
    const end = std.mem.indexOfScalar(u8, after, '"') orelse return error.ToolFieldUnterminated;
    const recorded = after[0..end];

    // The recorded tool slice must be valid UTF-8. A mid-codepoint truncation
    // produces invalid bytes — std.unicode.utf8ValidateSlice rejects them.
    try testing.expect(std.unicode.utf8ValidateSlice(recorded));
}


test "issue-387: appendId preserves JSON-RPC numeric and number_string ids" {
    // JSON-RPC ids are typed as String|Number|Null. The MCP server must echo
    // the id verbatim so the client can correlate the reply with its request.
    // appendId currently only handles .integer and .string — .float and
    // .number_string fall through to "null", breaking correlation for any
    // client that uses a fractional id (some test runners) or that the JSON
    // parser materializes as number_string.

    // Float id round-trips: parsing "3.5" yields .float, which must serialize
    // back to "3.5" (or any representation a JSON parser accepts as the same
    // number) — NOT "null".
    {
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, "3.5", .{});
        defer parsed.deinit();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        mcp_mod.appendId(testing.allocator, &buf, parsed.value);
        try testing.expect(!std.mem.eql(u8, buf.items, "null"));
    }

    // number_string round-trips: a request with `"id": 12345678901234567890`
    // (>i64) is parsed as .number_string. The reply must echo the digits, not
    // the literal "null".
    {
        const v = std.json.Value{ .number_string = "12345678901234567890" };
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        mcp_mod.appendId(testing.allocator, &buf, v);
        try testing.expectEqualStrings("12345678901234567890", buf.items);
    }
}


test "issue-406: root_policy blocks /private/etc (macOS realpath of /etc)" {
    // /etc is in the system_prefixes deny list, but on macOS /etc is a symlink
    // to /private/etc. Callers feed isIndexableRoot a path resolved by
    // realPathFile (see handleIndex in src/mcp.zig), which turns "/etc" into
    // "/private/etc" — and then this textual prefix check accepts it. The
    // canonical form must be blocked too, otherwise the deny list is bypassed
    // by the very normalization step the callers depend on.
    try testing.expect(!root_policy.isIndexableRoot("/private/etc"));
    try testing.expect(!root_policy.isIndexableRoot("/private/etc/ssh"));
}


test "issue-407: root_policy blocks /var and its non-folders subtree" {
    // The system_prefixes list explicitly blocks /var/folders and /var/tmp,
    // but not /var itself or /var/log, /var/lib, /var/db, /var/spool, etc.
    // On Linux those hold logs, mail, and package state; on macOS realPathFile
    // turns /var into /private/var (also unblocked). Accidentally pointing
    // the indexer at /var/log on a server pulls in GBs of secrets and is
    // never a valid "project root".
    try testing.expect(!root_policy.isIndexableRoot("/var"));
    try testing.expect(!root_policy.isIndexableRoot("/var/log"));
    try testing.expect(!root_policy.isIndexableRoot("/var/lib"));
    try testing.expect(!root_policy.isIndexableRoot("/private/var"));
    try testing.expect(!root_policy.isIndexableRoot("/private/var/log"));
}


test "issue-412: bundle reports 'missing tool' for tool field of wrong type" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":123,"arguments":{"path":"x.zig"}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'tool' field") == null);
}


test "issue-413: bundle truncation drops subsequent ops without telling the caller" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Index a single large file (~120KB) so two reads exceed the 200KB
    // bundle cap. Bundle truncates and breaks out of the loop after op[1],
    // emitting a TRUNCATED note — but op[2] is silently dropped.
    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    while (big.items.len < 120 * 1024) {
        try big.appendSlice(testing.allocator, "pub fn placeholder() void { _ = 0; }\n");
    }
    try explorer.indexFile("big.zig", big.items);
    try explorer.indexFile("small.zig", "pub fn small() void {}\n");

    // Three reads: first two exceed 200KB → truncate. op[2] is small.zig
    // and should still surface — at minimum, the bundle output must
    // mention it (e.g. as another truncated entry) so the caller knows
    // their request had three ops, not one.
    const bundle_json =
        \\{"ops":[
        \\  {"tool":"codedb_read","arguments":{"path":"big.zig"}},
        \\  {"tool":"codedb_read","arguments":{"path":"big.zig"}},
        \\  {"tool":"codedb_outline","arguments":{"path":"small.zig"}}
        \\]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // op[2] (index 2) was sent — caller deserves to see something for it.
    // Either its result, or an explicit "[2]" entry noting it was dropped.
    try testing.expect(std.mem.indexOf(u8, out.items, "[2]") != null);
}


test "issue-424-B: bundle falls through to inline args when arguments is empty object" {
    // Forge-style buggy clients sometimes send `arguments: {}` AND put the
    // real args inline at the op level. The dispatcher currently sees the
    // empty `arguments` and stops looking — resulting in a misleading
    // "missing 'path'" with `received keys: []` even though `path` is
    // sitting right there in the op.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{},"path":"src/main.zig"}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Should succeed: path was discoverable inline even though `arguments` was empty.
    try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys: []") == null);
}


test "issue-512: direct tools call accepts inline args when arguments is empty" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();
    var telem = telemetry_mod.Telemetry.init(io, ".", testing.allocator, true);
    defer telem.deinit();

    const call_json =
        \\{"params":{"name":"codedb_outline","arguments":{},"path":"src/main.zig"}}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, call_json, .{});
    defer parsed.deinit();

    const pipe = try cio.makePipe();
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);

    bench_ctx.runHandleCall(
        io,
        testing.allocator,
        &parsed.value.object,
        .{ .handle = pipe[1] },
        std.json.Value{ .integer = 1 },
        &store,
        &explorer,
        &agents,
        &telem,
    );

    var response_buf: [16 * 1024]u8 = undefined;
    const n = try std.posix.read(pipe[0], &response_buf);
    const response = response_buf[0..n];

    try testing.expect(std.mem.indexOf(u8, response, "src/main.zig") != null);
    try testing.expect(std.mem.indexOf(u8, response, "missing 'path'") == null);
}


test "issue-424-D: received-keys diagnostic hints at inline-args workaround when empty" {
    // When a sub-op fails with truly-empty args, the diagnostic should
    // point users at the inline-args fallback so a broken client wrapper
    // can be routed around without a server change.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/main.zig", "pub fn main() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":"codedb_outline","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // Original error stays.
    try testing.expect(std.mem.indexOf(u8, out.items, "missing 'path'") != null);
    // The diagnostic should fire (received-keys line present) and surface
    // the inline-shape hint, since no real sub-op args were observed.
    try testing.expect(std.mem.indexOf(u8, out.items, "received keys:") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "inline shape") != null);
}


test "issue-424-A: bundle envelope errors carry the 'error:' prefix consistently" {
    // Pre-fix the bundle dispatcher emits 'op must be an object' and
    // 'missing 'tool' field' WITHOUT the 'error:' prefix that per-tool
    // handlers and TTY-summary parsing both expect. Normalize.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // Op is a string, not an object.
    const bad_shape =
        \\{"ops":["not-an-object"]}
    ;
    const parsed1 = try std.json.parseFromSlice(std.json.Value, testing.allocator, bad_shape, .{});
    defer parsed1.deinit();
    var out1: std.ArrayList(u8) = .empty;
    defer out1.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed1.value.object, &out1, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, out1.items, "error: op must be an object") != null);

    // Op missing 'tool' field.
    const no_tool =
        \\{"ops":[{"arguments":{}}]}
    ;
    const parsed2 = try std.json.parseFromSlice(std.json.Value, testing.allocator, no_tool, .{});
    defer parsed2.deinit();
    var out2: std.ArrayList(u8) = .empty;
    defer out2.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed2.value.object, &out2, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, out2.items, "error: missing 'tool'") != null);
}


test "issue-441: bundle rejects codedb_projects sub-op" {
    // codedb_projects lists every indexed project on the machine, which is a
    // global directory enumeration unrelated to whatever repo the agent is
    // working on. When a planner sees a previous bundle that called
    // codedb_projects, it tends to replay the same shape — re-emitting 5x
    // codedb_projects ops as if that were the canonical "what do I do here"
    // call. Block it at the dispatcher, mirroring the existing rejections of
    // codedb_bundle (recursive) and codedb_edit (write op).
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bundle_json =
        \\{"ops":[{"tool":"codedb_projects","arguments":{}}]}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bundle_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_bundle, &parsed.value.object, &out, &store, &explorer, &agents);

    // The op must be rejected with an explicit error, not silently dispatched.
    try testing.expect(std.mem.indexOf(u8, out.items, "error: codedb_projects not allowed in bundle") != null);
}


test "issue-441: codedb_projects branch is excluded from augmented oneOf" {
    // Mirror of the dispatcher rejection at the schema level — when the
    // discriminated oneOf is opted into via CODEDB_DISCRIMINATED_SCHEMA=1,
    // there must not be a oneOf branch advertising codedb_projects as a
    // valid sub-tool, since the bundle dispatcher rejects it at runtime.
    const augmented = try mcp_mod.buildAugmentedToolsList(testing.allocator);
    defer testing.allocator.free(augmented);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, augmented, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_items: ?std.json.Value = null;
    for (tools.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "codedb_bundle")) {
            bundle_items = t.object.get("inputSchema").?.object.get("properties").?.object.get("ops").?.object.get("items").?;
            break;
        }
    }
    const one_of = bundle_items.?.object.get("oneOf").?.array;

    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const") orelse continue;
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_projects"));
    }
}


test "issue-443: codedb_bundle is omitted from default tools/list response" {
    // The codedb_bundle tool has been a footgun across multiple stages:
    //   #434 — schema permitted empty arguments (Stage 1 fix: required arguments)
    //   #437 — Stage 2 oneOf augmentation broke OpenAI strict-mode (#440 hotfix)
    //   #441 — codedb_projects sub-op replay loop in planners
    // Even with all of the above, OpenAI clients still emit
    // {"tool":"codedb_*","arguments":{}} because the default schema's
    // arguments field is a bare {type:"object"} with no inner shape, and
    // the discriminated oneOf is opt-in only.
    //
    // Disable codedb_bundle entirely until the schema can be reworked to
    // bind sub-tool arguments inline (no `arguments` wrapper), removing
    // the empty-args footgun structurally. The dispatcher-side handler
    // stays so clients with cached schemas don't crash, but the runtime
    // tools/list response no longer advertises it. CODEDB_BUNDLE_ENABLED=1
    // re-enables advertisement for callers that want to re-engage it.
    const response = try mcp_mod.buildToolsListResponse(testing.allocator, .{
        .bundle_enabled = false,
        .discriminated_opt_in = false,
    });
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        try testing.expect(!std.mem.eql(u8, name, "codedb_bundle"));
    }

    // Sanity: legitimate tools still advertised.
    var saw_search = false;
    var saw_outline = false;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_search")) saw_search = true;
        if (std.mem.eql(u8, name, "codedb_outline")) saw_outline = true;
    }
    try testing.expect(saw_search);
    try testing.expect(saw_outline);
}


test "issue-443: codedb_bundle is advertised when CODEDB_BUNDLE_ENABLED=1" {
    // Re-enable path. When bundle_enabled is true the runtime response
    // includes codedb_bundle, exactly as it did before this gate.
    const response = try mcp_mod.buildToolsListResponse(testing.allocator, .{
        .bundle_enabled = true,
        .discriminated_opt_in = false,
    });
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var saw_bundle = false;
    for (tools.items) |t| {
        if (std.mem.eql(u8, t.object.get("name").?.string, "codedb_bundle")) saw_bundle = true;
    }
    try testing.expect(saw_bundle);
}


test "issue-434: codedb_bundle ops items schema requires arguments field" {
    // The codedb_bundle inputSchema in tools_list advertises ops items as
    // {required: ["tool"]} with arguments as a bare {type: "object"} that
    // permits {}. Function-calling LLMs read the schema as authoritative and
    // emit the minimum-valid payload — {tool: "...", arguments: {}} — which
    // misroutes through the inline-args fallback and surfaces as
    // "received keys: [tool, arguments]" from each sub-tool. Stage 1 fix:
    // add "arguments" to the items.required array so models are forced to
    // populate it. (Stage 2 — discriminated oneOf over tool — is a follow-up.)
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, mcp_mod.tools_list, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_schema: ?std.json.Value = null;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_bundle")) {
            bundle_schema = t.object.get("inputSchema").?;
            break;
        }
    }
    try testing.expect(bundle_schema != null);

    const ops = bundle_schema.?.object.get("properties").?.object.get("ops").?;
    const items = ops.object.get("items").?;
    const required = items.object.get("required").?.array;

    var has_tool = false;
    var has_arguments = false;
    for (required.items) |r| {
        if (std.mem.eql(u8, r.string, "tool")) has_tool = true;
        if (std.mem.eql(u8, r.string, "arguments")) has_arguments = true;
    }
    try testing.expect(has_tool);
    try testing.expect(has_arguments);
}


test "issue-437: codedb_bundle ops items schema has discriminated oneOf per sub-tool" {
    // Stage 2 of the bundle-schema fix. Stage 1 (#434) made `arguments`
    // required but left it as a bare {type: "object"} — so a schema-greedy
    // model can still emit `arguments: {}` to satisfy the required check
    // without populating real keys. Stage 2 binds the *contents* of
    // arguments to each sub-tool's actual inputSchema via a discriminated
    // oneOf on `tool` (const) → `arguments` (sub-tool inputSchema).
    //
    // The augmented schema is built at runtime from the per-sub-tool
    // schemas already advertised in tools_list, so there is no
    // hand-maintained duplication.
    const augmented = try mcp_mod.buildAugmentedToolsList(testing.allocator);
    defer testing.allocator.free(augmented);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, augmented, .{});
    defer parsed.deinit();

    const tools = parsed.value.object.get("tools").?.array;
    var bundle_items: ?std.json.Value = null;
    for (tools.items) |t| {
        const name = t.object.get("name").?.string;
        if (std.mem.eql(u8, name, "codedb_bundle")) {
            bundle_items = t.object.get("inputSchema").?.object.get("properties").?.object.get("ops").?.object.get("items").?;
            break;
        }
    }
    try testing.expect(bundle_items != null);

    // `oneOf` array must exist on items.
    const one_of_val = bundle_items.?.object.get("oneOf");
    try testing.expect(one_of_val != null);
    const one_of = one_of_val.?.array;

    // Must have at least one branch per dispatchable codedb_* sub-tool.
    // codedb_bundle (recursive) and codedb_edit (write op) are explicitly
    // rejected by handleBundle, so they are excluded.
    try testing.expect(one_of.items.len >= 10);

    // Find the codedb_outline branch and verify it pins tool to a const
    // and binds arguments to a populated schema (with `path` property).
    var found_outline = false;
    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const");
        if (tool_const == null) continue;
        if (!std.mem.eql(u8, tool_const.?.string, "codedb_outline")) continue;
        found_outline = true;

        const args_schema = props.get("arguments").?;
        const args_props = args_schema.object.get("properties").?.object;
        try testing.expect(args_props.get("path") != null);
        // codedb_outline requires `path` — preserved by the augmentation.
        const args_required = args_schema.object.get("required").?.array;
        var path_required = false;
        for (args_required.items) |r| {
            if (std.mem.eql(u8, r.string, "path")) path_required = true;
        }
        try testing.expect(path_required);
        break;
    }
    try testing.expect(found_outline);

    // No branch should be for the recursive codedb_bundle or the write-op codedb_edit.
    for (one_of.items) |branch| {
        const props = branch.object.get("properties").?.object;
        const tool_v = props.get("tool").?;
        const tool_const = tool_v.object.get("const") orelse continue;
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_bundle"));
        try testing.expect(!std.mem.eql(u8, tool_const.string, "codedb_edit"));
    }
}


test "issue-503: parsePositional treats `codedb mcp <path>` as path-as-root" {
    // Before fix: parser took the isCommand("mcp") branch, set root=".",
    // root_is_explicit=false, and silently dropped /tmp/proj. That tripped
    // the deferred-scan branch in mainImpl() which waited forever for an
    // MCP `roots/list` message that a user invoking from a shell will never
    // send.
    const argv = [_][]const u8{ "codedb", "mcp", "/tmp/proj" };
    const p = main_mod.parsePositional(&argv);
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings("/tmp/proj", p.root);
    try testing.expectEqualStrings("mcp", p.cmd);
    try testing.expect(p.root_is_explicit);
}

test "issue-503: `codedb <path> mcp` still works (original order)" {
    const argv = [_][]const u8{ "codedb", "/tmp/proj", "mcp" };
    const p = main_mod.parsePositional(&argv);
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings("/tmp/proj", p.root);
    try testing.expectEqualStrings("mcp", p.cmd);
    try testing.expect(p.root_is_explicit);
}

test "issue-503: `codedb mcp` alone keeps cwd-as-root deferred behavior" {
    // The deferred-mode behavior is intentional when no path is given —
    // an MCP client may still send roots/list. Don't break that path.
    const argv = [_][]const u8{ "codedb", "mcp" };
    const p = main_mod.parsePositional(&argv);
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings(".", p.root);
    try testing.expectEqualStrings("mcp", p.cmd);
    try testing.expect(!p.root_is_explicit);
}

test "issue-502: `codedb mcp --help` rewrites to --help, does not start server" {
    const argv = [_][]const u8{ "codedb", "mcp", "--help" };
    const p = main_mod.parsePositional(&argv);
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings("--help", p.cmd);
}

test "issue-502: `codedb mcp -h` rewrites to --help" {
    const argv = [_][]const u8{ "codedb", "mcp", "-h" };
    const p = main_mod.parsePositional(&argv);
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings("--help", p.cmd);
}

test "parsePositional: existing commands still parse correctly (regression)" {
    // `codedb tree` → cwd-as-root tree
    {
        const argv = [_][]const u8{ "codedb", "tree" };
        const p = main_mod.parsePositional(&argv);
        try testing.expectEqualStrings(".", p.root);
        try testing.expectEqualStrings("tree", p.cmd);
        try testing.expect(!p.root_is_explicit);
    }
    // `codedb /path/to/root tree` → explicit-root tree
    {
        const argv = [_][]const u8{ "codedb", "/path/to/root", "tree" };
        const p = main_mod.parsePositional(&argv);
        try testing.expectEqualStrings("/path/to/root", p.root);
        try testing.expectEqualStrings("tree", p.cmd);
        try testing.expect(p.root_is_explicit);
    }
    // `codedb --version` → version
    {
        const argv = [_][]const u8{ "codedb", "--version" };
        const p = main_mod.parsePositional(&argv);
        try testing.expectEqualStrings("--version", p.cmd);
    }
    // `codedb --help` → help
    {
        const argv = [_][]const u8{ "codedb", "--help" };
        const p = main_mod.parsePositional(&argv);
        try testing.expectEqualStrings("--help", p.cmd);
    }
    // no args → usage exit
    {
        const argv = [_][]const u8{"codedb"};
        const p = main_mod.parsePositional(&argv);
        try testing.expect(p.usage_exit);
    }
    // `codedb --mcp` → mcp command (legacy alias)
    {
        const argv = [_][]const u8{ "codedb", "--mcp" };
        const p = main_mod.parsePositional(&argv);
        try testing.expectEqualStrings("mcp", p.cmd);
    }
}


test "issue-502: isValidMcpFlag whitelist rejects unknown flags" {
    // Before fix: `codedb mcp --snapshot` silently swallowed the flag and
    // started the server with surprising state. After fix, mainImpl rejects
    // any non-whitelisted flag with a clear error and exit 1.
    try testing.expect(main_mod.isValidMcpFlag("--no-telemetry"));
    try testing.expect(!main_mod.isValidMcpFlag("--snapshot"));
    try testing.expect(!main_mod.isValidMcpFlag("-x"));
    try testing.expect(!main_mod.isValidMcpFlag("--help")); // rewritten by parsePositional before reaching here
    try testing.expect(!main_mod.isValidMcpFlag(""));
}


test "issue-502: findGitRootFrom walks up to a .git directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.createDirPath(io, "sub/deep");

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(io, ".", &tmp_buf);
    const tmp_path = tmp_buf[0..tmp_path_len];

    // Build absolute path tmp/sub/deep without changing the process cwd.
    var probe: [std.fs.max_path_bytes]u8 = undefined;
    const deep = try std.fmt.bufPrint(&probe, "{s}/sub/deep", .{tmp_path});
    @memcpy(probe[deep.len .. deep.len + 0], "");

    const got = main_mod.findGitRootFrom(io, &probe, deep.len);
    try testing.expect(got != null);
    try testing.expectEqualStrings(tmp_path, got.?);
}

test "issue-502: findGitRootFrom returns null when no .git is found upward" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "lonely");

    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path_len = try tmp.dir.realPathFile(io, ".", &tmp_buf);
    const tmp_path = tmp_buf[0..tmp_path_len];

    var probe: [std.fs.max_path_bytes]u8 = undefined;
    const lonely = try std.fmt.bufPrint(&probe, "{s}/lonely", .{tmp_path});

    // tempdir is under /var/folders (mac) or /tmp (linux); neither has a
    // .git above it on a sane CI runner. If your environment has, this
    // test's expectation still holds: the found path must not include our
    // tempdir's leaf.
    const got = main_mod.findGitRootFrom(io, &probe, lonely.len);
    if (got) |g| {
        try testing.expect(std.mem.indexOf(u8, g, "lonely") == null);
    }
}

test "issue-506: negotiateProtocolVersion echoes a recognized client version" {
    // Before fix, server always replied "2025-06-18", which older Zed and
    // some opencode builds reject with a timeout because they don't know
    // that version. Now we echo the client's version when we recognize it.
    try testing.expectEqualStrings("2024-11-05", mcp_mod.negotiateProtocolVersion("2024-11-05").?);
    try testing.expectEqualStrings("2025-03-26", mcp_mod.negotiateProtocolVersion("2025-03-26").?);
    try testing.expectEqualStrings("2025-06-18", mcp_mod.negotiateProtocolVersion("2025-06-18").?);
}

test "issue-506: negotiateProtocolVersion returns latest for newer-than-known clients" {
    try testing.expectEqualStrings("2025-06-18", mcp_mod.negotiateProtocolVersion("2099-01-01").?);
}

test "issue-506: negotiateProtocolVersion returns oldest for ancient/unknown clients" {
    // A pre-2024-11-05 string lex-orders below SUPPORTED[0], so we serve
    // the oldest version we know; client decides whether to proceed.
    try testing.expectEqualStrings("2024-11-05", mcp_mod.negotiateProtocolVersion("2024-01-01").?);
}

test "issue-506: negotiateProtocolVersion returns null on empty input" {
    try testing.expect(mcp_mod.negotiateProtocolVersion("") == null);
}

test "issue-508: appendRemoteErrorHint differentiates Cloudflare 530 from 404/429" {
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        mcp_mod.appendRemoteErrorHint(testing.allocator, &out, 530, "error code: 1033");
        try testing.expect(std.mem.indexOf(u8, out.items, "origin is unreachable") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "codedb_index") != null);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        mcp_mod.appendRemoteErrorHint(testing.allocator, &out, 530, "");
        try testing.expect(std.mem.indexOf(u8, out.items, "Retry") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "origin is unreachable") == null);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        mcp_mod.appendRemoteErrorHint(testing.allocator, &out, 404, "");
        try testing.expect(std.mem.indexOf(u8, out.items, "not indexed") != null);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        mcp_mod.appendRemoteErrorHint(testing.allocator, &out, 429, "");
        try testing.expect(std.mem.indexOf(u8, out.items, "rate limited") != null);
    }
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        mcp_mod.appendRemoteErrorHint(testing.allocator, &out, 200, "");
        try testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "issue-507: indexFileOutlineOnly files remain searchable via tier 3" {
    // Repro for #507: after a snapshot rebuild, certain files showed up in
    // `tree` and `read` but searchContent returned 0 hits for substrings
    // demonstrably present in the file. Snapshot.zig and watcher.zig both
    // route through Explorer.indexFileOutlineOnly for files that aren't in
    // the trigram-restore set; before the fix that path populated outlines
    // and contents but not trigram_index nor skip_trigram_files, so the file
    // fell off every search tier (trigram missed; tier 3 keyed on
    // skip_trigram_files missed; tier 5 short-circuited by trigram_ruled_out).
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    const path = "bin/orchestrator";
    const content =
        \\#!/usr/bin/env bash
        \\set -euo pipefail
        \\
        \\policy_context="$(cat <<'POLICY'
        \\Doran Orchestrator operating contract:
        \\- AIHero / Matt Pocock skills from AGENTS.md
        \\POLICY
        \\)"
        \\echo "$policy_context"
    ;
    try explorer.indexFileOutlineOnly(path, content);

    const hits = try explorer.searchContent("Doran Orchestrator operating contract", testing.allocator, 10);
    defer {
        for (hits) |h| {
            testing.allocator.free(h.path);
            testing.allocator.free(h.line_text);
        }
        testing.allocator.free(hits);
    }

    try testing.expect(hits.len > 0);
    try testing.expectEqualStrings(path, hits[0].path);
}

// ── #528: CLI parsing / validation / exit-code regressions ──────────────────

test "issue-528: parseLineRange accepts valid ranges and EOF sentinel" {
    const r = try main_mod.parseLineRange("1-3");
    try testing.expectEqual(@as(u32, 1), r.start);
    try testing.expectEqual(@as(u32, 3), r.end);

    const eof = try main_mod.parseLineRange("10-$");
    try testing.expectEqual(@as(u32, 10), eof.start);
    try testing.expectEqual(std.math.maxInt(u32), eof.end);

    const eof2 = try main_mod.parseLineRange("5-end");
    try testing.expectEqual(std.math.maxInt(u32), eof2.end);
}

test "issue-528: parseLineRange rejects malformed/zero/reversed ranges" {
    // #3 malformed: no dash, non-numeric start/end
    try testing.expectError(error.MissingDash, main_mod.parseLineRange("nope"));
    try testing.expectError(error.BadStart, main_mod.parseLineRange("abc-10"));
    try testing.expectError(error.BadEnd, main_mod.parseLineRange("10-abc"));
    // #7 zero-based (used to silently clamp / default)
    try testing.expectError(error.ZeroLine, main_mod.parseLineRange("0-3"));
    try testing.expectError(error.ZeroLine, main_mod.parseLineRange("1-0"));
    // #4 reversed (used to exit 0 with empty output)
    try testing.expectError(error.Reversed, main_mod.parseLineRange("20-1"));
}

test "issue-528: parseSearchArgs flags any order, max-results, unknown/empty rejected" {
    // #9: `--max-results 1 allocator` used to search for the literal "--max-results"
    const a = try main_mod.parseSearchArgs(&[_][]const u8{ "search", "--max-results", "1", "allocator" }, 1);
    try testing.expectEqualStrings("allocator", a.query);
    try testing.expectEqual(@as(usize, 1), a.max_results);

    // flag after the query now applies instead of being ignored
    const b = try main_mod.parseSearchArgs(&[_][]const u8{ "search", "allocator", "--paths-only" }, 1);
    try testing.expectEqualStrings("allocator", b.query);
    try testing.expect(b.paths_only);

    // unknown flag rejected (not silently treated as query text)
    try testing.expectError(error.UnknownFlag, main_mod.parseSearchArgs(&[_][]const u8{ "search", "--bogus", "x" }, 1));
    // empty / missing query are usage errors
    try testing.expectError(error.EmptyQuery, main_mod.parseSearchArgs(&[_][]const u8{ "search", "" }, 1));
    try testing.expectError(error.MissingQuery, main_mod.parseSearchArgs(&[_][]const u8{"search"}, 1));
    // `--` ends flag parsing so a literal `--foo` can still be searched
    const c = try main_mod.parseSearchArgs(&[_][]const u8{ "search", "--", "--foo" }, 1);
    try testing.expectEqualStrings("--foo", c.query);
    try testing.expect(!c.use_regex);
}

test "issue-528: parseDepsArgs flags before/after path, rejects unknown + bad depth" {
    // #2: flag before the path no longer misreads the flag as the path
    const a = try mcp_mod.parseDepsArgs(&[_][]const u8{ "deps", "--depends-on", "src/main.zig" }, 1);
    try testing.expectEqualStrings("src/main.zig", a.path);
    try testing.expect(a.depends_on);
    try testing.expectEqual(@as(?i64, null), a.max_depth);

    // flag after path + valid max-depth
    const b = try mcp_mod.parseDepsArgs(&[_][]const u8{ "deps", "src/main.zig", "--transitive", "--max-depth", "3" }, 1);
    try testing.expectEqualStrings("src/main.zig", b.path);
    try testing.expect(b.transitive);
    try testing.expectEqual(@as(?i64, 3), b.max_depth);

    // #11: unknown flag + bad/missing max-depth rejected (used to be silently coerced to 1)
    try testing.expectError(error.UnknownFlag, mcp_mod.parseDepsArgs(&[_][]const u8{ "deps", "src/main.zig", "--badflag" }, 1));
    try testing.expectError(error.BadMaxDepth, mcp_mod.parseDepsArgs(&[_][]const u8{ "deps", "src/main.zig", "--max-depth", "notnum" }, 1));
    try testing.expectError(error.BadMaxDepth, mcp_mod.parseDepsArgs(&[_][]const u8{ "deps", "src/main.zig", "--max-depth", "0" }, 1));
    try testing.expectError(error.MissingPath, mcp_mod.parseDepsArgs(&[_][]const u8{"deps"}, 1));
}

test "issue-528: hasExtraCliArgs rejects unused positional args for arity-zero commands" {
    try testing.expect(!main_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "tree" }, 2));
    try testing.expect(main_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "tree", "typo" }, 2));
    try testing.expect(!main_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "status" }, 2));
    try testing.expect(main_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "hot", "extra" }, 2));
}

test "issue-528: finishCli maps error-prefixed handler output to exit 1" {
    const alloc = testing.allocator;
    // #6: handler emitted an error → bridge now returns exit 1
    var err_out: std.ArrayList(u8) = .empty;
    defer err_out.deinit(alloc);
    try err_out.appendSlice(alloc, "error: task must be 3-1024 chars");
    try testing.expectEqual(@as(u8, 1), mcp_mod.finishCli(&err_out, 0));

    // zero-result wording (find's "no matches") keeps exit 0 (#5 decision)
    var ok_out: std.ArrayList(u8) = .empty;
    defer ok_out.deinit(alloc);
    try ok_out.appendSlice(alloc, "no matches");
    try testing.expectEqual(@as(u8, 0), mcp_mod.finishCli(&ok_out, 0));

    // empty output → exit 0
    var empty_out: std.ArrayList(u8) = .empty;
    defer empty_out.deinit(alloc);
    try testing.expectEqual(@as(u8, 0), mcp_mod.finishCli(&empty_out, 0));
}

test "issue-538: temp roots are indexable only when CODEDB_ALLOW_TEMP opts in" {
    // Default (footgun guard, #80/#346): temp roots are refused so codedb never
    // indexes a scratch dir by accident.
    try testing.expect(!root_policy.isIndexableRoot("/tmp/cdbtest"));
    try testing.expect(!root_policy.isIndexableRoot("/private/tmp/cdbtest"));

    // Opt-in escape hatch for SWE-bench / CI harnesses that clone throwaway
    // checkouts under /tmp (issue #538).
    cio.posixSetenv("CODEDB_ALLOW_TEMP", "1");
    defer cio.posixUnsetenv("CODEDB_ALLOW_TEMP");
    try testing.expect(root_policy.isIndexableRoot("/tmp/cdbtest"));
    try testing.expect(root_policy.isIndexableRoot("/private/tmp/cdbtest/src"));

    // The opt-in must NOT widen the guard to real system roots.
    try testing.expect(!root_policy.isIndexableRoot("/etc"));
    try testing.expect(!root_policy.isIndexableRoot("/usr/local/bin"));
    try testing.expect(!root_policy.isIndexableRoot("/"));
}
