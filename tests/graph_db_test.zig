//! Integration tests for the graph database (SQLite-backed).
const std = @import("std");
const graph_db = @import("zindeks").storage.graph_db;

test "graph_db open and migrate" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    const tables = try db.queryScalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    try std.testing.expectEqual(@as(i64, 6), tables);
}

test "graph_db insert document" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('src/main.zig', 'Zig')");

    var stmt = try db.prepare("SELECT path, language FROM documents WHERE id = 1");
    defer stmt.finalize();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("src/main.zig", try stmt.columnText(0));
    try std.testing.expectEqualStrings("Zig", try stmt.columnText(1));
}

test "graph_db insert symbol" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('lib.zig', 'Zig')");
    _ = db.lastInsertRowid();

    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'foo', 'function', 5, 12)");
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowid());
}

test "graph_db insert edge" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('mod.zig', 'Zig')");
    _ = db.lastInsertRowid();
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'main', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'init', 'function', 15, 20)");

    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 2, 'CALLS', 0.95)");

    var stmt = try db.prepare(
        \\SELECT e.edge_type, e.confidence, s.name
        \\FROM edges e JOIN symbols s ON s.id = e.target_symbol_id
        \\WHERE e.source_symbol_id = 1
    );
    defer stmt.finalize();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("CALLS", try stmt.columnText(0));
    try std.testing.expectApproxEqRel(@as(f64, 0.95), try stmt.columnFloat(1), 0.001);
    try std.testing.expectEqualStrings("init", try stmt.columnText(2));
}

test "graph_db kind boost from string" {
    try std.testing.expectApproxEqRel(@as(f32, 1.30), graph_db.kindBoostFromString("function"), 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 1.20), graph_db.kindBoostFromString("struct_type"), 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 1.10), graph_db.kindBoostFromString("const_value"), 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 1.00), graph_db.kindBoostFromString("variable"), 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 0.80), graph_db.kindBoostFromString("unknown"), 0.001);
}

test "graph_db find kind boosts" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('a.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('b.zig', 'Zig')");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'parseFile', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'parseFile', 'variable', 1, 5)");

    var boosts = try db.findKindBoosts("%parseFile%", std.testing.allocator);
    defer boosts.deinit();

    try std.testing.expectEqual(@as(usize, 2), boosts.count());
    try std.testing.expectApproxEqRel(@as(f32, 1.30), boosts.get(1).?, 0.001);
    try std.testing.expectApproxEqRel(@as(f32, 1.00), boosts.get(2).?, 0.001);
}

test "graph_db find related documents" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('main.zig', 'Zig')");
    try db.exec("INSERT INTO documents (path, language) VALUES ('lib.zig', 'Zig')");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (1, 'main', 'function', 1, 10)");
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (2, 'init', 'function', 1, 10)");
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES (1, 2, 'CALLS', 0.95)");

    var related = try db.findRelatedDocuments("%main%", 0.3, std.testing.allocator);
    defer related.deinit();

    try std.testing.expectEqual(@as(usize, 1), related.count());
    try std.testing.expectApproxEqRel(@as(f32, 0.95), related.get(2).?, 0.001);
}
