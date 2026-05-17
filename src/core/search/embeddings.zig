//! Lightweight embedding generation using FastText-style subword embeddings.
//!
//! Generates 384-dimensional f32 embeddings from symbol names, doc comments,
//! and normalized code tokens. Uses n-gram subword hashing to produce
//! distributed vector representations without external models.
//!
//! Approach:
//!   1. Extract character n-grams (3-6 chars) from input text
//!   2. Hash each n-gram to a slot in the embedding dimension
//!   3. Sum/average the contributions for the final vector
//!
//! This is a simple but effective technique — it captures morphological
//! similarity (e.g., "getUser" and "setUser" will have similar embeddings).

const std = @import("std");
const tokenizer = @import("tokenizer.zig");

/// Embedding dimension — must match the vector storage column size.
pub const EMBEDDING_DIM: usize = 384;

/// Number of subword n-gram hashes used per token.
const NGRAM_HASHES: usize = 4;

/// N-gram length range (inclusive min, inclusive max).
const NGRAM_MIN: usize = 3;
const NGRAM_MAX: usize = 6;

/// A generated embedding vector.
pub const Embedding = struct {
    vector: [EMBEDDING_DIM]f32,
    dim: usize,

    /// Return the vector as a byte slice for BLOB storage.
    pub fn asBytes(self: *const Embedding) []const u8 {
        return std.mem.sliceAsBytes(self.vector[0..self.dim]);
    }

    /// De-serialize an embedding from a BLOB.
    pub fn fromBytes(bytes: []const u8) !Embedding {
        if (bytes.len % @sizeOf(f32) != 0) return error.InvalidEmbedding;
        const count = bytes.len / @sizeOf(f32);
        if (count > EMBEDDING_DIM) return error.InvalidEmbedding;
        var emb: Embedding = .{ .vector = std.mem.zeroes([EMBEDDING_DIM]f32), .dim = count };
        const floats = std.mem.bytesAsSlice(f32, bytes);
        @memcpy(emb.vector[0..count], floats);
        return emb;
    }
};

/// Generate an embedding from arbitrary text.
/// Returns a zeroed embedding for empty input.
pub fn embedText(text: []const u8) Embedding {
    var vec: [EMBEDDING_DIM]f32 = [_]f32{0.0} ** EMBEDDING_DIM;
    if (text.len == 0) return .{ .vector = vec, .dim = EMBEDDING_DIM };

    // Extract tokens from text (whitespace/punctuation separated)
    var token_count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        // Skip non-alphanumeric
        while (i < text.len and !std.ascii.isAlphanumeric(text[i])) i += 1;
        const start = i;
        while (i < text.len and std.ascii.isAlphanumeric(text[i])) i += 1;
        if (start == i) continue;

        const token = text[start..i];
        addTokenToVector(&vec, token);
        token_count += 1;
    }

    if (token_count == 0) return .{ .vector = vec, .dim = EMBEDDING_DIM };

    // Normalize: divide by token count for length normalization
    if (token_count > 1) {
        const scale: f32 = 1.0 / @as(f32, @floatFromInt(token_count));
        for (&vec) |*v| v.* *= scale;
    }

    // L2 normalize
    l2Normalize(&vec);

    return .{ .vector = vec, .dim = EMBEDDING_DIM };
}

/// Generate an embedding specific to code identifiers.
/// Uses tokenizer to split camelCase/snake_case, then applies
/// subword n-grams to each sub-token.
pub fn embedIdentifier(identifier: []const u8) Embedding {
    var vec: [EMBEDDING_DIM]f32 = [_]f32{0.0} ** EMBEDDING_DIM;
    if (identifier.len == 0) return .{ .vector = vec, .dim = EMBEDDING_DIM };

    // First, add the full identifier as a token
    addTokenToVector(&vec, identifier);

    // Then split and add sub-tokens
    var splits: [tokenizer.MAX_SPLITS][]const u8 = undefined;
    const n = tokenizer.splitIdentifier(identifier, &splits);
    for (splits[0..n]) |sub| {
        addTokenToVector(&vec, sub);
    }

    const total: f32 = @floatFromInt(1 + n);
    const scale: f32 = 1.0 / total;
    for (&vec) |*v| v.* *= scale;
    l2Normalize(&vec);

    return .{ .vector = vec, .dim = EMBEDDING_DIM };
}

/// Generate a document-level embedding from multiple text sources
/// (symbol names, doc comments, code content). Each source contributes
/// equally to the final embedding.
pub fn embedDocument(
    symbols: []const []const u8,
    comments: []const u8,
    code_tokens: []const u8,
) Embedding {
    var vec: [EMBEDDING_DIM]f32 = [_]f32{0.0} ** EMBEDDING_DIM;
    var count: f32 = 0;

    // Symbols get extra weight — each is a separate embedding
    for (symbols) |sym| {
        const sym_emb = embedIdentifier(sym);
        for (&vec, sym_emb.vector) |*v, sv| v.* += sv;
        count += 1;
    }

    if (comments.len > 0) {
        const comment_emb = embedText(comments);
        for (&vec, comment_emb.vector) |*v, cv| v.* += cv;
        count += 1;
    }

    if (code_tokens.len > 0) {
        const code_emb = embedText(code_tokens);
        for (&vec, code_emb.vector) |*v, kv| v.* += kv;
        count += 1;
    }

    if (count > 0) {
        const scale: f32 = 1.0 / count;
        for (&vec) |*v| v.* *= scale;
    }

    l2Normalize(&vec);
    return .{ .vector = vec, .dim = EMBEDDING_DIM };
}

/// Add hash-based subword n-gram contributions to a vector.
fn addTokenToVector(vec: *[EMBEDDING_DIM]f32, token: []const u8) void {
    var lowered: [256]u8 = undefined;
    const len = @min(token.len, lowered.len);
    for (token[0..len], 0..) |c, j| {
        lowered[j] = std.ascii.toLower(c);
    }
    const tok = lowered[0..len];

    var local: [EMBEDDING_DIM]f32 = [_]f32{0.0} ** EMBEDDING_DIM;
    var contrib_count: usize = 0;

    // Extract character n-grams
    var n: usize = NGRAM_MIN;
    while (n <= NGRAM_MAX) : (n += 1) {
        if (tok.len < n) continue;
        var pos: usize = 0;
        while (pos + n <= tok.len) : (pos += 1) {
            const ngram = tok[pos .. pos + n];
            const slot = hashToSlot(ngram);
            local[slot] = 1.0;
            contrib_count += 1;
        }
    }

    if (contrib_count > 0) {
        const scale: f32 = 1.0 / @as(f32, @floatFromInt(contrib_count));
        for (local, 0..) |lv, j| {
            vec[j] += lv * scale;
        }
    }
}

/// Hash an n-gram to a slot within EMBEDDING_DIM.
fn hashToSlot(ngram: []const u8) usize {
    const h = std.hash.Wyhash.hash(0x9e3779b97f4a7c15, ngram);
    return @as(usize, @intCast(h % EMBEDDING_DIM));
}

/// L2 normalize a vector in place.
fn l2Normalize(vec: []f32) void {
    var norm: f32 = 0;
    for (vec) |v| norm += v * v;
    norm = @sqrt(norm);
    if (norm > 0) {
        for (vec) |*v| v.* /= norm;
    }
}

/// Compute cosine similarity between two vectors.
/// Assumes both vectors are already L2-normalized (or of equal dimension).
/// Returns value in [-1, 1] where 1 is identical.
pub fn cosineSimilarity(a: []const f32, b: []const f32) f32 {
    const n = @min(a.len, b.len);
    if (n == 0) return 0;

    var dot: f32 = 0;
    var mag_a: f32 = 0;
    var mag_b: f32 = 0;

    for (a[0..n], b[0..n]) |av, bv| {
        dot += av * bv;
        mag_a += av * av;
        mag_b += bv * bv;
    }

    if (mag_a == 0 or mag_b == 0) return 0;
    return dot / (@sqrt(mag_a) * @sqrt(mag_b));
}

test "embedText produces valid embedding" {
    const emb = embedText("hello world test");
    try std.testing.expectEqual(@as(usize, EMBEDDING_DIM), emb.dim);
    // Check that the vector is non-zero
    var non_zero = false;
    for (emb.vector) |v| {
        if (v != 0) non_zero = true;
    }
    try std.testing.expect(non_zero);
}

test "embedText empty returns zeros" {
    const emb = embedText("");
    for (emb.vector) |v| {
        try std.testing.expectEqual(@as(f32, 0), v);
    }
}

test "embedIdentifier camelCase" {
    const emb = embedIdentifier("userRepo");
    try std.testing.expectEqual(@as(usize, EMBEDDING_DIM), emb.dim);
}

test "cosineSimilarity identical" {
    const emb = embedText("function handler server");
    const sim = cosineSimilarity(&emb.vector, &emb.vector);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), sim, 0.001);
}

test "cosineSimilarity orthogonal" {
    var a: [4]f32 = [_]f32{ 1, 0, 0, 0 };
    var b: [4]f32 = [_]f32{ 0, 1, 0, 0 };
    const sim = cosineSimilarity(&a, &b);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sim, 0.001);
}

test "embedding asBytes roundtrip" {
    const emb = embedText("test");
    const bytes = emb.asBytes();
    const restored = try Embedding.fromBytes(bytes);
    try std.testing.expectEqual(emb.dim, restored.dim);
    for (emb.vector, restored.vector) |a, b| {
        try std.testing.expectApproxEqAbs(a, b, 0.001);
    }
}
