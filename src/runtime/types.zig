// runtime/types.zig — Shared types for the agent orchestration layer.
//
// All runtime modules import this for Backend, AgentMode, ResolvedAgent, etc.

const std = @import("std");

/// Which backend to spawn the agent on.
pub const Backend = enum {
    claude,  // `claude -p` (Claude Code CLI)
    codex,   // `codex app-server` (Codex app-server protocol)

    pub fn label(self: Backend) []const u8 {
        return switch (self) {
            .claude => "claude",
            .codex  => "codex",
        };
    }
};

/// Agent behavior presets.  Each mode maps to a default model tier.
pub const AgentMode = enum {
    smart,  // balanced: Sonnet — good at most tasks
    rush,   // fast/cheap: Haiku — quick answers, low cost
    deep,   // thorough: Opus — hard reasoning, architecture
    free,   // budget: Haiku — same as rush but explicitly cost-free

    pub fn label(self: AgentMode) []const u8 {
        return switch (self) {
            .smart => "smart",
            .rush  => "rush",
            .deep  => "deep",
            .free  => "free",
        };
    }

    pub fn defaultModel(self: AgentMode) []const u8 {
        return switch (self) {
            .smart => "claude-sonnet-4-6",
            .rush  => "claude-haiku-4-5-20251001",
            .deep  => "claude-opus-4-6",
            .free  => "claude-haiku-4-5-20251001",
        };
    }

    pub fn fromString(s: []const u8) ?AgentMode {
        if (std.mem.eql(u8, s, "smart")) return .smart;
        if (std.mem.eql(u8, s, "rush"))  return .rush;
        if (std.mem.eql(u8, s, "deep"))  return .deep;
        if (std.mem.eql(u8, s, "free"))  return .free;
        return null;
    }
};

/// Named agent specification — defines what an agent role looks like.
pub const RoleSpec = struct {
    name: []const u8,           // e.g. "finder", "reviewer", "fixer"
    model: ?[]const u8 = null,  // override model (null = use grid/mode default)
    writable: bool = false,     // can this role write files?
    system_prompt: ?[]const u8 = null, // role-specific instructions
    allowed_tools: ?[]const u8 = null, // tool allowlist (null = all)
    max_turns: ?u32 = null,     // turn limit (null = unlimited)
};

/// The output of resolve() — everything needed to spawn an agent.
pub const ResolvedAgent = struct {
    backend: Backend,
    model: []const u8,
    system_prompt: []const u8,   // assembled: role + mode + tool preamble
    writable: bool,
    allowed_tools: ?[]const u8,
    permission_mode: ?[]const u8,
    reasoning_effort: ?[]const u8,  // "low" | "medium" | "high" | "xhigh" | null
    max_turns: ?u32,
    cwd: ?[]const u8,
    mode: AgentMode,
    role: ?[]const u8,           // role name if one was resolved
};

/// Options passed to run_agent / run_task from MCP tool params.
pub const AgentRequest = struct {
    prompt: []const u8,
    role: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    model: ?[]const u8 = null,
    writable: ?bool = null,
    allowed_tools: ?[]const u8 = null,
    permission_mode: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,  // explicit override; bolt-* aliases also set this
    cwd: ?[]const u8 = null,
    max_turns: ?u32 = null,
};

// ── Tests ─────────────────────────────────────────────────────────────────────

test "types: AgentMode.fromString round-trips" {
    try std.testing.expectEqual(AgentMode.smart, AgentMode.fromString("smart").?);
    try std.testing.expectEqual(AgentMode.rush,  AgentMode.fromString("rush").?);
    try std.testing.expectEqual(AgentMode.deep,  AgentMode.fromString("deep").?);
    try std.testing.expectEqual(AgentMode.free,  AgentMode.fromString("free").?);
    try std.testing.expectEqual(@as(?AgentMode, null), AgentMode.fromString("unknown"));
}

test "types: AgentMode.defaultModel returns expected models" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", AgentMode.smart.defaultModel());
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", AgentMode.rush.defaultModel());
    try std.testing.expectEqualStrings("claude-opus-4-6", AgentMode.deep.defaultModel());
}

test "types: Backend.label returns correct strings" {
    try std.testing.expectEqualStrings("claude", Backend.claude.label());
    try std.testing.expectEqualStrings("codex", Backend.codex.label());
}
