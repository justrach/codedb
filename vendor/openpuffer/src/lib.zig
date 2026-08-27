//! Public in-process HNSW engine.
//!
//! Dependents `@import("openpuffer")` and get `Hnsw`, `Options`, `SearchResult`,
//! and the SIMD vector helpers. HTTP serve (`src/server.zig`), persistence
//! clients, and the CLI are not part of this root.

const hnsw = @import("hnsw.zig");
const vecmath = @import("vector.zig");

pub const Hnsw = hnsw.Hnsw;
pub const Options = hnsw.Options;
pub const SearchResult = hnsw.SearchResult;

pub const vector = vecmath;
pub const dot = vecmath.dot;
pub const cosineDistance = vecmath.cosineDistance;
pub const l2Norm = vecmath.l2Norm;
pub const normalize = vecmath.normalize;
pub const dotI8 = vecmath.dotI8;

test "library root re-exports init/insert/search" {
    const std = @import("std");
    const Index = Hnsw(void);
    var idx = Index.init(std.testing.allocator, 4, .{});
    defer idx.deinit();
    _ = try idx.insert(&.{ 1, 0, 0, 0 });
    _ = try idx.insert(&.{ 0, 1, 0, 0 });
    const hits = try idx.search(&.{ 0.9, 0.1, 0, 0 }, 1, 16, std.testing.allocator);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(usize, 1), hits.len);
    try std.testing.expectEqual(@as(u32, 0), hits[0].id);
    try std.testing.expect(idx.hasStoredF32());
}

test "library store_f32=false leaves the f32 slab empty" {
    const std = @import("std");
    const Index = Hnsw(void);
    var idx = Index.init(std.testing.allocator, 4, .{ .store_f32 = false });
    defer idx.deinit();
    _ = try idx.insert(&.{ 1, 0, 0, 0 });
    try std.testing.expect(!idx.hasStoredF32());
    try std.testing.expectEqual(@as(usize, 0), idx.vectorConst(0).len);
    const hits = try idx.search(&.{ 1, 0, 0, 0 }, 1, 8, std.testing.allocator);
    defer std.testing.allocator.free(hits);
    try std.testing.expectEqual(@as(u32, 0), hits[0].id);
}
