// telemetry.zig — opt-in Sentry + Datadog integration.
// Activates when SENTRY_DSN or DD_AGENT_HOST env vars are set.
// All sends are fire-and-forget — never blocks request handling.

const std = @import("std");
const builtin = @import("builtin");
const env_mod = @import("mer");

fn env(name: []const u8) ?[]const u8 {
    return env_mod.env(name);
}

// ── Sentry ──────────────────────────────────────────────────────────────────
// Sends error events to Sentry via the HTTP envelope endpoint.
// Set SENTRY_DSN=https://<key>@<host>/<project_id>

/// Parsed Sentry DSN components.
const SentryConfig = struct {
    key: []const u8,
    host: []const u8,
    project_id: []const u8,
};

pub fn parseSentryDsn(dsn: []const u8) ?SentryConfig {
    // Format: https://<key>@<host>/<project_id>
    const after_scheme = if (std.mem.indexOf(u8, dsn, "://")) |i| dsn[i + 3 ..] else return null;
    const at = std.mem.indexOfScalar(u8, after_scheme, '@') orelse return null;
    const key = after_scheme[0..at];
    const rest = after_scheme[at + 1 ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..slash];
    const project_id = rest[slash + 1 ..];
    if (key.len == 0 or host.len == 0 or project_id.len == 0) return null;
    return .{ .key = key, .host = host, .project_id = project_id };
}

/// Report an error to Sentry. Non-blocking (spawns a thread).
pub fn sentryCapture(
    error_name: []const u8,
    path: []const u8,
    framework_version: []const u8,
) void {
    if (comptime builtin.os.tag == .freestanding) return;
    const dsn_str = env("SENTRY_DSN") orelse return;
    const cfg = parseSentryDsn(dsn_str) orelse return;

    // Build the envelope on the stack.
    var envelope_buf: [4096]u8 = undefined;
    const envelope = std.fmt.bufPrint(&envelope_buf,
        \\{{"dsn":"https://{s}@{s}/{s}"}}
        \\{{"type":"event"}}
        \\{{"level":"error","platform":"other","sdk":{{"name":"merjs","version":"{s}"}},"exception":{{"values":[{{"type":"{s}","value":"Route handler error on {s}"}}]}},"request":{{"url":"{s}"}},"tags":{{"framework":"merjs","zig":"{s}"}}}}
    , .{ cfg.key, cfg.host, cfg.project_id, framework_version, error_name, path, path, @import("builtin").zig_version_string }) catch return;

    // Build the POST URL.
    var url_buf: [256]u8 = undefined;
    const url = std.fmt.bufPrint(
        &url_buf,
        "https://{s}/api/{s}/envelope/",
        .{ cfg.host, cfg.project_id },
    ) catch return;

    const t = spawnSentry(url, envelope) orelse return;
    t.detach();
}

fn spawnSentry(url: []const u8, envelope: []const u8) ?std.Thread {
    // Both buffers and the allocator survive the request's stack frame.
    const alloc = std.heap.page_allocator;
    const url_copy = alloc.dupe(u8, url) catch return null;
    const payload_copy = alloc.dupe(u8, envelope) catch {
        alloc.free(url_copy);
        return null;
    };
    return std.Thread.spawn(.{}, sentrySendThread, .{ url_copy, payload_copy }) catch {
        alloc.free(url_copy);
        alloc.free(payload_copy);
        return null;
    };
}

fn sentrySendThread(url: []const u8, payload: []const u8) void {
    defer {
        const alloc = std.heap.page_allocator;
        alloc.free(url);
        alloc.free(payload);
    }
    const alloc = std.heap.page_allocator;
    var client = std.http.Client{ .allocator = alloc };
    defer client.deinit();

    _ = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = payload,
        .extra_headers = &.{
            .{ .name = "Content-Type", .value = "application/x-sentry-envelope" },
        },
    }) catch {};
}

// ── Datadog (DogStatsD) ─────────────────────────────────────────────────────
// Sends metrics via UDP to the local Datadog agent.
// Set DD_AGENT_HOST (default: 127.0.0.1) and DD_DOGSTATSD_PORT (default: 8125).

var statsd_addr: ?std.net.Address = null;
var statsd_sock: ?std.posix.socket_t = null;

fn getStatsdSocket() ?std.posix.socket_t {
    if (comptime builtin.os.tag == .freestanding) return null;
    if (statsd_sock) |s| return s;

    const host = env("DD_AGENT_HOST") orelse return null;
    const port_str = env("DD_DOGSTATSD_PORT") orelse "8125";
    const port = std.fmt.parseInt(u16, port_str, 10) catch 8125;
    statsd_addr = std.net.Address.parseIp(host, port) catch return null;
    statsd_sock = std.posix.socket(
        std.posix.AF.INET,
        std.posix.SOCK.DGRAM,
        0,
    ) catch return null;
    return statsd_sock;
}

/// Send a timing metric to Datadog.
/// Example: `merjs.request.duration:1234|ms|#path:/,method:GET,status:200`
pub fn ddTiming(path: []const u8, method: []const u8, status: u16, duration_us: u64) void {
    const sock = getStatsdSocket() orelse return;
    const addr = statsd_addr orelse return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.duration:{d}|ms|#path:{s},method:{s},status:{d}\n" ++
            "merjs.request.count:1|c|#path:{s},method:{s},status:{d}",
        .{ duration_us / 1000, path, method, status, path, method, status },
    ) catch return;

    _ = std.posix.sendto(sock, msg, 0, &addr.any, addr.getOsSockLen()) catch {};
}

/// Send an error event to Datadog.
pub fn ddError(path: []const u8, method: []const u8, error_name: []const u8) void {
    const sock = getStatsdSocket() orelse return;
    const addr = statsd_addr orelse return;

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "merjs.request.error:1|c|#path:{s},method:{s},error:{s}",
        .{ path, method, error_name },
    ) catch return;

    _ = std.posix.sendto(sock, msg, 0, &addr.any, addr.getOsSockLen()) catch {};
}

test "parseSentryDsn: valid DSN" {
    const cfg = parseSentryDsn("https://abc123@o1234.ingest.sentry.io/456789").?;
    try std.testing.expectEqualStrings("abc123", cfg.key);
    try std.testing.expectEqualStrings("o1234.ingest.sentry.io", cfg.host);
    try std.testing.expectEqualStrings("456789", cfg.project_id);
}

test "parseSentryDsn: missing scheme returns null" {
    try std.testing.expect(parseSentryDsn("abc123@o1234.ingest.sentry.io/456789") == null);
}

test "parseSentryDsn: missing at-sign returns null" {
    try std.testing.expect(parseSentryDsn("https://o1234.ingest.sentry.io/456789") == null);
}

test "parseSentryDsn: missing project slash returns null" {
    try std.testing.expect(parseSentryDsn("https://abc123@o1234.ingest.sentry.io") == null);
}

test "parseSentryDsn: empty key returns null" {
    try std.testing.expect(parseSentryDsn("https://@o1234.ingest.sentry.io/456789") == null);
}

test "parseSentryDsn: empty project_id returns null" {
    try std.testing.expect(parseSentryDsn("https://abc123@o1234.ingest.sentry.io/") == null);
}

test "security: sentry worker outlives the caller's stack buffers" {
    const thread = blk: {
        var url = "invalid-url".*;
        var payload = "test-envelope".*;
        const worker = spawnSentry(&url, &payload) orelse return error.TestUnexpectedResult;
        @memset(&url, 0);
        @memset(&payload, 0);
        break :blk worker;
    };
    // An invalid URL exercises cleanup without sending any network traffic.
    thread.join();
}
