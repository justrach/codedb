const std = @import("std");
const sty = @import("style.zig");

const Out = struct {
    file: std.fs.File,
    alloc: std.mem.Allocator,

    fn p(self: Out, comptime fmt: []const u8, args: anytype) void {
        const str = std.fmt.allocPrint(self.alloc, fmt, args) catch return;
        defer self.alloc.free(str);
        self.file.writeAll(str) catch {};
    }
};

const NukeStats = struct {
    killed_processes: usize = 0,
    snapshots_removed: usize = 0,
    integrations_removed: usize = 0,
    binaries_removed: usize = 0,
    removed_data_dir: bool = false,
};

pub fn run(stdout: std.fs.File, s: sty.Style, allocator: std.mem.Allocator) void {
    const out = Out{ .file = stdout, .alloc = allocator };
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
        out.p("{s}\xe2\x9c\x97{s} cannot determine HOME directory\n", .{ s.red, s.reset });
        std.process.exit(1);
    };
    defer allocator.free(home);

    var stats = NukeStats{};

    const self_pid = std.c.getpid();
    stats.killed_processes = killOtherCodedbProcesses(allocator, self_pid);
    stats.integrations_removed = deregisterInstalledIntegrations(allocator, home);
    stats.snapshots_removed = removeRegisteredSnapshots(allocator, home);

    if (deleteFileIfExists("codedb.snapshot")) {
        stats.snapshots_removed += 1;
    }

    stats.binaries_removed = removeInstalledBinaries(allocator, home);

    const codedb_dir = std.fmt.allocPrint(allocator, "{s}/.codedb", .{home}) catch {
        out.p("{s}\xe2\x9c\x97{s} failed to allocate uninstall paths\n", .{ s.red, s.reset });
        std.process.exit(1);
    };
    defer allocator.free(codedb_dir);

    if (std.fs.cwd().openDir(codedb_dir, .{})) |opened_dir| {
        var dir = opened_dir;
        dir.close();
        std.fs.cwd().deleteTree(codedb_dir) catch |err| {
            out.p("{s}\xe2\x9c\x97{s} failed to remove {s}: {}\n", .{ s.red, s.reset, codedb_dir, err });
            return;
        };
        stats.removed_data_dir = true;
    } else |_| {}

    out.p("{s}\xe2\x9c\x93{s} nuked codedb installation\n", .{ s.green, s.reset });
    out.p("  removed data dir      {s}{s}{s}\n", .{ s.dim, codedb_dir, s.reset });
    out.p("  removed snapshots     {d}\n", .{stats.snapshots_removed});
    out.p("  deregistered tools    {d}\n", .{stats.integrations_removed});
    out.p("  removed binaries      {d}\n", .{stats.binaries_removed});
    out.p("  terminated processes  {d}\n", .{stats.killed_processes});
    out.p("\n  to reinstall: {s}curl -fsSL https://codedb.codegraff.com/install.sh | bash{s}\n", .{ s.cyan, s.reset });
}

fn killOtherCodedbProcesses(allocator: std.mem.Allocator, self_pid: std.c.pid_t) usize {
    var killed: usize = 0;
    var pid_buf: [32]u8 = undefined;
    const self_pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{self_pid}) catch "0";

    const pgrep_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "pgrep", "-f", "codedb.*(serve|mcp)" },
        .max_output_bytes = 4096,
    }) catch return 0;
    defer allocator.free(pgrep_result.stdout);
    defer allocator.free(pgrep_result.stderr);

    var line_iter = std.mem.splitScalar(u8, pgrep_result.stdout, '\n');
    while (line_iter.next()) |pid_line| {
        const trimmed = std.mem.trim(u8, pid_line, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (std.mem.eql(u8, trimmed, self_pid_str)) continue;
        const kill_result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "kill", trimmed },
            .max_output_bytes = 256,
        }) catch continue;
        defer allocator.free(kill_result.stdout);
        defer allocator.free(kill_result.stderr);
        if (kill_result.term == .Exited and kill_result.term.Exited == 0) {
            killed += 1;
        }
    }

    return killed;
}

fn removeRegisteredSnapshots(allocator: std.mem.Allocator, home: []const u8) usize {
    var removed: usize = 0;
    const projects_dir = std.fmt.allocPrint(allocator, "{s}/.codedb/projects", .{home}) catch return 0;
    defer allocator.free(projects_dir);

    var dir = std.fs.cwd().openDir(projects_dir, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const proj_file = std.fmt.allocPrint(allocator, "{s}/{s}/project.txt", .{ projects_dir, entry.name }) catch continue;
        defer allocator.free(proj_file);
        const proj_root = std.fs.cwd().readFileAlloc(allocator, proj_file, 4096) catch continue;
        defer allocator.free(proj_root);

        const trimmed_root = std.mem.trim(u8, proj_root, " \t\r\n");
        if (trimmed_root.len == 0) continue;

        const snap = std.fmt.allocPrint(allocator, "{s}/codedb.snapshot", .{trimmed_root}) catch continue;
        defer allocator.free(snap);
        if (deleteFileIfExists(snap)) removed += 1;
    }

    return removed;
}

fn deregisterInstalledIntegrations(allocator: std.mem.Allocator, home: []const u8) usize {
    var removed: usize = 0;

    const claude_config = std.fmt.allocPrint(allocator, "{s}/.claude.json", .{home}) catch return removed;
    defer allocator.free(claude_config);
    if (deregisterJsonIntegrationFile(allocator, claude_config) catch false) removed += 1;

    const gemini_config = std.fmt.allocPrint(allocator, "{s}/.gemini/settings.json", .{home}) catch return removed;
    defer allocator.free(gemini_config);
    if (deregisterJsonIntegrationFile(allocator, gemini_config) catch false) removed += 1;

    const cursor_config = std.fmt.allocPrint(allocator, "{s}/.cursor/mcp.json", .{home}) catch return removed;
    defer allocator.free(cursor_config);
    if (deregisterJsonIntegrationFile(allocator, cursor_config) catch false) removed += 1;

    const codex_config = std.fmt.allocPrint(allocator, "{s}/.codex/config.toml", .{home}) catch return removed;
    defer allocator.free(codex_config);
    if (deregisterCodexIntegrationFile(allocator, codex_config) catch false) removed += 1;

    return removed;
}

fn removeInstalledBinaries(allocator: std.mem.Allocator, home: []const u8) usize {
    var removed: usize = 0;

    const self_exe = std.fs.selfExePathAlloc(allocator) catch null;
    defer if (self_exe) |path| allocator.free(path);

    if (self_exe) |path| {
        if (deleteFileIfExists(path)) removed += 1;
    }

    const home_bin = std.fmt.allocPrint(allocator, "{s}/bin/codedb", .{home}) catch return removed;
    defer allocator.free(home_bin);
    if (self_exe == null or !std.mem.eql(u8, self_exe.?, home_bin)) {
        if (deleteFileIfExists(home_bin)) removed += 1;
    }

    const home_bin_exe = std.fmt.allocPrint(allocator, "{s}/bin/codedb.exe", .{home}) catch return removed;
    defer allocator.free(home_bin_exe);
    if ((self_exe == null or !std.mem.eql(u8, self_exe.?, home_bin_exe)) and !std.mem.eql(u8, home_bin, home_bin_exe)) {
        if (deleteFileIfExists(home_bin_exe)) removed += 1;
    }

    return removed;
}

fn deleteFileIfExists(path: []const u8) bool {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return false,
    };
    return true;
}

fn readOptionalConfigFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return content;
}

pub fn deregisterJsonIntegrationFile(allocator: std.mem.Allocator, path: []const u8) !bool {
    const content = (try readOptionalConfigFile(allocator, path)) orelse return false;
    defer allocator.free(content);

    const rewritten = try removeJsonMcpServerEntry(allocator, content, "codedb") orelse return false;
    defer allocator.free(rewritten);
    try rewriteConfigFile(path, rewritten);
    return true;
}

pub fn deregisterCodexIntegrationFile(allocator: std.mem.Allocator, path: []const u8) !bool {
    const content = (try readOptionalConfigFile(allocator, path)) orelse return false;
    defer allocator.free(content);

    const rewritten = try removeCodexMcpServerBlock(allocator, content, "codedb") orelse return false;
    defer allocator.free(rewritten);
    try rewriteConfigFile(path, rewritten);
    return true;
}

fn rewriteConfigFile(path: []const u8, content: []const u8) !void {
    if (std.mem.trim(u8, content, " \t\r\n").len == 0) {
        std.fs.cwd().deleteFile(path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

pub fn removeJsonMcpServerEntry(allocator: std.mem.Allocator, content: []const u8, server_name: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    const servers_value = parsed.value.object.getPtr("mcpServers") orelse return null;
    if (servers_value.* != .object) return null;
    if (!servers_value.object.swapRemove(server_name)) return null;
    if (servers_value.object.count() == 0) {
        _ = parsed.value.object.swapRemove("mcpServers");
    }

    const json = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{ .whitespace = .indent_2 });
    errdefer allocator.free(json);

    var out: std.ArrayList(u8) = .{};
    defer out.deinit(allocator);
    try out.appendSlice(allocator, json);
    try out.append(allocator, '\n');
    allocator.free(json);
    return try out.toOwnedSlice(allocator);
}

pub fn removeCodexMcpServerBlock(allocator: std.mem.Allocator, content: []const u8, server_name: []const u8) !?[]u8 {
    const header = try std.fmt.allocPrint(allocator, "[mcp_servers.{s}]", .{server_name});
    defer allocator.free(header);

    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = trimTomlLineForHeader(content[line_start..line_end]);
        if (std.mem.eql(u8, line, header)) {
            var remove_start = line_start;
            if (remove_start > 0) {
                var prev_start = remove_start - 1;
                while (prev_start > 0 and content[prev_start - 1] != '\n') : (prev_start -= 1) {}
                const prev_line = std.mem.trim(u8, content[prev_start .. remove_start - 1], " \t\r");
                if (prev_line.len == 0) {
                    remove_start = prev_start;
                }
            }

            var remove_end: usize = if (line_end < content.len) line_end + 1 else content.len;
            while (remove_end < content.len) {
                const next_end = std.mem.indexOfScalarPos(u8, content, remove_end, '\n') orelse content.len;
                const next_line = trimTomlLineForHeader(content[remove_end..next_end]);
                if (next_line.len > 0 and next_line[0] == '[') break;
                remove_end = if (next_end < content.len) next_end + 1 else content.len;
            }

            var out: std.ArrayList(u8) = .{};
            defer out.deinit(allocator);
            try out.appendSlice(allocator, content[0..remove_start]);
            try out.appendSlice(allocator, content[remove_end..]);
            return try out.toOwnedSlice(allocator);
        }
        line_start = if (line_end < content.len) line_end + 1 else content.len;
    }

    return null;
}

fn trimTomlLineForHeader(line: []const u8) []const u8 {
    const no_cr = std.mem.trimRight(u8, line, "\r");
    const trimmed = std.mem.trim(u8, no_cr, " \t");
    const comment_start = std.mem.indexOfScalar(u8, trimmed, '#') orelse return trimmed;
    return std.mem.trimRight(u8, trimmed[0..comment_start], " \t");
}
