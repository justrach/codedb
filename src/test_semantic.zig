const std = @import("std");
const testing = std.testing;
const semantic = @import("semantic.zig");
const cio = @import("cio.zig");
const io = std.testing.io;

const EnvVarGuard = struct {
    name: []const u8,
    had_prev: bool,
    prev_len: usize,
    prev: [4096]u8,

    fn save(name: []const u8) EnvVarGuard {
        var guard = EnvVarGuard{ .name = name, .had_prev = false, .prev_len = 0, .prev = undefined };
        if (cio.posixGetenv(name)) |value| {
            if (value.len <= guard.prev.len) {
                @memcpy(guard.prev[0..value.len], value);
                guard.prev_len = value.len;
                guard.had_prev = true;
            }
        }
        return guard;
    }

    fn restore(self: *const EnvVarGuard) void {
        if (self.had_prev) cio.posixSetenv(self.name, self.prev[0..self.prev_len]) else cio.posixUnsetenv(self.name);
    }
};

const EmbeddingEnvGuards = struct {
    guards: [5]EnvVarGuard,

    fn init() EmbeddingEnvGuards {
        const names = [_][]const u8{
            "CODEDB_EMBEDDINGS_URL",
            "CODEDB_EMBEDDINGS_MODEL",
            "CODEDB_EMBEDDINGS_TOKEN",
            "CODEDB_EMBEDDINGS_DIMENSIONS",
            "CODEDB_EMBEDDINGS_TIMEOUT_MS",
        };
        var self: EmbeddingEnvGuards = undefined;
        for (names, 0..) |name, i| self.guards[i] = EnvVarGuard.save(name);
        return self;
    }

    fn deinit(self: *const EmbeddingEnvGuards) void {
        for (&self.guards) |*guard| guard.restore();
    }
};

const MockEmbeddingServer = struct {
    server: *std.Io.net.Server,
    response: []const u8,
    status: []const u8 = "200 OK",
    delay_ms: u32 = 0,
    request: [65536]u8 = undefined,
    request_len: usize = 0,
    failure: ?anyerror = null,

    fn contentLength(headers: []const u8) !usize {
        var lines = std.mem.splitSequence(u8, headers, "\r\n");
        while (lines.next()) |line| {
            const prefix = "content-length:";
            if (line.len >= prefix.len and std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix)) {
                return std.fmt.parseInt(usize, std.mem.trim(u8, line[prefix.len..], " \t"), 10);
            }
        }
        return error.MissingContentLength;
    }

    fn run(self: *MockEmbeddingServer) void {
        const stream = self.server.accept(io) catch |err| {
            self.failure = err;
            return;
        };
        defer stream.close(io);

        while (self.request_len < self.request.len) {
            var iov = [1][]u8{self.request[self.request_len..]};
            const n = stream.read(io, &iov) catch |err| {
                self.failure = err;
                return;
            };
            if (n == 0) break;
            self.request_len += n;
            const header_end = std.mem.indexOf(u8, self.request[0..self.request_len], "\r\n\r\n") orelse continue;
            const content_len = contentLength(self.request[0..header_end]) catch |err| {
                self.failure = err;
                return;
            };
            if (self.request_len >= header_end + 4 + content_len) break;
        }

        if (self.delay_ms > 0) io.sleep(.fromMilliseconds(self.delay_ms), .awake) catch {};
        var writer_buf: [4096]u8 = undefined;
        var writer = stream.writer(io, &writer_buf);
        var header_buf: [256]u8 = undefined;
        const header = std.fmt.bufPrint(&header_buf, "HTTP/1.1 {s}\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ self.status, self.response.len }) catch return;
        writer.interface.writeAll(header) catch return;
        writer.interface.writeAll(self.response) catch return;
        writer.interface.flush() catch return;
    }
};

const RetryEmbeddingServer = struct {
    server: *std.Io.net.Server,
    response: []const u8,
    failure: ?anyerror = null,

    fn run(self: *RetryEmbeddingServer) void {
        for ([_][]const u8{ "429 Too Many Requests", "503 Service Unavailable", "200 OK" }) |status| {
            var one = MockEmbeddingServer{ .server = self.server, .response = self.response, .status = status };
            one.run();
            if (one.failure) |err| {
                self.failure = err;
                return;
            }
        }
    }
};

fn makeMockEmbeddingResponseWithScalar(
    allocator: std.mem.Allocator,
    model: []const u8,
    count: usize,
    dimensions: usize,
    nonzero_scalar: []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const writer = cio.listWriter(&out, allocator);
    try writer.print("{{\"model\":\"{s}\",\"data\":[", .{model});
    for (0..count) |row| {
        if (row > 0) try writer.writeByte(',');
        try writer.print("{{\"index\":{d},\"embedding\":[", .{row});
        for (0..dimensions) |column| {
            if (column > 0) try writer.writeByte(',');
            try writer.writeAll(if (column == row % dimensions) nonzero_scalar else "0");
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice(allocator);
}

fn makeMockEmbeddingResponse(allocator: std.mem.Allocator, model: []const u8, count: usize, dimensions: usize) ![]u8 {
    return makeMockEmbeddingResponseWithScalar(allocator, model, count, dimensions, "1");
}

fn configureMockEndpoint(server: *const std.Io.net.Server, model: []const u8, timeout_ms: u32) !void {
    var url_buf: [128]u8 = undefined;
    const url = try std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/custom/embeddings", .{server.socket.address.getPort()});
    cio.posixSetenv("CODEDB_EMBEDDINGS_URL", url);
    cio.posixSetenv("CODEDB_EMBEDDINGS_MODEL", model);
    cio.posixSetenv("CODEDB_EMBEDDINGS_TOKEN", "mock-secret-token");
    cio.posixSetenv("CODEDB_EMBEDDINGS_DIMENSIONS", "64");
    var timeout_buf: [16]u8 = undefined;
    const timeout = try std.fmt.bufPrint(&timeout_buf, "{d}", .{timeout_ms});
    cio.posixSetenv("CODEDB_EMBEDDINGS_TIMEOUT_MS", timeout);
}

test "semantic: parses out-of-order OpenAI embeddings and computes cosine" {
    const response =
        \\{"data":[
        \\  {"index":2,"embedding":[0,1,0]},
        \\  {"index":0,"embedding":[1,0,0]},
        \\  {"index":1,"embedding":[1,0,0]}
        \\]}
    ;
    const scores = try semantic.scoresFromResponse(testing.allocator, response, 2, 3);
    defer testing.allocator.free(scores);
    try testing.expectApproxEqAbs(@as(f32, 1), scores[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), scores[1], 0.0001);
}

test "semantic: rejects wrong dimensions and duplicate indices" {
    try testing.expectError(error.InvalidEmbeddingDimensions, semantic.scoresFromResponse(
        testing.allocator,
        \\{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":[1,0]}]}
    ,
        1,
        3,
    ));
    try testing.expectError(error.InvalidEmbeddingResponse, semantic.scoresFromResponse(
        testing.allocator,
        \\{"data":[{"index":0,"embedding":[1,0,0]},{"index":0,"embedding":[1,0,0]}]}
    ,
        1,
        3,
    ));
}

test "semantic: parses raw vectors in response index order" {
    const vectors = try semantic.vectorsFromResponse(
        testing.allocator,
        \\{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}
    ,
        2,
        2,
    );
    defer testing.allocator.free(vectors);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0, 1 }, vectors);
}

test "semantic: decodes negotiated little-endian base64 float16 vectors" {
    const vectors = try semantic.vectorsFromResponse(
        testing.allocator,
        \\{"encoding_format":"base64-f16","data":[
        \\  {"index":1,"embedding":"ADgAwA=="},
        \\  {"index":0,"embedding":"ADwAAA=="}
        \\]}
    ,
        2,
        2,
    );
    defer testing.allocator.free(vectors);
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0.5, -2 }, vectors);
}

test "semantic: float16 and JSON transports preserve retrieval ordering" {
    const legacy =
        \\{"data":[
        \\  {"index":0,"embedding":[1,0]},
        \\  {"index":1,"embedding":[0.75,0.25]},
        \\  {"index":2,"embedding":[0,1]}
        \\]}
    ;
    const compact =
        \\{"encoding_format":"base64-f16","data":[
        \\  {"index":2,"embedding":"AAAAPA=="},
        \\  {"index":0,"embedding":"ADwAAA=="},
        \\  {"index":1,"embedding":"ADoANA=="}
        \\]}
    ;
    const legacy_scores = try semantic.scoresFromResponse(testing.allocator, legacy, 2, 2);
    defer testing.allocator.free(legacy_scores);
    const compact_scores = try semantic.scoresFromResponse(testing.allocator, compact, 2, 2);
    defer testing.allocator.free(compact_scores);
    try testing.expect(legacy_scores[0] > legacy_scores[1]);
    try testing.expect(compact_scores[0] > compact_scores[1]);
    try testing.expectApproxEqAbs(legacy_scores[0], compact_scores[0], 0.001);
    try testing.expectApproxEqAbs(legacy_scores[1], compact_scores[1], 0.001);
}

test "semantic: compact decoder rejects malformed length and non-finite values" {
    try testing.expectError(error.InvalidEmbeddingDimensions, semantic.vectorsFromResponse(
        testing.allocator,
        \\{"encoding_format":"base64-f16","data":[{"index":0,"embedding":"AAA="}]}
    ,
        1,
        2,
    ));
    try testing.expectError(error.InvalidEmbeddingNumber, semantic.vectorsFromResponse(
        testing.allocator,
        \\{"encoding_format":"base64-f16","data":[{"index":0,"embedding":"AH4="}]}
    ,
        1,
        1,
    ));
    try testing.expectError(error.InvalidEmbeddingResponse, semantic.vectorsFromResponse(
        testing.allocator,
        \\{"encoding_format":"float","data":[{"index":0,"embedding":"ADw="}]}
    ,
        1,
        1,
    ));
}

test "semantic: advisory fusion keeps lexical channel dominant" {
    const best_lexical_worst_semantic = semantic.advisoryRrfScore(0, 23);
    const second_lexical_best_semantic = semantic.advisoryRrfScore(1, 0);
    try testing.expect(best_lexical_worst_semantic > second_lexical_best_semantic);
}

test "semantic: ANN fusion preserves the top-three lexical guard" {
    const guarded_score = semantic.annRrfScore(true, 2, false, 99);
    const semantic_only_score = semantic.annRrfScore(false, 3, true, 0);
    try testing.expect(semantic_only_score > guarded_score);
    try testing.expect(semantic.annRankComesBefore(
        true,
        2,
        false,
        guarded_score,
        "src/lexical.zig",
        false,
        3,
        true,
        semantic_only_score,
        "src/semantic.zig",
    ));
    try testing.expect(!semantic.annRankComesBefore(
        false,
        3,
        true,
        semantic_only_score,
        "src/semantic.zig",
        true,
        2,
        false,
        guarded_score,
        "src/lexical.zig",
    ));
}

test "semantic: endpoint validation parses the authority instead of trusting a prefix" {
    const base = semantic.Config{
        .url = "https://example.com/v1/embeddings",
        .model = "test-model",
        .token = null,
        .dimensions = 512,
        .timeout_ms = semantic.default_timeout_ms,
    };
    try base.validate();
    var config = base;
    config.url = "http://127.0.0.1:8765/v1/embeddings";
    try config.validate();
    config.url = "http://localhost:8765/v1/embeddings";
    try config.validate();
    config.url = "http://[::1]:8765/v1/embeddings";
    try config.validate();

    const rejected = [_]struct { url: []const u8, expected: anyerror }{
        .{ .url = "http://example.com/v1/embeddings", .expected = error.InsecureEmbeddingEndpoint },
        .{ .url = "http://localhost:80@evil.example/v1/embeddings", .expected = error.InvalidEmbeddingConfig },
        .{ .url = "http://127.0.0.1:80@evil.example/v1/embeddings", .expected = error.InvalidEmbeddingConfig },
        .{ .url = "https://user@example.com/v1/embeddings", .expected = error.InvalidEmbeddingConfig },
        .{ .url = "https://example.com/v1/embeddings#fragment", .expected = error.InvalidEmbeddingConfig },
        .{ .url = "file:///tmp/embeddings", .expected = error.InvalidEmbeddingConfig },
    };
    for (rejected) |case| {
        config.url = case.url;
        try testing.expectError(case.expected, config.validate());
    }
}

test "semantic: environment overrides are explicit and invalid values fail closed" {
    const names = [_][]const u8{
        "CODEDB_EMBEDDINGS_URL",
        "CODEDB_EMBEDDINGS_MODEL",
        "CODEDB_EMBEDDINGS_TOKEN",
        "CODEDB_EMBEDDINGS_DIMENSIONS",
        "CODEDB_EMBEDDINGS_TIMEOUT_MS",
    };
    var guards: [names.len]EnvVarGuard = undefined;
    for (names, 0..) |name, i| guards[i] = EnvVarGuard.save(name);
    defer for (&guards) |*guard| guard.restore();

    cio.posixSetenv("CODEDB_EMBEDDINGS_URL", "http://127.0.0.1:9876/v1/embeddings");
    cio.posixSetenv("CODEDB_EMBEDDINGS_MODEL", "override-model");
    cio.posixSetenv("CODEDB_EMBEDDINGS_TOKEN", "test-token-not-from-dotenv");
    cio.posixSetenv("CODEDB_EMBEDDINGS_DIMENSIONS", "256");
    cio.posixSetenv("CODEDB_EMBEDDINGS_TIMEOUT_MS", "3210");
    const configured = semantic.Config.fromEnv();
    try configured.validate();
    try testing.expectEqualStrings("http://127.0.0.1:9876/v1/embeddings", configured.url);
    try testing.expectEqualStrings("override-model", configured.model);
    try testing.expectEqualStrings("test-token-not-from-dotenv", configured.token.?);
    try testing.expectEqual(@as(u16, 256), configured.dimensions);
    try testing.expectEqual(@as(u32, 3210), configured.timeout_ms);

    cio.posixSetenv("CODEDB_EMBEDDINGS_DIMENSIONS", "not-a-number");
    try testing.expectError(error.InvalidEmbeddingConfig, semantic.Config.fromEnv().validate());
    cio.posixSetenv("CODEDB_EMBEDDINGS_DIMENSIONS", "256");
    cio.posixSetenv("CODEDB_EMBEDDINGS_TIMEOUT_MS", "0");
    try testing.expectError(error.InvalidEmbeddingConfig, semantic.Config.fromEnv().validate());
}

test "semantic: calibration cosine detects a changed vector space" {
    try testing.expectApproxEqAbs(@as(f32, 1), try semantic.cosineF32(&.{ 1, 0, 0 }, &.{ 1, 0, 0 }), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), try semantic.cosineF32(&.{ 1, 0, 0 }, &.{ 0, 1, 0 }), 0.0001);
}

test "semantic: cloud-boundary path guard rejects env secrets and unsafe paths" {
    const rejected = [_][]const u8{
        ".env",
        ".env.local",
        ".ENV",
        ".Env.local",
        ".envrc",
        ".direnv/cache.envrc",
        "config/.env.production",
        "frontend.env",
        "keys/private.pem",
        "keys/PRIVATE_KEY.PEM",
        "keys/service.KeY",
        "credentials.json",
        "config/Credentials.JSON",
        "deep/.ssh/id_ed25519",
        "deep/.SSH/id_ed25519",
        "../outside.zig",
        "/etc/passwd",
    };
    for (rejected) |path| try testing.expect(!semantic.isRemoteCandidatePathAllowed(path));

    try testing.expect(semantic.isRemoteCandidatePathAllowed("src/main.zig"));
    try testing.expect(semantic.isRemoteCandidatePathAllowed("config/.envoy.json"));
}

test "semantic: endpoint override batches 25 inputs with auth and validates provider model" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    const response = try makeMockEmbeddingResponse(testing.allocator, "mock-model", 25, 64);
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", 2_000);

    var mock = MockEmbeddingServer{ .server = &server, .response = response };
    const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
    var inputs: [25][]const u8 = undefined;
    for (&inputs, 0..) |*input, i| input.* = if (i == 0) "first" else "code";
    const result = semantic.embedRemoteTexts(io, testing.allocator, &inputs) catch |err| {
        thread.join();
        return err;
    };
    defer testing.allocator.free(result.vectors);
    thread.join();
    if (mock.failure) |err| return err;

    try testing.expectEqual(@as(usize, 25), result.count);
    try testing.expectEqual(@as(usize, 25 * 64), result.vectors.len);
    const request = mock.request[0..mock.request_len];
    try testing.expect(std.mem.indexOf(u8, request, "POST /custom/embeddings HTTP/1.1") != null);
    try testing.expect(std.mem.indexOf(u8, request, "authorization: Bearer mock-secret-token") != null or
        std.mem.indexOf(u8, request, "Authorization: Bearer mock-secret-token") != null);
    const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return error.InvalidMockRequest;
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, request[header_end + 4 ..], .{});
    defer parsed.deinit();
    try testing.expectEqualStrings("mock-model", parsed.value.object.get("model").?.string);
    try testing.expectEqual(@as(usize, 25), parsed.value.object.get("input").?.array.items.len);
    try testing.expectEqualStrings("float", parsed.value.object.get("encoding_format").?.string);
}

test "semantic: provider model mismatch fails closed" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    const response = try makeMockEmbeddingResponse(testing.allocator, "different-model", 1, 64);
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", 2_000);

    var mock = MockEmbeddingServer{ .server = &server, .response = response };
    const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
    const outcome = semantic.embedRemoteTexts(io, testing.allocator, &.{"code"});
    if (outcome) |result| testing.allocator.free(result.vectors) else |_| {}
    thread.join();
    if (mock.failure) |err| return err;
    try testing.expectError(error.EmbeddingModelMismatch, outcome);
}

test "semantic: provider f64 values that overflow f32 fail closed" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    // 1e100 is finite as the JSON parser's f64, but not representable as the
    // f32 vectors consumed by the local ANN index.
    const response = try makeMockEmbeddingResponseWithScalar(testing.allocator, "mock-model", 1, 64, "1e100");
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", 2_000);

    var mock = MockEmbeddingServer{ .server = &server, .response = response };
    const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
    const outcome = semantic.embedRemoteTexts(io, testing.allocator, &.{"code"});
    if (outcome) |result| testing.allocator.free(result.vectors) else |_| {}
    thread.join();
    if (mock.failure) |err| return err;
    try testing.expectError(error.InvalidEmbeddingNumber, outcome);
}

test "semantic: no-sidecar exact fallback rejects overflowing cosine from mock provider" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    // The exact fallback embeds one query and one bounded candidate. Each
    // scalar is finite f64, while its square overflows the cosine accumulator.
    const response = try makeMockEmbeddingResponseWithScalar(testing.allocator, "mock-model", 2, 64, "1e200");
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", 2_000);

    var mock = MockEmbeddingServer{ .server = &server, .response = response };
    const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
    const outcome = semantic.scoreRemote(
        io,
        testing.allocator,
        "find bounded implementation",
        &.{.{ .path = "src/bounded.zig", .text = "L1: pub fn bounded() void {}" }},
    );
    if (outcome) |result| testing.allocator.free(result.scores) else |_| {}
    thread.join();
    if (mock.failure) |err| return err;
    try testing.expectError(error.InvalidEmbeddingNumber, outcome);
}

test "semantic: request deadline cancels a stalled local provider" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    const response = try makeMockEmbeddingResponse(testing.allocator, "mock-model", 1, 64);
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", semantic.min_timeout_ms);

    var mock = MockEmbeddingServer{ .server = &server, .response = response, .delay_ms = 100 };
    const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
    const outcome = semantic.embedRemoteTexts(io, testing.allocator, &.{"code"});
    if (outcome) |result| testing.allocator.free(result.vectors) else |_| {}
    thread.join();
    // A canceled client may close before the delayed server write. That is the
    // expected deadline path, so only read/accept failures are recorded above.
    try testing.expectError(error.EmbeddingTimeout, outcome);
}

test "semantic: provider 4xx and 5xx responses fail closed with retryable classes" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    for ([_]struct { status: []const u8, expected: anyerror }{
        .{ .status = "429 Too Many Requests", .expected = error.EmbeddingRateLimited },
        .{ .status = "500 Internal Server Error", .expected = error.EmbeddingProviderUnavailable },
    }) |case| {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
        defer server.deinit(io);
        try configureMockEndpoint(&server, "mock-model", 2_000);
        var mock = MockEmbeddingServer{ .server = &server, .response = "{\"error\":\"mock\"}", .status = case.status };
        const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
        const outcome = semantic.embedRemoteTexts(io, testing.allocator, &.{"code"});
        if (outcome) |result| testing.allocator.free(result.vectors) else |_| {}
        thread.join();
        if (mock.failure) |err| return err;
        try testing.expectError(case.expected, outcome);
    }
}

test "semantic: explicit index batches retry bounded 429 and 5xx responses" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    const response = try makeMockEmbeddingResponse(testing.allocator, "mock-model", 1, 64);
    defer testing.allocator.free(response);
    const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
    defer server.deinit(io);
    try configureMockEndpoint(&server, "mock-model", 2_000);

    var mock = RetryEmbeddingServer{ .server = &server, .response = response };
    const thread = try std.Thread.spawn(.{}, RetryEmbeddingServer.run, .{&mock});
    const result = semantic.embedIndexRemoteTexts(io, testing.allocator, &.{"code"}) catch |err| {
        thread.join();
        return err;
    };
    defer testing.allocator.free(result.vectors);
    thread.join();
    if (mock.failure) |err| return err;
    try testing.expectEqual(@as(usize, 1), result.count);
}

test "semantic: truncated and oversized provider bodies fail closed" {
    var guards = EmbeddingEnvGuards.init();
    defer guards.deinit();

    const oversized = try testing.allocator.alloc(u8, semantic.max_response_bytes + 1);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    for ([_][]const u8{ "{\"model\":\"mock-model\",\"data\":[", oversized }) |response| {
        const addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        var server = try addr.listen(io, .{ .reuse_address = true, .mode = .stream, .protocol = .tcp });
        defer server.deinit(io);
        try configureMockEndpoint(&server, "mock-model", 2_000);
        var mock = MockEmbeddingServer{ .server = &server, .response = response };
        const thread = try std.Thread.spawn(.{}, MockEmbeddingServer.run, .{&mock});
        const outcome = semantic.embedRemoteTexts(io, testing.allocator, &.{"code"});
        if (outcome) |result| {
            testing.allocator.free(result.vectors);
            thread.join();
            return error.ExpectedEmbeddingFailure;
        } else |_| {}
        thread.join();
        // The oversized case commonly closes the client while the mock is
        // writing, which is expected and deliberately not treated as a server
        // failure here.
    }
}
