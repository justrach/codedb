// runtime/roles.zig — Role registry (#259)
//
// Built-in agent role definitions. Each role specifies default behavior
// (writable, system prompt, tool allowlist). Roles are the semantic layer
// between the user's intent and the technical agent configuration.
//
// Future: roles will be loadable from config.toml [agents.*] sections.

const std = @import("std");
const types = @import("types.zig");
const RoleSpec = types.RoleSpec;

/// Built-in roles.  These are the defaults — config.toml can override.
const builtin_roles = [_]RoleSpec{
    .{
        .name = "finder",
        .writable = false,
        .system_prompt = "You are a code finder. Search the codebase to locate relevant files, " ++
            "functions, and patterns. Report findings with file:line references. " ++
            "Do NOT modify any files.",
    },
    .{
        .name = "reviewer",
        .writable = false,
        .system_prompt = "You are a code reviewer. Analyze the code for correctness, memory safety, " ++
            "and best practices. Check: errdefer on every allocation, lock ordering, " ++
            "API correctness, and missing test coverage. " ++
            "Lead with concrete findings, include file:line references. " ++
            "If you find NO issues, respond with exactly: NO_ISSUES_FOUND",
    },
    .{
        .name = "fixer",
        .writable = true,
        .system_prompt = "You are a code fixer. Fix the issues described in your task. " ++
            "Read files before editing, verify each edit with diff. " ++
            "One focused change per file. Do not introduce new functionality — " ++
            "only fix the reported issues.",
    },
    .{
        .name = "explorer",
        .writable = false,
        .system_prompt = "You are a code explorer. Trace execution paths through the codebase. " ++
            "Map affected code paths and gather evidence without proposing fixes. " ++
            "Report your findings with file:line references.",
    },
    .{
        .name = "architect",
        .writable = false,
        .system_prompt = "You are a software architect. Analyze the codebase structure and design " ++
            "implementation plans. Consider trade-offs, identify critical paths, and " ++
            "recommend approaches. Do NOT modify files — output a plan.",
    },
    .{
        .name = "orchestrator",
        .writable = false,
        .system_prompt = "You are a task orchestrator. Decompose the given task into concrete " ++
            "sub-tasks that can be executed by worker agents in parallel. " ++
            "Assign a role to each sub-task. Output valid JSON.",
    },
    .{
        .name = "synthesizer",
        .writable = false,
        .system_prompt = "You are a result synthesizer. Combine the outputs from multiple agents " ++
            "into a single coherent response. Resolve conflicts, deduplicate findings, " ++
            "and present a unified summary.",
    },
    .{
        .name = "monitor",
        .writable = false,
        .system_prompt = "You are a build monitor. Run tests and report results. " ++
            "Do NOT modify any files.",
        .allowed_tools = "Bash",
    },
};

/// Look up a built-in role by name.  Returns null if not found.
pub fn getRole(name: []const u8) ?RoleSpec {
    for (builtin_roles) |role| {
        if (std.mem.eql(u8, role.name, name)) return role;
    }
    return null;
}

/// Return the list of all built-in role names (for documentation / decompose_feature).
pub fn allRoleNames() []const []const u8 {
    const S = struct {
        const names = blk: {
            var arr: [builtin_roles.len][]const u8 = undefined;
            for (builtin_roles, 0..) |role, i| {
                arr[i] = role.name;
            }
            break :blk arr;
        };
    };
    return &S.names;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "roles: getRole returns known roles" {
    const finder = getRole("finder") orelse return error.RoleNotFound;
    try std.testing.expectEqualStrings("finder", finder.name);
    try std.testing.expect(!finder.writable);

    const fixer = getRole("fixer") orelse return error.RoleNotFound;
    try std.testing.expectEqualStrings("fixer", fixer.name);
    try std.testing.expect(fixer.writable);
}

test "roles: getRole returns null for unknown" {
    try std.testing.expectEqual(@as(?RoleSpec, null), getRole("nonexistent"));
}

test "roles: allRoleNames includes expected roles" {
    const names = allRoleNames();
    try std.testing.expect(names.len >= 7);
    // Check finder is in there
    var found = false;
    for (names) |n| {
        if (std.mem.eql(u8, n, "finder")) found = true;
    }
    try std.testing.expect(found);
}

test "roles: reviewer is read-only, fixer is writable" {
    const reviewer = getRole("reviewer").?;
    const fixer = getRole("fixer").?;
    try std.testing.expect(!reviewer.writable);
    try std.testing.expect(fixer.writable);
}

test "roles: orchestrator and synthesizer are read-only" {
    const orch = getRole("orchestrator").?;
    const synth = getRole("synthesizer").?;
    try std.testing.expect(!orch.writable);
    try std.testing.expect(!synth.writable);
}
