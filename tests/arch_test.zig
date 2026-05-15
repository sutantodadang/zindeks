//! Tests for architecture analysis — hotspots, module coupling.
const std = @import("std");
const graph_db = @import("zindeks").storage.graph_db;
const arch = @import("zindeks").analysis.arch;

fn setupArchTestGraph() !graph_db.GraphDb {
    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();

    // Two modules (documents)
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/main.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/util.zig', 'Zig')");

    // Symbols in main.zig (document 1)
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'main', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'init', 'function', 11, 20)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'handleRequest', 'function', 21, 30)");

    // Symbols in util.zig (document 2)
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'parse', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'validate', 'function', 11, 20)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'format', 'function', 21, 30)");

    // Internal edges (within main.zig): main -> init, main -> handleRequest
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 2, 'calls', 1.0)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 3, 'calls', 0.9)");

    // Internal edges (within util.zig): parse -> validate
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (4, 5, 'calls', 0.8)");

    // Cross-module edges: main -> parse, init -> format (from main.zig to util.zig)
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 4, 'calls', 1.0)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (2, 6, 'calls', 0.7)");

    // Many incoming calls to validate (makes it a hotspot)
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 5, 'calls', 0.5)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (3, 5, 'calls', 0.6)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (6, 5, 'calls', 0.7)");

    return db;
}

test "arch getHotSpots returns sorted results" {
    var db = try setupArchTestGraph();
    defer db.close();

    const hotspots = try arch.getHotSpots(std.testing.allocator, &db, 5);
    defer {
        for (hotspots) |*h| h.deinit(std.testing.allocator);
        std.testing.allocator.free(hotspots);
    }

    try std.testing.expect(hotspots.len >= 1);

    // Check sorted order (first has highest total)
    if (hotspots.len >= 2) {
        try std.testing.expect(hotspots[0].total >= hotspots[1].total);
    }

    // validate should be a hotspot (many incoming)
    var found_validate = false;
    for (hotspots) |h| {
        if (std.mem.eql(u8, h.name, "validate")) found_validate = true;
    }
    try std.testing.expect(found_validate);
}

test "arch getHotSpots respects limit" {
    var db = try setupArchTestGraph();
    defer db.close();

    const hotspots = try arch.getHotSpots(std.testing.allocator, &db, 2);
    defer {
        for (hotspots) |*h| h.deinit(std.testing.allocator);
        std.testing.allocator.free(hotspots);
    }

    try std.testing.expect(hotspots.len <= 2);
}

test "arch getModuleCoupling" {
    var db = try setupArchTestGraph();
    defer db.close();

    var coupling = try arch.getModuleCoupling(&db);

    try std.testing.expect(coupling.total_edges > 0);
    try std.testing.expect(coupling.external_edges > 0); // we have cross-module edges
    try std.testing.expect(coupling.internal_edges > 0); // we have internal edges

    // coupling ratio should be between 0 and 1
    const ratio = coupling.couplingRatio();
    try std.testing.expect(ratio > 0.0);
    try std.testing.expect(ratio < 1.0);
}

test "arch getArchitecture keeps existing API" {
    var db = try setupArchTestGraph();
    defer db.close();

    var view = try arch.getArchitecture(std.testing.allocator, &db);
    defer view.deinit(std.testing.allocator);

    // Basic stats should be populated
    try std.testing.expect(view.total_files == 2);
    try std.testing.expect(view.total_symbols == 6);
    try std.testing.expect(view.total_edges == 8);
}

test "arch getModuleCoupling zero edges" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    var coupling = try arch.getModuleCoupling(&db);
    try std.testing.expectEqual(@as(u32, 0), coupling.total_edges);
    try std.testing.expectEqual(@as(u32, 0), coupling.external_edges);

    const ratio = coupling.couplingRatio();
    try std.testing.expectEqual(@as(f64, 0.0), ratio);
}
