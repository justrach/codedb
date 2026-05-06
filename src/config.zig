const std = @import("std");

/// User-tunable config loaded from .codedbrc files.
///
/// Resolution order (first match wins):
///   1. --config-file=<path>  (explicit)
///   2. $CWD/.codedbrc
///   3. <binary_dir>/.codedbrc
///
/// Format: one `key = value` per line. Blank lines and `#`-prefixed lines
/// are ignored. Unknown keys are silently ignored so upgrades don't break
/// older configs.
///
/// Addresses #101 (max_versions) and #102 (max_cached).
pub const Config = struct {
    /// Cap per-file version history in the Store. Default 100.
    max_versions: usize = 100,
    /// Cap on files kept in the Explorer's in-memory content cache. Default 1000.
    max_cached: u32 = 1000,

    pub const default: Config = .{};

    /// Parse a config body. Errors only on malformed integer values for
    /// known keys; unknown keys are ignored.
    pub fn parse(body: []const u8) !Config {
        var cfg: Config = .{};
        var lines = std.mem.splitScalar(u8, body, '\n');
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val = std.mem.trim(u8, line[eq + 1 ..], " \t");
            if (std.mem.eql(u8, key, "max_versions")) {
                cfg.max_versions = std.fmt.parseInt(usize, val, 10) catch return error.InvalidMaxVersions;
                if (cfg.max_versions == 0) return error.InvalidMaxVersions;
            } else if (std.mem.eql(u8, key, "max_cached")) {
                cfg.max_cached = std.fmt.parseInt(u32, val, 10) catch return error.InvalidMaxCached;
                if (cfg.max_cached == 0) return error.InvalidMaxCached;
            }
        }
        return cfg;
    }

    /// Load a config from a specific path. Returns the default config if the
    /// file doesn't exist; propagates parse errors.
    pub fn loadFromPath(io: std.Io, alloc: std.mem.Allocator, path: []const u8) !Config {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config.default,
            else => return err,
        };
        defer file.close(io);
        const size = try file.length(io);
        if (size > 64 * 1024) return error.ConfigTooLarge;
        const body = try alloc.alloc(u8, @intCast(size));
        defer alloc.free(body);
        const read = try file.readPositionalAll(io, body, 0);
        return try parse(body[0..read]);
    }

    /// Walk the resolution order and load the first config found.
    /// `explicit_path` is the value of --config-file (if passed, null otherwise).
    /// `binary_dir` is the absolute directory containing the running codedb binary.
    pub fn loadDefault(
        io: std.Io,
        alloc: std.mem.Allocator,
        explicit_path: ?[]const u8,
        binary_dir: ?[]const u8,
    ) !Config {
        if (explicit_path) |p| return try loadFromPath(io, alloc, p);

        // Step 2: $CWD/.codedbrc
        if (cwdConfigExists(io)) {
            return try loadFromPath(io, alloc, ".codedbrc");
        }

        // Step 3: <binary_dir>/.codedbrc
        if (binary_dir) |bd| {
            const path = try std.fmt.allocPrint(alloc, "{s}/.codedbrc", .{bd});
            defer alloc.free(path);
            return try loadFromPath(io, alloc, path);
        }

        return Config.default;
    }

    fn cwdConfigExists(io: std.Io) bool {
        const f = std.Io.Dir.cwd().openFile(io, ".codedbrc", .{}) catch return false;
        f.close(io);
        return true;
    }
};

// ── Tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "config: defaults" {
    const cfg = Config.default;
    try testing.expectEqual(@as(usize, 100), cfg.max_versions);
    try testing.expectEqual(@as(u32, 1000), cfg.max_cached);
}

test "config: parse single key" {
    const cfg = try Config.parse("max_versions = 42\n");
    try testing.expectEqual(@as(usize, 42), cfg.max_versions);
    try testing.expectEqual(@as(u32, 1000), cfg.max_cached);
}

test "config: parse both keys with comments and whitespace" {
    const cfg = try Config.parse(
        \\# codedb config
        \\
        \\max_versions = 200
        \\  max_cached   =   2048
        \\# trailing comment
        \\
    );
    try testing.expectEqual(@as(usize, 200), cfg.max_versions);
    try testing.expectEqual(@as(u32, 2048), cfg.max_cached);
}

test "config: unknown keys are ignored" {
    const cfg = try Config.parse("unknown_key = 99\nmax_versions = 5\n");
    try testing.expectEqual(@as(usize, 5), cfg.max_versions);
}

test "config: malformed value rejected" {
    try testing.expectError(error.InvalidMaxVersions, Config.parse("max_versions = not_a_number\n"));
    try testing.expectError(error.InvalidMaxVersions, Config.parse("max_versions = 0\n"));
    try testing.expectError(error.InvalidMaxCached, Config.parse("max_cached = 0\n"));
}
