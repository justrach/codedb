// runtime/prompts.zig — System prompt assembly (#267)
//
// Builds the full system prompt for an agent from:
//   1. Role-specific instructions (from roles.zig)
//   2. Mode behavior guidance
//   3. Tool preamble (dynamic, based on cascade.zig detection)
//
// The assembled prompt is what gets injected before the user's task prompt.

const std = @import("std");
const types = @import("types.zig");
const cascade = @import("cascade.zig");
const roles = @import("roles.zig");

const AgentMode = types.AgentMode;
const ToolTier = cascade.ToolTier;

// ── Tool Preambles ───────────────────────────────────────────────────────────

const ZIG_TOOLS_PREAMBLE =
    \\ENVIRONMENT: The following shell commands are on PATH and MUST be used for all file I/O:
    \\
    \\  zigrep  "pattern" path/          # search code (scope mode: zigrep -S)
    \\  zigread FILE                     # read file with line numbers
    \\  zigread -o FILE                  # structural outline
    \\  zigread -s SYMBOL FILE           # extract function by name
    \\  zigread -L FROM-TO FILE          # read line range
    \\  zigpatch FILE FROM-TO <<'EOF'    # replace line range
    \\    new content
    \\  EOF
    \\  zigpatch FILE -s SYMBOL <<'EOF'  # replace function by name (immune to line drift)
    \\    new content
    \\  EOF
    \\  zigcreate FILE --content "..."   # create new file
    \\  zigdiff FILE                     # verify edit landed correctly
    \\
    \\RULES:
    \\  - NEVER use sed, awk, patch, tee, echo/printf redirects (>, >>), or heredocs to write files
    \\  - Always zigread before zigpatch; always zigdiff after zigpatch
    \\  - One focused change per file; do not rewrite files wholesale
    \\  - Cite file:line for every finding
    \\  - Prefer zigpatch -s SYMBOL for multi-iteration edits (immune to line drift)
    \\
;

const STANDARD_TOOLS_PREAMBLE =
    \\ENVIRONMENT: Use standard shell tools for file I/O:
    \\
    \\  rg "pattern" path/               # search code (ripgrep)
    \\  cat -n FILE                      # read file with line numbers
    \\  sed -i 's/old/new/g' FILE        # edit file in-place
    \\  grep -rn "pattern" path/         # search (fallback)
    \\
    \\RULES:
    \\  - Read before editing; verify after editing
    \\  - One focused change per file
    \\  - Cite file:line for every finding
    \\
;

const MINIMAL_TOOLS_PREAMBLE =
    \\ENVIRONMENT: Only basic shell tools available:
    \\
    \\  grep -rn "pattern" path/         # search code
    \\  cat -n FILE                      # read file
    \\
    \\RULES:
    \\  - Read before editing; cite file:line for findings
    \\
;

// ── Mode Guidance ───────────────────────────────────────────────────────────

fn modeGuidance(mode: AgentMode) []const u8 {
    return switch (mode) {
        .smart => "MODE: balanced — thorough but concise. Explore enough to be confident, then act.",
        .rush  => "MODE: fast — give the quickest useful answer. Skip deep analysis. Be brief.",
        .deep  => "MODE: thorough — take your time. Explore all angles. Explain your reasoning.",
        .free  => "MODE: budget — minimal resource usage. Short answers, no unnecessary exploration.",
    };
}

/// Get the tool preamble for a given tier.
pub fn toolPreamble(tier: ToolTier) []const u8 {
    return switch (tier) {
        .zig_tools => ZIG_TOOLS_PREAMBLE,
        .standard  => STANDARD_TOOLS_PREAMBLE,
        .minimal   => MINIMAL_TOOLS_PREAMBLE,
    };
}

/// Assemble the full system prompt from role + mode + tool tier.
/// Caller owns the returned slice.
pub fn assemble(
    alloc: std.mem.Allocator,
    role_name: ?[]const u8,
    mode: AgentMode,
    tier: ToolTier,
) []const u8 {
    const role_prompt: []const u8 = blk: {
        if (role_name) |rn| {
            if (roles.getRole(rn)) |role| {
                if (role.system_prompt) |sp| break :blk sp;
            }
        }
        break :blk "";
    };

    const mode_line = modeGuidance(mode);
    const tool_pre = toolPreamble(tier);

    // Format: [role instructions]\n[mode line]\n\n[tool preamble]\nTask:\n
    return std.fmt.allocPrint(alloc,
        "{s}\n{s}\n\n{s}\nTask:\n",
        .{ role_prompt, mode_line, tool_pre },
    ) catch alloc.dupe(u8, tool_pre) catch "";
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "prompts: toolPreamble returns correct preamble for each tier" {
    const zig_pre = toolPreamble(.zig_tools);
    try std.testing.expect(std.mem.indexOf(u8, zig_pre, "zigrep") != null);

    const std_pre = toolPreamble(.standard);
    try std.testing.expect(std.mem.indexOf(u8, std_pre, "rg") != null);

    const min_pre = toolPreamble(.minimal);
    try std.testing.expect(std.mem.indexOf(u8, min_pre, "grep") != null);
}

test "prompts: assemble includes role, mode, and tools" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, "finder", .smart, .zig_tools);
    defer alloc.free(result);

    // Should contain role prompt
    try std.testing.expect(std.mem.indexOf(u8, result, "code finder") != null);
    // Should contain mode guidance
    try std.testing.expect(std.mem.indexOf(u8, result, "balanced") != null);
    // Should contain tool preamble
    try std.testing.expect(std.mem.indexOf(u8, result, "zigrep") != null);
}

test "prompts: assemble with null role still includes mode and tools" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, null, .rush, .standard);
    defer alloc.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "fast") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rg") != null);
}

test "prompts: assemble with unknown role falls back gracefully" {
    const alloc = std.testing.allocator;
    const result = assemble(alloc, "nonexistent_role", .deep, .zig_tools);
    defer alloc.free(result);

    // Should still have mode + tools, just no role prompt
    try std.testing.expect(std.mem.indexOf(u8, result, "thorough") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "zigrep") != null);
}
