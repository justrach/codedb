//! Parity-test probe CLI.
//!
//! Wire shape:  nanoregex_probe <pattern> <haystack> [flags]
//! Flags string (3rd argv) is any concatenation of `i`/`m`/`s` matching
//! Python re's IGNORECASE / MULTILINE / DOTALL — same encoding used by
//! tests/parity/run.sh.
//!
//! Output: one match per line as `start..end\tmatched_bytes`. Bytes are
//! emitted raw (no escaping) so the harness can diff byte-for-byte against
//! `re.finditer` output formatted the same way.
//!
//! Stdio is via extern libc `write`: Zig 0.16 removed the synchronous
//! stdlib wrappers we used to rely on, and nanoregex links libc anyway.

const std = @import("std");
const nanoregex = @import("nanoregex");

extern "c" fn write(fd: c_int, ptr: [*]const u8, len: usize) isize;

fn writeAll(fd: c_int, data: []const u8) void {
    var rem = data;
    while (rem.len > 0) {
        const n = write(fd, rem.ptr, rem.len);
        if (n <= 0) return;
        rem = rem[@intCast(n)..];
    }
}

fn parseFlags(s: []const u8) nanoregex.Flags {
    var f: nanoregex.Flags = .{};
    for (s) |c| switch (c) {
        'i' => f.case_insensitive = true,
        'm' => f.multiline = true,
        's' => f.dot_all = true,
        else => {},
    };
    return f;
}

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var args_list: std.ArrayList([]const u8) = .empty;
    defer args_list.deinit(alloc);
    var args_iter = init.minimal.args.iterate();
    while (args_iter.next()) |arg| try args_list.append(alloc, arg);
    const args = args_list.items;

    if (args.len < 2) {
        writeAll(2, "usage: nanoregex_probe <pattern> [<haystack>] [<flags>]\n");
        std.process.exit(2);
    }
    const pattern = args[1];
    const haystack: []const u8 = if (args.len >= 3) args[2] else "";
    const flags = parseFlags(if (args.len >= 4) args[3] else "");

    var r = nanoregex.Regex.compileWithFlags(alloc, pattern, flags) catch |err| {
        var tmp: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&tmp, "PARSE_ERROR: {s}\n", .{@errorName(err)}) catch "PARSE_ERROR\n";
        writeAll(1, msg);
        // Exit 0 — the harness checks output content, not exit code, so
        // PARSE_ERROR on both sides should match cleanly.
        std.process.exit(0);
    };
    defer r.deinit();

    const matches = r.findAll(alloc, haystack) catch {
        writeAll(2, "ENGINE_ERROR\n");
        std.process.exit(1);
    };
    defer {
        for (matches) |*m| @constCast(m).deinit(alloc);
        alloc.free(matches);
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    var line_buf: [256]u8 = undefined;
    for (matches) |m| {
        const header = std.fmt.bufPrint(&line_buf, "{d}..{d}\t", .{ m.span.start, m.span.end }) catch continue;
        try buf.appendSlice(alloc, header);
        try buf.appendSlice(alloc, haystack[m.span.start..m.span.end]);
        try buf.append(alloc, '\n');
    }
    writeAll(1, buf.items);
}
