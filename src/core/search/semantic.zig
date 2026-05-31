//! Semantic search engine using document embeddings.
//!
//! Queries the document_embeddings table in the SQLite graph database,
//! computes cosine similarity between the query embedding and each
//! stored document embedding, and returns ranked results.
//!
//! Works alongside the BM25 engine for hybrid retrieval.

const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");
const embeddings = @import("embeddings.zig");

/// A single semantic search result.
pub const SemResult = struct {
    doc_id: u32,
    document_path: []const u8,
    score: f32, // cosine similarity [0, 1]
};

/// Search results from semantic search.
pub const SemResults = struct {
    items: []SemResult,

    pub fn deinit(self: *SemResults, allocator: std.mem.Allocator) void {
        for (self.items) |*item| {
            allocator.free(item.document_path);
        }
        allocator.free(self.items);
        self.items = &.{};
    }
};

/// Internal scored result for sorting.
const ScoredDoc = struct {
    doc_id: u32,
    score: f32,
    path: []const u8,
};

/// Run semantic search against stored document embeddings.
///
///   - gdb:  Open graph database (must have been migrated — contains document_embeddings)
///   - query: Natural language query string
///   - limit: Maximum number of results to return
///   - allocator: Memory allocator for result strings
pub fn search(
    gdb: *graph_db.GraphDb,
    query: []const u8,
    limit: usize,
    allocator: std.mem.Allocator,
) !SemResults {
    // Generate query embedding
    const query_emb = embeddings.embedText(query);

    // Bounded top-k selection.  Rather than scoring every embedding into a
    // list, duping every path, and sorting the whole set (O(N) allocations
    // plus an O(N log N) sort per query — painful at 10k+ documents), we keep
    // only the best `limit` results in a small list ordered ascending by score
    // (index 0 is the current minimum, cheap to evict).  Paths are duped only
    // for candidates that actually make the cut.
    var top = try std.ArrayList(ScoredDoc).initCapacity(allocator, limit);
    defer top.deinit(allocator);

    var stmt = try gdb.prepare(
        \\SELECT de.id, de.document_id, de.vector, d.path
        \\FROM document_embeddings de
        \\JOIN documents d ON d.id = de.document_id
    );
    defer stmt.finalize();

    while (try stmt.step()) {
        const doc_id = try stmt.columnInt(1);
        const vec_bytes = try stmt.columnBlob(2);
        const path = try stmt.columnText(3);

        const doc_emb = embeddings.Embedding.fromBytes(vec_bytes) catch continue;

        const sim = embeddings.cosineSimilarity(
            query_emb.vector[0..query_emb.dim],
            doc_emb.vector[0..doc_emb.dim],
        );

        // Only positive similarities qualify.
        if (sim <= 0) continue;
        // Reject early (no dupe) when the top-k is full and this candidate
        // cannot beat the current minimum.  The `limit == 0` short-circuit
        // guards the `top.items[0]` access.
        if (top.items.len == limit and (limit == 0 or sim <= top.items[0].score)) continue;

        const path_owned = try allocator.dupe(u8, path);
        errdefer allocator.free(path_owned);
        const cand = ScoredDoc{
            .doc_id = @intCast(doc_id),
            .score = sim,
            .path = path_owned,
        };

        // Evict the current minimum when full to make room.
        if (top.items.len == limit) {
            const removed = top.orderedRemove(0);
            allocator.free(removed.path);
        }
        // Insert keeping ascending order by score.
        var ins: usize = 0;
        while (ins < top.items.len and top.items[ins].score < sim) ins += 1;
        try top.insert(allocator, ins, cand);
    }

    // `top` is ascending by score; emit results descending (best first).
    const n = top.items.len;
    const results = try allocator.alloc(SemResult, n);
    for (top.items, 0..) |item, i| {
        results[n - 1 - i] = .{
            .doc_id = item.doc_id,
            .document_path = item.path,
            .score = item.score,
        };
    }

    return .{ .items = results };
}

/// Compute embedding for a query string (same as embedText, exposed for reuse).
pub fn embedQuery(query: []const u8) embeddings.Embedding {
    return embeddings.embedText(query);
}

test "semantic search empty result on empty db" {
    var gdb = try graph_db.GraphDb.open(":memory:");
    defer gdb.close();
    try gdb.migrate();

    const results = try search(&gdb, "test query", 10, std.testing.allocator);
    defer results.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), results.items.len);
}

test "embedQuery produces embedding" {
    const emb = embedQuery("search for this");
    try std.testing.expectEqual(@as(usize, embeddings.EMBEDDING_DIM), emb.dim);
}

test "semantic search bounds to limit and returns descending scores" {
    const allocator = std.testing.allocator;
    var gdb = try graph_db.GraphDb.open(":memory:");
    defer gdb.close();
    try gdb.migrate();

    // Seed several documents, each with an embedding derived from a distinct
    // text.  The query reuses one of the texts so similarity varies across
    // rows — enough to exercise the top-k eviction and ordering paths.
    const texts = [_][]const u8{
        "alpha report generation service",
        "beta authentication middleware",
        "gamma database connection pool",
        "delta http router handler",
        "epsilon embedding vector search",
    };
    for (texts, 0..) |t, i| {
        var path_buf: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "src/doc{d}.zig", .{i});
        var ins = try gdb.prepare("INSERT INTO documents (path) VALUES (?)");
        defer ins.finalize();
        try ins.bindText(1, path);
        _ = try ins.step();
        const doc_id: i64 = @intCast(i + 1);
        const emb = embeddings.embedText(t);
        try gdb.insertEmbedding(doc_id, emb.asBytes(), @intCast(emb.dim), "test");
    }

    // limit smaller than the number of matching docs → result is capped.
    const limit: usize = 3;
    var results = try search(&gdb, "alpha report generation service", limit, allocator);
    defer results.deinit(allocator);

    try std.testing.expect(results.items.len <= limit);
    try std.testing.expect(results.items.len > 0);

    // Scores must be sorted descending (best first).
    var prev: f32 = std.math.inf(f32);
    for (results.items) |item| {
        try std.testing.expect(item.score <= prev);
        prev = item.score;
    }
}
