// Rate limit management for GitHub API calls
//
// GitHub allows 5000 requests/hour for authenticated users.
// This module provides:
//   - Token bucket rate limiter with configurable capacity/refill
//   - Exponential backoff with jitter for retries
//   - Rate limit header parsing from gh CLI responses
//   - Guardrail: warns when approaching the limit

const std = @import("std");

// ── Constants ───────────────────────────────────────────────────────────────

pub const DEFAULT_CAPACITY: u32 = 5000;
pub const DEFAULT_REFILL_INTERVAL_MS: i64 = 3_600_000; // 1 hour
pub const WARN_THRESHOLD: u32 = 500; // warn when remaining < this
pub const MAX_BACKOFF_MS: u64 = 60_000; // 60 seconds max backoff
pub const BASE_BACKOFF_MS: u64 = 1_000; // 1 second base

// ── Token Bucket Rate Limiter ───────────────────────────────────────────────

pub const RateLimiter = struct {
    capacity: u32,
    remaining: u32,
    reset_at_ms: i64, // unix timestamp ms when bucket refills
    refill_interval_ms: i64,

    pub fn init(capacity: u32) RateLimiter {
        return .{
            .capacity = capacity,
            .remaining = capacity,
            .reset_at_ms = std.time.milliTimestamp() + DEFAULT_REFILL_INTERVAL_MS,
            .refill_interval_ms = DEFAULT_REFILL_INTERVAL_MS,
        };
    }

    /// Try to consume one token. Returns true if allowed, false if rate limited.
    pub fn tryAcquire(self: *RateLimiter) bool {
        self.maybeRefill();
        if (self.remaining > 0) {
            self.remaining -= 1;
            return true;
        }
        return false;
    }

    /// Check if we should warn about approaching the limit.
    pub fn shouldWarn(self: *const RateLimiter) bool {
        return self.remaining <= WARN_THRESHOLD and self.remaining > 0;
    }

    /// Check if we're rate limited (no tokens remaining).
    pub fn isLimited(self: *RateLimiter) bool {
        self.maybeRefill();
        return self.remaining == 0;
    }

    /// Update remaining count from GitHub API response headers.
    pub fn updateFromHeaders(self: *RateLimiter, remaining: u32, reset_epoch: i64) void {
        self.remaining = remaining;
        self.reset_at_ms = reset_epoch * 1000; // GitHub sends seconds
    }

    /// Milliseconds until the bucket refills.
    pub fn msUntilReset(self: *const RateLimiter) i64 {
        const now = std.time.milliTimestamp();
        const diff = self.reset_at_ms - now;
        return @max(diff, 0);
    }

    fn maybeRefill(self: *RateLimiter) void {
        const now = std.time.milliTimestamp();
        if (now >= self.reset_at_ms) {
            self.remaining = self.capacity;
            self.reset_at_ms = now + self.refill_interval_ms;
        }
    }
};

// ── Exponential Backoff ─────────────────────────────────────────────────────

pub const Backoff = struct {
    attempt: u32,
    base_ms: u64,
    max_ms: u64,

    pub fn init() Backoff {
        return .{
            .attempt = 0,
            .base_ms = BASE_BACKOFF_MS,
            .max_ms = MAX_BACKOFF_MS,
        };
    }

    /// Get the next backoff delay in milliseconds.
    /// Uses exponential backoff with full jitter.
    pub fn nextDelayMs(self: *Backoff) u64 {
        const exp: u6 = @intCast(@min(self.attempt, 5));
        const base_delay = self.base_ms * (@as(u64, 1) << exp);
        const capped = @min(base_delay, self.max_ms);
        self.attempt += 1;

        // Add jitter: random value between 0 and capped
        // Use simple deterministic jitter based on attempt count
        const jitter = (capped * (@as(u64, self.attempt) * 7 + 3)) % (capped + 1);
        return @min(jitter, capped);
    }

    /// Reset backoff after a successful request.
    pub fn reset(self: *Backoff) void {
        self.attempt = 0;
    }

    /// True if we've exceeded max retries.
    pub fn exhausted(self: *const Backoff) bool {
        return self.attempt >= 6; // 2^5 = 32 seconds, then give up
    }
};

// ── Rate Limit Header Parsing ───────────────────────────────────────────────

/// Parse X-RateLimit-Remaining from a response string.
/// Looks for patterns like "X-RateLimit-Remaining: 4999"
pub fn parseRateLimitRemaining(response: []const u8) ?u32 {
    return parseHeaderValue(response, "X-RateLimit-Remaining:");
}

/// Parse X-RateLimit-Reset from a response string.
pub fn parseRateLimitReset(response: []const u8) ?i64 {
    const val = parseHeaderValue(response, "X-RateLimit-Reset:") orelse return null;
    return @intCast(val);
}

fn parseHeaderValue(response: []const u8, header: []const u8) ?u32 {
    const idx = std.mem.indexOf(u8, response, header) orelse return null;
    const after = response[idx + header.len ..];
    const trimmed = std.mem.trimLeft(u8, after, " ");

    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] >= '0' and trimmed[end] <= '9') end += 1;
    if (end == 0) return null;

    return std.fmt.parseInt(u32, trimmed[0..end], 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────────────

test "RateLimiter basic acquire" {
    var rl = RateLimiter.init(3);

    try std.testing.expect(rl.tryAcquire());
    try std.testing.expect(rl.tryAcquire());
    try std.testing.expect(rl.tryAcquire());
    try std.testing.expect(!rl.tryAcquire()); // exhausted
    try std.testing.expectEqual(@as(u32, 0), rl.remaining);
}

test "RateLimiter shouldWarn" {
    var rl = RateLimiter.init(5000);
    try std.testing.expect(!rl.shouldWarn()); // 5000 remaining

    rl.remaining = 500;
    try std.testing.expect(rl.shouldWarn());

    rl.remaining = 499;
    try std.testing.expect(rl.shouldWarn());

    rl.remaining = 0;
    try std.testing.expect(!rl.shouldWarn()); // 0 = limited, not warning
}

test "RateLimiter updateFromHeaders" {
    var rl = RateLimiter.init(5000);
    rl.updateFromHeaders(4200, 1700003600);

    try std.testing.expectEqual(@as(u32, 4200), rl.remaining);
    try std.testing.expectEqual(@as(i64, 1700003600000), rl.reset_at_ms);
}

test "Backoff exponential growth" {
    var b = Backoff.init();

    const d0 = b.nextDelayMs();
    const d1 = b.nextDelayMs();
    const d2 = b.nextDelayMs();

    // Each delay should be bounded by the exponential cap
    try std.testing.expect(d0 <= BASE_BACKOFF_MS);
    try std.testing.expect(d1 <= BASE_BACKOFF_MS * 2);
    try std.testing.expect(d2 <= BASE_BACKOFF_MS * 4);
}

test "Backoff reset" {
    var b = Backoff.init();
    _ = b.nextDelayMs();
    _ = b.nextDelayMs();
    try std.testing.expectEqual(@as(u32, 2), b.attempt);

    b.reset();
    try std.testing.expectEqual(@as(u32, 0), b.attempt);
}

test "Backoff exhausted" {
    var b = Backoff.init();
    try std.testing.expect(!b.exhausted());

    b.attempt = 6;
    try std.testing.expect(b.exhausted());
}

test "parseRateLimitRemaining" {
    try std.testing.expectEqual(@as(?u32, 4999), parseRateLimitRemaining("X-RateLimit-Remaining: 4999\n"));
    try std.testing.expectEqual(@as(?u32, 0), parseRateLimitRemaining("X-RateLimit-Remaining: 0\n"));
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining("no header here"));
}

test "parseRateLimitReset" {
    try std.testing.expectEqual(@as(?i64, 1700003600), parseRateLimitReset("X-RateLimit-Reset: 1700003600\n"));
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset("no header here"));
}

test "constants are reasonable" {
    try std.testing.expectEqual(@as(u32, 5000), DEFAULT_CAPACITY);
    try std.testing.expectEqual(@as(u32, 500), WARN_THRESHOLD);
    try std.testing.expectEqual(@as(u64, 60_000), MAX_BACKOFF_MS);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "RateLimiter with capacity=0 is immediately limited" {
    var rl = RateLimiter.init(0);
    try std.testing.expect(!rl.tryAcquire()); // no tokens available
    try std.testing.expect(rl.isLimited());
    try std.testing.expect(!rl.shouldWarn()); // 0 remaining, shouldWarn is false
}

test "RateLimiter with capacity=1" {
    var rl = RateLimiter.init(1);
    // remaining=1, which is <= WARN_THRESHOLD (500) and > 0 → shouldWarn is true
    try std.testing.expect(rl.shouldWarn());

    try std.testing.expect(rl.tryAcquire()); // first acquire succeeds
    try std.testing.expect(!rl.tryAcquire()); // second fails
    try std.testing.expectEqual(@as(u32, 0), rl.remaining);
}

test "Backoff delay values are always bounded by max_ms" {
    var b = Backoff.init();
    var i: u32 = 0;
    while (i < 20) : (i += 1) {
        const delay = b.nextDelayMs();
        try std.testing.expect(delay <= MAX_BACKOFF_MS);
    }
}

test "Backoff after reset returns to base delay range" {
    var b = Backoff.init();
    // Exhaust several attempts
    _ = b.nextDelayMs();
    _ = b.nextDelayMs();
    _ = b.nextDelayMs();
    try std.testing.expectEqual(@as(u32, 3), b.attempt);

    b.reset();
    try std.testing.expectEqual(@as(u32, 0), b.attempt);

    // First delay after reset should be bounded by base
    const d = b.nextDelayMs();
    try std.testing.expect(d <= BASE_BACKOFF_MS);
}

test "parseRateLimitRemaining with malformed header" {
    // Header name present but no number
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining("X-RateLimit-Remaining: \n"));
    // Header name present but followed by letters
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining("X-RateLimit-Remaining: abc\n"));
    // Partial header name
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining("X-RateLimit-Remaining\n"));
    // Empty string
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining(""));
}

test "parseRateLimitRemaining with very large number" {
    // u32 max = 4294967295
    try std.testing.expectEqual(@as(?u32, 4294967295), parseRateLimitRemaining("X-RateLimit-Remaining: 4294967295\n"));
    // Overflow u32
    try std.testing.expectEqual(@as(?u32, null), parseRateLimitRemaining("X-RateLimit-Remaining: 4294967296\n"));
}

test "multiple headers in same response" {
    const response = "Content-Type: application/json\r\nX-RateLimit-Remaining: 4200\r\nX-RateLimit-Reset: 1700003600\r\n";

    try std.testing.expectEqual(@as(?u32, 4200), parseRateLimitRemaining(response));
    try std.testing.expectEqual(@as(?i64, 1700003600), parseRateLimitReset(response));
}

test "RateLimiter msUntilReset is non-negative" {
    var rl = RateLimiter.init(100);
    // reset_at_ms is set to now + refill_interval, so should be positive
    try std.testing.expect(rl.msUntilReset() >= 0);

    // Simulate past reset time
    rl.reset_at_ms = 0;
    try std.testing.expectEqual(@as(i64, 0), rl.msUntilReset());
}

test "RateLimiter updateFromHeaders converts seconds to ms" {
    var rl = RateLimiter.init(5000);
    rl.updateFromHeaders(100, 1000);
    try std.testing.expectEqual(@as(u32, 100), rl.remaining);
    try std.testing.expectEqual(@as(i64, 1000000), rl.reset_at_ms); // 1000 * 1000
}

test "Backoff exhausted boundary" {
    var b = Backoff.init();
    b.attempt = 5;
    try std.testing.expect(!b.exhausted()); // 5 < 6

    b.attempt = 6;
    try std.testing.expect(b.exhausted()); // 6 >= 6

    b.attempt = 100;
    try std.testing.expect(b.exhausted()); // 100 >= 6
}

test "parseRateLimitReset with malformed header" {
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset("X-RateLimit-Reset: abc\n"));
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset("X-RateLimit-Reset: \n"));
    try std.testing.expectEqual(@as(?i64, null), parseRateLimitReset(""));
}

test "parseHeaderValue with number at end of string (no newline)" {
    try std.testing.expectEqual(@as(?u32, 42), parseRateLimitRemaining("X-RateLimit-Remaining: 42"));
}
