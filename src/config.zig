// config.zig — Load .devswarm/config.toml into a Config struct.
//
// Minimal TOML parser — handles flat [section] and [section.sub] tables
// with string and integer values.  Designed only for the devswarm config
// format; it does NOT attempt to be a general-purpose TOML library.
//
// Config is loaded lazily by resolveWithProbe() and passed into resolve().

const std = @import("std");

// ── Public types ──────────────────────────────────────────────────────────────

/// Per-role overrides from [agents.<role>] sections.
pub const RoleConfig = struct {
    model:     ?[]const u8 = null,  // model override (haiku | sonnet | opus | full ID)
    backend:   ?[]const u8 = null,  // backend override (claude | codex | amp)
    sandbox:   ?[]const u8 = null,  // sandbox hint (read-only | write)
    max_turns: ?u32        = null,
};

/// Parsed representation of .devswarm/config.toml.
pub const Config = struct {
    /// [provider] primary = "claude" | "codex" | "amp" | "auto"
    primary:       ?[]const u8 = null,
    /// [provider] claude_default = "sonnet" | "opus" | full model ID
    claude_default: ?[]const u8 = null,
    /// [provider] codex_default = "codex-mini-latest" | ...
    codex_default:  ?[]const u8 = null,
    /// [agents.<role>] sections, keyed by role name (owned strings)
    roles: std.StringHashMap(RoleConfig),

    pub fn deinit(self: *Config, alloc: std.mem.Allocator) void {
        if (self.primary)        |p| alloc.free(p);
        if (self.claude_default) |d| alloc.free(d);
        if (self.codex_default)  |d| alloc.free(d);
        var it = self.roles.iterator();
        while (it.next()) |e| {
            alloc.free(e.key_ptr.*);
            const rc = e.value_ptr;
            if (rc.model)   |v| alloc.free(v);
            if (rc.backend) |v| alloc.free(v);
            if (rc.sandbox) |v| alloc.free(v);
        }
        self.roles.deinit();
    }
};

// ── Public API ────────────────────────────────────────────────────────────────

/// Load config from a specific path.  Returns error on I/O or OOM.
pub fn load(alloc: std.mem.Allocator, path: []const u8) !Config {
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 256 * 1024);
    defer alloc.free(text);
    return parse(alloc, text);
}

/// Load config from the default per-repo path (.devswarm/config.toml).
/// Returns null (not an error) if the file doesn't exist.
pub fn loadDefault(alloc: std.mem.Allocator) ?Config {
    return load(alloc, ".devswarm/config.toml") catch null;
}

// ── Parser ────────────────────────────────────────────────────────────────────

fn parse(alloc: std.mem.Allocator, text: []const u8) !Config {
    var cfg = Config{ .roles = std.StringHashMap(RoleConfig).init(alloc) };
    errdefer cfg.deinit(alloc);

    // current_section tracks the active [section] header.
    // We only allocate it when it's non-empty.
    var section: []const u8 = "";
    var section_buf: [256]u8 = undefined;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // Skip blank lines and comments
        if (line.len == 0 or line[0] == '#') continue;

        // Section header: [provider], [agents.finder], etc.
        if (line[0] == '[') {
            const close = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const name = std.mem.trim(u8, line[1..close], " \t");
            if (name.len > 0 and name.len < section_buf.len) {
                @memcpy(section_buf[0..name.len], name);
                section = section_buf[0..name.len];
            }
            continue;
        }

        // Key = value
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key   = std.mem.trim(u8, line[0..eq],    " \t");
        const raw_v = std.mem.trim(u8, line[eq + 1..], " \t");
        const val   = stripQuotes(raw_v);

        try applyKV(alloc, &cfg, section, key, val);
    }

    return cfg;
}

fn applyKV(
    alloc:   std.mem.Allocator,
    cfg:     *Config,
    section: []const u8,
    key:     []const u8,
    val:     []const u8,
) !void {
    if (std.mem.eql(u8, section, "provider")) {
        if (std.mem.eql(u8, key, "primary")) {
            if (cfg.primary) |old| alloc.free(old);
            cfg.primary = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "claude_default")) {
            if (cfg.claude_default) |old| alloc.free(old);
            cfg.claude_default = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "codex_default")) {
            if (cfg.codex_default) |old| alloc.free(old);
            cfg.codex_default = try alloc.dupe(u8, val);
        }
        return;
    }

    // [agents.<role>] — role name is everything after "agents."
    const agents_prefix = "agents.";
    if (std.mem.startsWith(u8, section, agents_prefix)) {
        const role_name = section[agents_prefix.len..];
        if (role_name.len == 0) return;

        // Get or insert a RoleConfig entry
        const key_copy = try alloc.dupe(u8, role_name);
        errdefer alloc.free(key_copy);
        const gop = try cfg.roles.getOrPut(key_copy);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        } else {
            alloc.free(key_copy); // entry exists — key not stored, free the copy
        }

        const rc = gop.value_ptr;
        if (std.mem.eql(u8, key, "model")) {
            if (rc.model)   |old| alloc.free(old);
            rc.model   = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "backend")) {
            if (rc.backend) |old| alloc.free(old);
            rc.backend = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "sandbox")) {
            if (rc.sandbox) |old| alloc.free(old);
            rc.sandbox = try alloc.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "max_turns")) {
            rc.max_turns = std.fmt.parseInt(u32, val, 10) catch null;
        }
        return;
    }
}

/// Strip surrounding double or single quotes from a TOML string value.
fn stripQuotes(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"')  return s[1 .. s.len - 1];
    if (s.len >= 2 and s[0] == '\'' and s[s.len - 1] == '\'') return s[1 .. s.len - 1];
    return s;
}

// ── Tests ─────────────────────────────────────────────────────────────────────

test "config: parse primary and claude_default" {
    const alloc = std.testing.allocator;
    const toml =
        \\[provider]
        \\primary = "claude"
        \\claude_default = "opus"
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);

    try std.testing.expectEqualStrings("claude", cfg.primary.?);
    try std.testing.expectEqualStrings("opus", cfg.claude_default.?);
}

test "config: parse [agents.<role>] model override" {
    const alloc = std.testing.allocator;
    const toml =
        \\[agents.finder]
        \\model = "haiku"
        \\
        \\[agents.reviewer]
        \\model = "opus"
        \\backend = "codex"
        \\max_turns = 5
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);

    const finder = cfg.roles.get("finder").?;
    try std.testing.expectEqualStrings("haiku", finder.model.?);

    const reviewer = cfg.roles.get("reviewer").?;
    try std.testing.expectEqualStrings("opus", reviewer.model.?);
    try std.testing.expectEqualStrings("codex", reviewer.backend.?);
    try std.testing.expectEqual(@as(?u32, 5), reviewer.max_turns);
}

test "config: comments and blank lines are skipped" {
    const alloc = std.testing.allocator;
    const toml =
        \\# This is a comment
        \\
        \\[provider]
        \\# primary = "codex"
        \\primary = "auto"
    ;
    var cfg = try parse(alloc, toml);
    defer cfg.deinit(alloc);

    try std.testing.expectEqualStrings("auto", cfg.primary.?);
}

test "config: loadDefault returns null when file absent" {
    // We're running in a directory without .devswarm/config.toml
    const alloc = std.testing.allocator;
    try std.testing.expect(loadDefault(alloc) == null);
}
