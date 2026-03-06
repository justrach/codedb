// runtime/resolve.zig — The resolution brain (#276)
//
// Resolution chain (highest priority wins):
//   1. MCP param override (model: "bolt-pro" in tool call)
//   2. Role config default (from roles.zig)
//   3. Grid tier (role→model from grid.zig)
//   4. Mode default (smart→Sonnet, deep→Opus, etc.)
//   5. Hardcoded fallback (Sonnet)

const std = @import("std");
const types = @import("types.zig");
const detect = @import("detect.zig");
const cascade = @import("cascade.zig");
const grid = @import("grid.zig");
const roles = @import("roles.zig");
const prompts = @import("prompts.zig");

const Backend = types.Backend;
const AgentMode = types.AgentMode;
const ResolvedAgent = types.ResolvedAgent;
const AgentRequest = types.AgentRequest;
const Backends = detect.Backends;
const ToolAvailability = cascade.ToolAvailability;

pub fn resolve(
    alloc: std.mem.Allocator,
    request: AgentRequest,
    backends: Backends,
    tools: ToolAvailability,
) ResolvedAgent {
    // 1. Resolve mode
    const mode: AgentMode = blk: {
        if (request.mode) |m| {
            if (AgentMode.fromString(m)) |parsed| break :blk parsed;
        }
        break :blk .smart;
    };

    // 2. Resolve role spec
    const role_spec = if (request.role) |rn| roles.getRole(rn) else null;

    // 3. Resolve model + reasoning_effort together
    //    bolt-* aliases encode both in one string.
    var alias_effort: ?[]const u8 = null;
    const model: []const u8 = blk: {
        if (request.model) |m| {
            // bolt variants — OpenAI GPT-5.4 with explicit reasoning effort
            if (std.mem.eql(u8, m, "bolt-light"))  { alias_effort = "low";    break :blk "gpt-5.4"; }
            if (std.mem.eql(u8, m, "bolt-medium")) { alias_effort = "medium"; break :blk "gpt-5.4"; }
            if (std.mem.eql(u8, m, "bolt-pro"))    { alias_effort = "high";   break :blk "gpt-5.4"; }
            // single-word aliases
            if (std.mem.eql(u8, m, "bolt"))   break :blk "gpt-5.4";
            if (std.mem.eql(u8, m, "spark"))  break :blk "gpt-5.3-codex-spark";
            if (std.mem.eql(u8, m, "opus"))   break :blk "claude-opus-4-6";
            if (std.mem.eql(u8, m, "sonnet")) break :blk "claude-sonnet-4-6";
            if (std.mem.eql(u8, m, "haiku"))  break :blk "claude-haiku-4-5-20251001";
            break :blk m; // pass through full model IDs
        }
        if (role_spec) |rs| {
            if (rs.model) |rm| break :blk rm;
        }
        break :blk grid.resolveModel(request.role, mode);
    };

    // Explicit request.reasoning_effort beats alias default
    const reasoning_effort: ?[]const u8 = request.reasoning_effort orelse alias_effort;

    // 4. Resolve backend
    //    gpt-* and codex-* models → codex backend when available
    const backend: Backend = blk: {
        const is_openai = std.mem.startsWith(u8, model, "gpt-") or
                          std.mem.indexOf(u8, model, "codex") != null;
        if (is_openai and backends.codex) break :blk .codex;
        break :blk backends.preferred() orelse .claude;
    };

    // 5. Resolve writable flag
    const writable: bool = blk: {
        if (request.writable) |w| break :blk w;
        if (role_spec) |rs| break :blk rs.writable;
        break :blk false;
    };

    // 6. Resolve allowed_tools
    const allowed_tools: ?[]const u8 = blk: {
        if (request.allowed_tools) |at| break :blk at;
        if (role_spec) |rs| break :blk rs.allowed_tools;
        break :blk null;
    };

    // 7. Resolve permission mode
    const permission_mode: ?[]const u8 = request.permission_mode;

    // 8. Resolve max_turns
    const max_turns: ?u32 = blk: {
        if (request.max_turns) |mt| break :blk mt;
        if (role_spec) |rs| break :blk rs.max_turns;
        break :blk null;
    };

    // 9. Assemble system prompt
    const system_prompt = prompts.assemble(
        alloc,
        request.role,
        mode,
        tools.tier(),
    );

    return .{
        .backend          = backend,
        .model            = model,
        .system_prompt    = system_prompt,
        .writable         = writable,
        .allowed_tools    = allowed_tools,
        .permission_mode  = permission_mode,
        .reasoning_effort = reasoning_effort,
        .max_turns        = max_turns,
        .cwd              = request.cwd,
        .mode             = mode,
        .role             = request.role,
    };
}

pub fn resolveWithProbe(alloc: std.mem.Allocator, request: AgentRequest) ResolvedAgent {
    const backends = detect.probe(alloc);
    const tools = cascade.probe(alloc);
    return resolve(alloc, request, backends, tools);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolve: default mode is smart, default model is sonnet" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "test" }, .{ .claude = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", r.model);
    try std.testing.expectEqual(Backend.claude, r.backend);
    try std.testing.expectEqual(@as(?[]const u8, null), r.reasoning_effort);
}

test "resolve: bolt alias → gpt-5.4, no effort" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "bolt" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("gpt-5.4", r.model);
    try std.testing.expectEqual(Backend.codex, r.backend);
    try std.testing.expectEqual(@as(?[]const u8, null), r.reasoning_effort);
}

test "resolve: bolt-light → gpt-5.4 + low effort" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "bolt-light" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("gpt-5.4", r.model);
    try std.testing.expectEqualStrings("low", r.reasoning_effort.?);
}

test "resolve: bolt-medium → gpt-5.4 + medium effort" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "bolt-medium" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("gpt-5.4", r.model);
    try std.testing.expectEqualStrings("medium", r.reasoning_effort.?);
}

test "resolve: bolt-pro → gpt-5.4 + high effort" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "bolt-pro" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("gpt-5.4", r.model);
    try std.testing.expectEqualStrings("high", r.reasoning_effort.?);
}

test "resolve: explicit reasoning_effort overrides alias" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "bolt-light", .reasoning_effort = "xhigh" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("xhigh", r.reasoning_effort.?);
}

test "resolve: spark → gpt-5.3-codex-spark, codex backend" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "t", .model = "spark" }, .{ .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("gpt-5.3-codex-spark", r.model);
    try std.testing.expectEqual(Backend.codex, r.backend);
}

test "resolve: model alias 'opus' expands to full ID" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "test", .model = "opus" }, .{ .claude = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: role=fixer sets writable" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "fix it", .role = "fixer" }, .{ .claude = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expect(r.writable);
}

test "resolve: falls back to codex when only codex available" {
    const alloc = std.testing.allocator;
    const r = resolve(alloc, .{ .prompt = "test" }, .{ .claude = false, .codex = true }, .{});
    defer prompts.freeAssembled(alloc, r.system_prompt);
    try std.testing.expectEqual(Backend.codex, r.backend);
}
