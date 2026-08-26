const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const codesign_identity = b.option(
        []const u8,
        "codesign-identity",
        "macOS codesign identity. Disabled by default and skipped for x86_64-macos.",
    );

    // ── Exposed module: importable as @import("codedb") ──
    const codedb_mod = b.addModule("codedb", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── CLI executable ──
    // In ReleaseFast/Small, strip debug info to shrink the binary (~10%)
    // and the RSS at runtime (smaller __TEXT footprint = fewer pages
    // resident under load). Debug/ReleaseSafe keep symbols for stack traces.
    const strip_debug = optimize == .ReleaseFast or optimize == .ReleaseSmall;
    const exe = b.addExecutable(.{
        .name = "codedb",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .strip = strip_debug,
        }),
    });

    // #618/#504: reserve Mach-O header padding so codesign can append its
    // LC_CODE_SIGNATURE load command without overwriting __text. The pinned
    // toolchain leaves only 8 bytes of slack on x86_64-macos (fixed upstream
    // on 0.17 master); 0x1000 matches the verified workaround.
    if ((target.query.os_tag orelse target.result.os.tag) == .macos) {
        exe.headerpad_size = 0x1000;
    }

    // ── nanoregex dependency ──
    const nanoregex_dep = b.dependency("nanoregex", .{});
    exe.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));

    // ── OpenPuffer local ANN dependency ──
    // Only the pure-Zig library root is linked. Server, S3, Gemini, and
    // turbopuffer client modules remain outside codedb's graph.
    const openpuffer_dep = b.dependency("openpuffer", .{ .target = target, .optimize = optimize });
    const openpuffer_mod = openpuffer_dep.module("openpuffer");
    exe.root_module.addImport("openpuffer", openpuffer_mod);
    codedb_mod.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    codedb_mod.addImport("openpuffer", openpuffer_mod);

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    // #618: every macOS slice signs again. The x86_64 codesign crash (#504)
    // was missing load-command headerpad — codesign's appended
    // LC_CODE_SIGNATURE clobbered __text; the exe now reserves headerpad.
    if (codesign_identity) |identity| {
        const target_os = target.query.os_tag orelse target.result.os.tag;
        if (target_os == .macos and builtin.os.tag == .macos) {
            const codesign = b.addSystemCommand(&.{
                "codesign",
                "-f",
                "--options",
                "runtime",
                "--timestamp",
                "-s",
                identity,
            });
            codesign.addFileArg(exe.getEmittedBin());
            install_exe.step.dependOn(&codesign.step);
        }
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run codedb daemon");
    run_step.dependOn(&run_cmd.step);

    // ── Tests (split into independent binaries for faster compilation) ──
    const test_filter = b.option([]const u8, "test-filter", "Only run tests whose name contains this substring");
    const test_step = b.step("test", "Run all tests");

    const test_files = [_]struct { name: []const u8, path: []const u8, needs_nanoregex: bool }{
        .{ .name = "test-core", .path = "src/test_core.zig", .needs_nanoregex = false },
        .{ .name = "test-explore", .path = "src/test_explore.zig", .needs_nanoregex = true },
        .{ .name = "test-index", .path = "src/test_index.zig", .needs_nanoregex = true },
        .{ .name = "test-parser", .path = "src/test_parser.zig", .needs_nanoregex = true },
        .{ .name = "test-search", .path = "src/test_search.zig", .needs_nanoregex = true },
        .{ .name = "test-snapshot", .path = "src/test_snapshot.zig", .needs_nanoregex = true },
        .{ .name = "test-mcp", .path = "src/test_mcp.zig", .needs_nanoregex = true },
        .{ .name = "test-query", .path = "src/test_query.zig", .needs_nanoregex = true },
        .{ .name = "test-list-dir", .path = "src/test_list_dir.zig", .needs_nanoregex = false },
        .{ .name = "test-semantic", .path = "src/test_semantic.zig", .needs_nanoregex = false },
        .{ .name = "test-ann", .path = "src/test_ann.zig", .needs_nanoregex = false },
        .{ .name = "test-bench", .path = "src/test_bench.zig", .needs_nanoregex = true },
    };

    for (test_files) |tf| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tf.path),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        if (tf.needs_nanoregex) t.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
        t.root_module.addImport("openpuffer", openpuffer_mod);
        if (test_filter) |f| {
            const filters = b.allocator.alloc([]const u8, 1) catch @panic("oom");
            filters[0] = f;
            t.filters = filters;
        }
        const run = b.addRunArtifact(t);
        test_step.dependOn(&run.step);

        const individual_step = b.step(tf.name, b.fmt("Run {s}", .{tf.name}));
        individual_step.dependOn(&run.step);
    }

    // ── Library tests (verify the module root compiles) ──
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib_tests.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    lib_tests.root_module.addImport("openpuffer", openpuffer_mod);
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
    adversarial_tests.root_module.addImport("openpuffer", openpuffer_mod);
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
    bench.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    bench.root_module.addImport("openpuffer", openpuffer_mod);
    bench_run.addPassthruArgs();
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);

    // ── Edge-case benchmarks (synthetic pathological corpus) ──
    const bench_edge = b.addExecutable(.{
        .name = "bench-edge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_edge.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    bench_edge.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    bench_edge.root_module.addImport("openpuffer", openpuffer_mod);
    const bench_edge_run = b.addRunArtifact(bench_edge);
    bench_edge_run.addPassthruArgs();
    const bench_edge_step = b.step("bench-edge", "Run edge-case benchmarks (synthetic pathological corpus)");
    bench_edge_step.dependOn(&bench_edge_run.step);

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
    benchmark.root_module.addImport("nanoregex", nanoregex_dep.module("nanoregex"));
    benchmark.root_module.addImport("openpuffer", openpuffer_mod);
    const benchmark_run = b.addRunArtifact(benchmark);
    benchmark_run.addPassthruArgs();
    const benchmark_step = b.step("benchmark", "Run repo benchmark (use -- --root /path/to/repo)");
    benchmark_step.dependOn(&benchmark_run.step);

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
