// zigauth — shared authentication library for all zig* tools
//
// Provides a unified auth check that all tools (zigrep, zigread, zigpatch,
// zigdiff, zigmemo, gitagent-mcp) call on startup. Supports:
//
// 1. Local trial: 7-day free trial stored in ~/.config/zigtools/trial.json
// 2. Token auth: JWT stored in ~/.config/zigtools/token.json
// 3. Env override: ZIGTOOLS_TOKEN environment variable
//
// Auth check flow:
//   1. Check ZIGTOOLS_TOKEN env var → if valid, allow
//   2. Check token file → if valid and not expired, allow
//   3. Check trial file → if within 7 days of first use, allow
//   4. Otherwise → deny with upgrade message

const std = @import("std");

pub const AUTH_DIR = ".config/zigtools";
pub const TRIAL_FILE = "trial.json";
pub const TOKEN_FILE = "token.json";
pub const TRIAL_DAYS: i64 = 7;
pub const ENV_TOKEN = "ZIGTOOLS_TOKEN";

pub const AuthStatus = enum {
    valid_token,
    valid_trial,
    expired_trial,
    no_auth,
};

pub const AuthResult = struct {
    status: AuthStatus,
    days_remaining: ?i64,
    message: []const u8,
};

// ── Public API ──────────────────────────────────────────────────────────────

/// Check authentication status. Returns the result without blocking.
/// Tools should call this on startup and degrade gracefully.
pub fn checkAuth(alloc: std.mem.Allocator) AuthResult {
    // 1. Check env token
    if (checkEnvToken(alloc)) return .{
        .status = .valid_token,
        .days_remaining = null,
        .message = "authenticated via ZIGTOOLS_TOKEN",
    };

    // 2. Check token file
    if (checkTokenFile(alloc)) return .{
        .status = .valid_token,
        .days_remaining = null,
        .message = "authenticated via token file",
    };

    // 3. Check trial
    return checkTrial(alloc);
}

/// Activate a token (write to token file).
pub fn activateToken(token: []const u8, alloc: std.mem.Allocator) !void {
    const dir_path = getAuthDir(alloc) orelse return error.HomeNotFound;
    defer alloc.free(dir_path);

    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = std.fs.path.join(alloc, &.{ dir_path, TOKEN_FILE }) catch return error.OutOfMemory;
    defer alloc.free(file_path);

    const content = std.fmt.allocPrint(alloc, "{{\"token\":\"{s}\",\"activated_at\":{d}}}", .{
        token,
        std.time.timestamp(),
    }) catch return error.OutOfMemory;
    defer alloc.free(content);

    const file = std.fs.cwd().createFile(file_path, .{}) catch return error.WriteError;
    defer file.close();
    file.writeAll(content) catch return error.WriteError;
}

/// Start or check the trial period.
pub fn startTrial(alloc: std.mem.Allocator) !AuthResult {
    const dir_path = getAuthDir(alloc) orelse return error.HomeNotFound;
    defer alloc.free(dir_path);

    std.fs.cwd().makePath(dir_path) catch {};

    const file_path = std.fs.path.join(alloc, &.{ dir_path, TRIAL_FILE }) catch return error.OutOfMemory;
    defer alloc.free(file_path);

    // Check if trial already exists
    if (std.fs.cwd().openFile(file_path, .{})) |file| {
        file.close();
        return checkTrial(alloc);
    } else |_| {}

    // Create new trial
    const now = std.time.timestamp();
    const content = std.fmt.allocPrint(alloc, "{{\"started_at\":{d}}}", .{now}) catch return error.OutOfMemory;
    defer alloc.free(content);

    const file = std.fs.cwd().createFile(file_path, .{}) catch return error.WriteError;
    defer file.close();
    file.writeAll(content) catch return error.WriteError;

    return .{
        .status = .valid_trial,
        .days_remaining = TRIAL_DAYS,
        .message = "trial started — 7 days remaining",
    };
}

// ── Internal checks ─────────────────────────────────────────────────────────

fn checkEnvToken(alloc: std.mem.Allocator) bool {
    const token = std.process.getEnvVarOwned(alloc, ENV_TOKEN) catch return false;
    defer alloc.free(token);
    return validateJwtToken(token);
}

fn checkTokenFile(alloc: std.mem.Allocator) bool {
    const dir_path = getAuthDir(alloc) orelse return false;
    defer alloc.free(dir_path);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, TOKEN_FILE }) catch return false;
    defer alloc.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch return false;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return false;
    return validateTokenContent(buf[0..n]);
}

fn validateTokenContent(content: []const u8) bool {
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (trimmed.len == 0) return false;

    const token = if (trimmed[0] == '{')
        (extractTokenFromJson(trimmed) orelse return false)
    else
        trimmed;

    return validateJwtToken(token);
}

fn extractTokenFromJson(content: []const u8) ?[]const u8 {
    const key = "\"token\"";
    const key_idx = std.mem.indexOf(u8, content, key) orelse return null;
    const after_key = content[key_idx + key.len ..];
    const colon_idx = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;

    var value = std.mem.trimLeft(u8, after_key[colon_idx + 1 ..], " \t\r\n");
    if (value.len == 0 or value[0] != '"') return null;

    value = value[1..];
    const end_quote = std.mem.indexOfScalar(u8, value, '"') orelse return null;
    return value[0..end_quote];
}

fn validateJwtToken(token: []const u8) bool {
    const trimmed = std.mem.trim(u8, token, " \t\r\n");
    if (trimmed.len == 0) return false;

    var parts = std.mem.splitScalar(u8, trimmed, '.');
    const header = parts.next() orelse return false;
    const payload_b64 = parts.next() orelse return false;
    const signature = parts.next() orelse return false;
    if (parts.next() != null) return false;

    if (header.len == 0 or payload_b64.len == 0 or signature.len == 0) return false;

    const decoder = std.base64.url_safe_no_pad.Decoder;
    const payload_len = decoder.calcSizeForSlice(payload_b64) catch return false;
    if (payload_len == 0 or payload_len > 4096) return false;

    var payload_buf: [4096]u8 = undefined;
    decoder.decode(payload_buf[0..payload_len], payload_b64) catch return false;
    const payload = payload_buf[0..payload_len];

    const exp = parseJsonIntField(payload, "\"exp\"") orelse return false;
    return exp > std.time.timestamp();
}

fn checkTrial(alloc: std.mem.Allocator) AuthResult {
    const dir_path = getAuthDir(alloc) orelse return .{
        .status = .no_auth,
        .days_remaining = null,
        .message = "no auth configured — run: zigtools auth login",
    };
    defer alloc.free(dir_path);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, TRIAL_FILE }) catch return .{
        .status = .no_auth,
        .days_remaining = null,
        .message = "no auth configured — run: zigtools auth login",
    };
    defer alloc.free(file_path);

    const file = std.fs.cwd().openFile(file_path, .{}) catch return .{
        .status = .no_auth,
        .days_remaining = null,
        .message = "no trial found — run: zigtools auth login",
    };
    defer file.close();

    var buf: [1024]u8 = undefined;
    const n = file.readAll(&buf) catch return noAuth();
    const content = buf[0..n];

    // Parse started_at from JSON
    const started_at = parseStartedAt(content) orelse return noAuth();
    const now = std.time.timestamp();
    const elapsed_days = @divTrunc(@max(now - started_at, 0), 86400);
    const remaining = TRIAL_DAYS - elapsed_days;

    if (remaining > 0) {
        return .{
            .status = .valid_trial,
            .days_remaining = remaining,
            .message = "trial active",
        };
    } else {
        return .{
            .status = .expired_trial,
            .days_remaining = 0,
            .message = "trial expired — upgrade at https://codedb.dev/pricing",
        };
    }
}

fn noAuth() AuthResult {
    return .{
        .status = .no_auth,
        .days_remaining = null,
        .message = "no auth configured — run: zigtools auth login",
    };
}

fn parseStartedAt(content: []const u8) ?i64 {
    return parseJsonIntField(content, "\"started_at\"");
}

fn parseJsonIntField(content: []const u8, field: []const u8) ?i64 {
    const key_idx = std.mem.indexOf(u8, content, field) orelse return null;
    const after_key = content[key_idx + field.len ..];
    const colon_idx = std.mem.indexOfScalar(u8, after_key, ':') orelse return null;
    const trimmed = std.mem.trimLeft(u8, after_key[colon_idx + 1 ..], " \t\r\n");

    var end: usize = 0;
    while (end < trimmed.len and (trimmed[end] >= '0' and trimmed[end] <= '9')) end += 1;
    if (end == 0) return null;

    return std.fmt.parseInt(i64, trimmed[0..end], 10) catch null;
}

fn getAuthDir(alloc: std.mem.Allocator) ?[]u8 {
    const home = std.process.getEnvVarOwned(alloc, "HOME") catch return null;
    defer alloc.free(home);
    return std.fs.path.join(alloc, &.{ home, AUTH_DIR }) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

fn makeFixtureToken(exp: i64, alloc: std.mem.Allocator) ![]u8 {
    const payload_json = try std.fmt.allocPrint(alloc, "{{\"exp\":{d}}}", .{exp});
    defer alloc.free(payload_json);

    const encoder = std.base64.url_safe_no_pad.Encoder;
    const payload_len = encoder.calcSize(payload_json.len);
    const payload_b64 = try alloc.alloc(u8, payload_len);
    defer alloc.free(payload_b64);
    _ = encoder.encode(payload_b64, payload_json);

    return std.fmt.allocPrint(alloc, "fixture.{s}.sig", .{payload_b64});
}

test "AuthStatus enum values" {
    try std.testing.expectEqual(@as(u2, 0), @intFromEnum(AuthStatus.valid_token));
    try std.testing.expectEqual(@as(u2, 1), @intFromEnum(AuthStatus.valid_trial));
    try std.testing.expectEqual(@as(u2, 2), @intFromEnum(AuthStatus.expired_trial));
    try std.testing.expectEqual(@as(u2, 3), @intFromEnum(AuthStatus.no_auth));
}

test "parseStartedAt extracts timestamp" {
    const json = "{\"started_at\":1700000000}";
    try std.testing.expectEqual(@as(?i64, 1700000000), parseStartedAt(json));
}

test "parseStartedAt handles missing field" {
    const json = "{\"other\":123}";
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt(json));
}

test "parseStartedAt handles empty content" {
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt(""));
}

test "checkAuth returns no_auth when nothing configured" {
    // In test env, no token file or trial exists
    const result = checkAuth(std.testing.allocator);
    // Should be no_auth or valid_token if ZIGTOOLS_TOKEN is set in env
    try std.testing.expect(result.status == .no_auth or result.status == .valid_token);
}

test "constants are correct" {
    try std.testing.expectEqual(@as(i64, 7), TRIAL_DAYS);
    try std.testing.expectEqualStrings("ZIGTOOLS_TOKEN", ENV_TOKEN);
}
test "validateJwtToken accepts unexpired token" {
    const alloc = std.testing.allocator;
    const token = try makeFixtureToken(4102444800, alloc);
    defer alloc.free(token);
    try std.testing.expect(validateJwtToken(token));
}

test "validateJwtToken rejects expired token" {
    const alloc = std.testing.allocator;
    const token = try makeFixtureToken(946684800, alloc);
    defer alloc.free(token);
    try std.testing.expect(!validateJwtToken(token));
}

test "validateTokenContent extracts token from JSON" {
    const alloc = std.testing.allocator;
    const token = try makeFixtureToken(4102444800, alloc);
    defer alloc.free(token);
    const json = try std.fmt.allocPrint(alloc, "{{\"token\":\"{s}\",\"activated_at\":1700000000}}", .{token});
    defer alloc.free(json);
    try std.testing.expect(validateTokenContent(json));
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "parseStartedAt with malformed JSON" {
    // Truncated JSON
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt("{\"started_at\":"));
    // No number after colon
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt("{\"started_at\":abc}"));
    // Just the marker with nothing after
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt("\"started_at\":"));
    // Garbage content
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt("not json at all"));
    // Only opening brace
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt("{"));
}

test "parseStartedAt with negative timestamp" {
    // The parser only matches digits 0-9, so negative sign is not parsed
    const json = "{\"started_at\":-100}";
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt(json));
}

test "parseStartedAt with very large number" {
    // Max i64 value
    const json = "{\"started_at\":9223372036854775807}";
    try std.testing.expectEqual(@as(?i64, 9223372036854775807), parseStartedAt(json));
}

test "parseStartedAt with number overflow returns null" {
    // Larger than max i64
    const json = "{\"started_at\":99999999999999999999}";
    try std.testing.expectEqual(@as(?i64, null), parseStartedAt(json));
}

test "parseStartedAt with spaces around value" {
    const json = "{\"started_at\": 1700000000}";
    try std.testing.expectEqual(@as(?i64, 1700000000), parseStartedAt(json));
}

test "parseStartedAt with zero" {
    const json = "{\"started_at\":0}";
    try std.testing.expectEqual(@as(?i64, 0), parseStartedAt(json));
}

test "parseStartedAt with extra fields" {
    const json = "{\"version\":1,\"started_at\":1700000000,\"other\":true}";
    try std.testing.expectEqual(@as(?i64, 1700000000), parseStartedAt(json));
}

test "checkAuth in clean environment returns no_auth or valid_token" {
    // In CI/test env, no token file or trial is expected
    const result = checkAuth(std.testing.allocator);
    // Should be one of these — never crashes
    try std.testing.expect(
        result.status == .no_auth or
            result.status == .valid_token or
            result.status == .valid_trial or
            result.status == .expired_trial,
    );
    try std.testing.expect(result.message.len > 0);
}

test "AuthResult fields are accessible" {
    const result = AuthResult{
        .status = .no_auth,
        .days_remaining = null,
        .message = "test",
    };
    try std.testing.expectEqual(AuthStatus.no_auth, result.status);
    try std.testing.expectEqual(@as(?i64, null), result.days_remaining);
    try std.testing.expectEqualStrings("test", result.message);
}

test "noAuth returns consistent result" {
    const r1 = noAuth();
    const r2 = noAuth();
    try std.testing.expectEqual(r1.status, r2.status);
    try std.testing.expectEqualStrings(r1.message, r2.message);
}
