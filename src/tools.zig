// gitagent-mcp — Tool definitions
//
// Implements all 22 GitHub workflow tools across 5 groups:
//   Planning    → decompose_feature, get_project_state, get_next_task, prioritize_issues
//   Issues      → create_issue, create_issues_batch, update_issue, close_issue, link_issues, get_issue
//   Branches    → create_branch, get_current_branch, commit_with_context, push_branch
//   Pull Reqs   → create_pr, get_pr_status, list_open_prs, merge_pr, get_pr_diff
//   Analysis    → review_pr_impact, blast_radius, relevant_context, git_history_for, recently_changed
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
const graph_query = @import("graph/query.zig");
const graph_mod   = @import("graph/graph.zig");
const graph_store = @import("graph/storage.zig");

// ── Dynamic repo slug ─────────────────────────────────────────────────────────
// Updated from CWD on startup (notifications/initialized) and on every set_repo.
// MCP dispatch is single-threaded; mutex is belt-and-suspenders for drainer threads.
var g_repo_mu:  std.Thread.Mutex = .{};
var g_repo_buf: [512]u8          = undefined;
var g_repo_len: usize            = 0;

/// Returns the current GitHub repo slug (owner/repo), or "" if not detected.
pub fn currentRepo() []const u8 {
    g_repo_mu.lock();
    defer g_repo_mu.unlock();
    return if (g_repo_len == 0) "" else g_repo_buf[0..g_repo_len];
}

/// Returns the current repo slug, or writes an error and returns null.
/// Use this in tool handlers instead of currentRepo() directly.
fn repoOrErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8)) ?[]const u8 {
    const repo = currentRepo();
    if (repo.len == 0) {
        writeErr(alloc, out, "no repository detected — call set_repo with the repo path, or set REPO_PATH env var");
        return null;
    }
    return repo;
}

fn setCurrentRepo(slug: []const u8) void {
    if (slug.len == 0 or slug.len > g_repo_buf.len) return;
    g_repo_mu.lock();
    defer g_repo_mu.unlock();
    @memcpy(g_repo_buf[0..slug.len], slug);
    g_repo_len = slug.len;
}

/// Detect the GitHub repo slug from the CWD and update the global.
/// Tries `gh repo view` first, then falls back to parsing `git remote get-url origin`.
/// Call after any chdir to keep --repo in sync with the active repository.
pub fn detectAndUpdateRepo(alloc: std.mem.Allocator) void {
    // Try gh CLI first (most reliable — handles forks, renames, etc.)
    const result = gh.run(alloc, &.{ "gh", "repo", "view", "--json", "nameWithOwner" }) catch {
        detectViaGitRemote(alloc);
        return;
    };
    defer result.deinit(alloc);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch {
        detectViaGitRemote(alloc);
        return;
    };
    defer parsed.deinit();
    if (parsed.value == .object) {
        if (parsed.value.object.get("nameWithOwner")) |v| {
            if (v == .string) {
                setCurrentRepo(v.string);
                return;
            }
        }
    }
    // gh succeeded but returned unexpected JSON — fall back to git remote
    detectViaGitRemote(alloc);
}

/// Fallback detection: parse owner/repo from `git remote get-url origin`.
fn detectViaGitRemote(alloc: std.mem.Allocator) void {
    var child = std.process.Child.init(
        &.{ "git", "remote", "get-url", "origin" },
        alloc,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Close;
    child.stdin_behavior = .Close;

    if (child.spawn()) |_| {
        const stdout = child.stdout orelse return;
        var buf: [4096]u8 = undefined;
        const n = stdout.read(&buf) catch return;
        _ = child.wait() catch {};
        const url = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (parseGitHubSlug(url)) |slug| {
            setCurrentRepo(slug);
        }
    } else |_| {}
}

/// Extract "owner/repo" from a GitHub remote URL.
/// Handles https://github.com/owner/repo.git, git@github.com:owner/repo.git,
/// and ssh://git@github.com/owner/repo.git.
fn parseGitHubSlug(url: []const u8) ?[]const u8 {
    const markers = [_][]const u8{ "github.com/", "github.com:" };
    for (markers) |marker| {
        if (std.mem.indexOf(u8, url, marker)) |idx| {
            var slug = url[idx + marker.len ..];
            if (std.mem.endsWith(u8, slug, ".git")) {
                slug = slug[0 .. slug.len - 4];
            }
            // Must contain exactly one slash (owner/repo)
            if (std.mem.indexOf(u8, slug, "/") != null and
                std.mem.lastIndexOf(u8, slug, "/") == std.mem.indexOf(u8, slug, "/"))
            {
                return slug;
            }
        }
    }
    return null;
}

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
    close_issues_batch,
    close_issue,
    link_issues,
    get_issue,
    // Branches & commits
    create_branch,
    get_current_branch,
    commit_with_context,
    push_branch,
    // Pull requests
    create_pr,
    get_pr_status,
    list_open_prs,
    merge_pr,
    get_pr_diff,
    // Analysis
    review_pr_impact,
    blast_radius,
    relevant_context,
    git_history_for,
    recently_changed,
    // Graph queries
    symbol_at,
    find_callers,
    find_callees,
    find_dependents,
    // Repository management
    set_repo,
    // Agents — invoke Codex subagents as MCP tool calls
    run_reviewer,
    run_explorer,
    run_zig_infra,
    // Swarm — parallel multi-agent execution
    run_swarm,
    // Iterative review-fix loop
    review_fix_loop,
    // Claude Agent SDK — single agent turn with tool/permission controls
    run_agent,
    // Smart executor — picks strategy, roles, and models automatically
    run_task,
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
    \\{"name":"close_issues_batch","description":"Close multiple issues at once. Each issue is marked status:done. Use this instead of calling close_issue N times.","inputSchema":{"type":"object","properties":{"issue_numbers":{"type":"array","items":{"type":"integer"},"description":"Issue numbers to close"},"pr_number":{"type":"integer","description":"PR number that resolves all these issues (optional)"}},"required":["issue_numbers"]}},
    \\{"name":"close_issue","description":"Close an issue and mark it status:done. Optionally reference the PR that resolved it.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer"},"pr_number":{"type":"integer","description":"PR number that resolves this issue"}},"required":["issue_number"]}},
    \\{"name":"link_issues","description":"Mark one issue as blocked by others. Adds status:blocked to each blocked issue and writes dependency references into issue bodies.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer","description":"The issue that blocks others"},"blocks":{"type":"array","items":{"type":"integer"},"description":"Issue numbers that are blocked by issue_number"}},"required":["issue_number","blocks"]}},
    \\{"name":"get_issue","description":"Fetch a single GitHub issue by number. Returns title, body, state, labels, and comments. Use this to read any issue — including closed ones — when you only have the number.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer","description":"Issue number to fetch"}},"required":["issue_number"]}},
    \\{"name":"create_branch","description":"Create a feature or fix branch linked to an issue. Branch name: {type}/{issue_number}-{slugified-title}. Sets status:in-progress on the issue.","inputSchema":{"type":"object","properties":{"issue_number":{"type":"integer"},"branch_type":{"type":"string","enum":["feature","fix"],"description":"Branch prefix type"}},"required":["issue_number"]}},
    \\{"name":"get_current_branch","description":"Return the current git branch name and the issue number parsed from it (null if not a convention branch).","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"commit_with_context","description":"Stage and commit with a message referencing the current issue. Auto-detects issue number from branch name if not provided. If files is provided, only those files are staged; otherwise stages everything.","inputSchema":{"type":"object","properties":{"message":{"type":"string","description":"Commit message body"},"issue_number":{"type":"integer","description":"Issue to reference (auto-detected from branch if omitted)"},"files":{"type":"array","items":{"type":"string"},"description":"Specific files to stage (default: stage all with git add -A)"}},"required":["message"]}},
    \\{"name":"push_branch","description":"Push the current branch to origin.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"create_pr","description":"Open a pull request from the current branch to main. Auto-generates title and body from the linked issue if not provided. Sets status:in-review on the issue.","inputSchema":{"type":"object","properties":{"title":{"type":"string","description":"PR title (defaults to linked issue title)"},"body":{"type":"string","description":"PR body (defaults to issue summary + Closes #N)"}},"required":[]}},
    \\{"name":"get_pr_status","description":"Get CI status, review state, and merge readiness for a PR. Defaults to the PR for the current branch.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"}},"required":[]}},
    \\{"name":"list_open_prs","description":"List all open PRs with their CI status, review state, and linked issue numbers.","inputSchema":{"type":"object","properties":{},"required":[]}},
    \\{"name":"merge_pr","description":"Merge a pull request. Defaults to current branch's PR if pr_number is omitted. Supports squash, merge, and rebase strategies.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"},"strategy":{"type":"string","enum":["squash","merge","rebase"],"description":"Merge strategy (default: squash)"},"delete_branch":{"type":"boolean","description":"Delete the branch after merging (default: false)"}},"required":[]}},
    \\{"name":"get_pr_diff","description":"Get the diff for a pull request. Defaults to current branch's PR if pr_number is omitted. Use this to review what a PR changes before merging.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"}},"required":[]}},
    \\{"name":"review_pr_impact","description":"Analyze a PR's blast radius: extracts changed files and function symbols from the diff, then searches the codebase for all references to those symbols. Call this before approving or merging a PR to understand what other code might be affected by the changes. Also useful after creating a PR to self-review impact. Returns files changed, symbols modified, and which files reference each symbol.","inputSchema":{"type":"object","properties":{"pr_number":{"type":"integer","description":"PR number (defaults to current branch's PR)"}},"required":[]}},
    \\{"name":"blast_radius","description":"Find all files that reference symbols defined in a file or a specific symbol. Use this to understand the impact of changing a file or function before editing. Works offline with grep-based search.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to analyze (extracts symbols automatically)"},"symbol":{"type":"string","description":"Specific symbol name to search for"}},"required":[]}},
    \\{"name":"relevant_context","description":"Find files most related to a given file by analyzing symbol cross-references and imports. Use this to understand what other files you should read before modifying a file. Works offline with grep-based search.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to find context for"}},"required":["file"]}},
    \\{"name":"git_history_for","description":"Return the git commit history for a specific file. Use this to understand recent changes, who modified a file, and why. Works offline with local git.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"Path to file to get history for"},"count":{"type":"integer","description":"Number of commits to return (default 20)"}},"required":["file"]}},
    \\{"name":"recently_changed","description":"Return files that were recently modified across recent commits. Use this to understand what areas of the codebase are actively being worked on. Works offline with local git.","inputSchema":{"type":"object","properties":{"count":{"type":"integer","description":"Number of recent commits to scan (default 10)"}},"required":[]}},
    \\{"name":"symbol_at","description":"Find the symbol(s) defined at a given file path and line number in the CodeGraph. Returns symbol name, kind, scope, and location. Falls back to the closest symbol before the given line if no exact match. Requires a CodeGraph DB file at .codegraph/graph.bin.","inputSchema":{"type":"object","properties":{"file":{"type":"string","description":"File path to look up"},"line":{"type":"integer","description":"Line number to look up"}},"required":["file","line"]}},
    \\{"name":"find_callers","description":"Find all symbols that call/reference the given symbol ID. Returns caller name, location, edge kind, and weight. Requires a CodeGraph DB file at .codegraph/graph.bin.","inputSchema":{"type":"object","properties":{"symbol_id":{"type":"integer","description":"Symbol ID to find callers of"}},"required":["symbol_id"]}},
    \\{"name":"find_callees","description":"Find all symbols that the given symbol calls/references. Returns callee name, location, edge kind, and weight. Requires a CodeGraph DB file at .codegraph/graph.bin.","inputSchema":{"type":"object","properties":{"symbol_id":{"type":"integer","description":"Symbol ID to find callees of"}},"required":["symbol_id"]}},
    \\{"name":"find_dependents","description":"Find all symbols that transitively depend on the given symbol, ranked by Personalized PageRank score. Use this to understand the full blast radius of changing a symbol. Requires a CodeGraph DB file at .codegraph/graph.bin.","inputSchema":{"type":"object","properties":{"symbol_id":{"type":"integer","description":"Symbol ID to find dependents of"},"max_results":{"type":"integer","description":"Maximum number of results to return (default 10)"}},"required":["symbol_id"]}},
    \\{"name":"set_repo","description":"Switch the active repository path. All subsequent tool calls will operate against this repo. Invalidates the session cache.","inputSchema":{"type":"object","properties":{"path":{"type":"string","description":"Absolute path to the git repository root"}},"required":["path"]}},
    \\{"name":"run_reviewer","description":"Invoke the Codex reviewer subagent on the current branch. Checks errdefer gaps, RwLock ordering, Zig 0.15.x API misuse, and missing test coverage. Returns the agent's full findings.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Override the default review prompt"}},"required":[]}},
    \\{"name":"run_explorer","description":"Invoke the Codex explorer subagent to trace execution paths through the codebase. Read-only — maps affected code paths and gathers evidence without proposing fixes.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"What to explore, e.g. 'trace how get_next_task flows through gh.zig'"}},"required":["prompt"]}},
    \\{"name":"run_zig_infra","description":"Invoke the Codex zig_infra subagent to review build.zig module graph, named @import wiring, and test step coverage.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Override the default build wiring check prompt"}},"required":[]}},
    \\{"name":"run_swarm","description":"Spawn a self-organizing swarm of parallel Codex sub-agents to tackle a task. An orchestrator agent decomposes the task into sub-tasks, up to max_agents run concurrently via Zig threads, and a synthesis agent combines their outputs. Set writable=true to allow agents to edit files (for bug fixes, refactors). Best for broad research, multi-file analysis, multi-angle reviews, or parallel bug fixing.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"The high-level task for the swarm to solve"},"max_agents":{"type":"integer","description":"Maximum parallel sub-agents (default 5, hard cap 100)"},"writable":{"type":"boolean","description":"Allow agents to edit files and run shell commands (default false = read-only analysis)"}},"required":["prompt"]}},
    \\{"name":"review_fix_loop","description":"Iterative review-fix-review loop. Runs a read-only reviewer to find issues, then a writable agent to fix them, then re-reviews. Repeats until the reviewer reports no remaining issues or max_iterations is reached. Returns a JSON object with iteration history and convergence status.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"Override the default review criteria"},"max_iterations":{"type":"integer","description":"Maximum review-fix cycles (default 3, max 5)"}},"required":[]}},
    \\{"name":"run_agent","description":"Run a single agent turn. Provider-agnostic: resolves the best backend (Claude/Codex) based on mode, role, and available providers. The primitive layer — use run_task for smart multi-step execution.","inputSchema":{"type":"object","properties":{"prompt":{"type":"string","description":"The task or question for the agent"},"model":{"type":"string","description":"Model alias or full ID (default: claude-sonnet-4-6). Use \"opus\" for hardest tasks, \"haiku\" for fast/cheap."},"role":{"type":"string","description":"Agent role: finder, reviewer, fixer, explorer, architect, orchestrator, synthesizer, monitor"},"mode":{"type":"string","enum":["smart","rush","deep","free"],"description":"Agent mode: smart (Sonnet), rush (Haiku), deep (Opus), free (Haiku)"},"allowed_tools":{"type":"string","description":"Comma-separated tool allowlist, e.g. \"Bash,Read,Edit\". Omit to allow all tools."},"permission_mode":{"type":"string","enum":["default","acceptEdits","bypassPermissions"],"description":"Permission mode for file and shell operations"},"writable":{"type":"boolean","description":"Allow file writes (maps to bypassPermissions when permission_mode is unset)"},"cwd":{"type":"string","description":"Working directory override (default: current repo path)"}},"required":["prompt"]}},
    \\{"name":"run_task","description":"Smart executor: analyzes a task, picks the right strategy and agents, runs them with appropriate roles and models. Use this instead of run_agent for multi-step tasks. Supports chain presets (finder_fixer, reviewer_fixer, explore_report, architect_build) or auto-selection.","inputSchema":{"type":"object","properties":{"task":{"type":"string","description":"Task description — what needs to be done"},"preset":{"type":"string","enum":["finder_fixer","reviewer_fixer","explore_report","architect_build","custom"],"description":"Chain preset (default: auto-select based on task)"},"mode":{"type":"string","enum":["smart","rush","deep","free"],"description":"Agent mode for all agents in the chain"},"max_agents":{"type":"integer","description":"Max agents to spawn (default: preset-determined)"},"writable":{"type":"boolean","description":"Override write access (default: role-determined)"}},"required":["task"]}}
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
        .close_issues_batch    => handleCloseIssuesBatch(alloc, args, out),
        .close_issue           => handleCloseIssue(alloc, args, out),
        .link_issues           => handleLinkIssues(alloc, args, out),
        .get_issue             => handleGetIssue(alloc, args, out),
        // Branches & commits
        .create_branch         => handleCreateBranch(alloc, args, out),
        .get_current_branch    => handleGetCurrentBranch(alloc, args, out),
        .commit_with_context   => handleCommitWithContext(alloc, args, out),
        .push_branch           => handlePushBranch(alloc, args, out),
        // Pull requests
        .create_pr             => handleCreatePr(alloc, args, out),
        .get_pr_status         => handleGetPrStatus(alloc, args, out),
        .list_open_prs         => handleListOpenPrs(alloc, args, out),
        .merge_pr              => handleMergePr(alloc, args, out),
        .get_pr_diff           => handleGetPrDiff(alloc, args, out),
        // Analysis
        .review_pr_impact      => handleReviewPrImpact(alloc, args, out),
        .blast_radius          => handleBlastRadius(alloc, args, out),
        .relevant_context      => handleRelevantContext(alloc, args, out),
        .git_history_for       => handleGitHistoryFor(alloc, args, out),
        .recently_changed      => handleRecentlyChanged(alloc, args, out),
        // Graph queries
        .symbol_at             => handleSymbolAt(alloc, args, out),
        .find_callers          => handleFindCallers(alloc, args, out),
        .find_callees          => handleFindCallees(alloc, args, out),
        .find_dependents       => handleFindDependents(alloc, args, out),
        // Repository management
        .set_repo              => handleSetRepo(alloc, args, out),
        // Agents
        .run_reviewer          => handleRunReviewer(alloc, args, out),
        .run_explorer          => handleRunExplorer(alloc, args, out),
        .run_zig_infra         => handleRunZigInfra(alloc, args, out),
        // Swarm
        .run_swarm             => handleRunSwarm(alloc, args, out),
        // Iterative review-fix loop
        .review_fix_loop       => handleReviewFixLoop(alloc, args, out),
        // Claude Agent SDK
        .run_agent             => handleRunAgent(alloc, args, out),
        // Smart executor
        .run_task              => handleRunTask(alloc, args, out),
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
    const repo = repoOrErr(alloc, out) orelse return;
    const desc = mj.getStr(args, "feature_description") orelse {
        writeErr(alloc, out, "missing feature_description");
        return;
    };
    const labels_r = gh.run(alloc, &.{
        "gh", "label", "list",
        "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
    const issues_r = gh.run(alloc, &.{
        "gh", "issue", "list",
        "--repo", repo,
        "--json", "number,title,labels,state,url",
        "--limit", "200",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err));
        return;
    };
    defer issues_r.deinit(alloc);

    const prs_r = gh.run(alloc, &.{
        "gh", "pr", "list",
        "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
    // Lightweight fetch — just number + labels needed for priority + block filtering
    const parsed = gh.runJson(alloc, &.{
        "gh", "issue", "list",
        "--repo", repo,
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
        "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
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
            "--repo", repo,
            "--remove-label", "priority:p0,priority:p1,priority:p2,priority:p3",
        }) catch null;
        if (rm) |r| r.deinit(alloc);

        const r = gh.run(alloc, &.{
            "gh", "issue", "edit", num_str, "--add-label", prio,
            "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
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
    argv.appendSlice(alloc, &.{ "gh", "issue", "create", "--repo", repo, "--title", title, "--body", body }) catch return;

    var has_status = false;
    // Track skipped labels for warnings
    var skipped: std.ArrayList([]const u8) = .empty;
    defer skipped.deinit(alloc);

    if (args.get("labels")) |lv| {
        if (lv == .array) {
            for (lv.array.items) |lbl| {
                if (lbl != .string) continue;
                // Check if label exists in the repo cache; skip if missing
                if (cache.getLabel(lbl.string) == null and !std.mem.startsWith(u8, lbl.string, "status:") and !std.mem.startsWith(u8, lbl.string, "priority:")) {
                    skipped.appendSlice(alloc, &.{lbl.string}) catch {};
                    continue;
                }
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
    out.appendSlice(alloc, "\"") catch {};

    // Include warnings for skipped labels
    if (skipped.items.len > 0) {
        out.appendSlice(alloc, ",\"warnings\":[") catch {};
        for (skipped.items, 0..) |s, i| {
            if (i > 0) out.appendSlice(alloc, ",") catch {};
            out.appendSlice(alloc, "\"label not found: ") catch {};
            mj.writeEscaped(alloc, out, s);
            out.appendSlice(alloc, "\"") catch {};
        }
        out.appendSlice(alloc, "]") catch {};
    }
    out.appendSlice(alloc, "}") catch {};
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
    const repo = repoOrErr(alloc, out) orelse return;
    const num_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (num_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num_val.integer}) catch return;

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.appendSlice(alloc, &.{ "gh", "issue", "edit", num_str, "--repo", repo }) catch return;

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

    if (argv.items.len == 6) { // only "gh issue edit N --repo owner/repo" — nothing to do
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


fn handleCloseIssuesBatch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const numbers_val = args.get("issue_numbers") orelse {
        writeErr(alloc, out, "missing issue_numbers array"); return;
    };
    if (numbers_val != .array) { writeErr(alloc, out, "issue_numbers must be array"); return; }

    out.appendSlice(alloc, "[") catch return;
    var first = true;
    for (numbers_val.array.items) |item| {
        if (item != .integer) continue;

        // Build a synthetic single-issue args map
        var single_map = std.json.ObjectMap.init(alloc);
        defer single_map.deinit();
        single_map.put("issue_number", item) catch continue;
        // Forward optional pr_number if provided
        if (args.get("pr_number")) |pr| single_map.put("pr_number", pr) catch {};

        var single_out: std.ArrayList(u8) = .empty;
        defer single_out.deinit(alloc);
        handleCloseIssue(alloc, &single_map, &single_out);

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;
        out.appendSlice(alloc, single_out.items) catch {};
    }
    out.appendSlice(alloc, "]") catch {};
}

fn handleCloseIssue(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const repo = repoOrErr(alloc, out) orelse return;
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
            const cr = gh.run(alloc, &.{ "gh", "issue", "comment", num_str, "--repo", repo, "--body", comment }) catch null;
            if (cr) |r| r.deinit(alloc);
        }
    }

    const close_r = gh.run(alloc, &.{ "gh", "issue", "close", num_str, "--repo", repo }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    close_r.deinit(alloc);

    // Transition label: remove all status labels, apply status:done
    const edit_r = gh.run(alloc, &.{
        "gh", "issue", "edit", num_str,
        "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
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
        "gh", "issue", "comment", blocker_str, "--repo", repo, "--body", comment.items,
    }) catch null;
    if (bc) |r| r.deinit(alloc);

    // For each blocked issue: add status:blocked + comment
    out.appendSlice(alloc, "{\"linked\":[") catch return;
    var first = true;

    for (0..count) |i| {
        const ns = num_strs[i];
        const edit_r = gh.run(alloc, &.{
            "gh", "issue", "edit", ns, "--repo", repo, "--add-label", "status:blocked",
        }) catch null;
        if (edit_r) |r| r.deinit(alloc);

        var cb_buf: [64]u8 = undefined;
        const cb = std.fmt.bufPrint(&cb_buf, "Blocked by: #{s}.", .{blocker_str}) catch "";
        const cr = gh.run(alloc, &.{ "gh", "issue", "comment", ns, "--repo", repo, "--body", cb }) catch null;
        if (cr) |r| r.deinit(alloc);

        if (!first) out.appendSlice(alloc, ",") catch {};
        first = false;
        out.appendSlice(alloc, ns) catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn handleGetIssue(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const repo = repoOrErr(alloc, out) orelse return;
    const num_val = args.get("issue_number") orelse {
        writeErr(alloc, out, "missing issue_number"); return;
    };
    if (num_val != .integer) { writeErr(alloc, out, "issue_number must be integer"); return; }
    var num_buf: [16]u8 = undefined;
    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{num_val.integer}) catch {
        writeErr(alloc, out, "issue_number out of range"); return;
    };

    const r = gh.run(alloc, &.{
        "gh", "issue", "view", num_str,
        "--repo", repo,
        "--json", "number,title,body,state,labels,url,comments",
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    out.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \t\n\r")) catch {};
}


// ── Branches & commits ────────────────────────────────────────────────────────

fn handleCreateBranch(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const repo = repoOrErr(alloc, out) orelse return;
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
        "--repo", repo,
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
        "--repo", repo,
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

    // Stage: selective files or everything
    if (args.get("files")) |fv| {
        if (fv == .array and fv.array.items.len > 0) {
            var add_argv: std.ArrayList([]const u8) = .empty;
            defer add_argv.deinit(alloc);
            add_argv.appendSlice(alloc, &.{ "git", "add", "--" }) catch return;
            for (fv.array.items) |item| {
                if (item == .string) {
                    add_argv.appendSlice(alloc, &.{item.string}) catch return;
                }
            }
            const add_r = gh.run(alloc, add_argv.items) catch |err| {
                writeErr(alloc, out, gh.errorMessage(err)); return;
            };
            add_r.deinit(alloc);
        } else {
            const add_r = gh.run(alloc, &.{ "git", "add", "-A" }) catch |err| {
                writeErr(alloc, out, gh.errorMessage(err)); return;
            };
            add_r.deinit(alloc);
        }
    } else {
        const add_r = gh.run(alloc, &.{ "git", "add", "-A" }) catch |err| {
            writeErr(alloc, out, gh.errorMessage(err)); return;
        };
        add_r.deinit(alloc);
    }

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
    const repo = repoOrErr(alloc, out) orelse return;
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
            const ir = gh.run(alloc, &.{ "gh", "issue", "view", ns, "--repo", repo, "--json", "title,body" }) catch break :blk branch;
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
        "--repo", repo,
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
            "--repo", repo,
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
    const repo = repoOrErr(alloc, out) orelse return;
    const fields = "number,title,state,mergeable,statusCheckRollup,reviews,headRefName,url";
    const r = blk: {
        if (args.get("pr_number")) |pv| {
            if (pv == .integer) {
                var nb: [16]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{pv.integer}) catch {
                    writeErr(alloc, out, "bad pr_number"); return;
                };
                break :blk gh.run(alloc, &.{ "gh", "pr", "view", ns, "--repo", repo, "--json", fields });
            }
        }
        // Default: PR for current branch
        break :blk gh.run(alloc, &.{ "gh", "pr", "view", "--repo", repo, "--json", fields });
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
    const repo = repoOrErr(alloc, out) orelse return;
    const r = gh.run(alloc, &.{
        "gh", "pr", "list",
        "--repo", repo,
        "--json", "number,title,state,headRefName,url,statusCheckRollup",
        "--limit", "50",
    }) catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer r.deinit(alloc);
    out.appendSlice(alloc, std.mem.trim(u8, r.stdout, " \t\n\r")) catch {};
}

fn handleMergePr(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const repo = repoOrErr(alloc, out) orelse return;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(alloc);
    argv.appendSlice(alloc, &.{ "gh", "pr", "merge" }) catch return;

    // Optional pr_number — default to current branch's PR
    if (args.get("pr_number")) |pv| {
        if (pv == .integer) {
            var nb: [16]u8 = undefined;
            const ns = std.fmt.bufPrint(&nb, "{d}", .{pv.integer}) catch {
                writeErr(alloc, out, "bad pr_number"); return;
            };
            argv.appendSlice(alloc, &.{ns}) catch return;
        }
    }

    argv.appendSlice(alloc, &.{ "--repo", repo }) catch return;

    // Strategy: squash (default), merge, or rebase
    const strategy = mj.getStr(args, "strategy") orelse "squash";
    if (std.mem.eql(u8, strategy, "rebase")) {
        argv.appendSlice(alloc, &.{"--rebase"}) catch return;
    } else if (std.mem.eql(u8, strategy, "merge")) {
        argv.appendSlice(alloc, &.{"--merge"}) catch return;
    } else {
        argv.appendSlice(alloc, &.{"--squash"}) catch return;
    }

    // Optional delete_branch
    if (args.get("delete_branch")) |dv| {
        if (dv == .bool and dv.bool) {
            argv.appendSlice(alloc, &.{"--delete-branch"}) catch return;
        }
    }

    const r = gh.run(alloc, argv.items) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    out.appendSlice(alloc, "{\"merged\":true,\"strategy\":\"") catch return;
    mj.writeEscaped(alloc, out, strategy);
    out.appendSlice(alloc, "\"}") catch {};
}

fn handleGetPrDiff(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const repo = repoOrErr(alloc, out) orelse return;
    const r = blk: {
        if (args.get("pr_number")) |pv| {
            if (pv == .integer) {
                var nb: [16]u8 = undefined;
                const ns = std.fmt.bufPrint(&nb, "{d}", .{pv.integer}) catch {
                    writeErr(alloc, out, "bad pr_number"); return;
                };
                break :blk gh.run(alloc, &.{ "gh", "pr", "diff", ns, "--repo", repo });
            }
        }
        break :blk gh.run(alloc, &.{ "gh", "pr", "diff", "--repo", repo });
    } catch |err| { writeErr(alloc, out, gh.errorMessage(err)); return; };
    defer r.deinit(alloc);
    out.appendSlice(alloc, "{\"diff\":\"") catch return;
    mj.writeEscaped(alloc, out, std.mem.trim(u8, r.stdout, " \t\n\r"));
    out.appendSlice(alloc, "\"}") catch {};
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
            var refs: std.ArrayList([]const u8) = search.searchRefs(alloc, tool, sym.name, sym.file) catch |err| {
                writeErr(alloc, out, gh.errorMessage(err));
                return;
            };
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

    const tool = search.probe(alloc);

    // Collect symbols to search
    var syms: std.ArrayList([]const u8) = .empty;
    defer {
        for (syms.items) |s| alloc.free(s);
        syms.deinit(alloc);
    }

    if (sym_arg) |s| {
        const owned = alloc.dupe(u8, s) catch { writeErr(alloc, out, "alloc failed"); return; };
        syms.append(alloc, owned) catch { alloc.free(owned); writeErr(alloc, out, "alloc failed"); return; };
    }

    if (file_arg) |f| {
        const r = gh.run(alloc, &.{ "cat", f }) catch |err| {
            writeErr(alloc, out, gh.errorMessage(err)); return;
        };
        defer r.deinit(alloc);

        var extracted = search.extractSymbolsFromContent(alloc, r.stdout, 50);
        defer extracted.deinit(alloc);
        for (extracted.items) |s| {
            // Dupe: extracted slices point into r.stdout which is freed by defer above
            const owned = alloc.dupe(u8, s) catch continue;
            syms.append(alloc, owned) catch { alloc.free(owned); continue; };
        }
    }

    // Build JSON
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
            var refs: std.ArrayList([]const u8) = search.searchRefs(alloc, tool, sym, file_arg) catch |err| {
                writeErr(alloc, out, gh.errorMessage(err));
                return;
            };
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

fn handleRelevantContext(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file_arg = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing file"); return;
    };

    const r = gh.run(alloc, &.{ "cat", file_arg }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    const tool = search.probe(alloc);

    // Extract symbols
    var extracted = search.extractSymbolsFromContent(alloc, r.stdout, 50);
    defer extracted.deinit(alloc);

    // Score files by reference count — keys are owned (duped) strings
    var scores = std.StringHashMap(i32).init(alloc);
    defer {
        var kit = scores.keyIterator();
        while (kit.next()) |kp| {
            const key = kp.*;
            alloc.free(@constCast(key.ptr)[0..key.len]);
        }
        scores.deinit();
    }

    for (extracted.items) |sym| {
        var refs: std.ArrayList([]const u8) = search.searchRefs(alloc, tool, sym, file_arg) catch |err| {
            writeErr(alloc, out, gh.errorMessage(err));
            return;
        };
        defer {
            for (refs.items) |ref_s| alloc.free(ref_s);
            refs.deinit(alloc);
        }
        for (refs.items) |ref| {
            if (scores.contains(ref)) {
                if (scores.getPtr(ref)) |vp| vp.* += 1;
            } else {
                const owned = alloc.dupe(u8, ref) catch continue;
                scores.put(owned, 1) catch { alloc.free(owned); continue; };
            }
        }
    }

    // Boost @import targets
    var import_lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (import_lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "@import(\"")) |idx| {
            const rest = line[idx + 9 ..];
            if (std.mem.indexOf(u8, rest, "\"")) |end| {
                const import_path = rest[0..end];
                // Try to resolve relative import to a path
                if (std.mem.lastIndexOf(u8, file_arg, "/")) |dir_end| {
                    var path_buf: [512]u8 = undefined;
                    const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ file_arg[0..dir_end], import_path }) catch continue;
                    if (scores.contains(full)) {
                        if (scores.getPtr(full)) |vp| vp.* += 10;
                    } else {
                        const owned = alloc.dupe(u8, full) catch continue;
                        scores.put(owned, 10) catch { alloc.free(owned); continue; };
                    }
                }
            }
        }
    }

    // Sort by score
    const Entry = struct { path: []const u8, score: i32 };
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(alloc);

    var it = scores.iterator();
    while (it.next()) |kv| {
        entries.append(alloc, .{ .path = kv.key_ptr.*, .score = kv.value_ptr.* }) catch continue;
    }

    std.mem.sort(Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const max_results: usize = 20;
    const count = @min(entries.items.len, max_results);

    // Build JSON
    out.appendSlice(alloc, "{\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, file_arg);
    out.appendSlice(alloc, "\",\"context_files\":[") catch return;

    for (entries.items[0..count], 0..) |entry, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"path\":\"") catch {};
        mj.writeEscaped(alloc, out, entry.path);
        out.appendSlice(alloc, "\",\"score\":") catch {};
        var sb: [16]u8 = undefined;
        const ns = std.fmt.bufPrint(&sb, "{d}", .{entry.score}) catch "0";
        out.appendSlice(alloc, ns) catch {};
        out.appendSlice(alloc, "}") catch {};
    }

    out.appendSlice(alloc, "],\"search_tool\":\"") catch return;
    out.appendSlice(alloc, search.toolName(tool)) catch return;
    out.appendSlice(alloc, "\"}") catch {};
}

fn handleGitHistoryFor(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file_arg = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing file"); return;
    };

    var count_buf: [8]u8 = undefined;
    const count_str = blk: {
        if (args.get("count")) |cv| {
            if (cv == .integer and cv.integer > 0) {
                break :blk std.fmt.bufPrint(&count_buf, "{d}", .{cv.integer}) catch "20";
            }
        }
        break :blk "20";
    };

    const r = gh.run(alloc, &.{
        "git", "log", "--follow", "--format=%h%x00%an%x00%ai%x00%s",
        "-n", count_str, "--", file_arg,
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    out.appendSlice(alloc, "{\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, file_arg);
    out.appendSlice(alloc, "\",\"commits\":[") catch return;

    const trimmed = std.mem.trim(u8, r.stdout, " \t\n\r");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Split by null byte (0x00)
        var fields = std.mem.splitScalar(u8, line, 0);
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

fn handleRecentlyChanged(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    var count_buf: [8]u8 = undefined;
    const count_str = blk: {
        if (args.get("count")) |cv| {
            if (cv == .integer and cv.integer > 0) {
                break :blk std.fmt.bufPrint(&count_buf, "{d}", .{cv.integer}) catch "10";
            }
        }
        break :blk "10";
    };

    const r = gh.run(alloc, &.{
        "git", "log", "--name-only", "--pretty=format:", "-n", count_str,
    }) catch |err| {
        writeErr(alloc, out, gh.errorMessage(err)); return;
    };
    defer r.deinit(alloc);

    // Deduplicate file paths
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    var file_list: std.ArrayList([]const u8) = .empty;
    defer file_list.deinit(alloc);

    const trimmed = std.mem.trim(u8, r.stdout, " \t\n\r");
    var lines = std.mem.splitScalar(u8, trimmed, '\n');
    while (lines.next()) |line| {
        const path = std.mem.trim(u8, line, " \t\r");
        if (path.len == 0) continue;
        if (seen.contains(path)) continue;
        seen.put(path, {}) catch continue;
        file_list.append(alloc, path) catch continue;
    }

    // Build JSON
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

// ── Graph query handlers ──────────────────────────────────────────────────────

const GRAPH_PATH = ".codegraph/graph.bin";

fn loadGraph(alloc: std.mem.Allocator) ?graph_mod.CodeGraph {
    return graph_store.loadFromFile(GRAPH_PATH, alloc) catch return null;
}

fn handleSymbolAt(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const file = mj.getStr(args, "file") orelse {
        writeErr(alloc, out, "missing required parameter: file");
        return;
    };
    const line_val = mj.getInt(args, "line") orelse {
        writeErr(alloc, out, "missing required parameter: line");
        return;
    };
    const line: u32 = @intCast(@max(line_val, 0));

    var g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };
    defer g.deinit();

    const results = graph_query.symbolAt(&g, file, line, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"symbols\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeSymbolResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn handleFindCallers(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    var g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };
    defer g.deinit();

    const results = graph_query.findCallers(&g, id, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"callers\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeCallerResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn handleFindCallees(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    var g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };
    defer g.deinit();

    const results = graph_query.findCallees(&g, id, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"callees\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        writeCallerResultJson(alloc, out, r);
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn handleFindDependents(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const sym_id = mj.getInt(args, "symbol_id") orelse {
        writeErr(alloc, out, "missing required parameter: symbol_id");
        return;
    };
    const id: u64 = @intCast(@max(sym_id, 0));

    const max_results_val = mj.getInt(args, "max_results");
    const max_results: usize = if (max_results_val) |v| @intCast(@max(v, 1)) else 10;

    var g = loadGraph(alloc) orelse {
        writeErr(alloc, out, "no CodeGraph found at " ++ GRAPH_PATH ++ " — run ingestion first");
        return;
    };
    defer g.deinit();

    const results = graph_query.findDependents(&g, id, max_results, alloc) catch {
        writeErr(alloc, out, "query failed");
        return;
    };
    defer alloc.free(results);

    out.appendSlice(alloc, "{\"dependents\":[") catch return;
    for (results, 0..) |r, i| {
        if (i > 0) out.appendSlice(alloc, ",") catch {};
        out.appendSlice(alloc, "{\"id\":") catch {};
        var id_buf: [20]u8 = undefined;
        const id_s = std.fmt.bufPrint(&id_buf, "{d}", .{r.id}) catch continue;
        out.appendSlice(alloc, id_s) catch {};

        // Try to resolve symbol name
        if (g.getSymbol(r.id)) |sym| {
            out.appendSlice(alloc, ",\"name\":\"") catch {};
            mj.writeEscaped(alloc, out, sym.name);
            out.appendSlice(alloc, "\"") catch {};
        }

        out.appendSlice(alloc, ",\"score\":") catch {};
        var score_buf: [32]u8 = undefined;
        const score_s = std.fmt.bufPrint(&score_buf, "{d:.6}", .{r.score}) catch continue;
        out.appendSlice(alloc, score_s) catch {};
        out.appendSlice(alloc, "}") catch {};
    }
    out.appendSlice(alloc, "]}") catch {};
}

fn writeSymbolResultJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), r: graph_query.SymbolResult) void {
    out.appendSlice(alloc, "{\"id\":") catch return;
    var buf: [20]u8 = undefined;
    const id_s = std.fmt.bufPrint(&buf, "{d}", .{r.id}) catch return;
    out.appendSlice(alloc, id_s) catch return;
    out.appendSlice(alloc, ",\"name\":\"") catch return;
    mj.writeEscaped(alloc, out, r.name);
    out.appendSlice(alloc, "\",\"kind\":\"") catch return;
    out.appendSlice(alloc, @tagName(r.kind)) catch return;
    out.appendSlice(alloc, "\",\"file\":\"") catch return;
    mj.writeEscaped(alloc, out, r.file_path);
    out.appendSlice(alloc, "\",\"line\":") catch return;
    const line_s = std.fmt.bufPrint(&buf, "{d}", .{r.line}) catch return;
    out.appendSlice(alloc, line_s) catch return;
    out.appendSlice(alloc, ",\"col\":") catch return;
    const col_s = std.fmt.bufPrint(&buf, "{d}", .{r.col}) catch return;
    out.appendSlice(alloc, col_s) catch return;
    out.appendSlice(alloc, ",\"scope\":\"") catch return;
    mj.writeEscaped(alloc, out, r.scope);
    out.appendSlice(alloc, "\"}") catch return;
}

fn writeCallerResultJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), r: graph_query.CallerResult) void {
    writeSymbolResultJson(alloc, out, r.symbol);
    // Patch: replace trailing } with edge info + }
    _ = out.pop();
    out.appendSlice(alloc, ",\"edge_kind\":\"") catch return;
    out.appendSlice(alloc, @tagName(r.edge_kind)) catch return;
    out.appendSlice(alloc, "\",\"weight\":") catch return;
    var buf: [32]u8 = undefined;
    const w_s = std.fmt.bufPrint(&buf, "{d:.4}", .{r.weight}) catch return;
    out.appendSlice(alloc, w_s) catch return;
    out.appendSlice(alloc, "}") catch return;
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

// ── Repository management ─────────────────────────────────────────────────────


// ── Agent runners ─────────────────────────────────────────────────────────────
//
// Each handler shells out to `codex exec` with the appropriate prompt.
// `-c mcp_servers={}` prevents the inner Codex from starting unnecessary MCP
// servers (including gitagent-mcp itself), keeping the subprocess fast.

fn runCodexAgent(
    alloc:  std.mem.Allocator,
    prompt: []const u8,
    out:    *std.ArrayList(u8),
) void {
    const cas = @import("codex_appserver.zig");
    cas.runTurn(alloc, prompt, out);
}

fn handleRunReviewer(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const prompt = mj.getStr(args, "prompt") orelse
        "Review the current branch for correctness and memory safety. " ++
        "Check: errdefer on every allocation, RwLock ordering, " ++
        "Zig 0.15.x API (ArrayList.empty, append(alloc,v), deinit(alloc)), " ++
        "PPR push rule correctness, and missing test coverage. " ++
        "Lead with concrete findings, include file:line references.";
    runCodexAgent(alloc, prompt, out);
}

fn handleRunExplorer(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const prompt = mj.getStr(args, "prompt") orelse {
        writeErr(alloc, out, "run_explorer requires a prompt argument");
        return;
    };
    runCodexAgent(alloc, prompt, out);
}

fn handleRunZigInfra(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const prompt = mj.getStr(args, "prompt") orelse
        "Review build.zig: check every module uses @import(\"name\") not relative paths, " ++
        "every module with tests is wired into test_step, no circular deps exist in " ++
        "types->graph->ppr / types->edge_weights / graph+types->ingest->registry. " ++
        "Flag any @import(\"../path\") that crosses module boundaries.";
    runCodexAgent(alloc, prompt, out);
}

fn handleSetRepo(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const path = mj.getStr(args, "path") orelse {
        writeErr(alloc, out, "missing required argument: path");
        return;
    };
    std.posix.chdir(path) catch |err| {
        var msg: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&msg, "chdir failed: {}", .{err}) catch "chdir failed";
        writeErr(alloc, out, s);
        return;
    };
    // Invalidate cache, re-prime for new repo, detect GitHub slug
    cache.invalidate();
    cache.prefetch(alloc);
    detectAndUpdateRepo(alloc);
    // Return success with both path and detected GitHub slug
    const slug = currentRepo();
    out.appendSlice(alloc, "{\"ok\":true,\"path\":\"") catch return;
    mj.writeEscaped(alloc, out, path);
    out.appendSlice(alloc, "\",\"repo\":\"") catch return;
    if (slug.len > 0) {
        mj.writeEscaped(alloc, out, slug);
    } else {
        out.appendSlice(alloc, "(not detected)") catch {};
    }
    out.appendSlice(alloc, "\"}") catch return;
}

fn handleRunSwarm(alloc: std.mem.Allocator, args: *const std.json.ObjectMap, out: *std.ArrayList(u8)) void {
    const swarm = @import("swarm.zig");
    const cas   = @import("codex_appserver.zig");
    const prompt = mj.getStr(args, "prompt") orelse {
        writeErr(alloc, out, "missing required argument: prompt");
        return;
    };
    const max_agents: u32 = blk: {
        if (args.get("max_agents")) |v| {
            if (v == .integer and v.integer > 0) break :blk @intCast(@min(v.integer, swarm.HARD_MAX));
        }
        break :blk 5;
    };
    const policy: cas.SandboxPolicy = blk: {
        if (args.get("writable")) |v| {
            if (v == .bool and v.bool) break :blk .writable;
        }
        break :blk .read_only;
    };
    swarm.runSwarm(alloc, prompt, max_agents, out, policy);
}

fn handleReviewFixLoop(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const cas = @import("codex_appserver.zig");
    const swarm = @import("swarm.zig");

    const default_review_prompt =
        "Review the current branch for correctness and memory safety. " ++
        "Check: errdefer on every allocation, RwLock ordering, " ++
        "Zig 0.15.x API (ArrayList.empty, append(alloc,v), deinit(alloc)), " ++
        "PPR push rule correctness, and missing test coverage. " ++
        "Lead with concrete findings, include file:line references. " ++
        "If you find NO issues, respond with exactly: NO_ISSUES_FOUND";
    const review_prompt = mj.getStr(args, "prompt") orelse default_review_prompt;

    const max_iter: u32 = blk: {
        if (args.get("max_iterations")) |v| {
            if (v == .integer and v.integer > 0)
                break :blk @intCast(@min(v.integer, 5));
        }
        break :blk 3;
    };

    var out_json: std.ArrayList(u8) = .empty;
    defer {
        // Always flush whatever we have to `out`, even on early exit.
        // This guarantees the caller gets partial JSON rather than nothing.
        if (out_json.items.len > 0)
            out.appendSlice(alloc, out_json.items) catch {};
        out_json.deinit(alloc);
    }

    var converged = false;
    var completed: u32 = 0;

    // Start JSON output
    out_json.appendSlice(alloc, "{\"iterations\":[") catch return;

    var i: u32 = 0;
    while (i < max_iter) : (i += 1) {
        var iter_json: std.ArrayList(u8) = .empty;
        defer iter_json.deinit(alloc);

        if (i > 0) iter_json.appendSlice(alloc, ",") catch return;

        iter_json.appendSlice(alloc, "{\"iteration\":") catch return;
        iter_json.writer(alloc).print("{d}", .{i + 1}) catch return;

        // ── Phase 1: Review (read-only) ───────────────────────────────────
        iter_json.appendSlice(alloc, ",\"review\":\"") catch return;
        var review_out: std.ArrayList(u8) = .empty;
        defer review_out.deinit(alloc);
        cas.runTurnPolicy(alloc, review_prompt, &review_out, .read_only);

        mj.writeEscaped(alloc, &iter_json, review_out.items);
        iter_json.appendSlice(alloc, "\"") catch return;

        // Check convergence: reviewer found no issues
        const review_text = review_out.items;
        if (std.mem.indexOf(u8, review_text, "NO_ISSUES_FOUND") != null or
            review_text.len == 0)
        {
            iter_json.appendSlice(alloc, ",\"fix\":null}") catch return;
            out_json.appendSlice(alloc, iter_json.items) catch return;
            completed = i + 1;
            converged = true;
            break;
        }

        // ── Phase 2: Fix (writable) ───────────────────────────────────────
        const preamble = swarm.buildPreamble(alloc);
        defer if (preamble.len > 0) alloc.free(preamble);

        const fix_prompt = std.fmt.allocPrint(alloc,
            "{s}" ++
            "You are a code fixer. The following review findings were reported. " ++
            "Fix ALL issues listed below. Use zigread to read files, zigpatch to edit, " ++
            "and zigdiff to verify each fix. Do not introduce new functionality — " ++
            "only fix the reported issues.\n\n" ++
            "REVIEW FINDINGS:\n{s}",
            .{ preamble, review_text },
        ) catch {
            iter_json.appendSlice(alloc, ",\"fix\":\"OOM: fix prompt\"}") catch return;
            out_json.appendSlice(alloc, iter_json.items) catch return;
            completed = i + 1;
            break;
        };
        defer alloc.free(fix_prompt);

        var fix_out: std.ArrayList(u8) = .empty;
        defer fix_out.deinit(alloc);
        cas.runTurnPolicy(alloc, fix_prompt, &fix_out, .writable);

        iter_json.appendSlice(alloc, ",\"fix\":\"") catch return;
        mj.writeEscaped(alloc, &iter_json, fix_out.items);
        iter_json.appendSlice(alloc, "\"}") catch return;

        out_json.appendSlice(alloc, iter_json.items) catch return;
        completed = i + 1;
    }

    // Close JSON — completed tracks actual iterations regardless of exit path
    out_json.appendSlice(alloc, "],\"total_iterations\":") catch return;
    out_json.writer(alloc).print("{d}", .{completed}) catch return;

    if (converged) {
        out_json.appendSlice(alloc, ",\"converged\":true}") catch return;
    } else {
        out_json.appendSlice(alloc, ",\"converged\":false}") catch return;
    }
}

fn handleRunAgent(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const rt = @import("runtime.zig");

    const prompt = mj.getStr(args, "prompt") orelse {
        writeErr(alloc, out, "run_agent requires a prompt argument");
        return;
    };

    // Build context-enriched prompt: branch, issue, recent commits
    const enriched = blk: {
        var ctx: std.ArrayList(u8) = .empty;
        defer ctx.deinit(alloc);

        // Current branch
        if (gh.run(alloc, &.{ "git", "branch", "--show-current" })) |br| {
            defer br.deinit(alloc);
            const branch = std.mem.trim(u8, br.stdout, " \t\n\r");
            if (branch.len > 0) {
                ctx.appendSlice(alloc, "CONTEXT: branch=") catch {};
                ctx.appendSlice(alloc, branch) catch {};
                // Parse issue number from branch name
                if (state.parseIssueNumber(branch)) |n| {
                    var nb: [16]u8 = undefined;
                    const ns = std.fmt.bufPrint(&nb, ", issue=#{d}", .{n}) catch "";
                    ctx.appendSlice(alloc, ns) catch {};
                }
                ctx.appendSlice(alloc, "\n") catch {};
            }
        } else |_| {}

        // Recent commits
        if (gh.run(alloc, &.{ "git", "log", "-3", "--oneline" })) |lr| {
            defer lr.deinit(alloc);
            const log = std.mem.trim(u8, lr.stdout, " \t\n\r");
            if (log.len > 0) {
                ctx.appendSlice(alloc, "RECENT COMMITS:\n") catch {};
                ctx.appendSlice(alloc, log) catch {};
                ctx.appendSlice(alloc, "\n") catch {};
            }
        } else |_| {}

        if (ctx.items.len > 0) {
            ctx.appendSlice(alloc, "\n") catch {};
            ctx.appendSlice(alloc, prompt) catch {};
            break :blk alloc.dupe(u8, ctx.items) catch null;
        }
        break :blk null;
    };
    defer if (enriched) |e| alloc.free(e);

    const final_prompt = enriched orelse prompt;

    // Build AgentRequest from MCP params
    const req: rt.AgentRequest = .{
        .prompt        = final_prompt,
        .role          = mj.getStr(args, "role"),
        .mode          = mj.getStr(args, "mode"),
        .model         = mj.getStr(args, "model"),
        .allowed_tools = mj.getStr(args, "allowed_tools"),
        .cwd           = mj.getStr(args, "cwd"),
        .writable      = blk: {
            if (args.get("writable")) |v|
                if (v == .bool) break :blk v.bool;
            break :blk null;
        },
    };

    // resolve() picks backend + model + tools; dispatch() spawns
    const resolved = rt.resolve.resolveWithProbe(alloc, req);
    defer alloc.free(resolved.system_prompt);

    rt.dispatch.dispatch(alloc, resolved, final_prompt, out);
}

// ── run_task: smart executor with chain presets (#278) ────────────────────────

const ChainPreset = enum {
    finder_fixer,
    reviewer_fixer,
    explore_report,
    architect_build,
    custom,

    fn fromString(s: []const u8) ?ChainPreset {
        if (std.mem.eql(u8, s, "finder_fixer"))    return .finder_fixer;
        if (std.mem.eql(u8, s, "reviewer_fixer"))   return .reviewer_fixer;
        if (std.mem.eql(u8, s, "explore_report"))   return .explore_report;
        if (std.mem.eql(u8, s, "architect_build"))  return .architect_build;
        if (std.mem.eql(u8, s, "custom"))           return .custom;
        return null;
    }
};

/// Run a chain step: resolve + dispatch with the given role + prompt.
fn runChainStep(
    alloc: std.mem.Allocator,
    role: []const u8,
    mode: ?[]const u8,
    writable_override: ?bool,
    prompt: []const u8,
    step_out: *std.ArrayList(u8),
) void {
    const rt = @import("runtime.zig");
    const req: rt.AgentRequest = .{
        .prompt  = prompt,
        .role    = role,
        .mode    = mode,
        .writable = writable_override,
    };
    const resolved = rt.resolve.resolveWithProbe(alloc, req);
    defer alloc.free(resolved.system_prompt);
    rt.dispatch.dispatch(alloc, resolved, prompt, step_out);
}

fn handleRunTask(
    alloc: std.mem.Allocator,
    args: *const std.json.ObjectMap,
    out: *std.ArrayList(u8),
) void {
    const task = mj.getStr(args, "task") orelse {
        writeErr(alloc, out, "run_task requires a task argument");
        return;
    };

    const mode = mj.getStr(args, "mode");
    const writable_override: ?bool = blk: {
        if (args.get("writable")) |v|
            if (v == .bool) break :blk v.bool;
        break :blk null;
    };

    // Determine preset
    const preset: ChainPreset = blk: {
        if (mj.getStr(args, "preset")) |p| {
            if (ChainPreset.fromString(p)) |cp| break :blk cp;
        }
        // Auto-select: default to finder_fixer (most common pattern)
        break :blk .finder_fixer;
    };

    // Start JSON output
    out.appendSlice(alloc, "{\"preset\":\"") catch return;
    const preset_name: []const u8 = switch (preset) {
        .finder_fixer    => "finder_fixer",
        .reviewer_fixer  => "reviewer_fixer",
        .explore_report  => "explore_report",
        .architect_build => "architect_build",
        .custom          => "custom",
    };
    out.appendSlice(alloc, preset_name) catch return;
    out.appendSlice(alloc, "\",\"steps\":[") catch return;

    switch (preset) {
        .finder_fixer => {
            // Step 1: finder (read-only) — locate relevant code
            var finder_out: std.ArrayList(u8) = .empty;
            defer finder_out.deinit(alloc);

            const finder_prompt = std.fmt.allocPrint(alloc,
                "Find all code relevant to the following task. " ++
                "Report file paths and line numbers.\n\nTASK: {s}", .{task},
            ) catch task;
            defer if (finder_prompt.ptr != task.ptr) alloc.free(finder_prompt);

            runChainStep(alloc, "finder", mode, false, finder_prompt, &finder_out);

            out.appendSlice(alloc, "{\"role\":\"finder\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, finder_out.items);
            out.appendSlice(alloc, "\"},") catch return;

            // Step 2: fixer (writable) — apply changes based on findings
            var fixer_out: std.ArrayList(u8) = .empty;
            defer fixer_out.deinit(alloc);

            const fixer_prompt = std.fmt.allocPrint(alloc,
                "Fix the following task based on these findings. " ++
                "Read files before editing, verify each edit.\n\n" ++
                "TASK: {s}\n\nFINDINGS:\n{s}", .{ task, finder_out.items },
            ) catch task;
            defer if (fixer_prompt.ptr != task.ptr) alloc.free(fixer_prompt);

            runChainStep(alloc, "fixer", mode, writable_override orelse true, fixer_prompt, &fixer_out);

            out.appendSlice(alloc, "{\"role\":\"fixer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, fixer_out.items);
            out.appendSlice(alloc, "\"}") catch return;
        },
        .reviewer_fixer => {
            // Step 1: reviewer (read-only) — find issues
            var review_out: std.ArrayList(u8) = .empty;
            defer review_out.deinit(alloc);

            runChainStep(alloc, "reviewer", mode, false, task, &review_out);

            out.appendSlice(alloc, "{\"role\":\"reviewer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, review_out.items);
            out.appendSlice(alloc, "\"},") catch return;

            // Check convergence
            if (std.mem.indexOf(u8, review_out.items, "NO_ISSUES_FOUND") != null) {
                out.appendSlice(alloc, "{\"role\":\"fixer\",\"output\":\"No issues to fix\"}") catch return;
            } else {
                // Step 2: fixer (writable) — fix found issues
                var fixer_out: std.ArrayList(u8) = .empty;
                defer fixer_out.deinit(alloc);

                const fixer_prompt = std.fmt.allocPrint(alloc,
                    "Fix ALL issues listed below.\n\nREVIEW FINDINGS:\n{s}", .{review_out.items},
                ) catch task;
                defer if (fixer_prompt.ptr != task.ptr) alloc.free(fixer_prompt);

                runChainStep(alloc, "fixer", mode, writable_override orelse true, fixer_prompt, &fixer_out);

                out.appendSlice(alloc, "{\"role\":\"fixer\",\"output\":\"") catch return;
                mj.writeEscaped(alloc, out, fixer_out.items);
                out.appendSlice(alloc, "\"}") catch return;
            }
        },
        .explore_report => {
            // Step 1: explorer (read-only) — trace code paths
            var explore_out: std.ArrayList(u8) = .empty;
            defer explore_out.deinit(alloc);

            runChainStep(alloc, "explorer", mode, false, task, &explore_out);

            out.appendSlice(alloc, "{\"role\":\"explorer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, explore_out.items);
            out.appendSlice(alloc, "\"},") catch return;

            // Step 2: synthesizer (read-only) — summarize findings
            var synth_out: std.ArrayList(u8) = .empty;
            defer synth_out.deinit(alloc);

            const synth_prompt = std.fmt.allocPrint(alloc,
                "Synthesize these exploration findings into a clear report.\n\n" ++
                "TASK: {s}\n\nFINDINGS:\n{s}", .{ task, explore_out.items },
            ) catch task;
            defer if (synth_prompt.ptr != task.ptr) alloc.free(synth_prompt);

            runChainStep(alloc, "synthesizer", mode, false, synth_prompt, &synth_out);

            out.appendSlice(alloc, "{\"role\":\"synthesizer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, synth_out.items);
            out.appendSlice(alloc, "\"}") catch return;
        },
        .architect_build => {
            // Step 1: architect (read-only) — design plan
            var arch_out: std.ArrayList(u8) = .empty;
            defer arch_out.deinit(alloc);

            runChainStep(alloc, "architect", "deep", false, task, &arch_out);

            out.appendSlice(alloc, "{\"role\":\"architect\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, arch_out.items);
            out.appendSlice(alloc, "\"},") catch return;

            // Step 2: fixer (writable) — implement the plan
            var fixer_out: std.ArrayList(u8) = .empty;
            defer fixer_out.deinit(alloc);

            const fixer_prompt = std.fmt.allocPrint(alloc,
                "Implement the following architectural plan.\n\n" ++
                "PLAN:\n{s}", .{arch_out.items},
            ) catch task;
            defer if (fixer_prompt.ptr != task.ptr) alloc.free(fixer_prompt);

            runChainStep(alloc, "fixer", mode, writable_override orelse true, fixer_prompt, &fixer_out);

            out.appendSlice(alloc, "{\"role\":\"fixer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, fixer_out.items);
            out.appendSlice(alloc, "\"},") catch return;

            // Step 3: reviewer (read-only) — verify implementation
            var review_out: std.ArrayList(u8) = .empty;
            defer review_out.deinit(alloc);

            runChainStep(alloc, "reviewer", mode, false, task, &review_out);

            out.appendSlice(alloc, "{\"role\":\"reviewer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, review_out.items);
            out.appendSlice(alloc, "\"}") catch return;
        },
        .custom => {
            // Custom: just run as a single agent with the task
            var step_out: std.ArrayList(u8) = .empty;
            defer step_out.deinit(alloc);

            runChainStep(alloc, "fixer", mode, writable_override orelse true, task, &step_out);

            out.appendSlice(alloc, "{\"role\":\"fixer\",\"output\":\"") catch return;
            mj.writeEscaped(alloc, out, step_out.items);
            out.appendSlice(alloc, "\"}") catch return;
        },
    }

    out.appendSlice(alloc, "]}") catch return;
}
