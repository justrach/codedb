const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Version: defaults to build.zig.zon value; override with -Dversion=X.Y.Z at release
    const version = b.option([]const u8, "version", "Version string") orelse "0.0.25";
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    // mcp-zig: 131 KB MCP transport library, zero dependencies
    const mcp_dep = b.dependency("mcp_zig", .{});

    const exe = b.addExecutable(.{
        .name = "devswarm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_options);
    exe.root_module.addImport("mcp", mcp_dep.module("mcp"));
    b.installArtifact(exe);

    // zig build run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run devswarm server");
    run_step.dependOn(&run_cmd.step);

    // zig build test
    const test_filter = b.option([]const u8, "test-filter", "Filter tests by name substring");
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters     = if (test_filter) |f| &.{f} else &.{},
    });
    const run_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const run_protocol_tests = b.addRunArtifact(exe_tests);
    run_protocol_tests.addArgs(&.{ "--test-filter", "protocol" });
    const test_mcp_step = b.step("test-mcp", "Run MCP protocol regression tests");
    test_mcp_step.dependOn(&run_protocol_tests.step);
}
