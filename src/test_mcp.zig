const std = @import("std");
const builtin = @import("builtin");
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
const cli_args_mod = @import("cli_args.zig");
const out_mod = @import("out.zig");
const query_mod = @import("query.zig");
const cli_proxy_mod = @import("cli_proxy.zig");
const bootstrap_mod = @import("bootstrap.zig");
const background_mod = @import("background.zig");
const commands_mod = @import("commands.zig");
const mcp_json = @import("mcp_json.zig");
comptime {
    _ = @import("config.zig");
}

test "mcp json: line reader preserves newline and EOF framing" {
    var reader: std.Io.Reader = .fixed("first\nlast");

    const first = mcp_json.readLineBuf(testing.allocator, &reader) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("first", first);

    const last = mcp_json.readLineBuf(testing.allocator, &reader) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(last);
    try testing.expectEqualStrings("last", last);
    try testing.expect(mcp_json.readLineBuf(testing.allocator, &reader) == null);
}

test "mcp json: line reader enforces maximum message size" {
    const exact = try testing.allocator.alloc(u8, mcp_json.MAX_LINE);
    defer testing.allocator.free(exact);
    @memset(exact, 'x');
    var exact_reader: std.Io.Reader = .fixed(exact);
    const accepted = mcp_json.readLineBuf(testing.allocator, &exact_reader) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(accepted);
    try testing.expectEqual(exact.len, accepted.len);

    const oversized = try testing.allocator.alloc(u8, mcp_json.MAX_LINE + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'y');
    var oversized_reader: std.Io.Reader = .fixed(oversized);
    try testing.expect(mcp_json.readLineBuf(testing.allocator, &oversized_reader) == null);
}

test "mcp json: typed fields and escaping preserve protocol behavior" {
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"name":"codedb","count":7,"enabled":true,"other":null}
    , .{});
    defer parsed.deinit();
    const object = &parsed.value.object;
    try testing.expectEqualStrings("codedb", mcp_json.getStr(object, "name").?);
    try testing.expectEqual(@as(i64, 7), mcp_json.getInt(object, "count").?);
    try testing.expect(mcp_json.getBool(object, "enabled"));
    try testing.expect(mcp_json.getStr(object, "count") == null);
    try testing.expect(mcp_json.getInt(object, "name") == null);
    try testing.expect(!mcp_json.getBool(object, "missing"));

    var escaped: std.ArrayList(u8) = .empty;
    defer escaped.deinit(testing.allocator);
    mcp_json.writeEscaped(testing.allocator, &escaped, "plain \"quote\" \\ slash\n\r\t\x00\x08\x0c\x1f");
    try testing.expectEqualStrings(
        "plain \\\"quote\\\" \\\\ slash\\n\\r\\t\\u0000\\u0008\\u000c\\u001f",
        escaped.items,
    );
}

fn zigExe() []const u8 {
    return "zig";
}

fn builtCodedbExe() []const u8 {
    return if (builtin.os.tag == .windows) ".\\zig-out\\bin\\codedb.exe" else "./zig-out/bin/codedb";
}

const EnvVarGuard = struct {
    name: []const u8,
    had_prev: bool,
    prev_len: usize,
    prev: [4096]u8,

    fn save(name: []const u8) EnvVarGuard {
        var g = EnvVarGuard{ .name = name, .had_prev = false, .prev_len = 0, .prev = undefined };
        if (cio.posixGetenv(name)) |v| {
            if (v.len <= g.prev.len) {
                @memcpy(g.prev[0..v.len], v);
                g.prev_len = v.len;
                g.had_prev = true;
            }
        }
        return g;
    }

    fn restore(self: *const EnvVarGuard) void {
        if (self.had_prev) {
            cio.posixSetenv(self.name, self.prev[0..self.prev_len]);
        } else {
            cio.posixUnsetenv(self.name);
        }
    }
};

test "windows runCapture resolves executables from safe PATH entries only" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin");
    try tmp.dir.createDirPath(io, "repo");
    var exe = try tmp.dir.createFile(io, "bin/git.exe", .{});
    exe.close(io);
    var planted_bat = try tmp.dir.createFile(io, "repo/git.bat", .{});
    planted_bat.close(io);

    var bin_buf: [std.fs.max_path_bytes]u8 = undefined;
    const bin_len = try tmp.dir.realPathFile(io, "bin", &bin_buf);
    const bin_abs = bin_buf[0..bin_len];

    const old_path = EnvVarGuard.save("PATH");
    defer old_path.restore();
    const test_path = try std.fmt.allocPrint(testing.allocator, ".;relative;{s}", .{bin_abs});
    defer testing.allocator.free(test_path);
    cio.posixSetenv("PATH", test_path);

    const resolved = try cio.resolveExecutableFromPathWindows(testing.allocator, "git") orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(resolved);
    try testing.expect(std.mem.endsWith(u8, resolved, "git.exe"));
    try testing.expect(std.mem.startsWith(u8, resolved, bin_abs));

    try testing.expect((try cio.resolveExecutableFromPathWindows(testing.allocator, "git.bat")) == null);
    try testing.expect((try cio.resolveExecutableFromPathWindows(testing.allocator, ".\\git.exe")) == null);
}

test "windows cli pipe metadata parser rejects spoofable records" {
    const owner = "pid=123\npipe=\\\\.\\pipe\\codedb-123-deadbeef\n";
    const ok = cli_proxy_mod.parseCliPipeMetadata(owner) orelse return error.TestUnexpectedResult;
    try testing.expect(ok.pid == 123);
    try testing.expect(std.mem.eql(u8, ok.pipe_name, "\\\\.\\pipe\\codedb-123-deadbeef"));
    try testing.expect(cli_proxy_mod.cliPipeMetadataMatchesOwner(owner, 123, "\\\\.\\pipe\\codedb-123-deadbeef"));
    try testing.expect(!cli_proxy_mod.cliPipeMetadataMatchesOwner(owner, 124, "\\\\.\\pipe\\codedb-123-deadbeef"));
    try testing.expect(!cli_proxy_mod.cliPipeMetadataMatchesOwner(owner, 123, "\\\\.\\pipe\\codedb-other"));

    try testing.expect(cli_proxy_mod.parseCliPipeMetadata("pid=0\npipe=\\\\.\\pipe\\codedb-x\n") == null);
    try testing.expect(cli_proxy_mod.parseCliPipeMetadata("pid=123\npipe=\\\\.\\pipe\\other\n") == null);
    try testing.expect(cli_proxy_mod.parseCliPipeMetadata("pipe=\\\\.\\pipe\\codedb-x\n") == null);
}

fn buildCliForHelpTests() !void {
    const build = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ zigExe(), "build", "--global-cache-dir", ".zig-global-cache" },
        .max_output_bytes = 8192,
    });
    defer testing.allocator.free(build.stdout);
    defer testing.allocator.free(build.stderr);

    try testing.expect(build.term == .Exited);
    try testing.expect(build.term.Exited == 0);
}

test "windows cli-daemon auto-spawn proxies next query from unicode root" {
    // POSIX uses the Unix-socket daemon path. This test exercises the Windows
    // behavior-equivalent path: detached CreateProcessW startup plus named-pipe
    // proxying for the next process.
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    try buildCliForHelpTests();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "project-unicode-å/src");
    try tmp.dir.createDirPath(io, ".home");

    {
        const f = try tmp.dir.createFile(io, "project-unicode-å/src/sample.zig", .{ .truncate = true });
        defer f.close(io);
        try f.writeStreamingAll(io, "pub fn sampleSymbolForDaemon() void {}\n");
    }

    var project_buf: [std.fs.max_path_bytes]u8 = undefined;
    const project_len = try tmp.dir.realPathFile(io, "project-unicode-å", &project_buf);
    const project_root = project_buf[0..project_len];

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home_len = try tmp.dir.realPathFile(io, ".home", &home_buf);
    const test_home = home_buf[0..home_len];

    const g_allow = EnvVarGuard.save("CODEDB_ALLOW_TEMP");
    defer g_allow.restore();
    const g_idle = EnvVarGuard.save("CODEDB_CLI_DAEMON_IDLE_MS");
    defer g_idle.restore();
    const g_home = EnvVarGuard.save("HOME");
    defer g_home.restore();
    const g_profile = EnvVarGuard.save("USERPROFILE");
    defer g_profile.restore();
    cio.posixSetenv("CODEDB_ALLOW_TEMP", "1");
    cio.posixSetenv("CODEDB_CLI_DAEMON_IDLE_MS", "750");
    cio.posixSetenv("HOME", test_home);
    cio.posixSetenv("USERPROFILE", test_home);

    const cold = try cio.runCapture(.{
        .allocator = testing.allocator,
        .argv = &.{ builtCodedbExe(), project_root, "status" },
        .max_output_bytes = 64 * 1024,
    });
    defer testing.allocator.free(cold.stdout);
    defer testing.allocator.free(cold.stderr);
    try testing.expect(cold.term == .Exited);
    try testing.expectEqual(@as(u8, 0), cold.term.Exited);

    var warm_seen = false;
    var attempts: usize = 0;
    while (attempts < 20) : (attempts += 1) {
        cio.sleepMs(150);
        const warm = try cio.runCapture(.{
            .allocator = testing.allocator,
            .argv = &.{ builtCodedbExe(), project_root, "find", "sampleSymbolForDaemon" },
            .max_output_bytes = 64 * 1024,
        });
        defer testing.allocator.free(warm.stdout);
        defer testing.allocator.free(warm.stderr);

        if (warm.term == .Exited and warm.term.Exited == 0 and
            std.mem.indexOf(u8, warm.stdout, "src/sample.zig") != null and
            std.mem.indexOf(u8, warm.stdout, "loaded snapshot") == null)
        {
            warm_seen = true;
            break;
        }
    }

    // Let the short-idle detached daemon release files before tmp cleanup on Windows.
    cio.sleepMs(900);
    try testing.expect(warm_seen);
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
    // /private/tmp is macOS's canonical temp root; it doesn't exist on Linux
    // (creating it needs root, so this test could never pass there — caught by
    // the first full Linux suite run). /tmp is the same policy-denied class;
    // Windows keeps the original spelling.
    const tmp_base = if (builtin.os.tag == .linux) "/tmp" else "/private/tmp";
    const tmp_root = try std.fs.path.join(testing.allocator, &.{ tmp_base, tmp_name });
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

test "issue-629: projectRelPath accepts absolute paths inside the project root" {
    const MCP = @import("mcp.zig");
    const root = "/Users/dev/project";

    // Regression: codedb returned "path traversal not allowed" for ANY absolute
    // path, so agents that hold absolute paths abandoned codedb for bash (see
    // the #626 trajectory: codedb!,codedb! then seven bash calls). An absolute
    // path inside the project root must resolve to its project-relative form.
    try testing.expectEqualStrings("src/main.zig", MCP.projectRelPath("/Users/dev/project/src/main.zig", root).?);
    // A safe relative path passes through unchanged.
    try testing.expectEqualStrings("src/main.zig", MCP.projectRelPath("src/main.zig", root).?);

    // Security must still hold:
    try testing.expect(MCP.projectRelPath("/etc/passwd", root) == null); // outside the root
    try testing.expect(MCP.projectRelPath("/Users/dev/project/../secret", root) == null); // escapes via ..
    try testing.expect(MCP.projectRelPath("../../../etc/passwd", root) == null); // relative traversal
    try testing.expect(MCP.projectRelPath("/Users/dev/projectile/secret", root) == null); // sibling prefix, not a child
}

test "issue-624: convergence governor flags a repeated identical call" {
    const MCP = @import("mcp.zig");
    var gov: MCP.ConvergenceGovernor = .{};
    const sig: u64 = 0xC0FFEE;
    try testing.expectEqual(@as(usize, 1), gov.record(sig));
    try testing.expectEqual(@as(usize, 2), gov.record(sig));
    // Third identical call reaches the warn threshold — the loop is detected.
    try testing.expectEqual(@as(usize, 3), gov.record(sig));
    try testing.expect(gov.record(sig) >= MCP.ConvergenceGovernor.WARN_AT);

    // Distinct calls in sequence are never flagged as looping.
    var gov2: MCP.ConvergenceGovernor = .{};
    try testing.expectEqual(@as(usize, 1), gov2.record(1));
    try testing.expectEqual(@as(usize, 1), gov2.record(2));
    try testing.expectEqual(@as(usize, 1), gov2.record(3));
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
        .argv = &.{ builtCodedbExe(), "--help" },
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
        .argv = &.{ builtCodedbExe(), "-h" },
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
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    // Verify the polling infrastructure works for pipe-based transports
    const pipe = try cio.makePipe();
    defer cio.closeFd(pipe[0]);

    // Close write end — simulates client disconnect
    cio.closeFd(pipe[1]);

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
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const pipe = try cio.makePipe();
    defer cio.closeFd(pipe[0]);
    defer cio.closeFd(pipe[1]);

    var poll_fds = [_]std.posix.pollfd{.{
        .fd = pipe[0],
        .events = std.posix.POLL.IN | std.posix.POLL.HUP,
        .revents = 0,
    }};

    const result = try std.posix.poll(&poll_fds, 0);
    try testing.expectEqual(@as(usize, 0), result);
}

test "issue-148: codedb mcp exits when stdin is closed" {
    // #620: this used to spawn `zig build run -- --mcp` from the repo root, which
    // folded the compile step AND a full-repo snapshot load into the measured
    // window, so it flaked over the 5s budget under load. Build once up front
    // (outside the timing), then spawn the prebuilt binary against a tiny temp
    // project so only the real stdin-EOF-to-exit path is timed.
    try buildCliForHelpTests();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const proj_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const proj = path_buf[0..proj_len];
    tmp.dir.writeFile(io, .{ .sub_path = "a.zig", .data = "const x = 1;\n" }) catch {};

    // Integration test: spawn the built codedb mcp, close stdin, verify it exits
    var child = std.process.spawn(io, .{
        .argv = &.{ builtCodedbExe(), proj, "mcp" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch {
        // If spawn fails (e.g., binary not built), skip the test
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

test "bootstrap warmup is joinable before Explorer teardown" {
    const no_warmup = EnvVarGuard.save("CODEDB_NO_WARMUP");
    defer no_warmup.restore();
    const low_memory = EnvVarGuard.save("CODEDB_LOW_MEMORY");
    defer low_memory.restore();
    cio.posixUnsetenv("CODEDB_NO_WARMUP");
    cio.posixUnsetenv("CODEDB_LOW_MEMORY");

    const prev_state = mcp_mod.getScanState();
    defer mcp_mod.setScanState(prev_state);
    mcp_mod.setScanState(.walking);

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    const warmup = bootstrap_mod.spawnWarmup(io, testing.allocator, &explorer, ".", ".", &shutdown) orelse return error.TestUnexpectedResult;
    shutdown.store(true, .release);
    warmup.join();
}

test "bootstrap warmup disabled mode does not spawn a thread" {
    const no_warmup = EnvVarGuard.save("CODEDB_NO_WARMUP");
    defer no_warmup.restore();
    cio.posixSetenv("CODEDB_NO_WARMUP", "1");

    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var shutdown = std.atomic.Value(bool).init(false);
    try testing.expect(bootstrap_mod.spawnWarmup(io, testing.allocator, &explorer, ".", ".", &shutdown) == null);
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

    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\"}}", .{bin_rel});
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

    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\",\"line_start\":100,\"line_end\":10}}", .{rel});
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

test "codedb_outline paginates declaration-dense files" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("dense.zig",
        \\pub fn firstDense() void {}
        \\pub fn secondDense() void {}
        \\pub fn thirdDense() void {}
        \\pub fn fourthDense() void {}
        \\pub fn fifthDense() void {}
    );
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const first_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"dense.zig\",\"max_results\":2}", .{});
    defer first_args.deinit();
    var first: std.ArrayList(u8) = .empty;
    defer first.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &first_args.value.object, &first, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, first.items, "firstDense") != null);
    try testing.expect(std.mem.indexOf(u8, first.items, "secondDense") != null);
    try testing.expect(std.mem.indexOf(u8, first.items, "thirdDense") == null);
    try testing.expect(std.mem.indexOf(u8, first.items, "more: 3 symbols; offset=2") != null);

    const next_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"dense.zig\",\"max_results\":2,\"offset\":2}", .{});
    defer next_args.deinit();
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &next_args.value.object, &next, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, next.items, "firstDense") == null);
    try testing.expect(std.mem.indexOf(u8, next.items, "thirdDense") != null);
    try testing.expect(std.mem.indexOf(u8, next.items, "fourthDense") != null);
    try testing.expect(std.mem.indexOf(u8, next.items, "more: 1 symbols; offset=4") != null);

    const bad_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"dense.zig\",\"offset\":-1}", .{});
    defer bad_args.deinit();
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &bad_args.value.object, &bad, &store, &explorer, &agents);
    try testing.expect(std.mem.startsWith(u8, bad.items, "error: offset"));

    const past_args = try std.json.parseFromSlice(std.json.Value, testing.allocator, "{\"path\":\"dense.zig\",\"offset\":99}", .{});
    defer past_args.deinit();
    var past: std.ArrayList(u8) = .empty;
    defer past.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_outline, &past_args.value.object, &past, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, past.items, "showing symbols 0-0 of 5") != null);
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

test "issue-642: /var/home project dirs are indexable on OSTree (Silverblue/CoreOS)" {
    // OSTree distros (Fedora Silverblue/CoreOS/Nobara) bind-mount /home onto
    // /var/home, so /var/home/<user>/<project> is a real project path — and
    // realPathFile canonicalizes /home/<user>/<project> to it, the same way
    // #406/#407 turn /etc→/private/etc and /var→/private/var. It must index like
    // /home does, with no CODEDB_ALLOW_TEMP opt-in.
    try testing.expect(root_policy.isIndexableRoot("/var/home/xavi/project"));
    try testing.expect(root_policy.isIndexableRoot("/var/home/xavi/project/src"));
    // The bare home dir and /var itself stay denied (footgun guard, #174/#407).
    try testing.expect(!root_policy.isIndexableRoot("/var/home/xavi"));
    try testing.expect(!root_policy.isIndexableRoot("/var/home"));
    try testing.expect(!root_policy.isIndexableRoot("/var"));
    try testing.expect(!root_policy.isIndexableRoot("/var/log"));
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
    defer cio.closeFd(pipe[0]);
    defer cio.closeFd(pipe[1]);

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
    const n_raw = cio.readFd(pipe[0], &response_buf);
    try testing.expect(n_raw > 0);
    const n: usize = @intCast(n_raw);
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

test "tools list: compact agent surface advertises only task-critical tools" {
    const response = try mcp_mod.buildToolsListResponse(testing.allocator, .{
        // The compact allowlist wins even when optional full-profile tools are
        // enabled. Their handlers remain available to cached direct callers.
        .bundle_enabled = true,
        .discriminated_opt_in = true,
        .compact_agent_surface = true,
    });
    defer testing.allocator.free(response);

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, response, .{});
    defer parsed.deinit();

    const expected = [_][]const u8{
        "codedb_outline",
        "codedb_symbol",
        "codedb_search",
        "codedb_word",
        "codedb_callers",
        "codedb_callpath",
        "codedb_context",
        "codedb_deps",
        "codedb_read",
        "codedb_find",
    };
    const tools = parsed.value.object.get("tools").?.array;
    try testing.expectEqual(expected.len, tools.items.len);
    for (tools.items) |tool| {
        const name = tool.object.get("name").?.string;
        var expected_tool = false;
        for (expected) |candidate| {
            if (std.mem.eql(u8, name, candidate)) {
                expected_tool = true;
                break;
            }
        }
        try testing.expect(expected_tool);
    }

    // Exposure filtering must not remove dispatcher compatibility.
    try testing.expect(std.meta.stringToEnum(mcp_mod.Tool, "codedb_status") != null);
    try testing.expect(std.meta.stringToEnum(mcp_mod.Tool, "codedb_edit") != null);
    try testing.expect(std.meta.stringToEnum(mcp_mod.Tool, "codedb_remote") != null);
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

test "issue-639: unexpanded ${workspaceFolder} root normalizes to cwd, non-explicit" {
    // Editors that don't expand the ${workspaceFolder} placeholder pass the
    // literal token as the root. It must behave like a bare `codedb mcp`
    // (root ".", root_is_explicit=false) so the CODEDB_ROOT fallback, the #502
    // git-root walk-up, and deferred-scan mode all apply. Before the fix
    // parsePositional returned the literal placeholder with root_is_explicit
    // = true, and mainImpl only rewrote root -> "." (too late, and without
    // clearing the explicit flag), so all three paths were silently skipped.

    // `codedb ${workspaceFolder} mcp`
    {
        const argv = [_][]const u8{ "codedb", "${workspaceFolder}", "mcp" };
        const p = main_mod.parsePositional(&argv);
        try testing.expect(!p.usage_exit);
        try testing.expectEqualStrings(".", p.root);
        try testing.expectEqualStrings("mcp", p.cmd);
        try testing.expect(!p.root_is_explicit);
    }
    // `codedb mcp ${workspaceFolder}`
    {
        const argv = [_][]const u8{ "codedb", "mcp", "${workspaceFolder}" };
        const p = main_mod.parsePositional(&argv);
        try testing.expect(!p.usage_exit);
        try testing.expectEqualStrings(".", p.root);
        try testing.expectEqualStrings("mcp", p.cmd);
        try testing.expect(!p.root_is_explicit);
    }
}

test "issue-639: parsePositional root/explicit matrix across arg forms" {
    // The matrix that hid the bug: each arg form maps to a (root, cmd,
    // explicit) triple. The deferred-scan / git-root-walkup / CODEDB_ROOT
    // gates all key off (cmd=="mcp" and root=="." and !explicit), so the
    // placeholder rows MUST land on root=".", explicit=false to behave like
    // a bare `codedb mcp`. Anything else silently disables those paths (#639).
    const Case = struct {
        argv: []const []const u8,
        root: []const u8,
        cmd: []const u8,
        explicit: bool,
    };
    const cases = [_]Case{
        // bare mcp → cwd, deferred (non-explicit)
        .{ .argv = &.{ "codedb", "mcp" }, .root = ".", .cmd = "mcp", .explicit = false },
        // explicit path before cmd
        .{ .argv = &.{ "codedb", "/proj", "mcp" }, .root = "/proj", .cmd = "mcp", .explicit = true },
        // explicit path after mcp (#503)
        .{ .argv = &.{ "codedb", "mcp", "/proj" }, .root = "/proj", .cmd = "mcp", .explicit = true },
        // unexpanded placeholder before cmd → normalized to cwd, non-explicit (#639)
        .{ .argv = &.{ "codedb", "${workspaceFolder}", "mcp" }, .root = ".", .cmd = "mcp", .explicit = false },
        // unexpanded placeholder after mcp → normalized (#639)
        .{ .argv = &.{ "codedb", "mcp", "${workspaceFolder}" }, .root = ".", .cmd = "mcp", .explicit = false },
        // placeholder with a non-mcp command (generic root form) → cwd recovery (#639)
        .{ .argv = &.{ "codedb", "${workspaceFolder}", "search" }, .root = ".", .cmd = "search", .explicit = false },
        // explicit path + query cmd stays explicit
        .{ .argv = &.{ "codedb", "/proj", "search" }, .root = "/proj", .cmd = "search", .explicit = true },
    };
    for (cases) |c| {
        const p = main_mod.parsePositional(c.argv);
        try testing.expect(!p.usage_exit);
        try testing.expectEqualStrings(c.root, p.root);
        try testing.expectEqualStrings(c.cmd, p.cmd);
        try testing.expectEqual(c.explicit, p.root_is_explicit);
    }
}

test "issue-639: placeholder is normalized in cli_args only, never re-rewritten in main" {
    // Reintroduction guard. The bug hid because the placeholder was rewritten
    // late in the dispatcher (mainImpl), after the gates had already branched
    // on the un-normalized value. Keep the literal in exactly one place
    // (cli_args.zig); its presence in main.zig means a late rewrite is back.
    const main_src = @embedFile("main.zig");
    try testing.expect(std.mem.indexOf(u8, main_src, "${workspaceFolder}") == null);
}

test "issue-639: mcp root-resolution gate predicates" {
    const ca = cli_args_mod;
    // mcpRootIsImplicitCwd — single source for the #502 git-root walk-up AND
    // the deferred-scan handshake. Fires only for an implicit cwd mcp root.
    try testing.expect(ca.mcpRootIsImplicitCwd("mcp", ".", false)); // bare mcp → fire
    try testing.expect(!ca.mcpRootIsImplicitCwd("mcp", ".", true)); // env/path-pinned → skip
    try testing.expect(!ca.mcpRootIsImplicitCwd("mcp", "/proj", false)); // explicit path → skip
    try testing.expect(!ca.mcpRootIsImplicitCwd("search", ".", false)); // non-mcp → skip
    // mcpRootAcceptsEnv — gates the CODEDB_ROOT fallback (explicit or not).
    try testing.expect(ca.mcpRootAcceptsEnv("mcp", "."));
    try testing.expect(!ca.mcpRootAcceptsEnv("mcp", "/proj"));
    try testing.expect(!ca.mcpRootAcceptsEnv("status", "."));
}

test "issue-639: parsed ${workspaceFolder} feeds the gates like a bare `codedb mcp`" {
    // The two halves of the bug must agree: the parse half (parsePositional)
    // and the consume half (the gate predicates). Before the fix the
    // placeholder parsed to (root="${workspaceFolder}", explicit=true), so
    // both gates returned false and the #502 walk-up / deferred scan /
    // CODEDB_ROOT fallback were all silently skipped.
    const forms = [_][]const []const u8{
        &.{ "codedb", "${workspaceFolder}", "mcp" },
        &.{ "codedb", "mcp", "${workspaceFolder}" },
    };
    for (forms) |argv| {
        const p = main_mod.parsePositional(argv);
        try testing.expect(cli_args_mod.mcpRootIsImplicitCwd(p.cmd, p.root, p.root_is_explicit));
        try testing.expect(cli_args_mod.mcpRootAcceptsEnv(p.cmd, p.root));
    }
}

test "isolate: isHelpRequest matches the three help spellings, nothing else" {
    const ca = cli_args_mod;
    // The exact triple that was hand-written at four sites and drift-prone.
    try testing.expect(ca.isHelpRequest("--help"));
    try testing.expect(ca.isHelpRequest("-h"));
    try testing.expect(ca.isHelpRequest("help"));
    // Near-misses must not trip it — realistic typos / neighbouring flags.
    try testing.expect(!ca.isHelpRequest("--helpme"));
    try testing.expect(!ca.isHelpRequest("-help"));
    try testing.expect(!ca.isHelpRequest("h"));
    try testing.expect(!ca.isHelpRequest("--no-telemetry"));
    try testing.expect(!ca.isHelpRequest(""));
}

test "isolate: parsePositional routes every help form through isHelpRequest" {
    // Wiring: the parse half and the predicate must agree. Every argv that
    // should print usage parses to a cmd isHelpRequest recognizes — including
    // the #502 `codedb mcp --help` collapse to cmd="--help".
    const ca = cli_args_mod;
    inline for (.{ "--help", "-h", "help" }) |form| {
        const bare = main_mod.parsePositional(&.{ "codedb", form });
        try testing.expect(ca.isHelpRequest(bare.cmd));
        const after_mcp = main_mod.parsePositional(&.{ "codedb", "mcp", form });
        try testing.expect(ca.isHelpRequest(after_mcp.cmd));
    }
}

test "isolate: hand-written help-flag triple is gone from main.zig" {
    // Reintroduction guard. The `--help`/`-h`/`help` disjunction lived inline
    // in mainImpl at two sites; both now call isHelpRequest. The `-h` literal
    // existed nowhere else in main.zig, so its reappearance marks a re-inline
    // before it can drift from the cli_args source of truth.
    const main_src = @embedFile("main.zig");
    try testing.expect(std.mem.indexOf(u8, main_src, "\"-h\"") == null);
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

test "issue-570: codedb_context falls back to plain words for all-lowercase tasks" {
    // 'fix search ranking' has no identifier-shaped token (no snake_case, no
    // camelCase, no quotes), so extractContextCandidates finds nothing and the
    // handler dead-ends with 'no candidate identifiers found'. Natural-language
    // tasks are the documented input shape — the composer must fall back to
    // plain words instead of erroring.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/ranking.zig", "pub fn rankingBoost() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"task":"fix search ranking"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    // An all-lowercase task must not dead-end…
    try testing.expect(std.mem.indexOf(u8, out.items, "no candidate identifiers") == null);
    // …its longest meaningful word ('ranking') must drive the composer.
    try testing.expect(std.mem.indexOf(u8, out.items, "ranking") != null);
}

test "issue-573: cli bridge must not bind a leading flag as the positional name" {
    // Live repro: `codedb callers --max-results 3 indexFile` reported
    // "1 call sites for '--max-results'" — the bridge takes args[cmd_args_start]
    // blindly, so a leading flag silently becomes the name. It must fall
    // through to the command's usage error instead.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/a.zig", "pub fn indexFile() void {}\npub fn caller() void {\n    indexFile();\n}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const argv = [_][]const u8{ "--max-results", "3", "indexFile" };
    const code = mcp_mod.runCliTool(io, testing.allocator, &explorer, &store, ".", "callers", &argv, 0, &out);
    try testing.expect(code != null);
    // The flag must not be reported as the function name…
    try testing.expect(std.mem.indexOf(u8, out.items, "call sites for '--max-results'") == null);
    // …the command fails to its usage line instead.
    try testing.expect(std.mem.indexOf(u8, out.items, "callers <name>") != null);

    // Companion UX defect, same audit: an explicitly empty symbol name must be
    // a usage error (mirrors codedb_callers), not "no results for: ".
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const sargs_json =
        \\{"name":""}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, sargs_json, .{});
    defer parsed.deinit();

    var sout: std.ArrayList(u8) = .empty;
    defer sout.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_symbol, &parsed.value.object, &sout, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, sout.items, "error: empty name") != null);
}

test "issue-576: codedb_ls distinguishes a non-indexed path from an empty listing" {
    // `codedb ls nonexistent/dir` printed 'no entries' with exit 0 —
    // indistinguishable from a real-but-empty directory. An index only knows
    // a directory through files under it, so an empty listing for a non-empty
    // prefix always means the path is not indexed: say so (the 'error:' prefix
    // also makes finishCli return exit 1 on the CLI bridge).
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/a.zig", "pub fn a() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const bad_json =
        \\{"path":"nonexistent/dir"}
    ;
    const bad_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, bad_json, .{});
    defer bad_parsed.deinit();

    var bad_out: std.ArrayList(u8) = .empty;
    defer bad_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &bad_parsed.value.object, &bad_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, bad_out.items, "error: no indexed files under 'nonexistent/dir'") != null);

    // A real prefix still lists its entries.
    const ok_json =
        \\{"path":"src"}
    ;
    const ok_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, ok_json, .{});
    defer ok_parsed.deinit();

    var ok_out: std.ArrayList(u8) = .empty;
    defer ok_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_ls, &ok_parsed.value.object, &ok_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, ok_out.items, "a.zig") != null);
}

test "issue-578: cli bridge serves codedb_changes" {
    // `codedb changes` parsed as a ROOT directory (unknown first token in the
    // [root] <command> grammar) and printed usage — codedb_changes existed
    // only as an MCP tool because the bridge had no store to hand to
    // handleChanges. The bridge must serve it like the other read-only tools.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/a.zig", "pub fn a() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    _ = store.recordSnapshot("src/a.zig", 10, 123) catch {};

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    const argv = [_][]const u8{};
    const code = mcp_mod.runCliTool(io, testing.allocator, &explorer, &store, ".", "changes", &argv, 0, &out);
    // Pre-#578 the bridge did not know 'changes' and returned null.
    try testing.expect(code != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "seq:") != null);
}

// ─── audit (2026-06-09): latent-issue sweep — secret-path detection ───
// src/watcher.zig + src/snapshot.zig isSensitivePath missed *.env suffix files and
// .git-credentials, so those secrets were indexed/read.
test "audit: isSensitivePath blocks *.env suffix files and .git-credentials" {
    try testing.expect(watcher.isSensitivePath("production.env"));
    try testing.expect(watcher.isSensitivePath("staging.env"));
    try testing.expect(watcher.isSensitivePath("secrets.env"));
    try testing.expect(watcher.isSensitivePath("deploy/secrets.env"));
    try testing.expect(watcher.isSensitivePath(".git-credentials"));
    // existing positive (prefix .env.* form) must still hold
    try testing.expect(watcher.isSensitivePath(".env.production"));
    // negatives — guard against an over-broad change
    try testing.expect(!watcher.isSensitivePath("main.zig"));
    try testing.expect(!watcher.isSensitivePath("environment.ts"));
}

// ─── #568: empty deps lists print '(none)' with no '(N files)' summary ───
// Non-empty lists end with a '(N files)' summary; empty lists printed a body
// line '  (none)' and no summary, so machine consumers that parse the list
// body saw one entry (engram counted in-degree 1 for every zero-importer
// file). The summary line must be present unconditionally.
test "issue-568: deps empty list prints a (0 files) summary" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/lone.zig", "pub fn lonely() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    // imported_by (default): nothing imports src/lone.zig.
    const rev_json =
        \\{"path":"src/lone.zig"}
    ;
    const rev_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, rev_json, .{});
    defer rev_parsed.deinit();
    var rev_out: std.ArrayList(u8) = .empty;
    defer rev_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_deps, &rev_parsed.value.object, &rev_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, rev_out.items, "(none)") != null);
    try testing.expect(std.mem.indexOf(u8, rev_out.items, "(0 files)") != null);

    // depends_on: src/lone.zig imports nothing.
    const fwd_json =
        \\{"path":"src/lone.zig","direction":"depends_on"}
    ;
    const fwd_parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, fwd_json, .{});
    defer fwd_parsed.deinit();
    var fwd_out: std.ArrayList(u8) = .empty;
    defer fwd_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_deps, &fwd_parsed.value.object, &fwd_out, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, fwd_out.items, "(none)") != null);
    try testing.expect(std.mem.indexOf(u8, fwd_out.items, "(0 files)") != null);
}

test "issue-589: isSensitivePath blocks all OpenSSH default private key names" {
    // The exact-name list covers id_rsa and id_ed25519 but misses the other
    // ssh-keygen defaults: id_ecdsa, id_dsa, and the FIDO variants
    // id_ecdsa_sk / id_ed25519_sk. Outside ~/.ssh (which the directory rule
    // catches), a key copied into a repo — deploy/id_ecdsa — was indexed and
    // readable while deploy/id_rsa was blocked.
    const keys = [_][]const u8{ "id_ecdsa", "id_dsa", "id_ecdsa_sk", "id_ed25519_sk" };
    for (keys) |k| {
        try testing.expect(watcher.isSensitivePath(k));
        try testing.expect(snapshot_mod.isSensitivePath(k));
    }
    try testing.expect(watcher.isSensitivePath("deploy/id_ecdsa"));
    // negatives — names that merely start like a key must stay indexable
    try testing.expect(!watcher.isSensitivePath("id_map.zig"));
    try testing.expect(!watcher.isSensitivePath("identity.ts"));
}

test "issue-592: cli-daemon spawn lock is exclusive per project" {
    // Concurrent cold CLI calls used to fork a cli-daemon EACH (no mutual
    // exclusion), every duplicate re-scanned the index, and the stale-socket
    // unlink let late arrivals steal the winner's socket — orphan daemons
    // churned CPU long after the calls exited. The per-project flock makes
    // spawn mutually exclusive: holders win, probes report unavailable, and
    // the kernel releases the lock on any exit.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    if (builtin.os.tag == .windows) {
        try tmp.dir.createDirPath(io, "unicode-å");
    }
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(io, if (builtin.os.tag == .windows) "unicode-å" else ".", &path_buf);
    const dir_path = path_buf[0..dir_len];

    const held = main_mod.daemonLockTryAcquire(dir_path);
    try testing.expect(held != null);
    // A second acquire (the would-be duplicate daemon) must lose...
    try testing.expect(main_mod.daemonLockTryAcquire(dir_path) == null);
    // ...and the CLI spawn probe must report the lock as taken.
    try testing.expect(!main_mod.daemonLockAvailable(dir_path));

    main_mod.daemonLockRelease(held.?);
    try testing.expect(main_mod.daemonLockAvailable(dir_path));
}

test "cli-mcp-parity: runCliTool bridges navigation commands to MCP handlers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var exp = Explorer.init(aa, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    try exp.indexFile("src/store.zig", "pub const Store = struct {};\n");
    try exp.indexFile("src/main.zig", "const Store = @import(\"store.zig\").Store;\npub fn main() void {}\n");

    var store = Store.init(aa);

    // glob: pattern -> matching indexed paths (reuses handleGlob)
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(aa);
        const code = mcp_mod.runCliTool(io, aa, &exp, &store, ".", "glob", &.{ "codedb", ".", "glob", "src/*.zig" }, 3, &out);
        try testing.expectEqual(@as(?u8, 0), code);
        try testing.expect(std.mem.indexOf(u8, out.items, "src/store.zig") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, "src/main.zig") != null);
    }

    // symbol: name -> definition site (reuses handleSymbol)
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(aa);
        const code = mcp_mod.runCliTool(io, aa, &exp, &store, ".", "symbol", &.{ "codedb", ".", "symbol", "Store" }, 3, &out);
        try testing.expectEqual(@as(?u8, 0), code);
        try testing.expect(std.mem.indexOf(u8, out.items, "src/store.zig") != null);
    }

    // unknown command -> null so runQuery falls through to its own usage error
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(aa);
        try testing.expectEqual(@as(?u8, null), mcp_mod.runCliTool(io, aa, &exp, &store, ".", "bogus", &.{ "codedb", ".", "bogus" }, 3, &out));
    }

    // missing required arg -> usage line, exit 1
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(aa);
        try testing.expectEqual(@as(?u8, 1), mcp_mod.runCliTool(io, aa, &exp, &store, ".", "glob", &.{ "codedb", ".", "glob" }, 3, &out));
        try testing.expect(std.mem.indexOf(u8, out.items, "usage") != null);
    }
}

test "issue-531: codedb_context max_tokens packs sections by value under the budget" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // A defined symbol with a fat body (inlined when unbudgeted) plus several
    // mention files so the snippets section is large too.
    try explorer.indexFile("src/widget.zig",
        \\pub fn widgetFrobnicate() void {
        \\    const filler_line_01: u64 = 1;
        \\    const filler_line_02: u64 = 2;
        \\    const filler_line_03: u64 = 3;
        \\    const filler_line_04: u64 = 4;
        \\    const filler_line_05: u64 = 5;
        \\    const filler_line_06: u64 = 6;
        \\    const filler_line_07: u64 = 7;
        \\    const filler_line_08: u64 = 8;
        \\    const filler_line_09: u64 = 9;
        \\    const filler_line_10: u64 = 10;
        \\    const filler_line_11: u64 = 11;
        \\    const filler_line_12: u64 = 12;
        \\    const filler_line_13: u64 = 13;
        \\    const filler_line_14: u64 = 14;
        \\    const filler_line_15: u64 = 15;
        \\    const filler_line_16: u64 = 16;
        \\    const filler_line_17: u64 = 17;
        \\    const filler_line_18: u64 = 18;
        \\    const filler_line_19: u64 = 19;
        \\    const filler_line_20: u64 = 20;
        \\    _ = filler_line_01;
        \\}
    );
    var name_buf: [32]u8 = undefined;
    var content_buf: [512]u8 = undefined;
    for (0..5) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "src/mention_{d}.zig", .{i});
        const content = try std.fmt.bufPrint(&content_buf,
            \\pub fn helper_{d}() void {{
            \\    widgetFrobnicate();
            \\    widgetFrobnicate();
            \\    widgetFrobnicate();
            \\}}
        , .{i});
        try explorer.indexFile(name, content);
    }

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_full =
        \\{"task":"investigate widgetFrobnicate","detail":"full"}
    ;
    const parsed_full = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_full, .{});
    defer parsed_full.deinit();
    var out_full: std.ArrayList(u8) = .empty;
    defer out_full.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed_full.value.object, &out_full, &store, &explorer, &agents);

    const args_budget =
        \\{"task":"investigate widgetFrobnicate","max_tokens":256,"detail":"full"}
    ;
    const parsed_budget = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_budget, .{});
    defer parsed_budget.deinit();
    var out_budget: std.ArrayList(u8) = .empty;
    defer out_budget.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed_budget.value.object, &out_budget, &store, &explorer, &agents);

    // Unbudgeted output is unchanged (no markers) and bigger.
    try testing.expect(std.mem.indexOf(u8, out_full.items, "[max_tokens") == null);
    try testing.expect(out_full.items.len > out_budget.items.len);

    // Budgeted output respects ~4 chars/token, with a small allowance for
    // the omission markers themselves.
    try testing.expect(out_budget.items.len <= 256 * 4 + 512);
    try testing.expect(std.mem.indexOf(u8, out_budget.items, "[max_tokens") != null);

    // Value order: the head and the file list survive; the fat snippet
    // section is what gets dropped.
    try testing.expect(std.mem.indexOf(u8, out_budget.items, "# Task") != null);
    try testing.expect(std.mem.indexOf(u8, out_budget.items, "## Most-relevant files") != null);
    try testing.expect(std.mem.indexOf(u8, out_budget.items, "## Top sites") == null);
}

test "codedb_context batches same-file symbol bodies without changing formatting" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/batched.zig",
        \\pub fn alphaBody() void {
        \\    const value = "alpha";
        \\    _ = value;
        \\}
        \\pub fn betaBody() void {
        \\    const value = "beta";
        \\    _ = value;
        \\}
        \\pub fn gammaBody() void {
        \\    const value = "gamma";
        \\    _ = value;
        \\}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const args_json =
        \\{"task":"inspect `alphaBody` `betaBody` `gammaBody`","detail":"full"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "- alphaBody (function) — src/batched.zig:1\n           1 | pub fn alphaBody() void {\n           2 |     const value = \"alpha\";\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "- betaBody (function) — src/batched.zig:5\n           5 | pub fn betaBody() void {\n           6 |     const value = \"beta\";\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "- gammaBody (function) — src/batched.zig:9\n           9 | pub fn gammaBody() void {\n          10 |     const value = \"gamma\";\n") != null);
}

test "codedb_context compact extracts the member from a backtick expression" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/routes.zig",
        \\pub fn route() void {
        \\    registerRule();
        \\}
        \\fn registerRule() void {}
    );

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"trace `@app.route('/foo')` registration"}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.startsWith(u8, out.items, "keywords: route"));
    try testing.expect(std.mem.indexOf(u8, out.items, "## Body route — src/routes.zig:1-3") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "@app.route('/foo')") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "1|pub fn route() void {") != null);
}

test "codedb_context compact prioritizes production definitions and bodies per candidate" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("tests/alpha.zig", "pub fn alphaFocus() void { testOnly(); }\n");
    try explorer.indexFile("src/alpha_a.zig", "pub fn alphaFocus() void { alphaPrimary(); }\n");
    try explorer.indexFile("src/alpha_b.zig", "pub fn alphaFocus() void { alphaSecondary(); }\n");
    try explorer.indexFile("src/beta_a.zig", "pub fn betaFocus() void { betaPrimary(); }\n");
    try explorer.indexFile("src/beta_b.zig", "pub fn betaFocus() void { betaSecondary(); }\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"compare `alphaFocus` and `betaFocus`"}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    // Four source definitions no longer disable every body, and the test
    // duplicate does not consume either of alphaFocus's two definition slots.
    try testing.expect(std.mem.indexOf(u8, out.items, "alphaFocus function tests/alpha.zig") == null);
    try testing.expect(std.mem.indexOf(u8, out.items, "## Body alphaFocus") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "## Body betaFocus") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "alphaPrimary") != null or std.mem.indexOf(u8, out.items, "alphaSecondary") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "betaPrimary") != null or std.mem.indexOf(u8, out.items, "betaSecondary") != null);
}

test "codedb_context compact keeps a long symbol's executable tail with an explicit gap" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "pub fn longHandler() void {\n");
    for (1..28) |i| {
        const w = cio.listWriter(&source, testing.allocator);
        try w.print("    const filler_{d}: u32 = {d};\n", .{ i, i });
    }
    try source.appendSlice(testing.allocator, "    registerFinalRule();\n}\n");
    try explorer.indexFile("src/long.zig", source.items);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"inspect `longHandler`"}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, " omitted\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "registerFinalRule();") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "       1 |") == null);
}

test "codedb_context site excerpts stay query-centered, marked, and valid UTF-8" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();

    // The old prefix clamp spent the entire 320-byte snippet on line 1 and
    // silently omitted the actual hit on line 2. Off-boundary emoji bytes also
    // exercise both UTF-8 window edges.
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    for (0..200) |_| try source.appendSlice(testing.allocator, "🙂");
    try source.append(testing.allocator, '\n');
    try source.appendSlice(testing.allocator, "12345678uniqueAnchor");
    for (0..200) |_| try source.appendSlice(testing.allocator, "🙂");
    try source.append(testing.allocator, '\n');
    try explorer.indexFile("notes/long.txt", source.items);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"investigate \"uniqueAnchor-suffix\""}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "notes/long.txt:2") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "uniqueAnchor") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "B elided") != null);
    try testing.expect(std.unicode.utf8ValidateSlice(out.items));
}

test "codedb_context usage sites are fair, lexical, and distinct from call sites" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/targets.zig",
        \\pub fn alphaNeedle() void { alphaHelper(); }
        \\fn alphaHelper() void {}
        \\pub fn betaNeedle() void {}
        \\pub const SearchResult = struct { value: u8 };
    );
    try explorer.indexFile("src/alpha_calls.zig",
        \\pub fn alphaCallerA() void { alphaNeedle(); }
        \\pub fn alphaCallerB() void { alphaNeedle(); }
        \\pub fn alphaCallerC() void { alphaNeedle(); }
    );
    try explorer.indexFile("src/beta_calls.zig", "pub fn betaCaller() void { betaNeedle(); }\n");
    try explorer.indexFile("src/references.zig",
        \\pub fn keepReference() void {
        \\    const typed: SearchResult = .{ .value = 1 };
        \\    const quoted = "SearchResult";
        \\    // SearchResult is documentation, not a usage site.
        \\    _ = typed;
        \\    _ = quoted;
        \\}
    );
    try explorer.indexFile("schema/search.proto",
        \\message SearchResult {}
        \\message Envelope { SearchResult child = 1; }
    );
    try explorer.indexFile("src/flags.py", "enabled(\"feature_flag\")\n");

    var long_decoy: std.ArrayList(u8) = .empty;
    defer long_decoy.deinit(testing.allocator);
    try long_decoy.appendSlice(testing.allocator, "const decoy = \"");
    try long_decoy.appendNTimes(testing.allocator, 'x', 1200);
    try long_decoy.appendSlice(testing.allocator, "alphaNeedle()\";\n");
    try explorer.indexFile("src/decoy.js", long_decoy.items);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const fair_args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"find usages of `alphaNeedle` and `betaNeedle`"}
    , .{});
    defer fair_args.deinit();
    var fair: std.ArrayList(u8) = .empty;
    defer fair.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &fair_args.value.object, &fair, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, fair.items, "alphaCallerA") != null);
    try testing.expect(std.mem.indexOf(u8, fair.items, "betaCaller") != null);

    const refs_args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"find references to `SearchResult`"}
    , .{});
    defer refs_args.deinit();
    var refs: std.ArrayList(u8) = .empty;
    defer refs.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &refs_args.value.object, &refs, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, refs.items, "typed: SearchResult") != null);
    try testing.expect(std.mem.indexOf(u8, refs.items, "quoted = \"SearchResult\"") == null);
    try testing.expect(std.mem.indexOf(u8, refs.items, "SearchResult is documentation") == null);
    try testing.expect(std.mem.indexOf(u8, refs.items, "SearchResult child") != null);

    const literal_args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"find occurrences of \"feature_flag\""}
    , .{});
    defer literal_args.deinit();
    var literal: std.ArrayList(u8) = .empty;
    defer literal.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &literal_args.value.object, &literal, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, literal.items, "enabled(\"feature_flag\")") != null);

    const calls_args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"find call sites for `SearchResult`"}
    , .{});
    defer calls_args.deinit();
    var calls: std.ArrayList(u8) = .empty;
    defer calls.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &calls_args.value.object, &calls, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, calls.items, "typed: SearchResult") == null);

    const trace_args = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"trace call sites for `alphaNeedle`"}
    , .{});
    defer trace_args.deinit();
    var trace: std.ArrayList(u8) = .empty;
    defer trace.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &trace_args.value.object, &trace, &store, &explorer, &agents);
    try testing.expect(std.mem.indexOf(u8, trace.items, "## Callees") != null);
    try testing.expect(std.mem.indexOf(u8, trace.items, "alphaHelper") != null);
    try testing.expect(std.mem.indexOf(u8, trace.items, "## Sites") != null);
    try testing.expect(std.mem.indexOf(u8, trace.items, "src/decoy.js") == null);
}

test "codedb_context compact shares one hard byte cap across body head and tail" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "pub fn giantBody() void {\n");
    for (0..30) |line_i| {
        const w = cio.listWriter(&source, testing.allocator);
        try w.print("    const filler_{d} = \"", .{line_i});
        try source.appendNTimes(testing.allocator, 'x', 340);
        try source.appendSlice(testing.allocator, "\";\n");
    }
    try source.appendSlice(testing.allocator, "}\n");
    try explorer.indexFile("src/giant.zig", source.items);

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"inspect `giantBody`"}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);

    const body_start = std.mem.indexOf(u8, out.items, "## Body giantBody") orelse return error.TestUnexpectedResult;
    const body_end = std.mem.indexOfPos(u8, out.items, body_start + 1, "\n## ") orelse out.items.len;
    try testing.expect(body_end - body_start < 4300);
    try testing.expect(std.mem.indexOfPos(u8, out.items, body_start, "body byte cap reached") != null);
}

test "codedb_context compact budgets are monotonic and prioritize requested sites" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);
    try source.appendSlice(testing.allocator, "pub fn targetFn() void {\n");
    for (0..24) |line_i| {
        const w = cio.listWriter(&source, testing.allocator);
        try w.print("    const filler_{d}: u64 = {d};\n", .{ line_i, line_i });
    }
    try source.appendSlice(testing.allocator, "}\n");
    try explorer.indexFile("src/target.zig", source.items);
    try explorer.indexFile("src/use.zig", "pub const callback = targetFn;\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const stop_words = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"find code using `targetFn`"}
    , .{});
    defer stop_words.deinit();
    var stop_out: std.ArrayList(u8) = .empty;
    defer stop_out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &stop_words.value.object, &stop_out, &store, &explorer, &agents);
    try testing.expect(std.mem.startsWith(u8, stop_out.items, "keywords: targetFn\n"));

    const budgets = [_]u32{ 256, 320, 400, 512, 700, 1000 };
    const section_names = [_][]const u8{ "## Definitions", "## Body", "## Callers", "## Callees", "## Files", "## Sites" };
    var previous_sections: [section_names.len]bool = @splat(false);
    var previous_len: usize = 0;
    for (budgets) |budget| {
        var json_buf: [160]u8 = undefined;
        const args_json = try std.fmt.bufPrint(&json_buf, "{{\"task\":\"find usages of `targetFn`\",\"max_tokens\":{d}}}", .{budget});
        const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
        defer parsed.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);
        try testing.expect(out.items.len <= @as(usize, budget) * 5 / 2);
        try testing.expect(out.items.len >= previous_len);
        for (section_names, 0..) |section, section_i| {
            const present = std.mem.indexOf(u8, out.items, section) != null;
            if (previous_sections[section_i]) try testing.expect(present);
            previous_sections[section_i] = present;
        }
        if (budget == 256) {
            try testing.expect(std.mem.indexOf(u8, out.items, "## Sites") != null);
            try testing.expect(std.mem.indexOf(u8, out.items, "callback = targetFn") != null);
        }
        previous_len = out.items.len;
    }
}

test "codedb_context detail full retains legacy framing" {
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/item.zig", "pub fn itemLookup() void {}\n");
    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");
    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator,
        \\{"task":"inspect itemLookup","detail":"full"}
    , .{});
    defer parsed.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_context, &parsed.value.object, &out, &store, &explorer, &agents);
    try testing.expect(std.mem.startsWith(u8, out.items, "# Task\ninspect itemLookup\n"));
    try testing.expect(std.mem.indexOf(u8, out.items, "## Symbol definitions") != null);
}

test "issue-626: fullFileReadHint only nudges on large whole-file reads" {
    try testing.expect(Explorer.fullFileReadHint("one\ntwo\nthree\n") == null);

    var big: std.ArrayList(u8) = .empty;
    defer big.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 500) : (i += 1) try big.appendSlice(testing.allocator, "x\n");
    const hint = Explorer.fullFileReadHint(big.items);
    try testing.expect(hint != null);
    try testing.expect(std.mem.indexOf(u8, hint.?, "codedb_outline") != null);
}

test "issue-626: depsHint fires only on a single unambiguous definition" {
    try testing.expect(mcp_mod.depsHint(0) == null);
    try testing.expect(mcp_mod.depsHint(5) == null);
    const h = mcp_mod.depsHint(1);
    try testing.expect(h != null);
    try testing.expect(std.mem.indexOf(u8, h.?, "codedb_deps") != null);
}

// ── main.zig split verification (#main-split) ───────────────────────────────
// main.zig was decomposed into out/cli_args/query/cli_proxy/bootstrap/
// background/commands modules. These tests fail to compile if any extracted
// module loses a public symbol, and fail at runtime if main.zig's re-exports
// stop forwarding to the moved implementations.

test "split: extracted modules expose their public API" {
    // Referencing one decl from each extracted module forces it to compile and
    // asserts the symbol still exists after the move.
    comptime {
        _ = out_mod.Out;
        _ = out_mod.printUsage;
        _ = cli_args_mod.parsePositional;
        _ = cli_args_mod.parseLineRange;
        _ = cli_args_mod.parseSearchArgs;
        _ = cli_args_mod.hasExtraCliArgs;
        _ = cli_args_mod.findGitRoot;
        _ = cli_args_mod.findGitRootFrom;
        _ = cli_args_mod.isValidMcpFlag;
        _ = cli_args_mod.resolveRoot;
        _ = cli_args_mod.cliIsQueryCmd;
        _ = query_mod.runQuery;
        _ = cli_proxy_mod.daemonLockTryAcquire;
        _ = cli_proxy_mod.daemonLockAvailable;
        _ = cli_proxy_mod.cliDaemonListen;
        _ = cli_proxy_mod.cliTryProxy;
        _ = cli_proxy_mod.cliSocketPath;
        _ = bootstrap_mod.loadUserConfig;
        _ = bootstrap_mod.loadBestSnapshot;
        _ = bootstrap_mod.getDataDir;
        _ = bootstrap_mod.coldLoadOrScan;
        _ = bootstrap_mod.spawnWarmup;
        _ = bootstrap_mod.persistWordIndexToDisk;
        _ = background_mod.reapLoop;
        _ = background_mod.scanBg;
        _ = background_mod.triggerScanFromRoots;
        _ = background_mod.watcherDeferredLoop;
        _ = background_mod.idleWatchdog;
        _ = background_mod.cliIdleWatchdog;
        _ = commands_mod.RunCtx;
        _ = commands_mod.runBenchEngine;
        _ = commands_mod.runSnapshot;
        _ = commands_mod.runCliDaemon;
        _ = commands_mod.runServe;
        _ = commands_mod.runMcp;
    }
}

test "split: main.zig re-exports forward to the extracted impls" {
    // parsePositional via the main re-export must behave identically to the
    // cli_args implementation it forwards to.
    const argv = [_][]const u8{ "codedb", "search", "needle" };
    const via_main = main_mod.parsePositional(&argv);
    const via_mod = cli_args_mod.parsePositional(&argv);
    try testing.expectEqualStrings(via_mod.root, via_main.root);
    try testing.expectEqualStrings(via_mod.cmd, via_main.cmd);
    try testing.expectEqual(via_mod.cmd_args_start, via_main.cmd_args_start);

    const lr_main = try main_mod.parseLineRange("2-8");
    const lr_mod = try cli_args_mod.parseLineRange("2-8");
    try testing.expectEqual(lr_mod.start, lr_main.start);
    try testing.expectEqual(lr_mod.end, lr_main.end);

    const sa_main = try main_mod.parseSearchArgs(&[_][]const u8{ "search", "--paths-only", "needle" }, 1);
    const sa_mod = try cli_args_mod.parseSearchArgs(&[_][]const u8{ "search", "--paths-only", "needle" }, 1);
    try testing.expectEqualStrings(sa_mod.query, sa_main.query);
    try testing.expectEqual(sa_mod.paths_only, sa_main.paths_only);

    try testing.expectEqual(
        cli_args_mod.isValidMcpFlag("--no-telemetry"),
        main_mod.isValidMcpFlag("--no-telemetry"),
    );
    try testing.expectEqual(
        cli_args_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "tree", "x" }, 2),
        main_mod.hasExtraCliArgs(&[_][]const u8{ "codedb", "tree", "x" }, 2),
    );
}

test "split: cli_args parsing behaviour survives the move" {
    // The read-only query-command table is the single source of truth shared by
    // cliIsQueryCmd, isCommand, and the runQuery dispatch (#578); confirm it
    // still classifies query vs non-query commands after the extraction.
    try testing.expect(cli_args_mod.cliIsQueryCmd("search"));
    try testing.expect(cli_args_mod.cliIsQueryCmd("outline"));
    try testing.expect(!cli_args_mod.cliIsQueryCmd("serve"));
    try testing.expect(!cli_args_mod.cliIsQueryCmd("mcp"));

    // `codedb mcp <path>` is honored as `codedb <path> mcp` (#503).
    const p = cli_args_mod.parsePositional(&[_][]const u8{ "codedb", "mcp", "/proj" });
    try testing.expectEqualStrings("/proj", p.root);
    try testing.expectEqualStrings("mcp", p.cmd);
    try testing.expect(p.root_is_explicit);

    try testing.expectError(error.Reversed, cli_args_mod.parseLineRange("9-2"));
    try testing.expectError(error.UnknownFlag, cli_args_mod.parseSearchArgs(&[_][]const u8{ "search", "--bogus", "x" }, 1));
}

test "split: cli_proxy daemon lock works via main and cli_proxy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPathFile(io, ".", &path_buf);
    const dir_path = path_buf[0..dir_len];

    // Acquired via the cli_proxy module; main's re-export must see it held.
    const held = cli_proxy_mod.daemonLockTryAcquire(dir_path);
    try testing.expect(held != null);
    defer cli_proxy_mod.daemonLockRelease(held.?);
    try testing.expect(!main_mod.daemonLockAvailable(dir_path));
    try testing.expect(cli_proxy_mod.daemonLockTryAcquire(dir_path) == null);
}

test "issue-624: convergence nudge is suppressed for format=json" {
    // Regression: the #624 governor appended its plain-text nudge to the tool
    // output for any governed nav tool at the loop threshold — including
    // codedb_search, which supports format=json. Appending text to a JSON
    // payload corrupts it (the #626 nudges guard with `if (!json_fmt)`; the
    // governor did not). convergenceNudge now encodes that guard.
    const MCP = @import("mcp.zig");
    const warn = MCP.ConvergenceGovernor.WARN_AT;

    // Text output at/after the loop threshold surfaces the nudge.
    try testing.expect(MCP.convergenceNudge(warn, false) != null);
    try testing.expect(MCP.convergenceNudge(warn + 1, false) != null);

    // format=json must NOT — otherwise the appended text breaks the JSON.
    try testing.expect(MCP.convergenceNudge(warn, true) == null);
    try testing.expect(MCP.convergenceNudge(warn + 5, true) == null);

    // Below the loop threshold, never nudge regardless of format.
    try testing.expect(MCP.convergenceNudge(warn - 1, false) == null);
    try testing.expect(MCP.convergenceNudge(warn - 1, true) == null);
}

test "issue-632: codedb_read raw mode returns byte-exact range without line-number prefixes" {
    // #632: a ranged codedb_read emits line-number-prefixed output (handleRead
    // hardcodes extractLines line_numbers=true), so its bytes are NOT a verbatim
    // copy of the source. Agents therefore can't feed it to an exact-string
    // editor and fall back to a native read for the pre-edit span — defeating
    // codedb on the read path (see justrach/codegraff#66). A `raw` mode should
    // return the exact lines so codedb can serve read+edit, not just locate.
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

    // raw=true + a line range: expect the exact source bytes for lines 1-2,
    // with NO "N | " line-number prefixes (so it can feed an exact-match edit).
    const args_json = try std.fmt.allocPrint(testing.allocator, "{{\"path\":\"{s}\",\"line_start\":1,\"line_end\":2,\"raw\":true}}", .{rel});
    defer testing.allocator.free(args_json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, &out, &store, &explorer, &agents);

    // The exact source lines must be present verbatim...
    try testing.expect(std.mem.indexOf(u8, out.items, "alpha\nbeta") != null);
    // ...and there must be no line-number prefix separator ("N | "), which would
    // make the output non-byte-exact and unusable for an exact-string edit.
    try testing.expect(std.mem.indexOf(u8, out.items, " | ") == null);
}

test "issue-633: `index` is a recognized command (not a usage/unknown error)" {
    // `codedb <root> index` scanned + persisted (the cold-load path keys on
    // cmd=="index") but then fell through the dispatch with no `index` branch →
    // "unknown command: index" + exit 1; and `codedb index` (no root) was a
    // usage error because isCommand() never listed it. `index` must parse as a
    // first-class command.
    // `codedb index` (no explicit root) must parse as cmd=index, root=".".
    const p = main_mod.parsePositional(&[_][]const u8{ "codedb", "index" });
    try testing.expect(!p.usage_exit);
    try testing.expectEqualStrings("index", p.cmd);
    try testing.expectEqualStrings(".", p.root);

    // `codedb <root> index` (explicit root) also resolves cmd=index.
    const p2 = main_mod.parsePositional(&[_][]const u8{ "codedb", "/proj", "index" });
    try testing.expectEqualStrings("index", p2.cmd);
    try testing.expectEqualStrings("/proj", p2.root);
}

test "issue-632: codedb_read raw mode coverage — full-file byte-exact, default unchanged" {
    // Broader coverage for #632: (a) raw full-file read is byte-exact (no hash
    // header, no line-number prefix, no full-file hint); (b) the default ranged
    // read still has BOTH the hash header and the "N | " prefix (regression
    // guard); (c) a raw ranged read drops both.
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp_dir.dir.realPathFile(io, ".", &dir_buf);
    const dir_path = dir_buf[0..dir_path_len];

    const rel = "small.txt";
    const content = "alpha\nbeta\ngamma\n";
    const full = try std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ dir_path, rel });
    defer testing.allocator.free(full);
    {
        const f = try std.Io.Dir.cwd().createFile(io, full, .{ .truncate = true });
        defer f.close(io);
        try f.writePositionalAll(io, content, 0);
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

    const Run = struct {
        fn call(ctx: *mcp_mod.BenchContext, st: *Store, ex: *Explorer, ag: *AgentRegistry, args_json: []const u8, out: *std.ArrayList(u8)) !void {
            const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, args_json, .{});
            defer parsed.deinit();
            ctx.runDispatch(io, testing.allocator, .codedb_read, &parsed.value.object, out, st, ex, ag);
        }
    };

    // (a) raw full-file read → byte-exact copy of the source, nothing prepended.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try Run.call(&bench_ctx, &store, &explorer, &agents, "{\"path\":\"small.txt\",\"raw\":true}", &out);
        try testing.expectEqualStrings(content, out.items);
    }
    // (b) default ranged read → unchanged: hash header present AND "N | " prefix.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try Run.call(&bench_ctx, &store, &explorer, &agents, "{\"path\":\"small.txt\",\"line_start\":1,\"line_end\":2}", &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "hash:") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, " | ") != null);
    }
    // (c) raw ranged read → exact line, no hash header, no line-number prefix.
    {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(testing.allocator);
        try Run.call(&bench_ctx, &store, &explorer, &agents, "{\"path\":\"small.txt\",\"line_start\":2,\"line_end\":2,\"raw\":true}", &out);
        try testing.expect(std.mem.indexOf(u8, out.items, "beta") != null);
        try testing.expect(std.mem.indexOf(u8, out.items, " | ") == null);
        try testing.expect(std.mem.indexOf(u8, out.items, "hash:") == null);
    }
}

// ── #619: cli-daemon socket reclaim ─────────────────────────────────────────
// A long-lived serve/mcp daemon that loses the CLI-socket bind to an older
// cli-daemon must reclaim the socket once that owner exits, instead of
// disabling its proxy forever (the pre-fix single-shot behavior never retried).
test "issue-619: serve/mcp daemon reclaims the cli socket after the owner exits" {
    if (@import("builtin").os.tag == .windows) return; // no unix-socket proxy on Windows

    const abs_root = "/codedb-test-issue619-reclaim";
    var pbuf: [128]u8 = undefined;
    const sock_path = cli_proxy_mod.cliSocketPath(&pbuf, abs_root).?;
    var zbuf: [128]u8 = undefined;
    const sock_z = try cio.bufPrintZ(&zbuf, "{s}", .{sock_path});
    _ = std.c.unlink(sock_z.ptr);
    defer _ = std.c.unlink(sock_z.ptr);

    var sd = std.atomic.Value(bool).init(false);

    // A live cli-daemon owns the socket: acquire + hold a listening fd.
    const owner = cli_proxy_mod.cliAcquireListener(sock_path, false, 0, &sd).?;

    // Losing the race with no retry → give up at once (don't steal a live socket).
    try testing.expect(cli_proxy_mod.cliAcquireListener(sock_path, false, 0, &sd) == null);

    // Losing the race with retry, but shutdown already signalled → return at once.
    var sd_down = std.atomic.Value(bool).init(true);
    try testing.expect(cli_proxy_mod.cliAcquireListener(sock_path, true, 1000, &sd_down) == null);

    // A long-lived serve/mcp daemon (retry = true) keeps trying and reclaims the
    // socket once the owner exits — the core #619 fix (pre-fix: never retried).
    const Reclaimer = struct {
        path: []const u8,
        sd: *std.atomic.Value(bool),
        fd: ?c_int,
        done: std.atomic.Value(bool),
        fn run(self: *@This()) void {
            self.fd = cli_proxy_mod.cliAcquireListener(self.path, true, 10, self.sd);
            self.done.store(true, .release);
        }
    };
    var rc = Reclaimer{ .path = sock_path, .sd = &sd, .fd = null, .done = std.atomic.Value(bool).init(false) };
    const t = try std.Thread.spawn(.{}, Reclaimer.run, .{&rc});

    cio.sleepMs(30); // let the retry loop spin a few times
    _ = std.c.close(owner); // owner idle-exits
    t.join(); // reclaimer must return (pre-fix: no retry path → would never acquire)
    try testing.expect(rc.fd != null);
    if (rc.fd) |fd| _ = std.c.close(fd);
}

// ── #619: cli-daemon socket handover ────────────────────────────────────────
// The reclaim test above covers a serve/mcp daemon retrying until a dead or
// idle-exited owner lets go. This test covers the other half: an owner that
// is still LIVE must be actively signalled to give the socket up right away
// (freshest-wins), instead of the newcomer waiting out a full retry/idle
// cadence. cliServeConn is a private helper, so the owner side is simulated
// here with a tiny raw accept loop that mirrors exactly what it does on
// receipt of cli_yield_sentinel: read the frame, verify it, then give the
// socket up (close the listener + unlink the path).
const CliHandoverOwnerSim = struct {
    fd: c_int,
    sock_path: []const u8,
    sd: *std.atomic.Value(bool),
    saw_sentinel: bool = false,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *@This()) void {
        // Mirror the real accept loop: keep accepting connections and only
        // give the socket up once one of them is the actual yield sentinel.
        // A plain liveness probe (cliSocketLive — connect then close with no
        // data) must NOT be mistaken for a yield request.
        while (true) {
            const conn = std.c.accept(self.fd, null, null);
            if (conn < 0) break;
            var matched = false;
            var hdr: [5]u8 = undefined;
            var off: usize = 0;
            while (off < hdr.len) {
                const n = std.c.read(conn, hdr[off..].ptr, hdr.len - off);
                if (n <= 0) break;
                off += @intCast(n);
            }
            if (off == hdr.len) {
                const blob_len = std.mem.readInt(u32, hdr[1..5], .little);
                if (blob_len > 0 and blob_len <= 256) {
                    var buf: [256]u8 = undefined;
                    var boff: usize = 0;
                    while (boff < blob_len) {
                        const n = std.c.read(conn, buf[boff..].ptr, blob_len - boff);
                        if (n <= 0) break;
                        boff += @intCast(n);
                    }
                    if (boff == blob_len) {
                        matched = std.mem.eql(u8, buf[0..blob_len], cli_proxy_mod.cli_yield_sentinel);
                    }
                }
            }
            _ = std.c.close(conn);
            if (matched) {
                self.saw_sentinel = true;
                break;
            }
        }
        // Mirror the real accept loop's response to a yield request: give the
        // socket up entirely rather than waiting for an idle timeout.
        _ = std.c.close(self.fd);
        var zbuf: [128]u8 = undefined;
        if (cio.bufPrintZ(&zbuf, "{s}", .{self.sock_path})) |z| {
            _ = std.c.unlink(z.ptr);
        } else |_| {}
        self.sd.store(true, .release);
        self.done.store(true, .release);
    }
};

test "issue-619: serve/mcp daemon signals a live owner to yield instead of waiting out the retry cadence" {
    if (@import("builtin").os.tag == .windows) return; // no unix-socket proxy on Windows

    const abs_root = "/codedb-test-issue619-handover";
    var pbuf: [128]u8 = undefined;
    const sock_path = cli_proxy_mod.cliSocketPath(&pbuf, abs_root).?;
    var zbuf: [128]u8 = undefined;
    const sock_z = try cio.bufPrintZ(&zbuf, "{s}", .{sock_path});
    _ = std.c.unlink(sock_z.ptr);
    defer _ = std.c.unlink(sock_z.ptr);

    // A live owner holds the socket (stands in for an auto-spawned
    // cli-daemon or another serve/mcp daemon — same code path either way).
    var owner_sd = std.atomic.Value(bool).init(false);
    const owner_fd = cli_proxy_mod.cliAcquireListener(sock_path, false, 0, &owner_sd).?;
    var owner_sim = CliHandoverOwnerSim{ .fd = owner_fd, .sock_path = sock_path, .sd = &owner_sd };
    const owner_thread = try std.Thread.spawn(.{}, CliHandoverOwnerSim.run, .{&owner_sim});

    // Deliberately large retry interval: without an explicit yield signal,
    // a passive retrying newcomer could only reclaim the socket after a full
    // retry_interval_ms sleep (here 3000ms). The #619 handover instead sends
    // a one-shot yield request the live owner honors immediately, so
    // acquisition must complete far sooner than that passive cadence.
    var newcomer_sd = std.atomic.Value(bool).init(false);
    const start_ms = cio.milliTimestamp();
    const newcomer_fd = cli_proxy_mod.cliAcquireListener(sock_path, true, 3000, &newcomer_sd);
    const elapsed_ms = cio.milliTimestamp() - start_ms;

    owner_thread.join();
    try testing.expect(owner_sim.saw_sentinel); // owner actually received the sentinel frame
    try testing.expect(newcomer_fd != null); // and the newcomer took the socket over
    try testing.expect(elapsed_ms < 1500); // far under the passive 3000ms retry cadence
    if (newcomer_fd) |fd| _ = std.c.close(fd);
}

test "windows: spawnDetached command line round-trips argv with trailing backslashes" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const alloc = testing.allocator;

    const argv = [_][]const u8{ "C:\\tools\\codedb.exe", "D:\\", "cli-daemon", "say \"hi\"", "a\\\\b", "tail\\\\" };
    const cmd = cio.windowsCommandLine(alloc, &argv) orelse return error.TestUnexpectedResult;
    defer alloc.free(cmd);
    const cmd_w = try std.unicode.utf8ToUtf16LeAlloc(alloc, cmd);
    defer alloc.free(cmd_w);

    var it = try std.process.Args.Iterator.Windows.init(alloc, cmd_w);
    defer it.deinit();
    for (argv) |expected| {
        const got = it.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings(expected, got);
    }
    try testing.expect(it.next() == null);
}

test "search: exact-symbol query surfaces one definition without a duplicate nudge" {
    // Def-first rendering already returns the definition path, line, and
    // declaration. A separate nudge repeated the same evidence before it.
    var explorer = Explorer.init(testing.allocator, Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer explorer.deinit();
    try explorer.indexFile("src/thing.zig", "pub fn parseThing() void {}\n");

    var store = Store.init(testing.allocator);
    defer store.deinit();
    var agents = AgentRegistry.init(testing.allocator);
    defer agents.deinit();
    _ = try agents.register("__filesystem__");

    var bench_ctx = mcp_mod.BenchContext.init(testing.allocator, ".", Explorer.DEFAULT_CONTENT_CACHE_CAPACITY);
    defer bench_ctx.deinit();

    const search_json =
        \\{"query":"parseThing"}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, search_json, .{});
    defer parsed.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    bench_ctx.runDispatch(io, testing.allocator, .codedb_search, &parsed.value.object, &out, &store, &explorer, &agents);

    try testing.expect(std.mem.indexOf(u8, out.items, "is defined at") == null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, out.items, "src/thing.zig"));
    try testing.expect(std.mem.indexOf(u8, out.items, "1: pub fn parseThing") != null);
}

test "mcp: emit-rich-blocks defaults lean for agent clients, rich for GUI panels" {
    // Assumes a clean env (no CODEDB_MCP_LEAN/RICH override), as under `zig build test`.
    // Agent harnesses forward tool text straight into model context, so they
    // default LEAN — no colored summary / guidance blocks to pay output tokens for.
    try testing.expect(!mcp_mod.mcpEmitRichBlocks(null)); // no clientInfo -> lean
    try testing.expect(!mcp_mod.mcpEmitRichBlocks("claude-code"));
    try testing.expect(!mcp_mod.mcpEmitRichBlocks("codex"));
    try testing.expect(!mcp_mod.mcpEmitRichBlocks("cursor"));
    // Desktop GUI chat clients render a human-facing result panel -> rich blocks,
    // matched case-insensitively.
    try testing.expect(mcp_mod.mcpEmitRichBlocks("claude-ai"));
    try testing.expect(mcp_mod.mcpEmitRichBlocks("Claude-AI"));
}

test "mcp: agent clients get compact tools while GUI clients get full discovery" {
    // Assumes a clean CODEDB_MCP_TOOL_PROFILE env, as under `zig build test`.
    try testing.expect(mcp_mod.mcpUseCompactToolSurface(null));
    try testing.expect(mcp_mod.mcpUseCompactToolSurface("codex"));
    try testing.expect(mcp_mod.mcpUseCompactToolSurface("claude-code"));
    try testing.expect(mcp_mod.mcpUseCompactToolSurface("cursor"));
    try testing.expect(!mcp_mod.mcpUseCompactToolSurface("claude-ai"));
    try testing.expect(!mcp_mod.mcpUseCompactToolSurface("Claude-AI"));
}
