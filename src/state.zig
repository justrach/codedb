// gitagent-mcp — Label-based state machine
//
// GitHub is the state store. State is encoded in labels.
// This module defines the label constants and the transition logic.
//
// State transitions:
//   backlog ──(create_branch)──▶ in-progress
//   in-progress ──(create_pr)──▶ in-review
//   in-review ──(PR merged)────▶ done
//   any state ──(link_issues)──▶ blocked  (original label retained alongside)
//
// See issue #10 for full implementation.

const std = @import("std");

// ── Status label names ────────────────────────────────────────────────────────

pub const STATUS_BACKLOG     = "status:backlog";
pub const STATUS_IN_PROGRESS = "status:in-progress";
pub const STATUS_IN_REVIEW   = "status:in-review";
pub const STATUS_DONE        = "status:done";
pub const STATUS_BLOCKED     = "status:blocked";

/// All status labels — used to strip old status before applying new one.
pub const ALL_STATUS_LABELS = [_][]const u8{
    STATUS_BACKLOG,
    STATUS_IN_PROGRESS,
    STATUS_IN_REVIEW,
    STATUS_DONE,
    STATUS_BLOCKED,
};

// ── Priority label names ──────────────────────────────────────────────────────

pub const PRIORITY_P0 = "priority:p0";
pub const PRIORITY_P1 = "priority:p1";
pub const PRIORITY_P2 = "priority:p2";
pub const PRIORITY_P3 = "priority:p3";

pub const ALL_PRIORITY_LABELS = [_][]const u8{
    PRIORITY_P0, PRIORITY_P1, PRIORITY_P2, PRIORITY_P3,
};

// ── Branch naming ─────────────────────────────────────────────────────────────

pub const BranchType = enum { feature, fix };

/// Build a branch name: {type}/{issue_number}-{slugified_title}
/// Caller owns the returned slice (alloc.free).
pub fn buildBranchName(
    alloc: std.mem.Allocator,
    branch_type: BranchType,
    issue_number: u32,
    issue_title: []const u8,
) ![]u8 {
    const prefix: []const u8 = switch (branch_type) {
        .feature => "feature",
        .fix     => "fix",
    };
    const slug = try slugify(alloc, issue_title);
    defer alloc.free(slug);

    return std.fmt.allocPrint(alloc, "{s}/{d}-{s}", .{ prefix, issue_number, slug });
}

/// Slugify: lowercase, spaces and special chars → hyphens, collapse consecutive hyphens.
/// Caller owns the returned slice.
pub fn slugify(alloc: std.mem.Allocator, title: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_was_hyphen = false;

    for (title) |c| {
        const lower = std.ascii.toLower(c);
        if (std.ascii.isAlphanumeric(lower)) {
            out.append(alloc, lower) catch return error.OutOfMemory;
            last_was_hyphen = false;
        } else if (!last_was_hyphen and out.items.len > 0) {
            out.append(alloc, '-') catch return error.OutOfMemory;
            last_was_hyphen = true;
        }
    }

    // Trim trailing hyphen
    var result = try out.toOwnedSlice(alloc);
    if (result.len > 0 and result[result.len - 1] == '-') {
        result = result[0 .. result.len - 1];
    }

    // Cap at 50 chars to keep branch names sane
    if (result.len > 50) result = result[0..50];

    return result;
}

/// Validate a branch name against the naming convention.
/// Returns true if it matches: (feature|fix)/{digits}-{slug}
pub fn isConventionBranch(name: []const u8) bool {
    const prefixes = [_][]const u8{ "feature/", "fix/" };
    for (prefixes) |pfx| {
        if (std.mem.startsWith(u8, name, pfx)) {
            const rest = name[pfx.len..];
            // Must have at least one digit followed by '-'
            var i: usize = 0;
            while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
            if (i > 0 and i < rest.len and rest[i] == '-') return true;
        }
    }
    return false;
}

/// Parse the issue number from a convention branch name.
/// Returns null if the branch does not follow the convention.
pub fn parseIssueNumber(branch_name: []const u8) ?u32 {
    const prefixes = [_][]const u8{ "feature/", "fix/" };
    for (prefixes) |pfx| {
        if (std.mem.startsWith(u8, branch_name, pfx)) {
            const rest = branch_name[pfx.len..];
            var i: usize = 0;
            while (i < rest.len and std.ascii.isDigit(rest[i])) : (i += 1) {}
            if (i > 0) {
                return std.fmt.parseInt(u32, rest[0..i], 10) catch null;
            }
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "slugify basic" {
    const alloc = std.testing.allocator;
    const s = try slugify(alloc, "Add GitHub MCP Tools");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("add-github-mcp-tools", s);
}

test "slugify special chars" {
    const alloc = std.testing.allocator;
    const s = try slugify(alloc, "[INFRA] Project scaffold: Node.js + Zig");
    defer alloc.free(s);
    try std.testing.expectEqualStrings("infra-project-scaffold-node-js-zig", s);
}

test "parseIssueNumber" {
    try std.testing.expectEqual(@as(?u32, 7), parseIssueNumber("feature/7-issue-management-tools"));
    try std.testing.expectEqual(@as(?u32, 12), parseIssueNumber("fix/12-startup-crash"));
    try std.testing.expectEqual(@as(?u32, null), parseIssueNumber("main"));
    try std.testing.expectEqual(@as(?u32, null), parseIssueNumber("feature/no-issue-number"));
}

test "isConventionBranch" {
    try std.testing.expect(isConventionBranch("feature/1-scaffold"));
    try std.testing.expect(isConventionBranch("fix/42-crash-fix"));
    try std.testing.expect(!isConventionBranch("main"));
    try std.testing.expect(!isConventionBranch("feature/no-number"));
}
