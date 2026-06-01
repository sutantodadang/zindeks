//! int8 scalar quantization for embedding vectors.
//!
//! Document embeddings are L2-normalized f32 vectors (components in [-1, 1]).
//! We scale each component by 127 and round to i8, cutting memory 4x (1536 B →
//! 384 B at dim=384) and letting similarity run as an integer SIMD dot product.
//!
//! Because the source vectors are unit-norm, the dot product of two quantized
//! vectors divided by 127*127 approximates their cosine similarity closely
//! enough for ANN candidate ranking; exact f32 cosine is used for the final
//! re-rank where precision matters.

const std = @import("std");
const embeddings = @import("embeddings.zig");

pub const DIM: usize = embeddings.EMBEDDING_DIM;

/// Scale factor — maps [-1, 1] onto the i8 range [-127, 127].
pub const SCALE: f32 = 127.0;

/// A quantized embedding: one i8 code per dimension.
pub const Quantized = struct {
    codes: [DIM]i8,

    pub fn asBytes(self: *const Quantized) []const u8 {
        return std.mem.sliceAsBytes(self.codes[0..]);
    }

    pub fn fromBytes(bytes: []const u8) !Quantized {
        if (bytes.len != DIM) return error.InvalidQuantized;
        var q: Quantized = undefined;
        @memcpy(std.mem.sliceAsBytes(q.codes[0..]), bytes);
        return q;
    }
};

/// Quantize an L2-normalized f32 vector to int8 codes.  Values outside
/// [-1, 1] are clamped before scaling so quantization never overflows i8.
pub fn quantize(vec: []const f32) Quantized {
    var q: Quantized = .{ .codes = [_]i8{0} ** DIM };
    const n = @min(vec.len, DIM);
    for (0..n) |i| {
        const clamped = std.math.clamp(vec[i], -1.0, 1.0);
        const scaled = std.math.round(clamped * SCALE);
        q.codes[i] = @intFromFloat(std.math.clamp(scaled, -127.0, 127.0));
    }
    return q;
}

const LANES = 16;
const I8V = @Vector(LANES, i8);
const I16V = @Vector(LANES, i16);
const I32V = @Vector(LANES, i32);

/// SIMD integer dot product of two quantized vectors.
///
/// Products fit in i16 (127*127 = 16129 < 32767) and the running sum fits in
/// i32 (384 * 16129 ≈ 6.2M).  Processes 16 lanes at a time; a scalar tail
/// handles any remainder when DIM is not a multiple of LANES.
pub fn dot(a: *const [DIM]i8, b: *const [DIM]i8) i32 {
    var acc: I32V = @splat(0);
    var i: usize = 0;
    while (i + LANES <= DIM) : (i += LANES) {
        const va: I8V = a[i..][0..LANES].*;
        const vb: I8V = b[i..][0..LANES].*;
        const wa: I16V = va;
        const wb: I16V = vb;
        const prod: I16V = wa * wb;
        acc += @as(I32V, prod);
    }
    var sum: i32 = @reduce(.Add, acc);
    while (i < DIM) : (i += 1) {
        sum += @as(i32, a[i]) * @as(i32, b[i]);
    }
    return sum;
}

/// Approximate cosine similarity from quantized codes, in roughly [-1, 1].
pub fn similarity(a: *const [DIM]i8, b: *const [DIM]i8) f32 {
    const d: f32 = @floatFromInt(dot(a, b));
    return d / (SCALE * SCALE);
}

// ── Tests ────────────────────────────────────────────────────────────────

test "quantize clamps and scales" {
    var v = [_]f32{0} ** DIM;
    v[0] = 1.0;
    v[1] = -1.0;
    v[2] = 0.5;
    v[3] = 2.0; // out of range, must clamp
    const q = quantize(&v);
    try std.testing.expectEqual(@as(i8, 127), q.codes[0]);
    try std.testing.expectEqual(@as(i8, -127), q.codes[1]);
    try std.testing.expectEqual(@as(i8, 64), q.codes[2]); // round(0.5*127)=64
    try std.testing.expectEqual(@as(i8, 127), q.codes[3]); // clamped
}

test "dot equals scalar reference" {
    var pa = std.Random.DefaultPrng.init(42);
    const r = pa.random();
    var a: [DIM]i8 = undefined;
    var b: [DIM]i8 = undefined;
    for (0..DIM) |i| {
        a[i] = r.intRangeAtMost(i8, -127, 127);
        b[i] = r.intRangeAtMost(i8, -127, 127);
    }
    var expected: i32 = 0;
    for (0..DIM) |i| expected += @as(i32, a[i]) * @as(i32, b[i]);
    try std.testing.expectEqual(expected, dot(&a, &b));
}

test "similarity approximates f32 cosine for normalized vectors" {
    // Build two arbitrary vectors, L2-normalize, compare quantized similarity
    // against exact cosine. Tolerance accounts for int8 rounding.
    var pa = std.Random.DefaultPrng.init(7);
    const r = pa.random();
    var x = [_]f32{0} ** DIM;
    var y = [_]f32{0} ** DIM;
    for (0..DIM) |i| {
        x[i] = r.float(f32) * 2.0 - 1.0;
        y[i] = r.float(f32) * 2.0 - 1.0;
    }
    normalize(&x);
    normalize(&y);

    var cos: f32 = 0;
    for (0..DIM) |i| cos += x[i] * y[i];

    const qx = quantize(&x);
    const qy = quantize(&y);
    const approx = similarity(&qx.codes, &qy.codes);

    try std.testing.expect(@abs(approx - cos) < 0.02);
}

fn normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |c| sum += c * c;
    const norm = @sqrt(sum);
    if (norm == 0) return;
    for (v) |*c| c.* /= norm;
}
