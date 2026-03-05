// runtime/resolve.zig — The resolution brain (#276)
//
// Pure function: resolve(request, backends, tools) → ResolvedAgent
//
// Resolution chain (highest priority wins):
//   1. MCP param override (model: "opus" in tool call)
//   2. Role config default (from roles.zig)
//   3. Grid tier (role→model from grid.zig)
//   4. Mode default (smart→Sonnet, deep→Opus, etc.)
//   5. Hardcoded fallback (Sonnet)
//
// resolve() is pure — it reads config and returns a struct.  It never spawns anything.
// dispatch() (dispatch.zig) takes the ResolvedAgent and does the actual spawn.

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

/// Resolve an agent request into a fully-specified ResolvedAgent.
///
/// This is the brain of the orchestration layer.  All decisions about
/// which backend, model, prompt, and tools to use are made here.
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
        break :blk .smart; // default
    };

    // 2. Resolve role spec
    const role_spec = if (request.role) |rn| roles.getRole(rn) else null;

    // 3. Resolve model (priority: MCP param → role spec → grid → mode default)
    const model: []const u8 = blk: {
        // Highest: explicit MCP param
        if (request.model) |m| {
            // Handle aliases
            if (std.mem.eql(u8, m, "opus"))   break :blk "claude-opus-4-6";
            if (std.mem.eql(u8, m, "sonnet")) break :blk "claude-sonnet-4-6";
            if (std.mem.eql(u8, m, "haiku"))  break :blk "claude-haiku-4-5-20251001";
            break :blk m; // pass through full model IDs
        }
        // Role spec override
        if (role_spec) |rs| {
            if (rs.model) |rm| break :blk rm;
        }
        // Grid + mode
        break :blk grid.resolveModel(request.role, mode);
    };

    // 4. Resolve backend (prefer what's available; codex can't take a model param)
    const backend: Backend = blk: {
        // If model is explicitly a Codex model, use codex backend
        if (std.mem.indexOf(u8, model, "codex") != null and backends.codex)
            break :blk .codex;
        // Otherwise use the preferred available backend
        break :blk backends.preferred() orelse .claude;
    };

    // 5. Resolve writable flag (priority: MCP param → role spec → false)
    const writable: bool = blk: {
        if (request.writable) |w| break :blk w;
        if (role_spec) |rs| break :blk rs.writable;
        break :blk false;
    };

    // 6. Resolve allowed_tools (priority: MCP param → role spec → null)
    const allowed_tools: ?[]const u8 = blk: {
        if (request.allowed_tools) |at| break :blk at;
        if (role_spec) |rs| break :blk rs.allowed_tools;
        break :blk null;
    };

    // 7. Resolve max_turns
    const max_turns: ?u32 = blk: {
        if (request.max_turns) |mt| break :blk mt;
        if (role_spec) |rs| break :blk rs.max_turns;
        break :blk null;
    };

    // 8. Assemble system prompt
    const system_prompt = prompts.assemble(
        alloc,
        request.role,
        mode,
        tools.tier(),
    );

    return .{
        .backend       = backend,
        .model         = model,
        .system_prompt = system_prompt,
        .writable      = writable,
        .allowed_tools = allowed_tools,
        .max_turns     = max_turns,
        .cwd           = request.cwd,
        .mode          = mode,
        .role          = request.role,
    };
}

/// Convenience: resolve with live-probed backends and tools.
pub fn resolveWithProbe(alloc: std.mem.Allocator, request: AgentRequest) ResolvedAgent {
    const backends = detect.probe(alloc);
    const tools = cascade.probe(alloc);
    return resolve(alloc, request, backends, tools);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolve: default mode is smart, default model is sonnet" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expectEqual(AgentMode.smart, r.mode);
    try std.testing.expectEqualStrings("claude-sonnet-4-6", r.model);
    try std.testing.expectEqual(Backend.claude, r.backend);
    try std.testing.expect(!r.writable);
}

test "resolve: explicit mode=deep uses opus" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .mode = "deep" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expectEqual(AgentMode.deep, r.mode);
    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: role=fixer sets writable" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "fix it", .role = "fixer" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expect(r.writable);
    try std.testing.expectEqualStrings("fixer", r.role.?);
}

test "resolve: explicit writable=false overrides role" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .role = "fixer", .writable = false };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expect(!r.writable);
}

test "resolve: model alias 'opus' expands to full ID" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .model = "opus" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: grid overrides mode for known roles" {
    const alloc = std.testing.allocator;
    // orchestrator is opus in grid, even if mode is rush (which defaults to haiku)
    const req = AgentRequest{ .prompt = "test", .role = "orchestrator", .mode = "rush" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
    try std.testing.expectEqual(AgentMode.rush, r.mode);
}

test "resolve: falls back to codex when only codex available" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = false, .codex = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expectEqual(Backend.codex, r.backend);
}

test "resolve: system prompt includes tool preamble for zig_tools tier" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .role = "finder" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{
        .has_zigrep = true, .has_zigread = true, .has_zigpatch = true,
    };

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "zigrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "code finder") != null);
}

test "resolve: system prompt falls back to standard tools" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{ .has_rg = true };

    const r = resolve(alloc, req, backends, tools);
    defer alloc.free(r.system_prompt);

    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "rg") != null);
}
