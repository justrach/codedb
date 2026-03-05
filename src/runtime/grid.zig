// runtime/grid.zig — Model grid (#265)
//
// Static Role→Model mapping. The grid defines which model tier each role
// gets by default. resolve() uses this as one input in the resolution chain.
//
// Override hierarchy (highest priority first):
//   1. MCP param (model: "opus")
//   2. model_grid.toml override
//   3. Role config default
//   4. Mode default (smart→Sonnet, deep→Opus, etc.)
//   5. Grid tier (this file)
//   6. config.toml [defaults]
//   7. Hardcoded fallback (Sonnet)

const std = @import("std");
const types = @import("types.zig");
const AgentMode = types.AgentMode;

/// Model tier — abstract categories that map to concrete model IDs.
pub const ModelTier = enum {
    haiku,   // fast, cheap: Haiku
    sonnet,  // balanced: Sonnet
    opus,    // powerful: Opus

    pub fn toModelId(self: ModelTier) []const u8 {
        return switch (self) {
            .haiku  => "claude-haiku-4-5-20251001",
            .sonnet => "claude-sonnet-4-6",
            .opus   => "claude-opus-4-6",
        };
    }

    pub fn fromString(s: []const u8) ?ModelTier {
        if (std.mem.eql(u8, s, "haiku"))  return .haiku;
        if (std.mem.eql(u8, s, "sonnet")) return .sonnet;
        if (std.mem.eql(u8, s, "opus"))   return .opus;
        return null;
    }
};

/// Grid entry: role name → recommended model tier.
const GridEntry = struct {
    role: []const u8,
    tier: ModelTier,
};

/// Default grid — can be overridden by model_grid.toml.
const default_grid = [_]GridEntry{
    // Orchestration
    .{ .role = "orchestrator",  .tier = .opus },
    .{ .role = "synthesizer",   .tier = .sonnet },

    // Worker roles
    .{ .role = "finder",        .tier = .sonnet },
    .{ .role = "reviewer",      .tier = .sonnet },
    .{ .role = "fixer",         .tier = .sonnet },
    .{ .role = "explorer",      .tier = .sonnet },
    .{ .role = "architect",     .tier = .opus },

    // Budget roles
    .{ .role = "monitor",       .tier = .haiku },
    .{ .role = "linter",        .tier = .haiku },
    .{ .role = "formatter",     .tier = .haiku },
};

/// Look up the grid tier for a role.  Returns null if the role isn't in the grid.
pub fn tierForRole(role: []const u8) ?ModelTier {
    for (default_grid) |entry| {
        if (std.mem.eql(u8, entry.role, role)) return entry.tier;
    }
    return null;
}

/// Resolve the model ID for a given role + mode combination.
/// Priority: role grid → mode default → fallback (Sonnet).
pub fn resolveModel(role: ?[]const u8, mode: AgentMode) []const u8 {
    // 1. Check grid for role-specific tier
    if (role) |r| {
        if (tierForRole(r)) |tier| {
            return tier.toModelId();
        }
    }
    // 2. Fall back to mode default
    return mode.defaultModel();
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "grid: tierForRole returns correct tiers" {
    try std.testing.expectEqual(ModelTier.opus,   tierForRole("orchestrator").?);
    try std.testing.expectEqual(ModelTier.sonnet, tierForRole("finder").?);
    try std.testing.expectEqual(ModelTier.haiku,  tierForRole("monitor").?);
    try std.testing.expectEqual(@as(?ModelTier, null), tierForRole("unknown_role"));
}

test "grid: resolveModel uses grid for known roles" {
    try std.testing.expectEqualStrings("claude-opus-4-6", resolveModel("orchestrator", .smart));
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolveModel("finder", .rush));
}

test "grid: resolveModel falls back to mode when role unknown" {
    try std.testing.expectEqualStrings("claude-sonnet-4-6", resolveModel("unknown", .smart));
    try std.testing.expectEqualStrings("claude-opus-4-6", resolveModel(null, .deep));
    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", resolveModel(null, .rush));
}

test "grid: ModelTier round-trips" {
    try std.testing.expectEqual(ModelTier.haiku, ModelTier.fromString("haiku").?);
    try std.testing.expectEqual(ModelTier.sonnet, ModelTier.fromString("sonnet").?);
    try std.testing.expectEqual(ModelTier.opus, ModelTier.fromString("opus").?);
    try std.testing.expectEqual(@as(?ModelTier, null), ModelTier.fromString("gpt4"));
}
