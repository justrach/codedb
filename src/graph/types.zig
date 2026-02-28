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
