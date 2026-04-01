const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
        }),
    });

    // ── mcp-zig dependency ──
    const mcp_dep = b.dependency("mcp_zig", .{});
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
    b.installArtifact(exe);

    // ── macOS ad-hoc codesign (prevents SIGKILL on unsigned binaries) ──
    if (b.graph.host.result.os.tag == .macos and target.result.os.tag == .macos) {
        const codesign = b.addSystemCommand(&.{ "codesign", "-f", "-s", "-" });
        codesign.addArtifactArg(exe);
        b.getInstallStep().dependOn(&codesign.step);
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run codedb daemon");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ──
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("mcp", mcp_dep.module("mcp"));

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // ── Library tests (verify the module root compiles) ──
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // ── Adversarial tests ──
    const adversarial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adversarial_tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(adversarial_tests).step);

    // ── Benchmarks ──
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench.root_module.addImport("mcp", mcp_dep.module("mcp"));
    if (b.args) |args| bench_run.addArgs(args);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);
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
    wasm.rdynamic = true;
    wasm.entry = .disabled;

    const wasm_step = b.step("wasm", "Build WASM module for Cloudflare Workers");
    wasm_step.dependOn(&b.addInstallArtifact(wasm, .{
        .dest_dir = .{ .override = .{ .custom = "../wasm" } },
    }).step);
}
