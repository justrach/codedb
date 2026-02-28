// CodeGraph DB — core data types
//
// Every node in the code graph is one of: Symbol, File, Commit.
// Edges connect symbols to other symbols (calls, imports, etc.).

const std = @import("std");

// ── Node types ──────────────────────────────────────────────────────────────

pub const SymbolKind = enum(u8) {
    function,
    method,
    class,
    variable,
    constant,
    type_def,
    interface,
    module,
};

pub const Symbol = struct {
    id: u64,
    name: []const u8,
    kind: SymbolKind,
    file_id: u32,
    line: u32,
    col: u16,
    scope: []const u8, // e.g. "MyClass.method"
};

pub const Language = enum(u8) {
    typescript,
    javascript,
    zig,
    python,
    unknown = 255,
};

pub const File = struct {
    id: u32,
    path: []const u8,
    language: Language,
    last_modified: i64, // unix timestamp ms
    hash: [32]u8, // SHA-256
};

pub const Commit = struct {
    id: u32,
    hash: [40]u8, // hex SHA-1
    timestamp: i64,
    author: []const u8,
    message: []const u8,
};

// ── Edge types ──────────────────────────────────────────────────────────────

pub const EdgeKind = enum(u8) {
    calls,
    imports,
    defines,
    modifies,
    references,
};

pub const Edge = struct {
    src: u64,
    dst: u64,
    kind: EdgeKind,
    weight: f32 = 1.0,
};

// ── Tests ───────────────────────────────────────────────────────────────────

test "SymbolKind enum values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(SymbolKind.function));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(SymbolKind.method));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(SymbolKind.class));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(SymbolKind.variable));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(SymbolKind.constant));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(SymbolKind.type_def));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(SymbolKind.interface));
    try std.testing.expectEqual(@as(u8, 7), @intFromEnum(SymbolKind.module));
}

test "EdgeKind enum values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EdgeKind.calls));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EdgeKind.imports));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EdgeKind.defines));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(EdgeKind.modifies));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(EdgeKind.references));
}

test "Language enum values are stable" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Language.typescript));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Language.javascript));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Language.zig));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Language.python));
    try std.testing.expectEqual(@as(u8, 255), @intFromEnum(Language.unknown));
}

test "Edge default weight is 1.0" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls };
    try std.testing.expectEqual(@as(f32, 1.0), e.weight);
}

test "struct sizes are reasonable" {
    // Edge: src(8) + dst(8) + kind(1) + pad(3) + weight(4) = 24
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Edge));
    // Symbol should be under 80 bytes (slices are 16 bytes each on 64-bit)
    try std.testing.expect(@sizeOf(Symbol) <= 80);
    // File should be under 96 bytes
    try std.testing.expect(@sizeOf(File) <= 96);
}

// ── Edge case tests ─────────────────────────────────────────────────────────

test "SymbolKind all values are distinct" {
    const kinds = [_]SymbolKind{ .function, .method, .class, .variable, .constant, .type_def, .interface, .module };
    for (kinds, 0..) |a, i| {
        for (kinds, 0..) |b, j| {
            if (i != j) {
                try std.testing.expect(@intFromEnum(a) != @intFromEnum(b));
            }
        }
    }
}

test "SymbolKind enum count is 8" {
    const fields = @typeInfo(SymbolKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 8), fields.len);
}

test "EdgeKind all values are distinct" {
    const kinds = [_]EdgeKind{ .calls, .imports, .defines, .modifies, .references };
    for (kinds, 0..) |a, i| {
        for (kinds, 0..) |b, j| {
            if (i != j) {
                try std.testing.expect(@intFromEnum(a) != @intFromEnum(b));
            }
        }
    }
}

test "EdgeKind enum count is 5" {
    const fields = @typeInfo(EdgeKind).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
}

test "Language enum count is 5" {
    const fields = @typeInfo(Language).@"enum".fields;
    try std.testing.expectEqual(@as(usize, 5), fields.len);
}

test "Symbol with zero id" {
    const sym = Symbol{
        .id = 0,
        .name = "zero",
        .kind = .function,
        .file_id = 0,
        .line = 0,
        .col = 0,
        .scope = "",
    };
    try std.testing.expectEqual(@as(u64, 0), sym.id);
    try std.testing.expectEqualStrings("zero", sym.name);
}

test "Symbol with max u64 id" {
    const sym = Symbol{
        .id = std.math.maxInt(u64),
        .name = "max",
        .kind = .module,
        .file_id = std.math.maxInt(u32),
        .line = std.math.maxInt(u32),
        .col = std.math.maxInt(u16),
        .scope = "deep.nested.scope",
    };
    try std.testing.expectEqual(std.math.maxInt(u64), sym.id);
    try std.testing.expectEqual(std.math.maxInt(u32), sym.file_id);
    try std.testing.expectEqual(std.math.maxInt(u32), sym.line);
    try std.testing.expectEqual(std.math.maxInt(u16), sym.col);
}

test "Symbol with empty name and scope" {
    const sym = Symbol{
        .id = 1,
        .name = "",
        .kind = .variable,
        .file_id = 0,
        .line = 0,
        .col = 0,
        .scope = "",
    };
    try std.testing.expectEqual(@as(usize, 0), sym.name.len);
    try std.testing.expectEqual(@as(usize, 0), sym.scope.len);
}

test "File with empty path" {
    const f = File{
        .id = 0,
        .path = "",
        .language = .unknown,
        .last_modified = 0,
        .hash = [_]u8{0} ** 32,
    };
    try std.testing.expectEqual(@as(usize, 0), f.path.len);
    try std.testing.expectEqual(Language.unknown, f.language);
}

test "File with max values" {
    const f = File{
        .id = std.math.maxInt(u32),
        .path = "a" ** 256,
        .language = .python,
        .last_modified = std.math.maxInt(i64),
        .hash = [_]u8{0xFF} ** 32,
    };
    try std.testing.expectEqual(std.math.maxInt(u32), f.id);
    try std.testing.expectEqual(@as(usize, 256), f.path.len);
    try std.testing.expectEqual(std.math.maxInt(i64), f.last_modified);
    try std.testing.expectEqual(@as(u8, 0xFF), f.hash[31]);
}

test "File with negative timestamp" {
    const f = File{
        .id = 1,
        .path = "old.zig",
        .language = .zig,
        .last_modified = -1_000_000,
        .hash = [_]u8{0} ** 32,
    };
    try std.testing.expect(f.last_modified < 0);
}

test "Edge with weight zero" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls, .weight = 0.0 };
    try std.testing.expectEqual(@as(f32, 0.0), e.weight);
}

test "Edge with negative weight" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls, .weight = -1.0 };
    try std.testing.expectEqual(@as(f32, -1.0), e.weight);
}

test "Edge with very large weight" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls, .weight = std.math.floatMax(f32) };
    try std.testing.expectEqual(std.math.floatMax(f32), e.weight);
}

test "Edge with infinity weight" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls, .weight = std.math.inf(f32) };
    try std.testing.expect(std.math.isInf(e.weight));
}

test "Edge with NaN weight" {
    const e = Edge{ .src = 1, .dst = 2, .kind = .calls, .weight = std.math.nan(f32) };
    try std.testing.expect(std.math.isNan(e.weight));
}

test "Edge with max u64 src and dst" {
    const e = Edge{
        .src = std.math.maxInt(u64),
        .dst = std.math.maxInt(u64),
        .kind = .references,
        .weight = 0.5,
    };
    try std.testing.expectEqual(std.math.maxInt(u64), e.src);
    try std.testing.expectEqual(std.math.maxInt(u64), e.dst);
}

test "Edge self-loop (src == dst)" {
    const e = Edge{ .src = 42, .dst = 42, .kind = .references };
    try std.testing.expectEqual(e.src, e.dst);
    try std.testing.expectEqual(@as(f32, 1.0), e.weight);
}

test "Commit with empty author and message" {
    const c = Commit{
        .id = 0,
        .hash = [_]u8{'0'} ** 40,
        .timestamp = 0,
        .author = "",
        .message = "",
    };
    try std.testing.expectEqual(@as(usize, 0), c.author.len);
    try std.testing.expectEqual(@as(usize, 0), c.message.len);
}

test "Commit with negative timestamp" {
    const c = Commit{
        .id = 1,
        .hash = [_]u8{'a'} ** 40,
        .timestamp = -1,
        .author = "ancient",
        .message = "before epoch",
    };
    try std.testing.expect(c.timestamp < 0);
}

test "Commit with max id" {
    const c = Commit{
        .id = std.math.maxInt(u32),
        .hash = [_]u8{'f'} ** 40,
        .timestamp = std.math.maxInt(i64),
        .author = "max",
        .message = "max commit",
    };
    try std.testing.expectEqual(std.math.maxInt(u32), c.id);
    try std.testing.expectEqual(std.math.maxInt(i64), c.timestamp);
}

test "all EdgeKind values can be used in Edge struct" {
    const kinds = [_]EdgeKind{ .calls, .imports, .defines, .modifies, .references };
    for (kinds) |k| {
        const e = Edge{ .src = 1, .dst = 2, .kind = k };
        try std.testing.expectEqual(k, e.kind);
    }
}

test "all SymbolKind values can be used in Symbol struct" {
    const kinds = [_]SymbolKind{ .function, .method, .class, .variable, .constant, .type_def, .interface, .module };
    for (kinds) |k| {
        const sym = Symbol{ .id = 1, .name = "x", .kind = k, .file_id = 0, .line = 0, .col = 0, .scope = "" };
        try std.testing.expectEqual(k, sym.kind);
    }
}

test "all Language values can be used in File struct" {
    const langs = [_]Language{ .typescript, .javascript, .zig, .python, .unknown };
    for (langs) |l| {
        const f = File{ .id = 0, .path = "test", .language = l, .last_modified = 0, .hash = [_]u8{0} ** 32 };
        try std.testing.expectEqual(l, f.language);
    }
}
