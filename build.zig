const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // mcp-zig: 131 KB MCP transport library, zero dependencies
    const mcp_dep = b.dependency("mcp_zig", .{});

    const exe = b.addExecutable(.{
        .name = "gitagent-mcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });
    // mcp module available via @import("mcp") in all source files
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
    b.installArtifact(exe);

    // zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run gitagent-mcp server");
    run_step.dependOn(&run_cmd.step);

    // zig build test
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const run_protocol_tests = b.addRunArtifact(exe_tests);
    run_protocol_tests.addArgs(&.{ "--test-filter", "protocol" });
    const test_mcp_step = b.step("test-mcp", "Run MCP protocol regression tests");
    test_mcp_step.dependOn(&run_protocol_tests.step);
}
