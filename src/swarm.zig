// swarm.zig — Agent Swarm: orchestrate N parallel Codex sub-agents
//
// Pipeline:
//   1. Orchestrator agent decomposes the task into ≤max_agents sub-tasks (JSON)
//   2. N worker threads each run one sub-agent via codex app-server (in parallel)
//   3. Synthesis agent combines all results into `out`
//
// Threading: std.Thread.spawn per worker; each worker uses page_allocator so
// there is no allocator contention across threads.

const std = @import("std");
const mj  = @import("mcp").json;
const cas = @import("codex_appserver.zig");

/// Hard ceiling on parallel agents regardless of what the caller requests.
pub const HARD_MAX: u32 = 100;

/// Prepended to every writable-worker prompt so agents use the correct muonry
/// shell tools instead of falling back to sed/awk/patch/heredocs.
const WRITABLE_PREAMBLE =
    \\ENVIRONMENT: The following shell commands are on PATH and MUST be used for all file I/O:
    \\
    \\  zigrep  "pattern" path/          # search code (NOT ziggrep — the command is zigrep)
    \\  zigread FILE                     # read file with line numbers
    \\  zigread -o FILE                  # structural outline
    \\  zigread -s SYMBOL FILE           # extract function by name
    \\  zigread -L FROM-TO FILE          # read line range
    \\  zigpatch FILE FROM-TO <<'EOF'    # replace line range (PREFERRED for edits)
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
    \\  - NEVER write raw diff/patch syntax into source files
    \\  - Always zigread before zigpatch; always zigdiff after zigpatch
    \\  - One focused change per file; do not rewrite files wholesale
    \\  - Cite file:line for every finding
    \\
    \\MCP TOOLS (also available): mcp__muonry__read, mcp__muonry__search, mcp__muonry__edit
    \\
    \\Task:
    \\
;

// ── Worker ────────────────────────────────────────────────────────────────────

const Worker = struct {
    role:             []const u8,        // borrowed from parsed JSON (valid until parsed.deinit)
    prompt:           []const u8,        // borrowed from parsed JSON
    allocated_prompt: ?[]u8 = null,      // non-null for writable workers; freed after thread join
    out:              std.ArrayList(u8) = .empty,  // written by worker thread, freed by collector
};

const WorkerArgs = struct {
    worker: *Worker,
    policy: cas.SandboxPolicy,
};

fn workerFn(args: *WorkerArgs) void {
    const prompt = args.worker.allocated_prompt orelse args.worker.prompt;
    cas.runTurnPolicy(std.heap.page_allocator, prompt, &args.worker.out, args.policy);
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Run an agent swarm for `task`. Blocks until all sub-agents finish and
/// the synthesis agent has written its result to `out`.
pub fn runSwarm(
    alloc:      std.mem.Allocator,
    task:       []const u8,
    max_agents: u32,
    out:        *std.ArrayList(u8),
    policy:     cas.SandboxPolicy,
) void {
    const cap: usize = @min(max_agents, HARD_MAX);

    // ── Phase 1: Orchestrator decomposes task ─────────────────────────────
    const orch_prompt = std.fmt.allocPrint(alloc,
        "You are a task orchestrator. Decompose the task below into at most {d} " ++
        "independent, self-contained sub-tasks that can execute in parallel.\n" ++
        "Reply with ONLY a JSON array — no markdown, no prose:\n" ++
        "[{{\"role\":\"<role label>\",\"prompt\":\"<full sub-task prompt>\"}},...]\\n\\n" ++
        "Task: {s}",
        .{ cap, task },
    ) catch { appendErr(alloc, out, "OOM: orchestrator prompt"); return; };
    defer alloc.free(orch_prompt);

    var orch_out: std.ArrayList(u8) = .empty;
    defer orch_out.deinit(alloc);
    cas.runTurnPolicy(alloc, orch_prompt, &orch_out, .read_only); // orchestrator only reads

    // ── Phase 2: Parse sub-tasks from orchestrator output ─────────────────
    const raw = orch_out.items;
    const json_start = std.mem.indexOfScalar(u8, raw, '[') orelse {
        appendErr(alloc, out, "swarm: orchestrator returned no JSON array"); return;
    };
    const json_end = std.mem.lastIndexOfScalar(u8, raw, ']') orelse {
        appendErr(alloc, out, "swarm: orchestrator JSON array not closed"); return;
    };
    const js = raw[json_start .. json_end + 1];

    const parsed = std.json.parseFromSlice(
        std.json.Value, alloc, js, .{ .ignore_unknown_fields = true },
    ) catch { appendErr(alloc, out, "swarm: orchestrator returned invalid JSON"); return; };
    defer parsed.deinit();

    const arr = switch (parsed.value) {
        .array => |a| a,
        else   => { appendErr(alloc, out, "swarm: orchestrator value is not an array"); return; },
    };

    var workers = alloc.alloc(Worker, @min(arr.items.len, cap)) catch {
        appendErr(alloc, out, "OOM: workers"); return;
    };
    defer alloc.free(workers);

    var worker_args = alloc.alloc(WorkerArgs, workers.len) catch {
        appendErr(alloc, out, "OOM: worker_args"); return;
    };
    defer alloc.free(worker_args);

    var threads = alloc.alloc(?std.Thread, workers.len) catch {
        appendErr(alloc, out, "OOM: threads"); return;
    };
    defer alloc.free(threads);

    var count: usize = 0;
    for (arr.items[0..@min(arr.items.len, cap)]) |item| {
        const obj   = switch (item) { .object => |o| o, else => continue };
        const p_val = obj.get("prompt") orelse continue;
        const r_val = obj.get("role")   orelse std.json.Value{ .string = "agent" };
        const base  = switch (p_val) { .string => |s| s, else => continue };
        // For writable workers, prepend the tool-use preamble so agents use
        // zigrep/zigpatch/zigread instead of sed/awk/patch/heredocs.
        const allocated: ?[]u8 = if (policy == .writable)
            std.fmt.allocPrint(alloc, "{s}{s}", .{ WRITABLE_PREAMBLE, base }) catch null
        else
            null;
        workers[count] = .{
            .role             = switch (r_val) { .string => |s| s, else => "agent" },
            .prompt           = base,
            .allocated_prompt = allocated,
        };
        worker_args[count] = .{ .worker = &workers[count], .policy = policy };
        threads[count] = std.Thread.spawn(.{}, workerFn, .{&worker_args[count]}) catch null;
        count += 1;
    }

    if (count == 0) { appendErr(alloc, out, "swarm: no valid sub-tasks extracted"); return; }

    // ── Phase 3: Join all worker threads ──────────────────────────────────
    for (threads[0..count]) |maybe_t| {
        if (maybe_t) |t| t.join();
    }
    // Free preamble-prefixed prompts now that threads have finished.
    for (workers[0..count]) |w| {
        if (w.allocated_prompt) |p| alloc.free(p);
    }

    // ── Phase 4: Build synthesis prompt from worker results ───────────────
    var synth: std.ArrayList(u8) = .empty;
    defer synth.deinit(alloc);

    synth.appendSlice(alloc,
        "You are a synthesis agent. Combine these parallel sub-agent results " ++
        "into one coherent, well-structured response:\n\n",
    ) catch {};

    for (workers[0..count], 0..) |*w, i| {
        const header = std.fmt.allocPrint(
            alloc, "## Agent {d} — {s}\n", .{ i + 1, w.role },
        ) catch "";
        defer alloc.free(header);
        synth.appendSlice(alloc, header) catch {};
        synth.appendSlice(alloc, w.out.items) catch {};
        synth.appendSlice(alloc, "\n\n") catch {};
        w.out.deinit(std.heap.page_allocator);
    }

    synth.appendSlice(alloc, "Synthesize the above into a final answer.") catch {};

    // ── Phase 5: Synthesis agent ──────────────────────────────────────────
    cas.runTurnPolicy(alloc, synth.items, out, .read_only); // synthesis only reads
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "{\"error\":\"") catch return;
    mj.writeEscaped(alloc, out, msg);
    out.appendSlice(alloc, "\"}") catch {};
}
