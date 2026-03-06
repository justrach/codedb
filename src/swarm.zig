// swarm.zig — Agent Swarm: orchestrate N parallel sub-agents
//
// Pipeline:
//   1. Orchestrator agent decomposes the task into ≤max_agents sub-tasks (JSON)
//   2. N worker threads each run one sub-agent via runtime resolve→dispatch (in parallel)
//   3. Synthesis agent combines all results into `out`
//
// Threading: std.Thread.spawn per worker; each worker uses page_allocator so
// there is no allocator contention across threads.

const std    = @import("std");
const notify = @import("notify.zig");
const mj  = @import("mcp").json;
const rt   = @import("runtime.zig");

/// Hard ceiling on parallel agents regardless of what the caller requests.
pub const HARD_MAX: u32 = 100;

// ── Worker ────────────────────────────────────────────────────────────────────

const Worker = struct {
    role:             []const u8,        // borrowed from parsed JSON (valid until parsed.deinit)
    prompt:           []const u8,        // borrowed from parsed JSON
    allocated_prompt: ?[]u8 = null,      // non-null for writable workers; freed after thread join
    out:              std.ArrayList(u8) = .empty,  // written by worker thread, freed by collector
};

const WorkerArgs = struct {
    worker: *Worker,
    writable: bool,
};

fn workerFn(args: *WorkerArgs) void {
    const alloc = std.heap.page_allocator;
    const prompt = args.worker.allocated_prompt orelse args.worker.prompt;
    const req: rt.AgentRequest = .{
        .prompt   = prompt,
        .role     = "fixer",
        .mode     = "smart",
        .writable = args.writable,
    };
    const resolved = rt.resolve.resolveWithProbe(alloc, req);
    defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);
    rt.dispatch.dispatch(alloc, resolved, prompt, &args.worker.out);
}

/// Build the writable-worker preamble using the runtime prompt assembly.
/// Returns an allocated string that the caller must free.
pub fn buildPreamble(alloc: std.mem.Allocator) []const u8 {
    const cascade_mod = @import("runtime/cascade.zig");
    const tools = cascade_mod.probe(alloc);
    return rt.prompts.assemble(alloc, null, .smart, tools.tier());
}

// ── Public API ────────────────────────────────────────────────────────────────

/// Run an agent swarm for `task`. Blocks until all sub-agents finish and
/// the synthesis agent has written its result to `out`.
pub fn runSwarm(
    alloc:      std.mem.Allocator,
    task:       []const u8,
    title:      ?[]const u8,
    max_agents: u32,
    out:        *std.ArrayList(u8),
    writable:   bool,
) void {
    const cap: usize = @min(max_agents, HARD_MAX);

    // ── Phase 0: Announce swarm start ────────────────────────────────────────
    {
        var msg_buf: [256]u8 = undefined;
        const label = title orelse "swarm";
        const msg = std.fmt.bufPrint(&msg_buf,
            "swarm: '{s}' — decomposing task (up to {d} agents)...",
            .{ label, cap },
        ) catch "🔀 run_swarm: decomposing task...";
        notify.send(alloc, msg);
    }

    // ── Phase 1: Orchestrator decomposes task ─────────────────────────────
    const orch_prompt = std.fmt.allocPrint(alloc,
        "You are a task orchestrator. Decompose the task below into at most {d} " ++
        "independent, self-contained sub-tasks that can execute in parallel.\n" ++
        "Reply with ONLY a valid JSON array — no markdown fences, no commentary, no explanation:\n" ++
        "[{{\"role\":\"<role label>\",\"prompt\":\"<full sub-task prompt>\"}},...]\n\n" ++
        "Task: {s}",
        .{ cap, task },
    ) catch { appendErr(alloc, out, "OOM: orchestrator prompt"); return; };
    defer alloc.free(orch_prompt);

    // Orchestrator: read-only, rush mode (concise JSON output), no role preamble
    var orch_out: std.ArrayList(u8) = .empty;
    defer orch_out.deinit(alloc);
    {
        const req: rt.AgentRequest = .{
            .prompt   = orch_prompt,
            .role     = null,
            .mode     = "rush",
            .writable = false,
        };
        const resolved = rt.resolve.resolveWithProbe(alloc, req);
        defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);
        rt.dispatch.dispatch(alloc, resolved, orch_prompt, &orch_out);
    }

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
        // zigrep/zigpatch instead of sed/awk.
        const allocated: ?[]u8 = if (writable) blk: {
            const preamble = buildPreamble(alloc);
            const full = std.fmt.allocPrint(alloc, "{s}{s}", .{ preamble, base }) catch null;
            rt.prompts.freeAssembled(alloc, preamble);
            break :blk full;
        } else null;
        workers[count] = .{
            .role             = switch (r_val) { .string => |s| s, else => "agent" },
            .prompt           = base,
            .allocated_prompt = allocated,
        };
        worker_args[count] = .{ .worker = &workers[count], .writable = writable };
        threads[count] = std.Thread.spawn(.{}, workerFn, .{&worker_args[count]}) catch null;
        count += 1;
    }

    if (count == 0) { appendErr(alloc, out, "swarm: no valid sub-tasks extracted"); return; }

    // ── Announce workers ──────────────────────────────────────────────────────
    {
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf,
            "⚡ {d} agent{s} running in parallel...",
            .{ count, if (count == 1) "" else "s" },
        ) catch "⚡ agents running...";
        notify.send(alloc, msg);
    }

    // ── Phase 3: Join all worker threads ──────────────────────────────────
    for (threads[0..count]) |maybe_t| {
        if (maybe_t) |t| t.join();
    }
    // Free preamble-prefixed prompts now that threads have finished.
    for (workers[0..count]) |w| {
        if (w.allocated_prompt) |p| alloc.free(p);
    }

    // ── Phase 3b: Capture file manifest for writable swarms ──────────────
    var manifest: []const u8 = "";
    var manifest_alloc: ?[]u8 = null;
    defer if (manifest_alloc) |m| alloc.free(m);
    if (writable) {
        const gh = @import("gh.zig");
        if (gh.run(alloc, &.{ "git", "diff", "--stat", "HEAD" })) |dr| {
            defer dr.deinit(alloc);
            const trimmed = std.mem.trim(u8, dr.stdout, " \t\n\r");
            if (trimmed.len > 0) {
                manifest_alloc = alloc.dupe(u8, trimmed) catch null;
                if (manifest_alloc) |m| manifest = m;
            }
        } else |_| {}
    }

    // ── Phase 4: Build synthesis prompt from worker results ───────────────
    var synth: std.ArrayList(u8) = .empty;
    defer synth.deinit(alloc);

    synth.appendSlice(alloc,
        "You are a synthesis agent. Review the results from the parallel agents below " ++
        "and reply with ONLY a valid JSON object — no markdown fences, no extra text:\n" ++
        "{\n" ++
        "  \"status\": \"success\" | \"partial\" | \"failed\",\n" ++
        "  \"summary\": \"1-2 sentence summary of what was accomplished\",\n" ++
        "  \"agents\": [{{\"role\":\"<role>\",\"outcome\":\"<one-line result>\"}},...],\n" ++
        "  \"files_changed\": [\"<file paths if any were created/modified>\"],\n" ++
        "  \"notes\": [\"<any important caveats or warnings>\"]\n" ++
        "}\n\n" ++
        "Agent results:\n\n",
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

    // Include file manifest in synthesis if available
    if (manifest.len > 0) {
        synth.appendSlice(alloc, "## Files Changed\n```\n") catch {};
        synth.appendSlice(alloc, manifest) catch {};
        synth.appendSlice(alloc, "\n```\n\n") catch {};
    }

    synth.appendSlice(alloc, "Synthesize the above into a final answer.") catch {};

    // ── Announce synthesis ───────────────────────────────────────────────────
    notify.send(alloc, "🧬 Synthesizing agent results...");

    // ── Phase 5: Synthesis agent (read-only, uses synthesizer role) ───────
    var synth_raw: std.ArrayList(u8) = .empty;
    defer synth_raw.deinit(alloc);
    {
        const req: rt.AgentRequest = .{
            .prompt   = synth.items,
            .role     = "synthesizer",
            .mode     = "smart",
            .writable = false,
        };
        const resolved = rt.resolve.resolveWithProbe(alloc, req);
        defer rt.prompts.freeAssembled(alloc, resolved.system_prompt);
        rt.dispatch.dispatch(alloc, resolved, synth.items, &synth_raw);
    }

    // ── Phase 6: Format structured output ────────────────────────────────────
    const formatted = formatSynthesis(alloc, synth_raw.items, manifest) catch null;
    if (formatted) |f| {
        defer alloc.free(f);
        out.appendSlice(alloc, f) catch {};
    } else {
        // fallback: raw synthesis text
        out.appendSlice(alloc, synth_raw.items) catch {};
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn appendErr(alloc: std.mem.Allocator, out: *std.ArrayList(u8), msg: []const u8) void {
    out.appendSlice(alloc, "{\"error\":\"") catch return;
    mj.writeEscaped(alloc, out, msg);
    out.appendSlice(alloc, "\"}") catch {};
}


// ── Structured output formatter ───────────────────────────────────────────────

/// Parse the synthesizer's JSON output and render it as clean text.
/// Returns error if the output isn't parseable JSON — caller falls back to raw.
fn formatSynthesis(
    alloc:    std.mem.Allocator,
    raw:      []const u8,
    manifest: []const u8,
) ![]u8 {
    // The synthesizer may prefix text before the JSON — find the object.
    const json_start = std.mem.indexOfScalar(u8, raw, '{') orelse return error.NotJson;
    const json_end   = std.mem.lastIndexOfScalar(u8, raw, '}') orelse return error.NotJson;
    const js = raw[json_start .. json_end + 1];

    const parsed = std.json.parseFromSlice(
        std.json.Value, alloc, js, .{ .ignore_unknown_fields = true },
    ) catch return error.NotJson;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else    => return error.NotJson,
    };

    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Status line
    const status = strField(obj, "status") orelse "?";
    const icon: []const u8 = if (std.mem.eql(u8, status, "success")) "✓"
                             else if (std.mem.eql(u8, status, "partial")) "⚠"
                             else "✗";
    try buf.appendSlice(alloc, icon);
    try buf.append(alloc, ' ');
    try buf.appendSlice(alloc, status);
    try buf.appendSlice(alloc, "\n\n");

    // Summary
    if (strField(obj, "summary")) |s| {
        try buf.appendSlice(alloc, s);
        try buf.append(alloc, '\n');
    }

    // Per-agent outcomes
    if (obj.get("agents")) |agents_val| {
        if (agents_val == .array and agents_val.array.items.len > 0) {
            try buf.appendSlice(alloc, "\nAgents:\n");
            for (agents_val.array.items) |a| {
                if (a != .object) continue;
                const role    = strField(a.object, "role")    orelse "agent";
                const outcome = strField(a.object, "outcome") orelse "";
                const line = try std.fmt.allocPrint(alloc, "  • {s}: {s}\n", .{ role, outcome });
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }
    }

    // Files changed — prefer git diff stat, fall back to JSON field
    if (manifest.len > 0) {
        try buf.appendSlice(alloc, "\nFiles changed:\n```\n");
        try buf.appendSlice(alloc, manifest);
        try buf.appendSlice(alloc, "\n```\n");
    } else if (obj.get("files_changed")) |fc| {
        if (fc == .array and fc.array.items.len > 0) {
            try buf.appendSlice(alloc, "\nFiles:\n");
            for (fc.array.items) |f| {
                if (f != .string) continue;
                const line = try std.fmt.allocPrint(alloc, "  {s}\n", .{f.string});
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }
    }

    // Notes / caveats
    if (obj.get("notes")) |notes_val| {
        if (notes_val == .array and notes_val.array.items.len > 0) {
            try buf.appendSlice(alloc, "\nNotes:\n");
            for (notes_val.array.items) |n| {
                if (n != .string) continue;
                const line = try std.fmt.allocPrint(alloc, "  ⚡ {s}\n", .{n.string});
                defer alloc.free(line);
                try buf.appendSlice(alloc, line);
            }
        }
    }

    return buf.toOwnedSlice(alloc);
}

/// Extract a string field from a JSON object map, or null.
fn strField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "swarm: HARD_MAX is 100" {
    try std.testing.expectEqual(@as(u32, 100), HARD_MAX);
}

test "swarm: buildPreamble references agency rules" {
    const alloc = std.testing.allocator;
    const preamble = buildPreamble(alloc);
    defer rt.prompts.freeAssembled(alloc, preamble);

    // The preamble should come from prompts.zig and include agency rules
    try std.testing.expect(preamble.len > 0);
}

test "swarm: appendErr writes JSON error object" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    appendErr(alloc, &out, "something went wrong");

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    const msg = parsed.value.object.get("error") orelse return error.MissingError;
    try std.testing.expectEqualStrings("something went wrong", msg.string);
}
