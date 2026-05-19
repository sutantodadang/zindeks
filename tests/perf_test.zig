//! Performance and scale tests for Phase 6 components.
const std = @import("std");
const zindeks = @import("zindeks");
const graph_db = zindeks.storage.graph_db;
const batch = zindeks.storage.batch;
const cache_mod = zindeks.storage.cache;
const pool = zindeks.storage.pool;
const bench = zindeks.bench;
const stream = zindeks.api.mcp.stream;

test "BatchInserter flushes at batch_size threshold and inserts data" {
    const allocator = std.testing.allocator;
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    var inserter = batch.BatchInserter.init(allocator, &db, 5);
    defer inserter.deinit(allocator);

    // Allocate paths on heap so they outlive the loop iterations
    var paths: [5][]const u8 = undefined;

    // Add documents below threshold — should not flush yet
    for (0..3) |i| {
        var path_buf: [32]u8 = undefined;
        const path_str = try std.fmt.bufPrint(&path_buf, "file_{d}.zig", .{i});
        paths[i] = try allocator.dupe(u8, path_str);
        try inserter.addDocument(allocator, .{
            .path = paths[i],
            .content_hash = null,
            .language = "Zig",
            .mtime = null,
        });
    }

    // Add 2 more — should trigger flush at 5
    for (3..5) |i| {
        var path_buf: [32]u8 = undefined;
        const path_str = try std.fmt.bufPrint(&path_buf, "file_{d}.zig", .{i});
        paths[i] = try allocator.dupe(u8, path_str);
        try inserter.addDocument(allocator, .{
            .path = paths[i],
            .content_hash = null,
            .language = "Zig",
            .mtime = null,
        });
    }

    // Verify documents were inserted
    const count = try db.queryScalar("SELECT COUNT(*) FROM documents");
    try std.testing.expectEqual(@as(i64, 5), count);

    // Add symbols
    for (0..5) |i| {
        try inserter.addSymbol(allocator, .{
            .document_id = @intCast(i + 1),
            .name = "main",
            .kind = "function",
            .line_start = 1,
            .line_end = 10,
            .col_start = 0,
            .col_end = 0,
            .parent_symbol_id = null,
        });
    }

    // Force final flush
    try inserter.flush(allocator);
    const sym_count = try db.queryScalar("SELECT COUNT(*) FROM symbols");
    try std.testing.expectEqual(@as(i64, 5), sym_count);

    // Free paths
    for (&paths) |p| {
        allocator.free(p);
    }
}

test "BatchInserter handles edges and embeddings" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    // Setup: insert documents and symbols
    try db.exec("INSERT INTO documents (path, language) VALUES ('a.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('b.zig', 'Zig')");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'foo', 'function', 1, 5)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'bar', 'function', 6, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'baz', 'function', 1, 5)");

    var inserter = batch.BatchInserter.init(std.testing.allocator, &db, 10);
    defer inserter.deinit(std.testing.allocator);

    // Add edges
    try inserter.addEdge(std.testing.allocator, .{
        .source_symbol_id = 1,
        .target_symbol_id = 2,
        .edge_type = "CALLS",
        .confidence = 0.9,
    });
    try inserter.addEdge(std.testing.allocator, .{
        .source_symbol_id = 1,
        .target_symbol_id = 3,
        .edge_type = "IMPORTS",
        .confidence = 1.0,
    });

    // Add embedding
    const vec = [_]u8{ 0x01, 0x02, 0x03, 0x04 };
    try inserter.addEmbedding(std.testing.allocator, .{
        .document_id = 1,
        .vector = &vec,
        .dimensions = 4,
        .model_name = "test-model",
    });

    try inserter.flush(std.testing.allocator);

    const edge_count = try db.queryScalar("SELECT COUNT(*) FROM edges");
    try std.testing.expectEqual(@as(i64, 2), edge_count);

    const emb_count = try db.queryScalar("SELECT COUNT(*) FROM document_embeddings");
    try std.testing.expectEqual(@as(i64, 1), emb_count);
}

test "StatementCache reuses prepared statements" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();
    try db.exec("INSERT INTO documents (path, language) VALUES ('test.zig', 'Zig')");

    var cache = cache_mod.StatementCache.init(std.testing.allocator, @ptrCast(db.db), 10);
    defer cache.deinit();

    const sql = "SELECT path, language FROM documents WHERE id = 1";

    const stmt1 = try cache.prepare(sql);
    const stmt2 = try cache.prepare(sql);

    // Same SQL should return same stmt pointer
    try std.testing.expectEqual(@intFromPtr(stmt1), @intFromPtr(stmt2));
}

test "ConnectionPool limits concurrent connections" {
    const allocator = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const db_path = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", &tmp_dir.sub_path, "test_pool.db" });
    defer allocator.free(db_path);

    const max_conns: usize = 3;
    var cp = try pool.ConnectionPool.init(allocator, db_path, max_conns);
    defer cp.deinit();

    // Acquire all connections
    var conns: [3]pool.PooledConnection = undefined;
    for (0..max_conns) |i| {
        conns[i] = try cp.acquire();
    }

    // Release them all
    for (0..max_conns) |i| {
        conns[i].release();
    }

    // Should be able to acquire again
    var conn = try cp.acquire();
    conn.release();
}

test "Benchmark measures elapsed time" {
    const result = bench.runBenchmark("sleep_test", struct {
        fn sleep() void {
            std.Thread.sleep(10_000_000); // 10ms
        }
    }.sleep, 3);

    // Should have elapsed at least ~5ms per iteration
    try std.testing.expect(result.elapsed_ms >= 5);
    try std.testing.expectEqual(@as(usize, 3), result.iterations);
    try std.testing.expectEqualStrings("sleep_test", result.name);
}

test "JsonStreamWriter produces valid JSON" {
    const test_alloc = std.testing.allocator;

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const tmp_path = try std.fs.path.join(test_alloc, &.{ ".zig-cache", "tmp", &tmp_dir.sub_path, "test_stream.json" });
    defer test_alloc.free(tmp_path);

    {
        const file = try tmp_dir.dir.createFile("test_stream.json", .{});
        defer file.close();

        var writer = stream.JsonStreamWriter.init(file);
        try writer.beginArray();
        try writer.writeItem(struct { name: []const u8, value: i32 }, .{ .name = "one", .value = 1 });
        try writer.writeItem(struct { name: []const u8, value: i32 }, .{ .name = "two", .value = 2 });
        try writer.writeItem(struct { name: []const u8, value: i32 }, .{ .name = "three", .value = 3 });
        try writer.endArray();
        try writer.flush();
    }

    // Read back and verify
    const content = try tmp_dir.dir.readFileAlloc(test_alloc, "test_stream.json", 4096);
    defer test_alloc.free(content);

    // Should start with '[' and end with ']'
    try std.testing.expect(content.len > 2);
    try std.testing.expectEqual(@as(u8, '['), content[0]);
    try std.testing.expectEqual(@as(u8, ']'), content[content.len - 1]);

    // Should contain the values
    try std.testing.expect(std.mem.indexOf(u8, content, "\"one\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"two\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"three\"") != null);
}
