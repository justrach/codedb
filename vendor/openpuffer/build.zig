const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Engine-only vendor adapter. HTTP, persistence, and CLI sources are
    // omitted; local hnsw hardening is documented in UPSTREAM.md.
    const lib_mod = b.addModule("openpuffer", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib_tests = b.addTest(.{ .root_module = lib_mod });
    const hnsw_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hnsw.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const vector_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vector.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Run engine-only OpenPuffer tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(hnsw_tests).step);
    test_step.dependOn(&b.addRunArtifact(vector_tests).step);
}
