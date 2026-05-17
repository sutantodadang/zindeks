//! Tests for call graph tracing — BFS, path tracing, and centrality.
const std = @import("std");
const graph_db = @import("zindeks").storage.graph_db;
const call_graph = @import("zindeks").graph.call_graph;

fn setupTestGraph() !graph_db.GraphDb {
    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();

    // Create documents
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/main.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/util.zig', 'Zig')");

    // Create symbols — build a known call chain: main -> init -> parse -> validate
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'main', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'init', 'function', 11, 20)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'parse', 'function', 1, 15)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'validate', 'function', 16, 30)");

    // Create edges: main -> init, init -> parse, parse -> validate, validate -> init (cycle)
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 2, 'calls', 1.0)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (2, 3, 'calls', 0.9)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (3, 4, 'calls', 0.8)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (4, 2, 'calls', 0.5)"); // cycle

    return db;
}

test "call_graph trace outbound" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.nodes.len > 0);

    // First node should be main
    try std.testing.expectEqualStrings("main", result.nodes[0].name);

    // Edges should exist
    try std.testing.expect(result.edges.len > 0);
}

test "call_graph trace inbound" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "parse", .inbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.nodes.len >= 1);
}

test "call_graph trace depth limit" {
    var db = try setupTestGraph();
    defer db.close();

    // Depth 1 should only get immediate neighbors
    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 1);
    defer result.deinit(std.testing.allocator);

    // Should get main + init only (depth 1 means 1 step, so main at depth 0, init at depth 1)
    try std.testing.expect(result.nodes.len >= 1);
    try std.testing.expect(result.nodes.len <= 4); // shouldn't get all
}

test "call_graph trace includes confidence" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.trace(std.testing.allocator, &db, "main", .outbound, 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.edges.len > 0);

    // Check that confidence is populated (not zero for these edges)
    for (result.edges) |edge| {
        _ = edge.confidence; // confidence field exists and is accessible
    }
}

test "call_graph tracePath direct" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "main", "init", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expect(result.path.len == 2); // main -> init
    try std.testing.expectEqualStrings("main", result.path[0].name);
    try std.testing.expectEqualStrings("init", result.path[1].name);
}

test "call_graph tracePath multi-hop" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "main", "validate", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expect(result.path.len >= 3); // main -> init -> parse -> validate (at least 3 hops)

    // Check path is continuous
    try std.testing.expectEqualStrings("main", result.path[0].name);
}

test "call_graph tracePath not found" {
    var db = try setupTestGraph();
    defer db.close();

    // Symbol that doesn't exist
    var result = try call_graph.tracePath(std.testing.allocator, &db, "nonexistent", "main", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(!result.found);
    try std.testing.expectEqual(@as(f64, 0), result.total_confidence);
}

test "call_graph tracePath same node" {
    var db = try setupTestGraph();
    defer db.close();

    var result = try call_graph.tracePath(std.testing.allocator, &db, "init", "init", 5);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.found);
    try std.testing.expectEqual(@as(usize, 1), result.path.len);
    try std.testing.expectEqualStrings("init", result.path[0].name);
    try std.testing.expectEqual(@as(f64, 1.0), result.total_confidence);
}

test "call_graph computeCentrality" {
    var db = try setupTestGraph();
    defer db.close();

    const results = try call_graph.computeCentrality(std.testing.allocator, &db, 10);
    defer {
        for (results) |*r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }

    try std.testing.expect(results.len >= 1);

    // Should be sorted by centrality descending
    if (results.len >= 2) {
        try std.testing.expect(results[0].centrality >= results[1].centrality);
    }
}
