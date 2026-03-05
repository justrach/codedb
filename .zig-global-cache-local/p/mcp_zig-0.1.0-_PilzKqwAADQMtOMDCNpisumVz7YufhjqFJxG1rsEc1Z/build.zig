const std = @import("std");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Library module (for consumers using mcp-zig as a dependency) ──────────
    _ = b.addModule("mcp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target   = target,
        .optimize = optimize,
    });

    // ── Standalone server executable ─────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "mcp-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // zig build run — start the server (useful for manual smoke-testing)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the MCP server");
    run_step.dependOn(&run_cmd.step);

    // ── Client example executable ────────────────────────────────────────────
    const client_exe = b.addExecutable(.{
        .name = "mcp-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/client_example.zig"),
            .target   = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(client_exe);

    // zig build run-client -- /path/to/server
    const run_client = b.addRunArtifact(client_exe);
    run_client.step.dependOn(b.getInstallStep());
    if (b.args) |a| for (a) |arg| run_client.addArg(arg);
    const run_client_step = b.step("run-client", "Run the MCP client example");
    run_client_step.dependOn(&run_client.step);
}
