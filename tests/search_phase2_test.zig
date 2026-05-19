//! Phase 2 regression / correctness tests:
//! - SIMD cosine similarity parity vs scalar reference
//! - SIMD normalizeInto parity vs scalar reference
//! - Query classifier routing
//! - TermCache lookup wiring

const std = @import("std");
const zindeks = @import("zindeks");
const embeddings = zindeks.search.embeddings;
const engine_mod = zindeks.search.engine;
const storage = zindeks.storage.index;

// ─── Scalar reference implementations (for parity comparison) ────────

fn scalarCosineSim(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    if (n == 0) return 0;
    var dot: f32 = 0;
    var ma: f32 = 0;
    var mb: f32 = 0;
    for (a[0..n], b[0..n]) |av, bv| {
        dot += av * bv;
        ma += av * av;
        mb += bv * bv;
    }
    if (ma == 0 or mb == 0) return 0;
    return dot / (@sqrt(ma) * @sqrt(mb));
}

fn scalarNormalize(buf: []u8, value: []const u8) []const u8 {
    var n: usize = 0;
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (n < buf.len) {
                buf[n] = std.ascii.toLower(c);
                n += 1;
            }
        }
    }
    return buf[0..n];
}

// ─── 2.1 SIMD cosine similarity parity ──────────────────────────────

test "cosineSimilarity SIMD matches scalar for full-length vectors" {
    var prng = std.Random.DefaultPrng.init(0xC051);
    const rng = prng.random();

    var a: [384]f32 = undefined;
    var b: [384]f32 = undefined;
    for (&a) |*x| x.* = rng.float(f32) * 2.0 - 1.0;
    for (&b) |*x| x.* = rng.float(f32) * 2.0 - 1.0;

    const got = embeddings.cosineSimilarity(&a, &b);
    const want = scalarCosineSim(&a, &b);
    try std.testing.expectApproxEqAbs(want, got, 1e-5);
}

test "cosineSimilarity SIMD handles non-multiple-of-lanes lengths" {
    var a: [13]f32 = .{ 0.1, -0.2, 0.3, 0.4, -0.5, 0.6, 0.7, -0.8, 0.9, 1.0, -1.1, 1.2, 1.3 };
    var b: [13]f32 = .{ 1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4, 0.3, 0.2, 0.1, 0.05, 0.02, 0.01 };

    const got = embeddings.cosineSimilarity(&a, &b);
    const want = scalarCosineSim(&a, &b);
    try std.testing.expectApproxEqAbs(want, got, 1e-5);
}

test "cosineSimilarity returns 0 for zero-magnitude vector" {
    var zeros = [_]f32{0} ** 16;
    const b = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    try std.testing.expectEqual(@as(f32, 0), embeddings.cosineSimilarity(&zeros, &b));
}

// ─── 2.4 SIMD normalizeInto parity ──────────────────────────────────

test "normalizeInto SIMD matches scalar for mixed input" {
    const inputs = [_][]const u8{
        "HelloWorld",
        "snake_case_thing",
        "with spaces and punctuation!?",
        "MixedCASE123and_underscores",
        "",
        "a",
        "short",
        "exactly_sixteen!",
        "exactly_seventeen!!",
        "@#$%^&*()",
        "AllUPPER",
        "alllower",
        "1234567890",
        "x" ** 64,
    };
    for (inputs) |input| {
        var got_buf: [128]u8 = undefined;
        var want_buf: [128]u8 = undefined;
        const got = storage.normalizeInto(&got_buf, input);
        const want = scalarNormalize(&want_buf, input);
        try std.testing.expectEqualStrings(want, got);
    }
}

test "normalizeInto respects output buffer cap mid-chunk" {
    // A 32-byte input but only an 8-byte output: must stop emitting
    // after 8 chars, even though that happens inside a SIMD chunk.
    var buf: [8]u8 = undefined;
    const out = storage.normalizeInto(&buf, "abcdefghijklmnopqrstuvwxyz012345");
    try std.testing.expectEqualStrings("abcdefgh", out);
}

// ─── 2.2 Query classifier ───────────────────────────────────────────

test "classifyQuery: identifier_only for single identifier" {
    try std.testing.expectEqual(engine_mod.QueryShape.identifier_only, engine_mod.classifyQuery("camelCase"));
    try std.testing.expectEqual(engine_mod.QueryShape.identifier_only, engine_mod.classifyQuery("snake_case_thing"));
    try std.testing.expectEqual(engine_mod.QueryShape.identifier_only, engine_mod.classifyQuery("init"));
    try std.testing.expectEqual(engine_mod.QueryShape.identifier_only, engine_mod.classifyQuery("HTTPServer"));
    try std.testing.expectEqual(engine_mod.QueryShape.identifier_only, engine_mod.classifyQuery("foo123"));
}

test "classifyQuery: natural_language for everything else" {
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery("how does auth work"));
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery("foo bar"));
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery(""));
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery("12345"));
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery("foo.bar"));
    try std.testing.expectEqual(engine_mod.QueryShape.natural_language, engine_mod.classifyQuery("a-b"));
}

// ─── 2.3 TermCache wiring ───────────────────────────────────────────

test "TermCache: returns same result on hit and miss" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("cache_idx");
    var writer = try storage.Writer.init(allocator, tmp.dir, "cache_idx");
    defer writer.deinit();
    _ = try writer.addFile("a.zig", 1, 0, "pub fn alpha() void {}\n");
    _ = try writer.addFile("b.zig", 2, 0, "pub fn alpha() void {} pub fn beta() void {}\n");
    try writer.finish();

    var index = try storage.Index.open(allocator, tmp.dir, "cache_idx");
    defer index.close();

    var cache = engine_mod.TermCache.init(allocator, 8);
    defer cache.deinit();

    const first = cache.lookup(&index, "alpha") orelse return error.NoLookup;
    const second = cache.lookup(&index, "alpha") orelse return error.NoLookup;
    try std.testing.expectEqual(first.df, second.df);
    try std.testing.expectEqual(first.postings.ptr, second.postings.ptr);
    try std.testing.expect(first.df >= 1);
}

test "TermCache: unknown term returns null and is not cached" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("miss_idx");
    var writer = try storage.Writer.init(allocator, tmp.dir, "miss_idx");
    defer writer.deinit();
    _ = try writer.addFile("only.zig", 1, 0, "pub fn realname() void {}\n");
    try writer.finish();

    var index = try storage.Index.open(allocator, tmp.dir, "miss_idx");
    defer index.close();

    var cache = engine_mod.TermCache.init(allocator, 4);
    defer cache.deinit();

    try std.testing.expect(cache.lookup(&index, "doesnotexist") == null);
}
