//! `codedb install-hooks` — runs the packaged hook installer that ships next to
//! the binary as `<prefix>/share/codedb/install-hooks.sh` (see build.zig).
//!
//! Hook configuration is kept out of the binary on purpose: hooks execute
//! arbitrary commands with the user's permissions, so the exact script that
//! runs stays readable on disk and can be inspected before it is invoked.
const std = @import("std");
const cio = @import("cio.zig");
const sty = @import("style.zig");
const Out = @import("out.zig").Out;

/// Resolve `<prefix>/share/codedb/install-hooks.sh` from the running executable
/// (`<prefix>/bin/codedb`). Works for the curl installer (`~/bin` → `~/share`),
/// `zig build install`, and nix store paths alike.
pub fn packageScriptPath(allocator: std.mem.Allocator, self_exe: []const u8) ![]u8 {
    const bin_dir = std.fs.path.dirname(self_exe) orelse return error.NoExecutableDir;
    return std.fs.path.join(allocator, &.{ bin_dir, "..", "share", "codedb", "install-hooks.sh" });
}

pub fn run(io: std.Io, out: *Out, s: sty.Style, allocator: std.mem.Allocator, stdout: cio.File) void {
    const self_exe = std.process.executablePathAlloc(io, allocator) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve codedb executable: {s}\n", .{ s.red, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    defer allocator.free(self_exe);

    const script_path = packageScriptPath(allocator, self_exe) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} cannot resolve install-hooks script path: {s}\n", .{ s.red, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    defer allocator.free(script_path);

    std.Io.Dir.cwd().access(io, script_path, .{}) catch {
        out.p("{s}\xe2\x9c\x97{s} install-hooks script not found: {s}{s}{s}\n", .{ s.red, s.reset, s.bold, script_path, s.reset });
        out.p("  Reinstall codedb from a package that includes {s}share/codedb/install-hooks.sh{s}.\n", .{ s.bold, s.reset });
        out.exitWithFlush(1);
    };

    const argv = [_][]const u8{ "bash", script_path, "--codedb-bin", self_exe };
    const result = cio.runCapture(.{
        .allocator = allocator,
        .argv = &argv,
        .max_output_bytes = 4 * 1024 * 1024,
    }) catch |err| {
        out.p("{s}\xe2\x9c\x97{s} failed to run install-hooks script: {s}\n", .{ s.red, s.reset, @errorName(err) });
        out.exitWithFlush(1);
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    out.flush();
    if (result.stdout.len > 0) stdout.writeAll(result.stdout) catch {};
    if (result.stderr.len > 0) cio.File.stderr().writeAll(result.stderr) catch {};

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) std.process.exit(code);
        },
        .Signal => |signal| {
            out.p("{s}\xe2\x9c\x97{s} install-hooks script terminated by signal {d}\n", .{ s.red, s.reset, signal });
            out.exitWithFlush(1);
        },
        .Stopped => |signal| {
            out.p("{s}\xe2\x9c\x97{s} install-hooks script stopped by signal {d}\n", .{ s.red, s.reset, signal });
            out.exitWithFlush(1);
        },
        .Unknown => |status| {
            out.p("{s}\xe2\x9c\x97{s} install-hooks script exited with unknown status {d}\n", .{ s.red, s.reset, status });
            out.exitWithFlush(1);
        },
    }
}
