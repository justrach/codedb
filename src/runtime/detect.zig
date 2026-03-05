// runtime/detect.zig — Provider detection (#264)
//
// Probes the environment once to determine which agent backends are available.
// Thread-safe: guarded by mutex, probed once per session.

const std = @import("std");
const gh  = @import("../gh.zig");
const types = @import("types.zig");

const Backend = types.Backend;

/// Bitfield of available backends.
pub const Backends = struct {
    claude: bool = false,
    codex: bool = false,

    pub fn any(self: Backends) bool {
        return self.claude or self.codex;
    }

    /// Return the preferred backend (claude first, then codex).
    /// This is NOT a hardcoded preference — resolve() can override based on
    /// role/mode/config. This is just the "if nothing else says otherwise" default.
    pub fn preferred(self: Backends) ?Backend {
        if (self.claude) return .claude;
        if (self.codex)  return .codex;
        return null;
    }
};

var g_mu: std.Thread.Mutex = .{};
var g_probed: bool = false;
var g_backends: Backends = .{};

/// Probe the environment for available agent backends.
/// Cached after first call.  Thread-safe.
pub fn probe(alloc: std.mem.Allocator) Backends {
    g_mu.lock();
    defer g_mu.unlock();

    if (g_probed) return g_backends;

    // Check for AGENT_SDK_BACKEND=codex override
    const env_backend = std.process.getEnvVarOwned(alloc, "AGENT_SDK_BACKEND") catch "";
    defer if (env_backend.len > 0) alloc.free(env_backend);

    if (std.mem.eql(u8, env_backend, "codex")) {
        // User explicitly wants codex only
        g_backends.codex = true;
        g_probed = true;
        return g_backends;
    }

    // Probe claude CLI
    if (gh.run(alloc, &.{ "claude", "--version" })) |r| {
        r.deinit(alloc);
        g_backends.claude = true;
    } else |_| {
        // Try via login shell (same pattern as agent_sdk.zig)
        const shell = std.process.getEnvVarOwned(alloc, "SHELL") catch
            alloc.dupe(u8, "/bin/zsh") catch "";
        defer if (shell.len > 0) alloc.free(shell);
        if (shell.len > 0) {
            if (gh.run(alloc, &.{ shell, "-lc", "claude --version" })) |r| {
                r.deinit(alloc);
                g_backends.claude = true;
            } else |_| {}
        }
    }

    // Probe codex app-server
    if (gh.run(alloc, &.{ "codex", "--version" })) |r| {
        r.deinit(alloc);
        g_backends.codex = true;
    } else |_| {
        const shell = std.process.getEnvVarOwned(alloc, "SHELL") catch
            alloc.dupe(u8, "/bin/zsh") catch "";
        defer if (shell.len > 0) alloc.free(shell);
        if (shell.len > 0) {
            if (gh.run(alloc, &.{ shell, "-lc", "codex --version" })) |r| {
                r.deinit(alloc);
                g_backends.codex = true;
            } else |_| {}
        }
    }

    g_probed = true;
    return g_backends;
}

/// Force re-probe on next call (e.g. after PATH changes).
pub fn invalidate() void {
    g_mu.lock();
    defer g_mu.unlock();
    g_probed = false;
    g_backends = .{};
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "detect: Backends.preferred returns claude when both available" {
    const b = Backends{ .claude = true, .codex = true };
    try std.testing.expectEqual(Backend.claude, b.preferred().?);
}

test "detect: Backends.preferred returns codex when only codex available" {
    const b = Backends{ .claude = false, .codex = true };
    try std.testing.expectEqual(Backend.codex, b.preferred().?);
}

test "detect: Backends.preferred returns null when none available" {
    const b = Backends{ .claude = false, .codex = false };
    try std.testing.expectEqual(@as(?Backend, null), b.preferred());
}

test "detect: Backends.any returns false when empty" {
    const b = Backends{};
    try std.testing.expect(!b.any());
}

test "detect: invalidate resets probed state" {
    g_probed = true;
    g_backends = .{ .claude = true };
    invalidate();
    try std.testing.expect(!g_probed);
    try std.testing.expect(!g_backends.claude);
}
