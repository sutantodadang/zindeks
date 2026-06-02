//! Thinking-cache recall core — shared by the `recall_reasoning` MCP tool and
//! `get_context`. Embeds the query, scans the `reasoning` table, returns the
//! top-N by cosine similarity (filtered by confidence + age).

const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");
const embeddings = @import("../search/embeddings.zig");

pub const Match = struct {
    id: i64,
    problem: []const u8,
    reasoning: []const u8,
    files: []const u8,
    confidence: f64,
    score: f32,
    created_at: []const u8,
};

/// Recall up to `limit` prior reasoning entries semantically similar to
/// `query`. Owned slice; free via `freeMatches`. `min_confidence` filters weak
/// entries; `max_age_days > 0` filters stale ones (0 = unlimited).
pub fn recall(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    query: []const u8,
    limit: usize,
    min_confidence: f64,
    max_age_days: i64,
) ![]Match {
    const q_emb = embeddings.embedText(query);

    var sql_buf: [512]u8 = undefined;
    const sql: [:0]const u8 = if (max_age_days > 0)
        try std.fmt.bufPrintZ(&sql_buf, "SELECT id, problem, reasoning, files, confidence, vector, dimensions, created_at FROM reasoning WHERE confidence >= ? AND created_at >= datetime('now', '-{d} days')", .{max_age_days})
    else
        "SELECT id, problem, reasoning, files, confidence, vector, dimensions, created_at FROM reasoning WHERE confidence >= ?";

    var stmt = try gdb.prepare(sql);
    defer stmt.finalize();
    try stmt.bindFloat(1, min_confidence);

    var matches = std.ArrayList(Match){};
    errdefer {
        for (matches.items) |*m| {
            allocator.free(m.problem);
            allocator.free(m.reasoning);
            allocator.free(m.files);
            allocator.free(m.created_at);
        }
        matches.deinit(allocator);
    }

    while (try stmt.step()) {
        const row_dimensions = stmt.columnInt(6) catch 0;
        if (row_dimensions == 0) continue;
        const vec_bytes = stmt.columnBlob(5) catch continue;
        if (vec_bytes.len == 0) continue;
        const d_emb = embeddings.Embedding.fromBytes(vec_bytes) catch continue;
        const sim = embeddings.cosineSimilarity(
            q_emb.vector[0..q_emb.dim],
            d_emb.vector[0..d_emb.dim],
        );
        try matches.append(allocator, .{
            .id = try stmt.columnInt(0),
            .problem = try allocator.dupe(u8, try stmt.columnText(1)),
            .reasoning = try allocator.dupe(u8, try stmt.columnText(2)),
            .files = try allocator.dupe(u8, try stmt.columnText(3)),
            .confidence = stmt.columnFloat(4) catch 0.5,
            .score = sim,
            .created_at = try allocator.dupe(u8, try stmt.columnText(7)),
        });
    }

    std.mem.sort(Match, matches.items, {}, struct {
        fn desc(_: void, a: Match, b: Match) bool {
            return a.score > b.score;
        }
    }.desc);

    const owned = try matches.toOwnedSlice(allocator);
    if (owned.len > limit) {
        for (owned[limit..]) |*m| {
            allocator.free(m.problem);
            allocator.free(m.reasoning);
            allocator.free(m.files);
            allocator.free(m.created_at);
        }
        const trimmed = try allocator.realloc(owned, limit);
        return trimmed;
    }
    return owned;
}

pub fn freeMatches(allocator: std.mem.Allocator, matches: []const Match) void {
    for (matches) |m| {
        allocator.free(m.problem);
        allocator.free(m.reasoning);
        allocator.free(m.files);
        allocator.free(m.created_at);
    }
    allocator.free(matches);
}

test "reasoning recall returns saved entry ranked by similarity" {
    const a = std.testing.allocator;
    var gdb = try graph_db.GraphDb.open(":memory:");
    defer gdb.close();
    try gdb.migrate();

    const emb = embeddings.embedText("leiden community detection resolution tuning");
    var ins = try gdb.prepare("INSERT INTO reasoning (problem, reasoning, files, confidence, vector, dimensions) VALUES (?,?,?,?,?,?)");
    defer ins.finalize();
    try ins.bindText(1, "leiden community detection resolution tuning");
    try ins.bindText(2, "raise resolution for finer clusters");
    try ins.bindText(3, "");
    try ins.bindFloat(4, 0.8);
    try ins.bindBlob(5, emb.asBytes());
    try ins.bindInt(6, @intCast(emb.dim));
    _ = try ins.step();

    const matches = try recall(a, &gdb, "how to tune leiden clustering", 5, 0.0, 0);
    defer freeMatches(a, matches);

    try std.testing.expect(matches.len == 1);
    try std.testing.expect(matches[0].score > 0.0);
    try std.testing.expectEqualStrings("raise resolution for finer clusters", matches[0].reasoning);
}
