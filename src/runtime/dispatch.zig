// runtime/dispatch.zig — Backend dispatch (#262)
//
// Dumb plumbing: takes a ResolvedAgent + prompt and spawns on the correct backend.
// No decision-making — that's resolve()'s job.
//
// Backends:
//   - claude: spawns `claude -p` with stream-json output
//   - codex:  spawns `codex app-server` with stdio protocol

const std = @import("std");
const types = @import("types.zig");

const Backend = types.Backend;
const ResolvedAgent = types.ResolvedAgent;

/// Dispatch an agent run to the appropriate backend.
/// Writes the agent's text output to `out`.
pub fn dispatch(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    switch (resolved.backend) {
        .claude => spawnClaude(alloc, resolved, prompt, out),
        .codex  => spawnCodex(alloc, resolved, prompt, out),
    }
}

// ── Claude backend ────────────────────────────────────────────────────────

fn spawnClaude(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    const sdk = @import("../agent_sdk.zig");

    const perm_mode: []const u8 =
        if (resolved.writable) "bypassPermissions" else "default";

    const opts: sdk.AgentOptions = .{
        .model           = resolved.model,
        .writable        = resolved.writable,
        .allowed_tools   = resolved.allowed_tools,
        .permission_mode = perm_mode,
        .cwd             = resolved.cwd,
    };

    // Prepend system prompt to the user's prompt
    const full_prompt = if (resolved.system_prompt.len > 0)
        std.fmt.allocPrint(alloc, "{s}{s}", .{ resolved.system_prompt, prompt }) catch prompt
    else
        prompt;
    defer if (full_prompt.ptr != prompt.ptr) alloc.free(full_prompt);

    // Call the raw Claude spawn function directly (not runAgent, to avoid circular deps)
    if (sdk.tryClaudeAgent(alloc, full_prompt, opts, out)) return;

    // If Claude spawn failed, fall back to codex within this dispatch
    spawnCodex(alloc, resolved, prompt, out);
}

// ── Codex backend ─────────────────────────────────────────────────────────

fn spawnCodex(
    alloc: std.mem.Allocator,
    resolved: ResolvedAgent,
    prompt: []const u8,
    out: *std.ArrayList(u8),
) void {
    const cas = @import("../codex_appserver.zig");

    const policy: cas.SandboxPolicy = if (resolved.writable) .writable else .read_only;

    // Prepend system prompt to the user's prompt
    const full_prompt = if (resolved.system_prompt.len > 0)
        std.fmt.allocPrint(alloc, "{s}{s}", .{ resolved.system_prompt, prompt }) catch prompt
    else
        prompt;
    defer if (full_prompt.ptr != prompt.ptr) alloc.free(full_prompt);

    cas.runTurnPolicy(alloc, full_prompt, out, policy);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

// dispatch() can only be integration-tested (needs actual claude/codex on PATH).
// Unit tests validate the dispatch routing logic via the Backend enum.

test "dispatch: Backend.label is correct" {
    try std.testing.expectEqualStrings("claude", Backend.claude.label());
    try std.testing.expectEqualStrings("codex", Backend.codex.label());
}
