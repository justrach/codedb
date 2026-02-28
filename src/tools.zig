// gitagent-mcp — Tool definitions
//
// Implements all 17 GitHub workflow tools across 5 groups:
//   Planning    → decompose_feature, get_project_state, get_next_task, prioritize_issues
//   Issues      → create_issue, create_issues_batch, update_issue, close_issue, link_issues
//   Branches    → create_branch, get_current_branch, commit_with_context, push_branch
//   Pull Reqs   → create_pr, get_pr_status, list_open_prs
//   Analysis    → review_pr_impact
//
// Each handler writes its result to `out: *std.ArrayList(u8)`.
// Whatever ends up in `out` becomes the tool response text shown to the model.
// On error: write a JSON error object to `out` — never crash the server.

const std   = @import("std");
const mj    = @import("mcp").json;
const gh    = @import("gh.zig");
const cache = @import("cache.zig");
const state  = @import("state.zig");
const search = @import("search.zig");

// ── Step 1: Tool enum ─────────────────────────────────────────────────────────

pub const Tool = enum {
    // Planning
    decompose_feature,
    get_project_state,
    get_next_task,
    prioritize_issues,
    // Issues
    create_issue,
    create_issues_batch,
    update_issue,
    close_issue,
    link_issues,
    // Branches & commits
    create_branch,
    get_current_branch,
    commit_with_context,
    push_branch,
    // Pull requests
    create_pr,
    get_pr_status,
    list_open_prs,
    // Analysis
    review_pr_impact,
    blast_radius,
    relevant_context,
    git_history_for,
    recently_changed,
};

// ── Step 2: Tool schemas ──────────────────────────────────────────────────────
//
// Descriptions tell the model WHEN and HOW to call each tool.
// writeResult strips \n before sending — multiline literals are fine here.

pub const tools_list =
    \\{"tools":[
    \\{"name":"decompose_feature","description":"Break a natural language feature description into ordered GitHub Issue drafts. Returns a JSON schema and available labels/milestones for the caller to populate. Call this before any new feature work.","inputSchema":{"type":"object","properties":{"feature_description":{"type":"string","description":"Plain English description of the feature to build"}},"required":["feature_description"]}},
    \\{"name":"get_project_state","description":"Return all open issues grouped by status label, all open branches, and all open PRs. Use this to understand current project state before picking up work.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"get_next_task","description":"Return the single highest-priority unblocked issue that has no open branch. Use this to decide what to work on next.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"prioritize_issues","description":"Apply priority labels (priority:p0–p3) to a set of issues based on their dependency order. Sinks (no dependents) get p0; independent issues get p2.","inputSchema":{"type":"object","properties":{"issue_numbers":{"type":"array","items":{"type":"integer"},"description":"Issue numbers to prioritize"}},"required":["issue_numbers"]}},
    \\{"name":"create_issue","description":"Create a single GitHub issue with title, body, labels, and optional milestone. Automatically applies status:backlog if no status label is provided.","inputSchema":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"labels":{"type":"array","items":{"type":"string"}},"milestone":{"type":"string"},"parent_issue":{"type":"integer","description":"Issue number this is a subtask of"}},"required":["title"]}},
    \\{"name":"create_issues_batch","description":"Create multiple GitHub issues in one call. Issues are fired concurrently in batches of 5 with a 200ms collection window. Use this after decompose_feature to create all issues at once.","inputSchema":{"type":"object","properties":{"issues":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"body":{"type":"string"},"labels":{"type":"array","items":{"type":"string"}},"milestone":{"type":"string"}},"required":["title"]}}},"required":["issues"]}},
    \\{"name":"update_issue","description":"Update an existing issue's title, body, or labels.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer"},"title":{"type":"string"},"body":{"type":"string"},"add_labels":{"type":"array","items":{"type":"string"}},"remove_labels":{"type":"array","items":{"type":"string"}}},"required":["issue_number"]}},
    \\{"name":"close_issue","description":"Close an issue and mark it status:done. Optionally reference the PR that resolved it.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer"},"pr_number":{"type":"integer","description":"PR number that resolves this issue"}},"required":["issue_number"]}},
    \\{"name":"link_issues","description":"Mark one issue as blocked by others. Adds status:blocked to each blocked issue and writes dependency references into issue bodies.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer","description":"The issue that blocks others"},"blocks":{"type":"array","items":{"type":"integer"},"description":"Issue numbers that are blocked by issue_number"}},"required":["issue_number","blocks"]}},
    \\{"name":"create_branch","description":"Create a feature or fix branch linked to an issue. Branch name: {type}/{issue_number}-{slugified-title}. Sets status:in-progress on the issue.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer"},"branch_type":{"type":"string","enum":["feature","fix"],"description":"Branch prefix type"}},"required":["issue_number"]}},
    \\{"name":"get_current_branch","description":"Return the current git branch name and the issue number parsed from it (null if not a convention branch).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"commit_with_context","description":"Stage all changes and commit with a message referencing the current issue. Auto-detects issue number from branch name if not provided.","inputSchema":{"type":"object","properties":{"message":{"type":"string","description":"Commit message body"},"issue_number":{"type":"integer","description":"Issue to reference (auto-detected from branch if omitted)"}},"required":["message"]}},
    \\{"name":"push_branch","description":"Push the current branch to origin.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"create_pr","description":"Open a pull request from the current branch to main. Auto-generates title and body from the linked issue if not provided. Sets status:in-review on the issue.","inputSchema":{"type":"object","properties":{"title":{"type":"string","description":"PR title (defaults to linked issue title)"},"body":{"type":"string","description":"PR body (defaults to issue summary + Closes #N)"}},"required":[]}},
    \\{"name":"get_pr_status","description":"Get CI status, review state, and merge readiness for a PR. Defaults to the PR for the current branch.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"}},"required":[]}},
    \\{"name":"list_open_prs","description":"List all open PRs with their CI status, review state, and linked issue numbers.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"review_pr_impact","description":"Analyze a PR's blast radius: extracts changed files and function symbols from the diff, then searches the codebase for all references to those symbols. Call this before approving or merging a PR to understand what other code might be affected by the changes. Also useful after creating a PR to self-review impact. Returns files changed, symbols modified, and which files reference each symbol.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"}},"required":[]}},
    \\{"name":"blast_radius","description":"Find all files that reference symbols defined in a file or a specific symbol. Use this to understand the impact of changing a file or function before editing. Works offline with grep-based search.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to analyze (extracts symbols automatically)"},"symbol":{"type":"string","description":"Specific symbol name to search for"}},"required":[]}},
    \\{"name":"relevant_context","description":"Find files most related to a given file by analyzing symbol cross-references and imports. Use this to understand what other files you should read before modifying a file. Works offline with grep-based search.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to find context for"}},"required":["file"]}},
    \\{"name":"git_history_for","description":"Return the git commit history for a specific file. Use this to understand recent changes, who modified a file, and why. Works offline with local git.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to get history for"},"count":{"type":"integer","description":"Number of commits to return (default 20)"}},"required":["file"]}},
    \\{"name":"recently_changed","description":"Return files that were recently modified across recent commits. Use this to understand what areas of the codebase are actively being worked on. Works offline with local git.","inputSchema":{"type":"object","properties":{"count":{"type":"integer","description":"Number of recent commits to scan (default 10)"}},"required":[]}}
    \\]}
;

// ── Step 3: Parser ────────────────────────────────────────────────────────────

pub fn parse(name: []const u8) ?Tool {
    return std.meta.stringToEnum(Tool, name);
}

// ── Step 4: Dispatch ──────────────────────────────────────────────────────────

pub fn dispatch(
    alloc: std.mem.Allocator,
    tool: Tool,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    switch (tool) {
        // Planning
        .decompose_feature     => handleDecomposeFeature(alloc, args, out),
        .get_project_state     => handleGetProjectState(alloc, args, out),
        .get_next_task         => handleGetNextTask(alloc, args, out),
        .prioritize_issues     => handlePrioritizeIssues(alloc, args, out),
        // Issues
        .create_issue          => handleCreateIssue(alloc, args, out),
        .create_issues_batch   => handleCreateIssuesBatch(alloc, args, out),
        .update_issue          => handleUpdateIssue(alloc, args, out),
        .close_issue           => handleCloseIssue(alloc, args, out),
        .link_issues           => handleLinkIssues(alloc, args, out),
        // Branches & commits
        .create_branch         => handleCreateBranch(alloc, args, out),
        .get_current_branch    => handleGetCurrentBranch(alloc, args, out),
        .commit_with_context   => handleCommitWithContext(alloc, args, out),
        .push_branch           => handlePushBranch(alloc, args, out),
        // Pull requests
        .create_pr             => handleCreatePr(alloc, args, out),
        .get_pr_status         => handleGetPrStatus(alloc, args, out),
        .list_open_prs         => handleListOpenPrs(alloc, args, out),
        // Analysis
        .review_pr_impact      => handleReviewPrImpact(alloc, args, out),
        .blast_radius          => handleBlastRadius(alloc, args, out),
        .relevant_context      => handleRelevantContext(alloc, args, out),
        .git_history_for       => handleGitHistoryFor(alloc, args, out),
        .recently_changed      => handleRecentlyChanged(alloc, args, out),
    }
}

// ── Handlers ──────────────────────────────────────────────────────────────────
//
// Stub implementations — each returns a structured placeholder.
// Real implementations land in the issues listed in each handler's comment.
// Error handling rule: write JSON error to `out`, never propagate or crash.

// ── Planning ──────────────────────────────────────────────────────────────────

fn handleDecomposeFeature(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const desc = mj.getStr(args, "feature_description") orelse {
        writeErr(alloc, out, "missing feature_description");
        return;
    };
    const labels_r = gh.run(alloc, &.{
        "gh", "label", "list",
        "--json", "name,description,color",
        "--limit", "100",
    }) catch null;
    defer if (labels_r) |r| r.deinit(alloc);

    out.appendSlice(alloc, "{\"feature_description\":\"") catch return;
    mj.writeEscaped(alloc, out, desc);
    out.appendSlice(alloc, "\",\"available_labels\":") catch return;
    if (labels_r) |r| {
        out.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \t\n\r")) catch {};
    } else {
        out.appendSlice(alloc, "[]") catch {};
    }
    out.appendSlice(alloc,
        \\,"instructions":"Use create_issues_batch to create the issues. status:backlog is auto-applied by create_issue when available. For ordering, add one of priority:p0, priority:p1, priority:p2, or priority:p3 as needed. Return an array of objects with title, body, and labels fields."}
    ) catch {};
}

fn handleGetProjectState(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = args;
    const issues_r = gh.run(alloc, &.{
        "gh", "issue", "list",
        "--json", "number,title,labels,state,url",
        "--limit", "200",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer issues_r.deinit(alloc);

    const prs_r = gh.run(alloc, &.{
        "gh", "pr", "list",
        "--json", "number,title,state,headRefName,url",
        "--limit", "50",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer prs_r.deinit(alloc);

    const issues_json = std.mem.trim(u8, issues_r.stdout, " \t\n\r");
    const prs_json    = std.mem.trim(u8, prs_r.stdout,   " \t\n\r");

    out.appendSlice(alloc, "{\"issues\":") catch return;
    out.appendSlice(alloc, issues_json)     catch return;
    out.appendSlice(alloc, ",\"open_prs\":") catch return;
    out.appendSlice(alloc, prs_json)        catch return;
    out.appendSlice(alloc, "}")             catch return;
}

fn handleGetNextTask(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = args;
    // Lightweight fetch — just number + labels needed for priority + block filtering
    const parsed = gh.runJson(alloc, &.{
        "gh", "issue", "list",
        "--label", "status:backlog",
        "--json", "number,labels",
        "--limit", "100",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer parsed.deinit();

    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => {
            writeErr(alloc, out, "unexpected response from gh issue list");
            return;
        },
    };

    if (items.len == 0) {
        out.appendSlice(alloc, "null") catch {};
        return;
    }

    // Find highest-priority issue that is not blocked
    var best_num: ?i64 = null;
    var best_prio: u8  = 255;

    for (items) |item| {
        if (item != .object) continue;
        const labels_val = item.object.get("labels") orelse continue;
        if (hasLabel(labels_val, "status:blocked")) continue;
        const prio = getPriority(labels_val);
        const num_val = item.object.get("number") orelse continue;
        const num = switch (num_val) { .integer => |n| n, else => continue };
        if (best_num == null or prio < best_prio) {
            best_num  = num;
            best_prio = prio;
        }
    }

    const num = best_num orelse {
        out.appendSlice(alloc, "null") catch {};
        return;
    };

    // Fetch full details for the winning issue
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch return;
    const detail_r = gh.run(alloc, &.{
        "gh", "issue", "view", num_str,
        "--json", "number,title,body,labels,url,state",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer detail_r.deinit(alloc);
    out.appendSlice(alloc, std.mem.trim(u8, detail_r.stdout, " \t\n\r")) catch {};
}

fn handlePrioritizeIssues(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const nums_val = args.get("issue_numbers") orelse {
        writeErr(alloc, out, "missing issue_numbers"); return;
    };
    if (nums_val != .array) { writeErr(alloc, out, "issue_numbers must be array"); return; }
    const nums = nums_val.array.items;

    out.appendSlice(alloc, "{\"prioritized\":[") catch return;
    var first = true;
    for (nums, 0..) |item, idx| {
        if (item != .integer) continue;
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{item.integer}) catch continue;
        // Sink (last in list) = p0; everything else = p2
        const prio: []const u8 = if (idx + 1 == nums.len) "priority:p0" else "priority:p2";

        // Strip old priority labels (ignore error — label may not exist)
        const rm = gh.run(alloc, &.{
            "gh", "issue", "edit", num_str,
            "--remove-label", "priority:p0,priority:p1,priority:p2,priority:p3",
        }) catch null;
        if (rm) |r| r.deinit(alloc);

        const r = gh.run(alloc, &.{
            "gh", "issue", "edit", num_str, "--add-label", prio,
        }) catch |err| {
            if (!first) out.appendSlice(alloc, ",") catch {};
            first = false;
            out.appendSlice(alloc, "{\"issue\":") catch {};
            out.appendSlice(alloc, num_str) catch {};
            out.appendSlice(alloc, ",\"error\":\"") catch {};
            mj.writeEscaped(alloc, out, gh.errorMessage(err));
            out.appendSlice(alloc, "\"}") catch {};
            continue;
        };
        r.deinit(alloc);

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;
        out.appendSlice(alloc, "{\"issue\":") catch {};
        out.appendSlice(alloc, num_str) catch {};
        out.appendSlice(alloc, ",\"priority\":\"") catch {};
        out.appendSlice(alloc, prio) catch {};
        out.appendSlice(alloc, "\"}") catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

// ── Issues ────────────────────────────────────────────────────────────────────

fn handleCreateIssue(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const title = mj.getStr(args, "title") orelse {
        writeErr(alloc, out, "missing title"); return;
    };

    // Build body — optionally append parent issue reference
    var body_buf: ?[]u8 = null;
    defer if (body_buf) |b| alloc.free(b);
    const body: []const u8 = blk: {
        const raw = mj.getStr(args, "body") orelse "";
        if (args.get("parent_issue")) |piv| {
            if (piv == .integer) {
                body_buf = std.fmt.allocPrint(alloc, "{s}\n\nParent issue: #{d}", .{ raw, piv.integer }) catch null;
                if (body_buf) |b| break :blk b;
            }
        }
        break :blk raw;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    // Note: gh issue create does NOT support --json; stdout is the new issue URL
    argv.appendSlice(alloc, &.{ "gh", "issue", "create", "--title", title, "--body", body }) catch return;

    var has_status = false;
    if (args.get("labels")) |lv| {
        if (lv == .array) {
            for (lv.array.items) |lbl| {
                if (lbl != .string) continue;
                argv.appendSlice(alloc, &.{ "--label", lbl.string }) catch return;
                if (std.mem.startsWith(u8, lbl.string, "status:")) has_status = true;
            }
        }
    }
    if (!has_status) {
        if (cache.getLabel("status:backlog") != null) {
            argv.appendSlice(alloc, &.{ "--label", "status:backlog" }) catch return;
        }
    }
    if (mj.getStr(args, "milestone")) |ms| argv.appendSlice(alloc, &.{ "--milestone", ms }) catch return;

    const r = gh.run(alloc, argv.items) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    // stdout is the issue URL, e.g. "https://github.com/owner/repo/issues/42\n"
    const url = std.mem.trim(u8, r.stdout, " \t\n\r");
    // Parse issue number from URL tail
    const slash_pos = std.mem.lastIndexOf(u8, url, "/");
    const num_str = if (slash_pos) |p| url[p + 1 ..] else "";
    const num = std.fmt.parseInt(i64, num_str, 10) catch -1;

    out.appendSlice(alloc, "{\"number\":") catch return;
    var nb: [16]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch "0";
    out.appendSlice(alloc, ns) catch {};
    out.appendSlice(alloc, ",\"url\":\"") catch return;
    mj.writeEscaped(alloc, out, url);
    out.appendSlice(alloc, "\",\"title\":\"") catch return;
    mj.writeEscaped(alloc, out, title);
    out.appendSlice(alloc, "\"}") catch {};
}

fn handleCreateIssuesBatch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const issues_val = args.get("issues") orelse {
        writeErr(alloc, out, "missing issues array"); return;
    };
    if (issues_val != .array) { writeErr(alloc, out, "issues must be array"); return; }

    out.appendSlice(alloc, "[") catch return;
    var first = true;
    for (issues_val.array.items) |item| {
        if (item != .object) continue;
        const issue_args = &item.object;

        var single_out: std.ArrayList(u8) = .empty;
        defer single_out.deinit(alloc);
        handleCreateIssue(alloc, issue_args, &single_out);

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;
        out.appendSlice(alloc, single_out.items) catch {};
    }
    out.appendSlice(alloc, "]") catch {};
}

fn handleUpdateIssue(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const num_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (num_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num_val.integer}) catch return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.appendSlice(alloc, &.{ "gh", "issue", "edit", num_str }) catch return;

    if (mj.getStr(args, "title")) |t| argv.appendSlice(alloc, &.{ "--title", t }) catch return;
    if (mj.getStr(args, "body"))  |b| argv.appendSlice(alloc, &.{ "--body",  b }) catch return;

    if (args.get("add_labels")) |lv| {
        if (lv == .array) {
            for (lv.array.items) |lbl| {
                if (lbl == .string) argv.appendSlice(alloc, &.{ "--add-label", lbl.string }) catch return;
            }
        }
    }
    if (args.get("remove_labels")) |lv| {
        if (lv == .array) {
            for (lv.array.items) |lbl| {
                if (lbl == .string) argv.appendSlice(alloc, &.{ "--remove-label", lbl.string }) catch return;
            }
        }
    }

    if (argv.items.len == 4) { // only "gh issue edit N" — nothing to do
        writeErr(alloc, out, "no fields to update"); return;
    }

    const r = gh.run(alloc, argv.items) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{{\"updated\":{d}}}", .{num_val.integer}) catch return;
    out.appendSlice(alloc, s) catch {};
}

fn handleCloseIssue(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const num_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (num_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num_val.integer}) catch return;

    // Optionally add a closing comment referencing the PR
    if (args.get("pr_number")) |pr_val| {
        if (pr_val == .integer) {
            var comment_buf: [64]u8 = undefined;
            const comment = std.fmt.bufPrint(&comment_buf, "Resolved by PR #{d}.", .{pr_val.integer}) catch "";
            const cr = gh.run(alloc, &.{ "gh", "issue", "comment", num_str, "--body", comment }) catch null;
            if (cr) |r| r.deinit(alloc);
        }
    }

    const close_r = gh.run(alloc, &.{ "gh", "issue", "close", num_str }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    close_r.deinit(alloc);

    // Transition label: remove all status labels, apply status:done
    const edit_r = gh.run(alloc, &.{
        "gh", "issue", "edit", num_str,
        "--remove-label", "status:backlog,status:in-progress,status:in-review,status:blocked",
        "--add-label",    "status:done",
    }) catch null;
    if (edit_r) |r| r.deinit(alloc);

    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{{\"closed\":{d}}}", .{num_val.integer}) catch return;
    out.appendSlice(alloc, s) catch {};
}

fn handleLinkIssues(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const blocker_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (blocker_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    const blocker = blocker_val.integer;

    const blocks_val = args.get("blocks") orelse {
        writeErr(alloc, out, "missing blocks array"); return;
    };
    if (blocks_val != .array) { writeErr(alloc, out, "blocks must be array"); return; }
    const blocked_items = blocks_val.array.items;
    if (blocked_items.len == 0) { out.appendSlice(alloc, "{\"linked\":[]}") catch {}; return; }

    // Build comma list "Blocks #X, #Y, #Z" for blocker comment
    var comment: std.ArrayList(u8) = .empty;
    defer comment.deinit(alloc);
    comment.appendSlice(alloc, "Blocks: ") catch {};

    var num_bufs: [32][16]u8 = undefined;
    var num_strs: [32][]const u8 = undefined;
    const max = @min(blocked_items.len, 32);
    var count: usize = 0;

    for (blocked_items[0..max]) |item| {
        if (item != .integer) continue;
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "#{d}", .{item.integer}) catch continue;
        if (count > 0) comment.appendSlice(alloc, ", ") catch {};
        comment.appendSlice(alloc, s) catch {};
        num_strs[count] = std.fmt.bufPrint(&num_bufs[count], "{d}", .{item.integer}) catch continue;
        count += 1;
    }

    // Comment on blocker — dedicated buffer, NOT num_bufs[0] (holds blocked issue numbers)
    var blocker_buf: [16]u8 = undefined;
    const blocker_str = std.fmt.bufPrint(&blocker_buf, "{d}", .{blocker}) catch "?";
    const bc = gh.run(alloc, &.{
        "gh", "issue", "comment", blocker_str, "--body", comment.items,
    }) catch null;
    if (bc) |r| r.deinit(alloc);

    // For each blocked issue: add status:blocked + comment
    out.appendSlice(alloc, "{\"linked\":[") catch return;
    var first = true;

    for (0..count) |i| {
        const ns = num_strs[i];
        const edit_r = gh.run(alloc, &.{
            "gh", "issue", "edit", ns, "--add-label", "status:blocked",
        }) catch null;
        if (edit_r) |r| r.deinit(alloc);

        var cb_buf: [64]u8 = undefined;
        const cb = std.fmt.bufPrint(&cb_buf, "Blocked by: #{s}.", .{blocker_str}) catch "";
        const cr = gh.run(alloc, &.{ "gh", "issue", "comment", ns, "--body", cb }) catch null;
        if (cr) |r| r.deinit(alloc);

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;
        out.appendSlice(alloc, ns) catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

// ── Branches & commits ────────────────────────────────────────────────────────

fn handleCreateBranch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const num_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (num_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    const num: u32 = @intCast(num_val.integer);
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num}) catch return;

    // Fetch issue title
    const issue_r = gh.run(alloc, &.{
        "gh", "issue", "view", num_str, "--json", "title",
    }) catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer issue_r.deinit(alloc);

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, issue_r.stdout, .{}) catch {
        writeErr(alloc, out, "could not parse issue JSON"); return;
    };
    defer parsed.deinit();

    const title = blk: {
        if (parsed.value == .object) {
            if (parsed.value.object.get("title")) |tv| {
                if (tv == .string) break :blk tv.string;
            }
        }
        break :blk "untitled";
    };

    const branch_type_str = mj.getStr(args, "branch_type") orelse "feature";
    const branch_type: state.BranchType = if (std.mem.eql(u8, branch_type_str, "fix")) .fix else .feature;

    const branch_name = state.buildBranchName(alloc, branch_type, num, title) catch {
        writeErr(alloc, out, "could not build branch name"); return;
    };
    defer alloc.free(branch_name);

    // Create local branch
    const checkout_r = gh.run(alloc, &.{ "git", "checkout", "-b", branch_name }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    checkout_r.deinit(alloc);

    // Transition issue to in-progress
    const edit_r = gh.run(alloc, &.{
        "gh", "issue", "edit", num_str,
        "--remove-label", "status:backlog,status:blocked",
        "--add-label",    "status:in-progress",
    }) catch null;
    if (edit_r) |r| r.deinit(alloc);

    out.appendSlice(alloc, "{\"branch\":\"") catch return;
    mj.writeEscaped(alloc, out, branch_name);
    out.appendSlice(alloc, "\",\"issue\":") catch return;
    out.appendSlice(alloc, num_str) catch return;
    out.appendSlice(alloc, "}") catch {};
}

fn handleGetCurrentBranch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = args;
    const r = gh.run(alloc, &.{ "git", "branch", "--show-current" }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer r.deinit(alloc);

    const branch = std.mem.trim(u8, r.stdout, " \t\n\r");
    const issue_num = state.parseIssueNumber(branch);

    out.appendSlice(alloc, "{\"branch\":\"") catch return;
    mj.writeEscaped(alloc, out, branch);
    out.appendSlice(alloc, "\",\"issue_number\":") catch return;
    if (issue_num) |n| {
        var buf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
        out.appendSlice(alloc, s) catch return;
    } else {
        out.appendSlice(alloc, "null") catch return;
    }
    out.appendSlice(alloc, "}") catch return;
}

fn handleCommitWithContext(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const message = mj.getStr(args, "message") orelse {
        writeErr(alloc, out, "missing message"); return;
    };

    // Resolve issue number: explicit arg > parsed from branch name
    const issue_num: ?i64 = blk: {
        if (args.get("issue_number")) |iv| {
            if (iv == .integer) break :blk iv.integer;
        }
        // Parse from current branch
        const br = gh.run(alloc, &.{ "git", "branch", "--show-current" }) catch break :blk null;
        defer br.deinit(alloc);
        const branch = std.mem.trim(u8, br.stdout, " \t\n\r");
        if (state.parseIssueNumber(branch)) |n| break :blk @intCast(n);
        break :blk null;
    };

    // Build full commit message
    const full_msg = if (issue_num) |n|
        std.fmt.allocPrint(alloc, "{s}\n\nRefs #{d}", .{ message, n }) catch return
    else
        alloc.dupe(u8, message) catch return;
    defer alloc.free(full_msg);

    // Stage everything
    const add_r = gh.run(alloc, &.{ "git", "add", "-A" }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    add_r.deinit(alloc);

    const commit_r = gh.run(alloc, &.{ "git", "commit", "-m", full_msg }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer commit_r.deinit(alloc);

    // Return the short hash from git log
    const log_r = gh.run(alloc, &.{ "git", "log", "-1", "--format=%h %s" }) catch null;
    defer if (log_r) |r| r.deinit(alloc);

    out.appendSlice(alloc, "{\"committed\":true,\"ref\":\"") catch return;
    if (log_r) |r| mj.writeEscaped(alloc, out, std.mem.trim(u8, r.stdout, " \t\n\r"));
    out.appendSlice(alloc, "\"}") catch {};
}

fn handlePushBranch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = args;
    const push_r = gh.run(alloc, &.{ "git", "push", "-u", "origin", "HEAD" }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer push_r.deinit(alloc);

    const branch_r = gh.run(alloc, &.{ "git", "branch", "--show-current" }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer branch_r.deinit(alloc);

    const branch = std.mem.trim(u8, branch_r.stdout, " \t\n\r");
    out.appendSlice(alloc, "{\"pushed\":true,\"branch\":\"") catch return;
    mj.writeEscaped(alloc, out, branch);
    out.appendSlice(alloc, "\"}") catch return;
}

// ── Pull requests ─────────────────────────────────────────────────────────────

fn handleCreatePr(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    // Determine current branch + linked issue
    const br_r = gh.run(alloc, &.{ "git", "branch", "--show-current" }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer br_r.deinit(alloc);
    const branch = std.mem.trim(u8, br_r.stdout, " \t\n\r");
    const issue_num = state.parseIssueNumber(branch);

    // Resolve title + body — provided args win, else pull from linked issue
    var title_buf: ?[]u8 = null;
    var body_buf:  ?[]u8 = null;
    defer if (title_buf) |b| alloc.free(b);
    defer if (body_buf)  |b| alloc.free(b);

    const title: []const u8 = blk: {
        if (mj.getStr(args, "title")) |t| break :blk t;
        if (issue_num) |n| {
            var nb: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch break :blk branch;
            const ir = gh.run(alloc, &.{ "gh", "issue", "view", ns, "--json", "title,body" }) catch break :blk branch;
            defer ir.deinit(alloc);
            const ip = std.json.parseFromSlice(std.json.Value, alloc, ir.stdout, .{}) catch break :blk branch;
            defer ip.deinit();
            if (ip.value == .object) {
                if (ip.value.object.get("title")) |tv| {
                    if (tv == .string) {
                        title_buf = alloc.dupe(u8, tv.string) catch null;
                        if (title_buf) |b| {
                            // Also set default body while we have the issue parsed
                            if (body_buf == null) {
                                if (ip.value.object.get("body")) |bv| {
                                    if (bv == .string) {
                                        var bb: [16]u8 = undefined;
                                        const ns2 = std.fmt.bufPrint(&bb, "{d}", .{n}) catch "";
                                        body_buf = std.fmt.allocPrint(alloc,
                                            "{s}\n\nCloses #{s}", .{ bv.string, ns2 }) catch null;
                                    }
                                }
                            }
                            break :blk b;
                        }
                    }
                }
            }
        }
        break :blk branch;
    };

    const body: []const u8 = blk: {
        if (mj.getStr(args, "body")) |b| break :blk b;
        if (body_buf) |b| break :blk b;
        if (issue_num) |n| {
            var nb: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&nb, "Closes #{d}", .{n}) catch break :blk "";
            body_buf = alloc.dupe(u8, s) catch null;
            if (body_buf) |b| break :blk b;
        }
        break :blk "";
    };

    const pr_r = gh.run(alloc, &.{
        "gh", "pr", "create",
        "--base",  "main",
        "--head",  branch,
        "--title", title,
        "--body",  body,
    }) catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer pr_r.deinit(alloc);

    // Parse PR number from URL: https://github.com/.../pull/42
    const url = std.mem.trim(u8, pr_r.stdout, " \t\n\r");
    const slash_pos = std.mem.lastIndexOf(u8, url, "/");
    const num_str = if (slash_pos) |p| url[p + 1 ..] else "";
    const num = std.fmt.parseInt(i64, num_str, 10) catch -1;

    // Transition linked issue to in-review
    if (issue_num) |n| {
        var nb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&nb, "{d}", .{n}) catch "";
        const er = gh.run(alloc, &.{
            "gh", "issue", "edit", ns,
            "--remove-label", "status:in-progress",
            "--add-label",    "status:in-review",
        }) catch null;
        if (er) |r| r.deinit(alloc);
    }

    var nb: [16]u8 = undefined;
    const ns = std.fmt.bufPrint(&nb, "{d}", .{num}) catch "0";
    out.appendSlice(alloc, "{\"number\":") catch return;
    out.appendSlice(alloc, ns) catch {};
    out.appendSlice(alloc, ",\"url\":\"") catch return;
    mj.writeEscaped(alloc, out, url);
    out.appendSlice(alloc, "\",\"title\":\"") catch return;
    mj.writeEscaped(alloc, out, title);
    out.appendSlice(alloc, "\"}") catch {};
}

fn handleGetPrStatus(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const fields = "number,title,state,mergeable,statusCheckRollup,reviews,headRefName,url";
    const r = blk: {
        if (args.get("pr_number")) |pv| {
            if (pv == .integer) {
                var nb: [16]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{pv.integer}) catch {
                    writeErr(alloc, out, "bad pr_number"); return;
                };
                break :blk gh.run(alloc, &.{ "gh", "pr", "view", ns, "--json", fields });
            }
        }
        // Default: PR for current branch
        break :blk gh.run(alloc, &.{ "gh", "pr", "view", "--json", fields });
    } catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer r.deinit(alloc);
    out.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \t\n\r")) catch {};
}

fn handleListOpenPrs(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    _ = args;
    const r = gh.run(alloc, &.{
        "gh", "pr", "list",
        "--json", "number,title,state,headRefName,url,statusCheckRollup",
        "--limit", "50",
    }) catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer r.deinit(alloc);
    out.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \t\n\r")) catch {};
}

// ── Analysis ──────────────────────────────────────────────────────────────────

fn handleReviewPrImpact(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    // 1. Get PR diff
    const diff_r = blk: {
        if (args.get("pr_number")) |pv| {
            if (pv == .integer) {
                var nb: [16]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{pv.integer}) catch {
                    writeErr(alloc, out, "bad pr_number"); return;
                };
                break :blk gh.run(alloc, &.{ "gh", "pr", "diff", ns });
            }
        }
        break :blk gh.run(alloc, &.{ "gh", "pr", "diff" });
    } catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer diff_r.deinit(alloc);

    const diff = std.mem.trim(u8, diff_r.stdout, " \t\n\r");

    // 2. Parse diff for files and symbols
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(alloc);
    var symbols: std.ArrayList(Symbol) = .empty;
    defer symbols.deinit(alloc);
    var seen_files = std.StringHashMap(void).init(alloc);
    defer seen_files.deinit();
    var seen_syms = std.StringHashMap(void).init(alloc);
    defer seen_syms.deinit();

    var current_file: ?[]const u8 = null;
    var sym_count: usize = 0;
    const max_symbols: usize = 50;

    var lines = std.mem.splitScalar(u8, diff, '\n');
    while (lines.next()) |line| {
        // Extract file paths from diff headers
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            if (search.extractFilePath(line)) |path| {
                if (!seen_files.contains(path)) {
                    const owned = alloc.dupe(u8, path) catch continue;
                    files.append(alloc, owned) catch { alloc.free(owned); continue; };
                    seen_files.put(owned, {}) catch {};
                    current_file = owned;
                } else {
                    current_file = path;
                }
            }
            continue;
        }

        if (sym_count >= max_symbols) continue;

        // Extract symbols from hunk headers
        if (std.mem.startsWith(u8, line, "@@")) {
            if (search.extractHunkSymbol(line)) |sym| {
                if (!seen_syms.contains(sym)) {
                    const owned_sym = alloc.dupe(u8, sym) catch continue;
                    symbols.append(alloc, .{ .name = owned_sym, .file = current_file }) catch {
                        alloc.free(owned_sym); continue;
                    };
                    seen_syms.put(owned_sym, {}) catch {};
                    sym_count += 1;
                }
            }
            continue;
        }

        // Extract symbols from added lines (new function definitions)
        if (std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++")) {
            if (search.extractIdentifierFromContext(line[1..])) |sym| {
                if (!seen_syms.contains(sym)) {
                    const owned_sym = alloc.dupe(u8, sym) catch continue;
                    symbols.append(alloc, .{ .name = owned_sym, .file = current_file }) catch {
                        alloc.free(owned_sym); continue;
                    };
                    seen_syms.put(owned_sym, {}) catch {};
                    sym_count += 1;
                }
            }
        }
    }

    // 3. Probe for search tool
    const tool = search.probe(alloc);

    // 4. Build JSON response
    out.appendSlice(alloc, "{\"files_changed\":[") catch return;
    for (files.items, 0..) |f, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "\"") catch {};
        mj.writeEscaped(alloc, out, f);
        out.appendSlice(alloc, "\"") catch {};
    }
    out.appendSlice(alloc, "],\"symbols\":[") catch return;

    for (symbols.items, 0..) |sym, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"name\":\"") catch {};
        mj.writeEscaped(alloc, out, sym.name);
        out.appendSlice(alloc, "\",\"file\":") catch {};
        if (sym.file) |f| {
            out.appendSlice(alloc, "\"") catch {};
            mj.writeEscaped(alloc, out, f);
            out.appendSlice(alloc, "\"") catch {};
        } else {
            out.appendSlice(alloc, "null") catch {};
        }

        // Search for references
        out.appendSlice(alloc, ",\"referenced_by\":[") catch {};
        if (tool != .none) {
            var refs: std.ArrayList([]const u8) = search.searchRefs(alloc, tool, sym.name, sym.file) catch
                .empty;
            defer {
                for (refs.items) |ref_s| alloc.free(ref_s);
                refs.deinit(alloc);
            }
            for (refs.items, 0..) |ref, j| {
                if (j > 0) out.appendSlice(alloc, ",") catch {};
                out.appendSlice(alloc, "\"") catch {};
                mj.writeEscaped(alloc, out, ref);
                out.appendSlice(alloc, "\"") catch {};
            }
        }
        out.appendSlice(alloc, "]}") catch {};
    }

    out.appendSlice(alloc, "],\"search_tool\":\"") catch return;
    out.appendSlice(alloc, search.toolName(tool)) catch return;
    out.appendSlice(alloc, "\"}") catch {};
}

// ── Analysis: blast_radius ────────────────────────────────────────────────────

fn handleBlastRadius(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file_arg = mj.getStr(args, "file");
    const sym_arg = mj.getStr(args, "symbol");

    if (file_arg == null and sym_arg == null) {
        writeErr(alloc, out, "provide at least one of: file, symbol");
        return;
    }

    var syms: std.ArrayList([]const u8) = .empty;
    defer {
        for (syms.items) |s| alloc.free(s);
        syms.deinit(alloc);
    }

    // Add explicit symbol if given
    if (sym_arg) |s| {
        const owned = alloc.dupe(u8, s) catch return;
        syms.append(alloc, owned) catch { alloc.free(owned); return; };
    }

    // Read file and extract symbols
    if (file_arg) |f| {
        const r = gh.run(alloc, &.{ "cat", f }) catch |err| {
            writeErr(alloc, out, gh.errorMessage(err));
            return;
        };
        defer r.deinit(alloc);
        var extracted = search.extractSymbolsFromContent(alloc, r.stdout, 50);
        defer extracted.deinit(alloc);
        for (extracted.items) |s| {
            const owned = alloc.dupe(u8, s) catch continue;
            syms.append(alloc, owned) catch { alloc.free(owned); continue; };
        }
    }

    const tool = search.probe(alloc);

    // Build JSON response
    out.appendSlice(alloc, "{\"file\":") catch return;
    if (file_arg) |f| {
        out.appendSlice(alloc, "\"") catch {};
        mj.writeEscaped(alloc, out, f);
        out.appendSlice(alloc, "\"") catch {};
    } else {
        out.appendSlice(alloc, "null") catch {};
    }
    out.appendSlice(alloc, ",\"symbols\":[") catch return;

    for (syms.items, 0..) |sym, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"name\":\"") catch {};
        mj.writeEscaped(alloc, out, sym);
        out.appendSlice(alloc, "\",\"referenced_by\":[") catch {};

        if (tool != .none) {
            var refs: std.ArrayList([]const u8) = search.searchRefs(alloc, tool, sym, file_arg) catch
                .empty;
            defer {
                for (refs.items) |ref_s| alloc.free(ref_s);
                refs.deinit(alloc);
            }
            for (refs.items, 0..) |ref, j| {
                if (j > 0) out.appendSlice(alloc, ",") catch {};
                out.appendSlice(alloc, "\"") catch {};
                mj.writeEscaped(alloc, out, ref);
                out.appendSlice(alloc, "\"") catch {};
            }
        }
        out.appendSlice(alloc, "]}") catch {};
    }

    out.appendSlice(alloc, "],\"search_tool\":\"") catch return;
    out.appendSlice(alloc, search.toolName(tool)) catch return;
    out.appendSlice(alloc, "\"}") catch {};
}

// ── Analysis: relevant_context ────────────────────────────────────────────────

fn handleRelevantContext(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing file");
        return;
    };

    const r = gh.run(alloc, &.{ "cat", file }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer r.deinit(alloc);
    const content = r.stdout;

    // Extract symbols
    var syms = search.extractSymbolsFromContent(alloc, content, 50);
    defer syms.deinit(alloc);

    const tool = search.probe(alloc);

    // Score files by reference count
    var scores = std.StringHashMap(i32).init(alloc);
    defer scores.deinit();

    if (tool != .none) {
        for (syms.items) |sym| {
            var refs = search.searchRefs(alloc, tool, sym, file) catch continue;
            defer {
                for (refs.items) |ref_s| alloc.free(ref_s);
                refs.deinit(alloc);
            }
            for (refs.items) |ref| {
                const owned_ref = alloc.dupe(u8, ref) catch continue;
                const entry = scores.getOrPut(owned_ref) catch { alloc.free(owned_ref); continue; };
                if (!entry.found_existing) {
                    entry.value_ptr.* = 1;
                } else {
                    alloc.free(owned_ref);
                    entry.value_ptr.* += 1;
                }
            }
        }
    }

    // Parse @import lines and boost scores
    var import_lines = std.mem.splitScalar(u8, content, '\n');
    while (import_lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.indexOf(u8, trimmed, "@import(\"")) |idx| {
            const after = trimmed[idx + 9 ..];
            if (std.mem.indexOf(u8, after, "\")")) |end| {
                const import_path = after[0..end];
                var path_buf: [512]u8 = undefined;
                const resolved: ?[]const u8 = blk: {
                    if (std.mem.lastIndexOf(u8, file, "/")) |slash| {
                        const dir = file[0 .. slash + 1];
                        const s = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ dir, import_path }) catch break :blk null;
                        break :blk s;
                    }
                    break :blk import_path;
                };
                if (resolved) |rp| {
                    const owned_rp = alloc.dupe(u8, rp) catch continue;
                    const entry = scores.getOrPut(owned_rp) catch { alloc.free(owned_rp); continue; };
                    if (!entry.found_existing) {
                        entry.value_ptr.* = 10;
                    } else {
                        alloc.free(owned_rp);
                        entry.value_ptr.* += 10;
                    }
                }
            }
        }
    }

    // Collect and sort by score descending
    const ScoredFile = struct { path: []const u8, score: i32 };
    var sorted: std.ArrayList(ScoredFile) = .empty;
    defer sorted.deinit(alloc);

    var it = scores.iterator();
    while (it.next()) |entry| {
        sorted.append(alloc, .{ .path = entry.key_ptr.*, .score = entry.value_ptr.* }) catch {};
    }

    std.mem.sort(ScoredFile, sorted.items, {}, struct {
        fn lessThan(_: void, a: ScoredFile, b: ScoredFile) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const cap = @min(sorted.items.len, 20);

    // Build JSON
    out.appendSlice(alloc, "{\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, file);
    out.appendSlice(alloc, "\",\"context_files\":[") catch return;

    for (sorted.items[0..cap], 0..) |sf, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"path\":\"") catch {};
        mj.writeEscaped(alloc, out, sf.path);
        out.appendSlice(alloc, "\",\"score\":") catch {};
        var sbuf: [16]u8 = undefined;
        const ss = std.fmt.bufPrint(&sbuf, "{d}", .{sf.score}) catch "0";
        out.appendSlice(alloc, ss) catch {};
        out.appendSlice(alloc, ",\"reason\":\"") catch {};
        if (sf.score >= 10) {
            out.appendSlice(alloc, "import + references") catch {};
        } else {
            out.appendSlice(alloc, "symbol references") catch {};
        }
        out.appendSlice(alloc, "\"}") catch {};
    }

    out.appendSlice(alloc, "],\"search_tool\":\"") catch return;
    out.appendSlice(alloc, search.toolName(tool)) catch return;
    out.appendSlice(alloc, "\"}") catch {};
}

// ── Analysis: git_history_for ─────────────────────────────────────────────────

fn handleGitHistoryFor(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing file");
        return;
    };

    var count_buf: [16]u8 = undefined;
    const count_str: []const u8 = blk: {
        if (args.get("count")) |cv| {
            if (cv == .integer) {
                break :blk std.fmt.bufPrint(&count_buf, "{d}", .{cv.integer}) catch "20";
            }
        }
        break :blk "20";
    };

    const r = gh.run(alloc, &.{
        "git", "log", "--follow", "--format=%h%x00%an%x00%ai%x00%s", "-n", count_str, "--", file,
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer r.deinit(alloc);

    out.appendSlice(alloc, "{\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, file);
    out.appendSlice(alloc, "\",\"commits\":[") catch return;

    const output = std.mem.trim(u8, r.stdout, " \t\n\r");
    if (output.len == 0) {
        out.appendSlice(alloc, "]}") catch {};
        return;
    }

    var commit_lines = std.mem.splitScalar(u8, output, '\n');
    var first = true;
    while (commit_lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;

        // Split by null byte (0x00)
        var fields = std.mem.splitScalar(u8, trimmed_line, 0);
        const hash = fields.next() orelse continue;
        const author = fields.next() orelse continue;
        const date_full = fields.next() orelse continue;
        const message = fields.next() orelse continue;

        // Trim date to YYYY-MM-DD (first 10 chars)
        const date = if (date_full.len >= 10) date_full[0..10] else date_full;

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;

        out.appendSlice(alloc, "{\"hash\":\"") catch {};
        mj.writeEscaped(alloc, out, hash);
        out.appendSlice(alloc, "\",\"author\":\"") catch {};
        mj.writeEscaped(alloc, out, author);
        out.appendSlice(alloc, "\",\"date\":\"") catch {};
        mj.writeEscaped(alloc, out, date);
        out.appendSlice(alloc, "\",\"message\":\"") catch {};
        mj.writeEscaped(alloc, out, message);
        out.appendSlice(alloc, "\"}") catch {};
    }

    out.appendSlice(alloc, "]}") catch {};
}

// ── Analysis: recently_changed ────────────────────────────────────────────────

fn handleRecentlyChanged(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    var count_buf: [16]u8 = undefined;
    const count_str: []const u8 = blk: {
        if (args.get("count")) |cv| {
            if (cv == .integer) {
                break :blk std.fmt.bufPrint(&count_buf, "{d}", .{cv.integer}) catch "10";
            }
        }
        break :blk "10";
    };

    const r = gh.run(alloc, &.{
        "git", "log", "--name-only", "--pretty=format:", "-n", count_str,
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer r.deinit(alloc);

    // Deduplicate file paths
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var file_list: std.ArrayList([]const u8) = .empty;
    defer {
        for (file_list.items) |f| alloc.free(f);
        file_list.deinit(alloc);
    }

    var file_lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (file_lines.next()) |line| {
        const trimmed_line = std.mem.trim(u8, line, " \t\r");
        if (trimmed_line.len == 0) continue;
        if (seen.contains(trimmed_line)) continue;
        const owned = alloc.dupe(u8, trimmed_line) catch continue;
        seen.put(owned, {}) catch { alloc.free(owned); continue; };
        file_list.append(alloc, owned) catch { alloc.free(owned); continue; };
    }

    out.appendSlice(alloc, "{\"since_commits\":") catch return;
    out.appendSlice(alloc, count_str) catch return;
    out.appendSlice(alloc, ",\"files\":[") catch return;

    for (file_list.items, 0..) |f, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "\"") catch {};
        mj.writeEscaped(alloc, out, f);
        out.appendSlice(alloc, "\"") catch {};
    }

    out.appendSlice(alloc, "]}") catch {};
}

const Symbol = struct {
    name: []const u8,
    file: ?[]const u8,
};

// ── Helpers ───────────────────────────────────────────────────────────────────

/// True if the labels JSON array contains a label with the given name.
fn hasLabel(labels_val: std.json.Value, name: []const u8) bool {
    if (labels_val != .array) return false;
    for (labels_val.array.items) |lbl| {
        if (lbl != .object) continue;
        const n = lbl.object.get("name") orelse continue;
        if (n != .string) continue;
        if (std.mem.eql(u8, n.string, name)) return true;
    }
    return false;
}

/// Returns 0–3 for priority:p0–p3, 4 if no priority label.
fn getPriority(labels_val: std.json.Value) u8 {
    if (labels_val != .array) return 4;
    for (labels_val.array.items) |lbl| {
        if (lbl != .object) continue;
        const n = lbl.object.get("name") orelse continue;
        if (n != .string) continue;
        if (std.mem.eql(u8, n.string, "priority:p0")) return 0;
        if (std.mem.eql(u8, n.string, "priority:p1")) return 1;
        if (std.mem.eql(u8, n.string, "priority:p2")) return 2;
        if (std.mem.eql(u8, n.string, "priority:p3")) return 3;
    }
    return 4;
}

fn stubNotImplemented(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    tool_name: []const u8,
    issue: u32,
) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf,
        \\{{"status":"not_implemented","tool":"{s}","see_issue":{d}}}
    , .{ tool_name, issue }) catch {
        out.appendSlice(alloc, "{\"error\":\"fmt overflow\"}") catch {};
        return;
    };
    out.appendSlice(alloc, s) catch {};
}

fn writeErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{msg}) catch {
        out.appendSlice(alloc, "{\"error\":\"unknown\"}") catch {};
        return;
    };
    out.appendSlice(alloc, s) catch {};
}
