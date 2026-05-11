const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "macOS codesign identity. Defaults to ad-hoc signing ('-').",
    ) orelse "-";

    // ── Exposed module: importable as @import("codedb") ──
    const codedb_mod = b.addModule("codedb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── CLI executable ──
    const exe = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // ── mcp-zig dependency ──
    const mcp_dep = b.dependency("mcp_zig", .{});
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));

    // ── nanoregex dependency ──
    const nanoregex_dep = b.dependency("nanoregex", .{});
    exe.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));

    b.installArtifact(exe);


    // ── macOS codesign (ad-hoc by default; configurable for release builds) ──
    if (target.result.os.tag == .macos and builtin.os.tag == .macos) {
        const codesign = b.addSystemCommand(&.{ "codesign", "-f", "-s", codesign_identity });
        codesign.addArtifactArg(exe);
        b.getInstallStep().dependOn(&codesign.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run codedb daemon");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    tests.root_module.addImport("mcp", mcp_dep.module("mcp"));
    tests.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    if (test_filter) |f| {
        const filters = b.allocator.alloc([]const u8, 1) catch @panic("oom");
        filters[0] = f;
        tests.filters = filters;
    }

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(tests);
    test_step.dependOn(&tests_run.step);


    // ── Library tests (verify the module root compiles) ──
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // ── Adversarial tests ──
    const adversarial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adversarial_tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    adversarial_tests.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    test_step.dependOn(&b.addRunArtifact(adversarial_tests).step);


    // ── Benchmarks ──
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench.root_module.addImport("mcp", mcp_dep.module("mcp"));
    bench.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);

    // ── Benchmark (repo benchmark — indexing speed, query latency, recall) ──
    const benchmark = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    benchmark.root_module.addImport("mcp", mcp_dep.module("mcp"));
    benchmark.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    const benchmark_run = b.addRunArtifact(benchmark);
    if (b.args) |args| benchmark_run.addArgs(args);
    const benchmark_step = b.step("benchmark", "Run repo benchmark (use -- --root /path/to/repo)");
    benchmark_step.dependOn(&benchmark_run.step);

    // Make module available so dependents don't need to wire it up manually
    _ = codedb_mod;

    // ── WASM build (for Cloudflare Workers) ──
    const wasm = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm.zig"),
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = .ReleaseSmall,
        }),
    });
    wasm.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const wasm_step = b.step("wasm", "Build WASM module for Cloudflare Workers");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../wasm" } },
    }).step);
}
