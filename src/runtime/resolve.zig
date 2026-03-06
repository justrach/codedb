// runtime/resolve.zig — The resolution brain (#276)
//
// Pure function: resolve(request, backends, tools, cfg) → ResolvedAgent
//
// Resolution chain (highest priority wins):
//   1. MCP param override (model: "opus" in tool call)
//   2. config.toml [agents.<role>] model/backend override
//   3. Role config default (from roles.zig)
//   4. Grid tier (role→model from grid.zig)
//   5. Mode default (smart→Sonnet, deep→Opus, etc.)
//   6. config.toml [provider] claude_default
//   7. Hardcoded fallback (Sonnet)
//
// resolve() is pure — it reads no files itself.  It never spawns anything.
// dispatch() (dispatch.zig) takes the ResolvedAgent and does the actual spawn.

const std = @import("std");
const types   = @import("types.zig");
const detect  = @import("detect.zig");
const cascade = @import("cascade.zig");
const grid    = @import("grid.zig");
const roles   = @import("roles.zig");
const prompts = @import("prompts.zig");
const config  = @import("../config.zig");

const Backend         = types.Backend;
const AgentMode       = types.AgentMode;
const ResolvedAgent   = types.ResolvedAgent;
const AgentRequest    = types.AgentRequest;
const Backends        = detect.Backends;
const ToolAvailability = cascade.ToolAvailability;

/// Resolve an agent request into a fully-specified ResolvedAgent.
///
/// cfg may be null — if so the resolution chain skips config-file steps.
pub fn resolve(
    alloc:    std.mem.Allocator,
    request:  AgentRequest,
    backends: Backends,
    tools:    ToolAvailability,
    cfg:      ?config.Config,
) ResolvedAgent {
    // 1. Resolve mode
    const mode: AgentMode = blk: {
        if (request.mode) |m| {
            if (AgentMode.fromString(m)) |parsed| break :blk parsed;
        }
        break :blk .smart; // default
    };

    // 2. Resolve role spec (static built-in)
    const role_spec = if (request.role) |rn| roles.getRole(rn) else null;

    // 2b. Resolve per-role config override (from config.toml)
    const role_cfg: ?config.RoleConfig = blk: {
        const c = cfg orelse break :blk null;
        const rn = request.role orelse break :blk null;
        break :blk c.roles.get(rn);
    };

    // 3. Resolve model
    //    Priority: MCP param → config [agents.<role>].model
    //              → role spec → grid → mode default → config claude_default → Sonnet
    const model: []const u8 = blk: {
        // Highest: explicit MCP param
        if (request.model) |m| {
            break :blk expandAlias(m);
        }
        // config.toml per-role model
        if (role_cfg) |rc| {
            if (rc.model) |m| break :blk expandAlias(m);
        }
        // Static role spec model
        if (role_spec) |rs| {
            if (rs.model) |rm| break :blk rm;
        }
        // Grid role-specific tier (overrides mode default and claude_default)
        if (request.role) |rn| {
            if (grid.tierForRole(rn)) |tier| break :blk tier.toModelId();
        }
        // config.toml global claude_default (beats mode default, lost to grid)
        if (cfg) |c| {
            if (c.claude_default) |d| break :blk expandAlias(d);
        }
        // Mode default (final fallback)
        break :blk mode.defaultModel();
    };

    // 4. Resolve backend
    //    Priority: explicit codex model → config [agents.<role>].backend
    //              → config [provider].primary → probed preferred
    const backend: Backend = blk: {
        // If model is explicitly a Codex model, use codex backend
        if (std.mem.indexOf(u8, model, "codex") != null and backends.codex)
            break :blk .codex;
        // config.toml per-role backend override
        if (role_cfg) |rc| {
            if (rc.backend) |b| {
                if (std.mem.eql(u8, b, "claude") and backends.claude) break :blk .claude;
                if (std.mem.eql(u8, b, "codex")  and backends.codex)  break :blk .codex;
            }
        }
        // config.toml global provider.primary
        if (cfg) |c| {
            if (c.primary) |p| {
                if (std.mem.eql(u8, p, "claude") and backends.claude) break :blk .claude;
                if (std.mem.eql(u8, p, "codex")  and backends.codex)  break :blk .codex;
            }
        }
        // Probe-based preferred
        break :blk backends.preferred() orelse .claude;
    };

    // 5. Resolve writable flag
    //    Priority: MCP param → config sandbox → role spec → false
    const writable: bool = blk: {
        if (request.writable) |w| break :blk w;
        if (role_cfg) |rc| {
            if (rc.sandbox) |s| break :blk std.mem.eql(u8, s, "write");
        }
        if (role_spec) |rs| break :blk rs.writable;
        break :blk false;
    };

    // 6. Resolve allowed_tools
    const allowed_tools: ?[]const u8 = blk: {
        if (request.allowed_tools) |at| break :blk at;
        if (role_spec) |rs| break :blk rs.allowed_tools;
        break :blk null;
    };

    // 7. Resolve permission mode (explicit MCP param only)
    const permission_mode: ?[]const u8 = request.permission_mode;

    // 8. Resolve max_turns
    //    Priority: MCP param → config [agents.<role>].max_turns → role spec → null
    const max_turns: ?u32 = blk: {
        if (request.max_turns) |mt| break :blk mt;
        if (role_cfg) |rc| {
            if (rc.max_turns) |mt| break :blk mt;
        }
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
        .backend         = backend,
        .model           = model,
        .system_prompt   = system_prompt,
        .writable        = writable,
        .allowed_tools   = allowed_tools,
        .permission_mode = permission_mode,
        .max_turns       = max_turns,
        .cwd             = request.cwd,
        .mode            = mode,
        .role            = request.role,
    };
}

/// Convenience: resolve with live-probed backends, tools, and default config.
pub fn resolveWithProbe(alloc: std.mem.Allocator, request: AgentRequest) ResolvedAgent {
    const backends = detect.probe(alloc);
    const tools    = cascade.probe(alloc);
    var cfg        = config.loadDefault(alloc);
    defer if (cfg) |*c| c.deinit(alloc);
    return resolve(alloc, request, backends, tools, cfg);
}

/// Expand short model aliases to full canonical IDs.
fn expandAlias(m: []const u8) []const u8 {
    if (std.mem.eql(u8, m, "opus"))   return "claude-opus-4-6";
    if (std.mem.eql(u8, m, "sonnet")) return "claude-sonnet-4-6";
    if (std.mem.eql(u8, m, "haiku"))  return "claude-haiku-4-5-20251001";
    return m; // pass-through for full model IDs
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "resolve: default mode is smart, default model is sonnet" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

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

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqual(AgentMode.deep, r.mode);
    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: role=fixer sets writable" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "fix it", .role = "fixer" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expect(r.writable);
    try std.testing.expectEqualStrings("fixer", r.role.?);
}

test "resolve: explicit writable=false overrides role" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .role = "fixer", .writable = false };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expect(!r.writable);
}

test "resolve: model alias 'opus' expands to full ID" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .model = "opus" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}

test "resolve: grid overrides mode for known roles" {
    const alloc = std.testing.allocator;
    // orchestrator is opus in grid, even if mode is rush (which defaults to haiku)
    const req = AgentRequest{ .prompt = "test", .role = "orchestrator", .mode = "rush" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
    try std.testing.expectEqual(AgentMode.rush, r.mode);
}

test "resolve: falls back to codex when only codex available" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = false, .codex = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqual(Backend.codex, r.backend);
}

test "resolve: system prompt includes tool preamble for zig_tools tier" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test", .role = "finder" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{
        .has_zigrep = true, .has_zigread = true, .has_zigpatch = true,
    };

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "zigrep") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "code finder") != null);
}

test "resolve: system prompt falls back to standard tools" {
    const alloc = std.testing.allocator;
    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{ .has_rg = true };

    const r = resolve(alloc, req, backends, tools, null);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expect(std.mem.indexOf(u8, r.system_prompt, "rg") != null);
}

test "resolve: config.toml [agents.finder] model=haiku overrides grid" {
    const alloc = std.testing.allocator;

    // Build a Config with finder → haiku
    var roles_map = std.StringHashMap(config.RoleConfig).init(alloc);
    try roles_map.put(try alloc.dupe(u8, "finder"), .{ .model = try alloc.dupe(u8, "haiku") });
    var cfg = config.Config{
        .roles = roles_map,
    };
    defer cfg.deinit(alloc);

    const req = AgentRequest{ .prompt = "find it", .role = "finder" };
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, cfg);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqualStrings("claude-haiku-4-5-20251001", r.model);
}

test "resolve: config.toml [provider].primary=codex routes to codex backend" {
    const alloc = std.testing.allocator;

    var cfg = config.Config{
        .primary = try alloc.dupe(u8, "codex"),
        .roles   = std.StringHashMap(config.RoleConfig).init(alloc),
    };
    defer cfg.deinit(alloc);

    const req = AgentRequest{ .prompt = "test" };
    const backends = Backends{ .claude = true, .codex = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, cfg);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqual(Backend.codex, r.backend);
}

test "resolve: config.toml [agents.reviewer] backend=codex and max_turns=3" {
    const alloc = std.testing.allocator;

    var roles_map = std.StringHashMap(config.RoleConfig).init(alloc);
    try roles_map.put(try alloc.dupe(u8, "reviewer"), .{
        .backend   = try alloc.dupe(u8, "codex"),
        .max_turns = 3,
    });
    var cfg = config.Config{ .roles = roles_map };
    defer cfg.deinit(alloc);

    const req = AgentRequest{ .prompt = "review it", .role = "reviewer" };
    const backends = Backends{ .claude = true, .codex = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, cfg);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqual(Backend.codex, r.backend);
    try std.testing.expectEqual(@as(?u32, 3), r.max_turns);
}

test "resolve: config.toml claude_default=opus applies when no role/grid override" {
    const alloc = std.testing.allocator;

    var cfg = config.Config{
        .claude_default = try alloc.dupe(u8, "opus"),
        .roles          = std.StringHashMap(config.RoleConfig).init(alloc),
    };
    defer cfg.deinit(alloc);

    // Role "finder" normally gets sonnet from grid — grid wins over claude_default
    // But a role with NO grid entry (e.g. "custom") should get opus from claude_default
    const req = AgentRequest{ .prompt = "test" }; // no role → falls through to claude_default
    const backends = Backends{ .claude = true };
    const tools = ToolAvailability{};

    const r = resolve(alloc, req, backends, tools, cfg);
    defer prompts.freeAssembled(alloc, r.system_prompt);

    try std.testing.expectEqualStrings("claude-opus-4-6", r.model);
}
