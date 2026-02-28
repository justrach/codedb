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

// ── Worker ────────────────────────────────────────────────────────────────────

const Worker = struct {
    role:   []const u8,         // borrowed from parsed JSON (valid until parsed.deinit)
    prompt: []const u8,         // borrowed from parsed JSON
    out:    std.ArrayList(u8) = .empty,  // written by worker thread, freed by collector
};

fn workerFn(w: *Worker) void {
    // Each worker owns its own page_allocator-backed memory; no lock needed.
    cas.runTurn(std.heap.page_allocator, w.prompt, &w.out);
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Run an agent swarm for `task`. Blocks until all sub-agents finish and
/// the synthesis agent has written its result to `out`.
pub fn runSwarm(
    alloc:      std.mem.Allocator,
    task:       []const u8,
    max_agents: u32,
    out:        *std.ArrayList(u8),
) void {
    const cap: usize = @min(max_agents, HARD_MAX);

    // ── Phase 1: Orchestrator decomposes task ─────────────────────────────
    const orch_prompt = std.fmt.allocPrint(alloc,
        "You are a task orchestrator. Decompose the task below into at most {d} " ++
        "independent, self-contained sub-tasks that can execute in parallel.\n" ++
        "Reply with ONLY a JSON array — no markdown, no prose:\n" ++
        "[{{\"role\":\"<role label>\",\"prompt\":\"<full sub-task prompt>\"}},...]\n\n" ++
        "Task: {s}",
        .{ cap, task },
    ) catch { appendErr(alloc, out, "OOM: orchestrator prompt"); return; };
    defer alloc.free(orch_prompt);

    var orch_out: std.ArrayList(u8) = .empty;
    defer orch_out.deinit(alloc);
    cas.runTurn(alloc, orch_prompt, &orch_out);

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

    // Collect valid sub-tasks (may be fewer than arr.items.len if some are malformed)
    var workers = alloc.alloc(Worker, @min(arr.items.len, cap)) catch {
        appendErr(alloc, out, "OOM: workers"); return;
    };
    defer alloc.free(workers);

    var threads = alloc.alloc(?std.Thread, workers.len) catch {
        appendErr(alloc, out, "OOM: threads"); return;
    };
    defer alloc.free(threads);

    var count: usize = 0;
    for (arr.items[0..@min(arr.items.len, cap)]) |item| {
        const obj   = switch (item) { .object => |o| o, else => continue };
        const p_val = obj.get("prompt") orelse continue;
        const r_val = obj.get("role")   orelse std.json.Value{ .string = "agent" };
        workers[count] = .{
            .role   = switch (r_val) { .string => |s| s, else => "agent" },
            .prompt = switch (p_val) { .string => |s| s, else => continue },
        };
        threads[count] = std.Thread.spawn(.{}, workerFn, .{&workers[count]}) catch null;
        count += 1;
    }

    if (count == 0) { appendErr(alloc, out, "swarm: no valid sub-tasks extracted"); return; }

    // ── Phase 3: Join all worker threads ──────────────────────────────────
    for (threads[0..count]) |maybe_t| {
        if (maybe_t) |t| t.join();
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
    cas.runTurn(alloc, synth.items, out);
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "{\"error\":\"") catch return;
    mj.writeEscaped(alloc, out, msg);
    out.appendSlice(alloc, "\"}") catch {};
}
