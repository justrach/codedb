const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Pass-through filter that the user can layer on top of any named step
    // to narrow further:   zig build test-dfa -Dtest-filter='alternation'
    const user_filter = b.option([]const u8, "test-filter", "Narrow test name filter (substring)");

    const nanoregex_mod = b.addModule("nanoregex", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const probe = b.addExecutable(.{
        .name = "nanoregex_probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/probe.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "nanoregex", .module = nanoregex_mod } },
        }),
    });
    b.installArtifact(probe);

    const bench = b.addExecutable(.{
        .name = "nanoregex_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
            .imports = &.{ .{ .name = "nanoregex", .module = nanoregex_mod } },
        }),
    });
    b.installArtifact(bench);

    // ─────────────────────────────────────────────────────────────────
    // Per-module test steps.
    //
    // The user's preferred iteration loop is to run ONE narrow named step
    // at a time, so each module has its own step that compiles a small
    // test binary scoped to that source file (+ its imports). There is
    // NO aggregate `test` step — `test-all` is explicit and opt-in.
    //
    // To narrow further:  zig build test-dfa -Dtest-filter='alternation'
    // ─────────────────────────────────────────────────────────────────

    _ = addTestStep(b, "test-ast", "src/ast.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-parser", "src/parser.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-nfa", "src/nfa.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-exec", "src/exec.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-prefilter", "src/prefilter.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-dfa", "src/dfa.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-minterm", "src/minterm.zig", &.{}, user_filter, target, optimize);
    _ = addTestStep(b, "test-root", "src/root.zig", &.{}, user_filter, target, optimize);

    // ── Pre-baked filtered shortcuts ──
    // Each named step runs only tests whose name contains one of the
    // listed substrings (Zig's --test-filter is OR-of-substrings).
    // Compile is cached and shared with the parent module's step.

    _ = addTestStep(b, "test-parser-core",  "src/parser.zig", &.{ "literal", "concat", "alternation" }, user_filter, target, optimize);
    _ = addTestStep(b, "test-parser-quant", "src/parser.zig", &.{ "quantifier" },                       user_filter, target, optimize);
    _ = addTestStep(b, "test-parser-class", "src/parser.zig", &.{ "class" },                            user_filter, target, optimize);
    _ = addTestStep(b, "test-parser-group", "src/parser.zig", &.{ "group" },                            user_filter, target, optimize);
    _ = addTestStep(b, "test-parser-error", "src/parser.zig", &.{ "errors" },                           user_filter, target, optimize);

    _ = addTestStep(b, "test-nfa-basic", "src/nfa.zig", &.{ "literal", "concat" },                       user_filter, target, optimize);
    _ = addTestStep(b, "test-nfa-quant", "src/nfa.zig", &.{ "star", "plus", "question", "counted" },    user_filter, target, optimize);
    _ = addTestStep(b, "test-nfa-alt",   "src/nfa.zig", &.{ "alt" },                                     user_filter, target, optimize);
    _ = addTestStep(b, "test-nfa-group", "src/nfa.zig", &.{ "group" },                                   user_filter, target, optimize);

    _ = addTestStep(b, "test-exec-basic",  "src/exec.zig", &.{ "literal", "no match" },                       user_filter, target, optimize);
    _ = addTestStep(b, "test-exec-quant",  "src/exec.zig", &.{ "greedy", "lazy", "counted", "optional" },     user_filter, target, optimize);
    _ = addTestStep(b, "test-exec-class",  "src/exec.zig", &.{ "class", "digit", "word" },                    user_filter, target, optimize);
    _ = addTestStep(b, "test-exec-group",  "src/exec.zig", &.{ "group" },                                     user_filter, target, optimize);
    _ = addTestStep(b, "test-exec-anchor", "src/exec.zig", &.{ "anchor", "boundary" },                        user_filter, target, optimize);

    _ = addTestStep(b, "test-dfa-rejects", "src/dfa.zig", &.{ "rejects" }, user_filter, target, optimize);
    _ = addTestStep(b, "test-dfa-match",   "src/dfa.zig", &.{ "literal", "plus", "alt", "class", "wildcard", "longest" }, user_filter, target, optimize);

    _ = addTestStep(b, "test-prefilter-full",     "src/prefilter.zig", &.{ "full literal" },     user_filter, target, optimize);
    _ = addTestStep(b, "test-prefilter-required", "src/prefilter.zig", &.{ "required literal" }, user_filter, target, optimize);

    // ─────────────────────────────────────────────────────────────────
    // Aggregate sweeps — explicit, opt-in. Run these AFTER you're done
    // iterating, not in the inner loop.
    // ─────────────────────────────────────────────────────────────────

    const ast_all      = addTestStep(b, "_test-ast-all",      "src/ast.zig",      &.{}, user_filter, target, optimize);
    const parser_all   = addTestStep(b, "_test-parser-all",   "src/parser.zig",   &.{}, user_filter, target, optimize);
    const nfa_all      = addTestStep(b, "_test-nfa-all",      "src/nfa.zig",      &.{}, user_filter, target, optimize);
    const exec_all     = addTestStep(b, "_test-exec-all",     "src/exec.zig",     &.{}, user_filter, target, optimize);
    const prefilter_all = addTestStep(b, "_test-prefilter-all", "src/prefilter.zig", &.{}, user_filter, target, optimize);
    const dfa_all      = addTestStep(b, "_test-dfa-all",      "src/dfa.zig",      &.{}, user_filter, target, optimize);
    const root_all     = addTestStep(b, "_test-root-all",     "src/root.zig",     &.{}, user_filter, target, optimize);

    const test_all = b.step("test-all", "Run ALL unit tests across every module (slow — use named steps in the inner loop)");
    test_all.dependOn(ast_all);
    test_all.dependOn(parser_all);
    test_all.dependOn(nfa_all);
    test_all.dependOn(exec_all);
    test_all.dependOn(prefilter_all);
    test_all.dependOn(dfa_all);
    test_all.dependOn(root_all);

    // ── Parity vs Python re (separate; never auto-runs) ──
    const parity_cmd = b.addSystemCommand(&.{"bash"});
    parity_cmd.addFileArg(b.path("tests/parity/run.sh"));
    parity_cmd.addFileArg(probe.getEmittedBin());
    parity_cmd.addDirectoryArg(b.path("tests/parity/fixtures"));
    const parity_step = b.step("parity", "Run Python-re parity tests (separate; opt-in)");
    parity_step.dependOn(&parity_cmd.step);
}

/// Build one focused test step. `filters` is OR'd substring matching
/// (test runs iff its name contains at least one of the filters, or all
/// pass when the list is empty). The user-level -Dtest-filter is appended
/// so a named step can be narrowed further from the command line.
fn addTestStep(
    b: *std.Build,
    step_name: []const u8,
    root_path: []const u8,
    base_filters: []const []const u8,
    user_filter: ?[]const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step {
    var filter_list = std.ArrayList([]const u8).empty;
    filter_list.appendSlice(b.allocator, base_filters) catch @panic("OOM");
    if (user_filter) |f| filter_list.append(b.allocator, f) catch @panic("OOM");

    const test_mod = b.createModule(.{
        .root_source_file = b.path(root_path),
        .target = target,
        .optimize = optimize,
    });
    const test_exe = b.addTest(.{
        .root_module = test_mod,
        .filters = filter_list.toOwnedSlice(b.allocator) catch @panic("OOM"),
    });
    const run_step = b.addRunArtifact(test_exe);
    const step = b.step(step_name, b.fmt("Run tests in {s}", .{root_path}));
    step.dependOn(&run_step.step);
    return step;
}
