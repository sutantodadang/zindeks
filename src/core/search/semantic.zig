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

    // Fetch all stored embeddings
    var scored = try std.ArrayList(ScoredDoc).initCapacity(allocator, 0);
    defer scored.deinit(allocator);

    var stmt = try gdb.prepare(
        \\SELECT de.id, de.document_id, de.vector, d.path
        \\FROM document_embeddings de
        \\JOIN documents d ON d.id = de.document_id
    );
    defer stmt.finalize();

    while (try stmt.step()) {
        const emb_id = try stmt.columnInt(0);
        _ = emb_id;
        const doc_id = try stmt.columnInt(1);
        const vec_bytes = try stmt.columnBlob(2);
        const path = try stmt.columnText(3);

        const doc_emb = embeddings.Embedding.fromBytes(vec_bytes) catch continue;

        const sim = embeddings.cosineSimilarity(
            query_emb.vector[0..query_emb.dim],
            doc_emb.vector[0..doc_emb.dim],
        );

        // Only include positive similarity results
        if (sim > 0) {
            try scored.append(allocator, .{
                .doc_id = @intCast(doc_id),
                .score = sim,
                .path = try allocator.dupe(u8, path),
            });
        }
    }

    // Sort by similarity descending (highest first)
    std.mem.sort(ScoredDoc, scored.items, {}, lessScoredDoc);
    if (scored.items.len > limit) {
        // Free paths beyond limit
        for (scored.items[limit..]) |item| {
            allocator.free(item.path);
        }
        scored.shrinkRetainingCapacity(limit);
    }

    // Build result list
    const results = try allocator.alloc(SemResult, scored.items.len);
    for (scored.items, 0..) |item, i| {
        results[i] = .{
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

fn lessScoredDoc(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    return a.score > b.score;
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
