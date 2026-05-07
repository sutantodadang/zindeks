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
    try std.testing.expectEqual(@as(i64, 5), tables);
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
