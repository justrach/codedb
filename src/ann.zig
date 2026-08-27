//! Local ANN building block for codedb semantic retrieval.
//!
//! This wraps OpenPuffer's pure-Zig HNSW engine. It deliberately imports only
//! the in-process index module: no HTTP server, object storage, Gemini client,
//! or turbopuffer client is linked into codedb.

const std = @import("std");
const openpuffer = @import("openpuffer");

pub const default_dimensions: u16 = 512;
/// OpenPuffer's merged codedb real-repository hill climb selected this 512D,
/// k=24 profile: 34-36% lower ANN p50 with 0.9992 clustered recall@24 and
/// 0.9958 real-repository exact-neighbor recall. Keep generic OpenPuffer's
/// wider defaults outside this narrowly measured codedb adapter.
pub const default_ef_search: u32 = 48;
pub const default_rerank_multiplier: usize = 2;

pub const SearchResult = openpuffer.SearchResult;
pub const Options = openpuffer.Options;

pub const Index = struct {
    inner: openpuffer.Hnsw(void),
    dimensions: u16,

    pub fn init(allocator: std.mem.Allocator, dimensions: u16, options: Options) Index {
        return .{
            .inner = openpuffer.Hnsw(void).init(allocator, dimensions, options),
            .dimensions = dimensions,
        };
    }

    pub fn deinit(self: *Index) void {
        self.inner.deinit();
    }

    pub fn len(self: *const Index) usize {
        return self.inner.len();
    }

    pub fn insert(self: *Index, vector: []const f32) !u32 {
        return self.inner.insert(vector);
    }

    /// Insert an OpenAI-compatible row-major embedding matrix. This is the
    /// explicit CodeDB/OpenPuffer contract: exactly `count * dimensions`
    /// values, the same dimensions the index was initialized with, and stable
    /// consecutive HNSW ids in response order.
    pub fn insertEmbeddingBatch(
        self: *Index,
        vectors: []const f32,
        count: usize,
        dimensions: u16,
    ) !u32 {
        if (count == 0) return error.InvalidEmbeddingBatch;
        if (dimensions != self.dimensions) return error.DimensionMismatch;
        const expected = std.math.mul(usize, count, dimensions) catch return error.InvalidEmbeddingBatchShape;
        if (vectors.len != expected) return error.InvalidEmbeddingBatchShape;
        const first_id = std.math.cast(u32, self.len()) orelse return error.IndexTooLarge;
        for (0..count) |row_index| {
            const start = row_index * @as(usize, dimensions);
            const id = try self.inner.insert(vectors[start..][0..dimensions]);
            if (id != first_id + row_index) return error.NonConsecutiveEmbeddingIds;
        }
        return first_id;
    }

    pub fn search(
        self: *Index,
        query: []const f32,
        k: usize,
        allocator: std.mem.Allocator,
    ) ![]SearchResult {
        return self.inner.searchAdvanced(
            query,
            k,
            default_ef_search,
            default_rerank_multiplier,
            allocator,
        );
    }

    pub fn serializedSize(self: *const Index) usize {
        return self.inner.serializedSize();
    }

    pub fn serialize(self: *const Index, allocator: std.mem.Allocator) ![]u8 {
        return self.inner.serialize(allocator);
    }

    pub fn load(self: *Index, bytes: []const u8) !void {
        return self.inner.load(bytes);
    }

    pub fn vectorConst(self: *const Index, id: u32) []const f32 {
        return self.inner.vectorConst(id);
    }

    pub fn hasStoredF32(self: *const Index) bool {
        return self.inner.hasStoredF32();
    }

    pub fn isMmapBacked(self: *const Index) bool {
        return self.inner.isMmapBacked();
    }

    pub fn slabImageSize(self: *const Index) !usize {
        return self.inner.slabImageSize();
    }

    pub fn writeSlabs(self: *const Index, path: []const u8) !void {
        return self.inner.writeSlabs(path);
    }

    pub fn loadMmap(self: *Index, path: []const u8) !void {
        return self.inner.loadMmap(path);
    }

    pub fn loadSlabsCopy(self: *Index, bytes: []const u8) !void {
        return self.inner.loadSlabsCopy(bytes);
    }
};

/// Persistent vector payload before ArrayList capacity and graph metadata.
/// OpenPuffer retains one f32 vector for exact rerank and one int8 vector for
/// traversal: five bytes per dimension per record.
pub fn vectorPayloadBytes(count: usize, dimensions: u16) !usize {
    return vectorPayloadBytesWithMode(count, dimensions, true);
}

pub fn vectorPayloadBytesWithMode(count: usize, dimensions: u16, store_f32: bool) !usize {
    const bytes_per_dimension: usize = if (store_f32) 5 else 1;
    return std.math.mul(usize, count, try std.math.mul(usize, dimensions, bytes_per_dimension));
}
