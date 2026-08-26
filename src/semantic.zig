//! Optional, privacy-bounded remote embeddings for codedb_context.
//!
//! The lexical/symbol pipeline always runs first. This module receives only
//! the already-bounded candidate snippets selected by that local pipeline,
//! sends them in one embedding batch, and returns advisory cosine scores.
//! It never uploads a repository, writes vectors, or falls back to a local/CPU
//! model. A network or provider failure is handled by the caller by keeping the
//! local BM25 ordering.

const std = @import("std");
const cio = @import("cio.zig");
const snapshot = @import("snapshot.zig");

pub const default_url = "https://embeddings.wiki.codes/v1/codedb/embeddings";
pub const default_model = "Qwen/Qwen3-Embedding-0.6B";
pub const default_dimensions: u16 = 512;
pub const default_timeout_ms: u32 = 15_000;
pub const min_timeout_ms: u32 = 10;
pub const max_timeout_ms: u32 = 120_000;
pub const max_documents: usize = 24;
// The free public codedb lane accepts at most 25 inputs per request. Indexing
// may fill all 25 slots because, unlike query reranking, it does not prepend a
// query vector to the batch.
pub const max_index_documents: usize = 25;
pub const max_document_bytes: usize = 2 * 1024;
// Keep the serialized anonymous request below Caddy's 64 KiB raw-body cap even
// when source punctuation/control bytes expand during JSON escaping.
pub const max_batch_text_bytes: usize = 8 * 1024;
pub const max_request_bytes: usize = 60 * 1024;
pub const max_response_bytes: usize = 2 * 1024 * 1024;
pub const max_index_batch_text_bytes: usize = 25 * 1024;
pub const max_index_embedding_attempts: usize = 3;
pub const index_embedding_retry_base_ms: u32 = 250;
pub const default_rrf_k: f32 = 60;
pub const default_semantic_weight: f32 = 0.05;
pub const default_ann_semantic_weight: f32 = 1.0;
pub const query_prefix_version = "qwen3-query-instruct-v1";
pub const document_card_version = "codedb-code-chunk-v2";
pub const calibration_text = "codedb vector-space calibration v1: deterministic code retrieval";
pub const calibration_min_cosine: f32 = 0.9999;

pub const Candidate = struct {
    path: []const u8,
    text: []const u8,
};

pub const Result = struct {
    scores: []f32,
    model: []const u8,
    dimensions: u16,
    documents_sent: usize,
    text_bytes_sent: usize,
    /// The hosted codedb endpoint is operated as transient inference with no
    /// request-body/vector retention. Custom endpoints are deliberately marked
    /// unverified: a local client cannot prove another operator's policy.
    retention: enum { none_by_codedb_policy, custom_endpoint_unverified },
};

pub const EmbeddingBatchResult = struct {
    /// Row-major `count * dimensions` f32 vectors.
    vectors: []f32,
    count: usize,
    model: []const u8,
    dimensions: u16,
    text_bytes_sent: usize,
    retention: enum { none_by_codedb_policy, custom_endpoint_unverified },
};

pub const Config = struct {
    url: []const u8,
    model: []const u8,
    token: ?[]const u8,
    dimensions: u16,
    timeout_ms: u32,

    pub fn fromEnv() Config {
        const url = nonEmptyEnv("CODEDB_EMBEDDINGS_URL") orelse default_url;
        const model = nonEmptyEnv("CODEDB_EMBEDDINGS_MODEL") orelse default_model;
        const token = nonEmptyEnv("CODEDB_EMBEDDINGS_TOKEN");
        const dimensions = if (nonEmptyEnv("CODEDB_EMBEDDINGS_DIMENSIONS")) |raw|
            parseDimensions(raw) orelse 0
        else
            default_dimensions;
        const timeout_ms = if (nonEmptyEnv("CODEDB_EMBEDDINGS_TIMEOUT_MS")) |raw|
            parseTimeoutMs(raw) orelse 0
        else
            default_timeout_ms;
        return .{
            .url = url,
            .model = model,
            .token = token,
            .dimensions = dimensions,
            .timeout_ms = timeout_ms,
        };
    }

    pub fn validate(self: Config) !void {
        if (self.url.len > 2048 or self.model.len > 256) return error.InvalidEmbeddingConfig;
        if (self.token) |token| if (token.len > 4096) return error.InvalidEmbeddingConfig;
        if (self.dimensions < 64 or self.dimensions > 4096) return error.InvalidEmbeddingConfig;
        if (self.timeout_ms < min_timeout_ms or self.timeout_ms > max_timeout_ms) return error.InvalidEmbeddingConfig;

        const uri = std.Uri.parse(self.url) catch return error.InvalidEmbeddingConfig;
        if (uri.user != null or uri.password != null or uri.fragment != null) return error.InvalidEmbeddingConfig;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.getHost(&host_buf) catch return error.InvalidEmbeddingConfig).bytes;
        if (host.len == 0) return error.InvalidEmbeddingConfig;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
        if (std.ascii.eqlIgnoreCase(uri.scheme, "http") and
            (std.ascii.eqlIgnoreCase(host, "localhost") or
                std.mem.eql(u8, host, "127.0.0.1") or
                std.mem.eql(u8, host, "[::1]"))) return;
        return error.InsecureEmbeddingEndpoint;
    }

    pub fn isCodedbHosted(self: Config) bool {
        const uri = std.Uri.parse(self.url) catch return false;
        if (!std.ascii.eqlIgnoreCase(uri.scheme, "https") or uri.user != null or uri.password != null) return false;
        var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
        const host = (uri.getHost(&host_buf) catch return false).bytes;
        return std.ascii.eqlIgnoreCase(host, "embeddings.wiki.codes");
    }

    /// Stable identity for all client-controlled parts of the vector space.
    /// The stored calibration vector separately detects server-side weight or
    /// quantization changes behind an otherwise identical endpoint/model.
    pub fn vectorSpaceId(self: Config) u64 {
        var hash = std.hash.Wyhash.init(0x4344_4256_5350_4143);
        hash.update(self.url);
        hash.update(&.{0});
        hash.update(self.model);
        hash.update(&.{0});
        hash.update(std.mem.asBytes(&self.dimensions));
        hash.update(query_prefix_version);
        hash.update(&.{0});
        hash.update(document_card_version);
        return hash.final();
    }
};

/// Final cloud-boundary guard. The watcher and snapshot loader already reject
/// sensitive paths, but this check is deliberately repeated immediately before
/// request construction so a stale, hand-built, or malformed in-memory index
/// still cannot send `.env`, credential, private-key, traversal, or absolute
/// paths to an embedding provider.
pub fn isRemoteCandidatePathAllowed(path: []const u8) bool {
    if (!snapshot.isSafeSnapshotPath(path)) return false;
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| path[sep + 1 ..] else path;
    // The cloud boundary is intentionally stricter than the local indexer:
    // block case variants, direnv files, and .envrc even on case-sensitive
    // filesystems. Avoid broad `.env*` matching so `.envoy.json` and
    // `.environment` remain ordinary source/config names.
    if (basename.len >= 4 and std.ascii.eqlIgnoreCase(basename[0..4], ".env")) {
        if (basename.len == 4 or basename[4] == '.' or basename[4] == '-' or basename[4] == '_' or
            std.ascii.eqlIgnoreCase(basename[4..], "rc")) return false;
    }
    if (basename.len >= 4 and std.ascii.eqlIgnoreCase(basename[basename.len - 4 ..], ".env")) return false;
    var components = std.mem.splitScalar(u8, path, '/');
    while (components.next()) |component| {
        if (std.ascii.eqlIgnoreCase(component, ".direnv")) return false;
    }
    return true;
}

fn nonEmptyEnv(name: []const u8) ?[]const u8 {
    const value = cio.posixGetenv(name) orelse return null;
    return if (value.len == 0) null else value;
}

fn parseDimensions(value: []const u8) ?u16 {
    const parsed = std.fmt.parseInt(u16, value, 10) catch return null;
    if (parsed < 64 or parsed > 4096) return null;
    return parsed;
}

fn parseTimeoutMs(value: []const u8) ?u32 {
    const parsed = std.fmt.parseInt(u32, value, 10) catch return null;
    if (parsed < min_timeout_ms or parsed > max_timeout_ms) return null;
    return parsed;
}

fn appendBoundedDocument(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    candidate: Candidate,
    remaining_batch_bytes: usize,
) ![]const u8 {
    const path_cap = @min(candidate.path.len, 512);
    const fixed = path_cap + 1;
    if (remaining_batch_bytes <= fixed) return error.BatchTextLimit;
    const text_cap = @min(candidate.text.len, @min(max_document_bytes, remaining_batch_bytes - fixed));
    const start = out.items.len;
    try out.appendSlice(allocator, candidate.path[0..path_cap]);
    try out.append(allocator, '\n');
    try out.appendSlice(allocator, candidate.text[0..text_cap]);
    return out.items[start..];
}

const EmbeddingRequest = struct {
    model: []const u8,
    input: []const []const u8,
    dimensions: u16,
    encoding_format: []const u8 = "float",
};

fn fetchEmbeddingResponseOnce(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    body: []const u8,
) ![]u8 {
    if (body.len > max_request_bytes) return error.EmbeddingRequestTooLarge;
    var headers: [2]std.http.Header = undefined;
    var header_count: usize = 1;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |value| allocator.free(value);
    if (config.token) |token| {
        const value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        auth_value = value;
        headers[1] = .{ .name = "authorization", .value = value };
        header_count = 2;
    }

    var client = std.http.Client{ .allocator = allocator, .io = io };
    defer client.deinit();
    const response_buffer = try allocator.alloc(u8, max_response_bytes);
    defer allocator.free(response_buffer);
    var response_writer = std.Io.Writer.fixed(response_buffer);
    const fetch_result = try client.fetch(.{
        .location = .{ .url = config.url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers[0..header_count],
        .response_writer = &response_writer,
    });
    if (fetch_result.status != .ok) {
        return switch (fetch_result.status) {
            .too_many_requests => error.EmbeddingRateLimited,
            .internal_server_error, .bad_gateway, .service_unavailable, .gateway_timeout => error.EmbeddingProviderUnavailable,
            else => error.EmbeddingProviderRejected,
        };
    }
    return try allocator.dupe(u8, response_writer.buffer[0..response_writer.end]);
}

fn waitForEmbeddingTimeout(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(timeout_ms), .awake);
}

const EmbeddingRace = union(enum) {
    fetch: anyerror![]u8,
    timeout: std.Io.Cancelable!void,
};

fn releaseRaceResult(allocator: std.mem.Allocator, result: EmbeddingRace) void {
    switch (result) {
        .fetch => |outcome| if (outcome) |response| allocator.free(response) else |_| {},
        .timeout => {},
    }
}

fn cancelAndDrainRace(allocator: std.mem.Allocator, select: *std.Io.Select(EmbeddingRace)) void {
    while (select.cancel()) |result| releaseRaceResult(allocator, result);
}

fn fetchEmbeddingResponse(
    io: std.Io,
    allocator: std.mem.Allocator,
    config: Config,
    body: []const u8,
) ![]u8 {
    var completed: [2]EmbeddingRace = undefined;
    var select = std.Io.Select(EmbeddingRace).init(io, &completed);
    select.async(.fetch, fetchEmbeddingResponseOnce, .{ io, allocator, config, body });
    select.async(.timeout, waitForEmbeddingTimeout, .{ io, config.timeout_ms });

    const first = try select.await();
    return switch (first) {
        .fetch => |outcome| blk: {
            // Cancel the timer. A second fetch result is impossible, but drain
            // defensively so an allocated response can never be discarded.
            cancelAndDrainRace(allocator, &select);
            break :blk try outcome;
        },
        .timeout => |outcome| {
            try outcome;
            cancelAndDrainRace(allocator, &select);
            return error.EmbeddingTimeout;
        },
    };
}

/// Embed an already-bounded batch. This is the primitive used by the local
/// file-card ANN builder and query-only ANN lookup. It never writes vectors.
pub fn embedRemoteTexts(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
) !EmbeddingBatchResult {
    const config = Config.fromEnv();
    try config.validate();
    if (inputs.len == 0 or inputs.len > max_index_documents) return error.InvalidEmbeddingBatch;
    var text_bytes: usize = 0;
    for (inputs) |input| {
        if (input.len < 1 or input.len > max_document_bytes) return error.InvalidEmbeddingDocument;
        text_bytes = std.math.add(usize, text_bytes, input.len) catch return error.EmbeddingRequestTooLarge;
    }
    if (text_bytes > max_index_batch_text_bytes) return error.EmbeddingRequestTooLarge;

    const body = try std.json.Stringify.valueAlloc(allocator, EmbeddingRequest{
        .model = config.model,
        .input = inputs,
        .dimensions = config.dimensions,
    }, .{});
    defer allocator.free(body);
    const response = try fetchEmbeddingResponse(io, allocator, config, body);
    defer allocator.free(response);
    const vectors = try vectorsFromProviderResponse(allocator, response, inputs.len, config.dimensions, config.model);
    return .{
        .vectors = vectors,
        .count = inputs.len,
        .model = config.model,
        .dimensions = config.dimensions,
        .text_bytes_sent = text_bytes,
        .retention = if (config.isCodedbHosted()) .none_by_codedb_policy else .custom_endpoint_unverified,
    };
}

/// Index builds are explicit, long-running operations, so transient hosted
/// lane pressure gets a small bounded retry budget. Interactive context calls
/// intentionally use `embedRemoteTexts` directly and fail fast to lexical.
pub fn embedIndexRemoteTexts(
    io: std.Io,
    allocator: std.mem.Allocator,
    inputs: []const []const u8,
) !EmbeddingBatchResult {
    for (0..max_index_embedding_attempts) |attempt| {
        return embedRemoteTexts(io, allocator, inputs) catch |err| {
            const retryable = err == error.EmbeddingRateLimited or
                err == error.EmbeddingProviderUnavailable or
                err == error.EmbeddingTimeout;
            if (!retryable or attempt + 1 == max_index_embedding_attempts) return err;
            const delay_ms = index_embedding_retry_base_ms << @intCast(attempt);
            io.sleep(.fromMilliseconds(delay_ms), .awake) catch {};
            continue;
        };
    }
    unreachable;
}

pub fn embedQueryRemote(
    io: std.Io,
    allocator: std.mem.Allocator,
    task: []const u8,
) !EmbeddingBatchResult {
    if (task.len < 3 or task.len > 1024) return error.InvalidEmbeddingQuery;
    const query = try std.fmt.allocPrint(
        allocator,
        "Instruct: Retrieve code relevant to the user request.\nQuery: {s}",
        .{task},
    );
    defer allocator.free(query);
    return embedRemoteTexts(io, allocator, &.{query});
}

/// Embed the private task and a fixed public canary in one bounded request.
/// The canary vector is compared with the one stored at ANN build time, which
/// detects server-side model/weight changes that reuse the same model string.
pub fn embedQueryAndCalibrationRemote(
    io: std.Io,
    allocator: std.mem.Allocator,
    task: []const u8,
) !EmbeddingBatchResult {
    if (task.len < 3 or task.len > 1024) return error.InvalidEmbeddingQuery;
    const query = try std.fmt.allocPrint(
        allocator,
        "Instruct: Retrieve code relevant to the user request.\nQuery: {s}",
        .{task},
    );
    defer allocator.free(query);
    return embedRemoteTexts(io, allocator, &.{ query, calibration_text });
}

pub fn cosineF32(a: []const f32, b: []const f32) !f32 {
    if (a.len == 0 or a.len != b.len) return error.InvalidEmbeddingDimensions;
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;
    for (a, b) |x32, y32| {
        if (!std.math.isFinite(x32) or !std.math.isFinite(y32)) return error.InvalidEmbeddingNumber;
        const x: f64 = x32;
        const y: f64 = y32;
        dot += x * y;
        norm_a += x * x;
        norm_b += y * y;
    }
    if (norm_a == 0 or norm_b == 0) return error.InvalidEmbeddingVector;
    return @floatCast(@max(-1.0, @min(1.0, dot / @sqrt(norm_a * norm_b))));
}

/// Make one batched remote request. The returned scores use `allocator` and
/// are aligned with `candidates[0..result.documents_sent]`.
pub fn scoreRemote(
    io: std.Io,
    allocator: std.mem.Allocator,
    task: []const u8,
    candidates: []const Candidate,
) !Result {
    const config = Config.fromEnv();
    try config.validate();
    if (task.len < 3 or task.len > 1024) return error.InvalidEmbeddingQuery;
    if (candidates.len == 0) return error.NoEmbeddingCandidates;

    var text_storage: std.ArrayList(u8) = .empty;
    defer text_storage.deinit(allocator);
    // The ArrayList may move while documents are appended, so offsets are
    // captured first and converted to slices only after the final append.
    const offsets = try allocator.alloc(struct { start: usize, len: usize }, @min(candidates.len, max_documents));
    defer allocator.free(offsets);

    var text_bytes: usize = 0;
    var actual_documents: usize = 0;
    for (candidates) |candidate| {
        if (actual_documents == max_documents) break;
        if (!isRemoteCandidatePathAllowed(candidate.path)) continue;
        if (text_bytes >= max_batch_text_bytes) break;
        const start = text_storage.items.len;
        _ = appendBoundedDocument(allocator, &text_storage, candidate, max_batch_text_bytes - text_bytes) catch |err| switch (err) {
            error.BatchTextLimit => break,
            else => return err,
        };
        const len = text_storage.items.len - start;
        offsets[actual_documents] = .{ .start = start, .len = len };
        text_bytes += len;
        actual_documents += 1;
    }
    if (actual_documents == 0) return error.NoEmbeddingCandidates;

    const instruction = "Instruct: Retrieve code relevant to the user request.\nQuery: ";
    const query = try std.fmt.allocPrint(allocator, "{s}{s}", .{ instruction, task });
    defer allocator.free(query);

    const inputs = try allocator.alloc([]const u8, actual_documents + 1);
    defer allocator.free(inputs);
    inputs[0] = query;
    for (offsets[0..actual_documents], 0..) |offset, i| {
        inputs[i + 1] = text_storage.items[offset.start .. offset.start + offset.len];
    }

    const body = try std.json.Stringify.valueAlloc(allocator, EmbeddingRequest{
        .model = config.model,
        .input = inputs,
        .dimensions = config.dimensions,
    }, .{});
    defer allocator.free(body);
    if (body.len > max_request_bytes) return error.EmbeddingRequestTooLarge;

    const response = try fetchEmbeddingResponse(io, allocator, config, body);
    defer allocator.free(response);

    const scores = try scoresFromProviderResponse(
        allocator,
        response,
        actual_documents,
        config.dimensions,
        config.model,
    );
    return .{
        .scores = scores,
        .model = config.model,
        .dimensions = config.dimensions,
        .documents_sent = actual_documents,
        .text_bytes_sent = text_bytes + query.len,
        .retention = if (config.isCodedbHosted()) .none_by_codedb_policy else .custom_endpoint_unverified,
    };
}

fn numberAsF64(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => error.InvalidEmbeddingNumber,
    };
}

/// Parse an OpenAI-compatible response into a validated row-major f32 matrix.
pub fn vectorsFromResponse(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    count: usize,
    dimensions: u16,
) ![]f32 {
    return vectorsFromProviderResponse(allocator, json_text, count, dimensions, null);
}

fn validateProviderModel(root: std.json.Value, expected_model: ?[]const u8) !void {
    const expected = expected_model orelse return;
    if (root != .object) return error.InvalidEmbeddingResponse;
    const model = root.object.get("model") orelse return error.InvalidEmbeddingModel;
    if (model != .string or !std.mem.eql(u8, model.string, expected)) return error.EmbeddingModelMismatch;
}

fn vectorsFromProviderResponse(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    count: usize,
    dimensions: u16,
    expected_model: ?[]const u8,
) ![]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    try validateProviderModel(parsed.value, expected_model);
    if (parsed.value != .object) return error.InvalidEmbeddingResponse;
    const data_value = parsed.value.object.get("data") orelse return error.InvalidEmbeddingResponse;
    if (data_value != .array or data_value.array.items.len != count) return error.InvalidEmbeddingResponse;

    const values_len = std.math.mul(usize, count, dimensions) catch return error.InvalidEmbeddingDimensions;
    const vectors = try allocator.alloc(f32, values_len);
    errdefer allocator.free(vectors);
    const seen = try allocator.alloc(bool, count);
    defer allocator.free(seen);
    @memset(seen, false);
    for (data_value.array.items) |item_value| {
        if (item_value != .object) return error.InvalidEmbeddingResponse;
        const index_value = item_value.object.get("index") orelse return error.InvalidEmbeddingResponse;
        if (index_value != .integer or index_value.integer < 0) return error.InvalidEmbeddingResponse;
        const index: usize = @intCast(index_value.integer);
        if (index >= count or seen[index]) return error.InvalidEmbeddingResponse;
        seen[index] = true;
        const embedding_value = item_value.object.get("embedding") orelse return error.InvalidEmbeddingResponse;
        if (embedding_value != .array or embedding_value.array.items.len != dimensions) return error.InvalidEmbeddingDimensions;
        const row = vectors[index * dimensions ..][0..dimensions];
        for (embedding_value.array.items, 0..) |value, i| {
            const number = try numberAsF64(value);
            if (!std.math.isFinite(number)) return error.InvalidEmbeddingNumber;
            row[i] = @floatCast(number);
        }
    }
    return vectors;
}

fn cosine(a: []const std.json.Value, b: []const std.json.Value) !f32 {
    if (a.len == 0 or a.len != b.len) return error.InvalidEmbeddingDimensions;
    var dot: f64 = 0;
    var norm_a: f64 = 0;
    var norm_b: f64 = 0;
    for (a, b) |av, bv| {
        const x = try numberAsF64(av);
        const y = try numberAsF64(bv);
        if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidEmbeddingNumber;
        dot += x * y;
        norm_a += x * x;
        norm_b += y * y;
    }
    if (norm_a == 0 or norm_b == 0) return error.InvalidEmbeddingVector;
    const raw = dot / @sqrt(norm_a * norm_b);
    return @floatCast(@max(-1.0, @min(1.0, raw)));
}

/// Parse an OpenAI-compatible embeddings response and return cosine scores for
/// document indices 1..N against query index 0. Items may arrive out of order.
pub fn scoresFromResponse(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    document_count: usize,
    dimensions: u16,
) ![]f32 {
    return scoresFromProviderResponse(allocator, json_text, document_count, dimensions, null);
}

fn scoresFromProviderResponse(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    document_count: usize,
    dimensions: u16,
    expected_model: ?[]const u8,
) ![]f32 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    try validateProviderModel(parsed.value, expected_model);
    if (parsed.value != .object) return error.InvalidEmbeddingResponse;
    const data_value = parsed.value.object.get("data") orelse return error.InvalidEmbeddingResponse;
    if (data_value != .array or data_value.array.items.len != document_count + 1) return error.InvalidEmbeddingResponse;

    const vectors = try allocator.alloc(?[]const std.json.Value, document_count + 1);
    defer allocator.free(vectors);
    @memset(vectors, null);
    for (data_value.array.items) |item_value| {
        if (item_value != .object) return error.InvalidEmbeddingResponse;
        const index_value = item_value.object.get("index") orelse return error.InvalidEmbeddingResponse;
        if (index_value != .integer or index_value.integer < 0) return error.InvalidEmbeddingResponse;
        const index: usize = @intCast(index_value.integer);
        if (index >= vectors.len or vectors[index] != null) return error.InvalidEmbeddingResponse;
        const embedding_value = item_value.object.get("embedding") orelse return error.InvalidEmbeddingResponse;
        if (embedding_value != .array or embedding_value.array.items.len != dimensions) return error.InvalidEmbeddingDimensions;
        vectors[index] = embedding_value.array.items;
    }
    const query = vectors[0] orelse return error.InvalidEmbeddingResponse;
    const scores = try allocator.alloc(f32, document_count);
    errdefer allocator.free(scores);
    for (scores, 0..) |*score, i| {
        score.* = try cosine(query, vectors[i + 1] orelse return error.InvalidEmbeddingResponse);
    }
    return scores;
}

/// Lexical-authoritative reciprocal-rank fusion. The semantic vote is capped
/// at 5% of the lexical vote: the top lexical result cannot be displaced by a
/// lower candidate, while embeddings can still resolve weaker tail rankings.
/// Exact definition files are kept in a separate leading group by the caller.
pub fn advisoryRrfScore(lexical_rank: usize, semantic_rank: usize) f32 {
    return advisoryRrfScoreWithPolicy(lexical_rank, semantic_rank, default_rrf_k, default_semantic_weight);
}

pub fn advisoryRrfScoreWithPolicy(lexical_rank: usize, semantic_rank: usize, rrf_k: f32, semantic_weight: f32) f32 {
    const k = @max(1, rrf_k);
    const weight = @max(0, @min(1, semantic_weight));
    const lexical_vote = 1.0 / (k + @as(f32, @floatFromInt(lexical_rank + 1)));
    const semantic_vote = weight / (k + @as(f32, @floatFromInt(semantic_rank + 1)));
    return lexical_vote + semantic_vote;
}

pub fn annRrfScore(lexical_present: bool, lexical_rank: usize, semantic_present: bool, semantic_rank: usize) f32 {
    const lexical_vote: f32 = if (lexical_present)
        1.0 / (default_rrf_k + @as(f32, @floatFromInt(lexical_rank + 1)))
    else
        0;
    const semantic_vote: f32 = if (semantic_present)
        default_ann_semantic_weight / (default_rrf_k + @as(f32, @floatFromInt(semantic_rank + 1)))
    else
        0;
    return lexical_vote + semantic_vote;
}

/// Conservative ANN ordering policy: the first three lexical results remain
/// authoritative, then local ANN may reorder/extend the tail via RRF.
pub fn annRankComesBefore(
    a_lexical_present: bool,
    a_lexical_rank: usize,
    a_semantic_present: bool,
    a_hybrid_score: f32,
    a_path: []const u8,
    b_lexical_present: bool,
    b_lexical_rank: usize,
    b_semantic_present: bool,
    b_hybrid_score: f32,
    b_path: []const u8,
) bool {
    const a_guard = a_lexical_present and a_lexical_rank < 3;
    const b_guard = b_lexical_present and b_lexical_rank < 3;
    if (a_guard != b_guard) return a_guard;
    if (a_guard) return a_lexical_rank < b_lexical_rank;
    if (a_hybrid_score != b_hybrid_score) return a_hybrid_score > b_hybrid_score;
    if (a_semantic_present != b_semantic_present) return a_semantic_present;
    if (a_lexical_rank != b_lexical_rank) return a_lexical_rank < b_lexical_rank;
    return std.mem.lessThan(u8, a_path, b_path);
}
