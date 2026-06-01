//! Integration test for the ANN (HNSW) index wired through semantic.zig.
//!
//! Verifies that:
//!   - searchAnn returns > 0 results on a small populated index
//!   - scores are descending (best first)
//!   - the top ANN result doc_id appears in the linear (exact) top-5

const std = @import("std");
const zindeks = @import("zindeks");
const graph_db = zindeks.storage.graph_db;
const semantic = zindeks.search.semantic;
const hnsw = zindeks.search.hnsw;
const quantize = zindeks.search.quantize;
const embeddings = zindeks.search.embeddings;

test "ANN searchAnn returns results and scores are descending" {
    const allocator = std.testing.allocator;

    var gdb = try graph_db.GraphDb.open(":memory:");
    defer gdb.close();
    try gdb.migrate();

    // Insert 20 documents with distinct text embeddings.
    const texts = [_][]const u8{
        "alpha report generation service",
        "beta authentication middleware layer",
        "gamma database connection pool manager",
        "delta http router handler factory",
        "epsilon embedding vector similarity search",
        "zeta cache invalidation strategy pattern",
        "eta logging infrastructure observability",
        "theta scheduler job queue worker",
        "iota configuration parser loader",
        "kappa metrics collection aggregation",
        "lambda api gateway reverse proxy",
        "mu session management token storage",
        "nu file system watcher event loop",
        "xi serialization deserialization codec",
        "omicron load balancer health check",
        "pi cryptographic hash signature verify",
        "rho websocket realtime push notification",
        "sigma query planner optimizer execution",
        "tau memory allocator pool arena",
        "upsilon build pipeline continuous integration",
    };

    for (texts, 0..) |text, i| {
        var path_buf: [48]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "src/module{d}.zig", .{i});
        var ins = try gdb.prepare("INSERT INTO documents (path) VALUES (?)");
        defer ins.finalize();
        try ins.bindText(1, path);
        _ = try ins.step();

        const doc_id: i64 = @intCast(i + 1);
        const emb = embeddings.embedText(text);
        try gdb.insertEmbedding(doc_id, emb.asBytes(), @intCast(emb.dim), "test");
    }

    // Build HNSW directly (mirrors what buildAndSaveAnn does internally).
    var h = hnsw.Hnsw.init(allocator, .{}, 0x5eed_1234);
    defer h.deinit();

    for (texts, 0..) |text, i| {
        const doc_id: u32 = @intCast(i + 1);
        const emb = embeddings.embedText(text);
        const q = quantize.quantize(emb.vector[0..emb.dim]);
        try h.insert(doc_id, &q.codes);
    }

    const query = "alpha report generation service";
    const limit: usize = 5;

    // ANN search
    var ann_results = try semantic.searchAnn(&gdb, &h, query, limit, allocator);
    defer ann_results.deinit(allocator);

    // Exact (linear) search for the same query
    var exact_results = try semantic.search(&gdb, query, limit, allocator);
    defer exact_results.deinit(allocator);

    // ANN must return at least 1 result
    try std.testing.expect(ann_results.items.len > 0);

    // Scores must be descending (best first)
    var prev_score: f32 = std.math.inf(f32);
    for (ann_results.items) |item| {
        try std.testing.expect(item.score <= prev_score);
        prev_score = item.score;
    }

    // The top ANN result should appear somewhere in the exact top-5
    // (recall parity on a small, non-tie set; ANN may re-order exact ties).
    const top_ann_doc_id = ann_results.items[0].doc_id;
    var found = false;
    for (exact_results.items) |item| {
        if (item.doc_id == top_ann_doc_id) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}
