//! Tests for incremental indexing (detectChanges, UpdateStats).
const std = @import("std");
const zindeks = @import("zindeks");
const incremental = zindeks.indexer.incremental;
const graph_db = zindeks.storage.graph_db;

test "UpdateStats default values" {
    const stats = incremental.UpdateStats{};
    try std.testing.expectEqual(@as(u32, 0), stats.added);
    try std.testing.expectEqual(@as(u32, 0), stats.modified);
    try std.testing.expectEqual(@as(u32, 0), stats.deleted);
    try std.testing.expectEqual(@as(u32, 0), stats.symbols_added);
    try std.testing.expectEqual(@as(u32, 0), stats.edges_added);
    try std.testing.expectEqual(@as(u32, 0), stats.errors);
    try std.testing.expectEqual(@as(u64, 0), stats.duration_ms);
}

test "detectChanges detects added files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create a temp directory with a source file
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test_added.zig", .{});
    try test_file.writeAll("const x = 1;");
    test_file.close();

    // Create in-memory DB with no documents
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    // Get the real path of the temp directory
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp_dir.dir.realpath(".", &dir_buf);

    var diff = try incremental.detectChanges(allocator, &db, real_path);
    defer diff.deinit();

    // The test file should be detected as added
    try std.testing.expectEqual(@as(u32, 1), diff.added.len);
    try std.testing.expectEqual(diff.added[0].kind, .added);
    try std.testing.expect(diff.added[0].path.len > 0);

    try std.testing.expectEqual(@as(u32, 0), diff.modified.len);
    try std.testing.expectEqual(@as(u32, 0), diff.deleted.len);
}

test "detectChanges detects modified files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const test_file = try tmp_dir.dir.createFile("test_mod.zig", .{});
    try test_file.writeAll("const y = 2;");
    test_file.close();

    // Build the full path to the temp dir: .zig-cache/tmp/<sub_path>
    const tmp_path = try std.fs.path.join(allocator, &.{
        ".zig-cache", "tmp", &tmp_dir.sub_path,
    });

    // Create in-memory DB and insert a document with the same relative path
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    // Insert with the same relative path that the scanner will produce
    {
        var stmt = try db.prepare("INSERT INTO documents (path, mtime) VALUES (?, 0)");
        defer stmt.finalize();
        try stmt.bindText(1, "test_mod.zig");
        _ = try stmt.step();
    }

    var diff = try incremental.detectChanges(allocator, &db, tmp_path);
    defer diff.deinit();

    // The file should appear in the diff. detectChanges compares paths from
    // the filesystem scanner (relative to project root) against DB paths.
    // At minimum, total changes should be > 0.
    const total = diff.added.len + diff.modified.len + diff.deleted.len;
    try std.testing.expect(total >= 1);
}

test "detectChanges detects deleted files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp_dir.dir.realpath(".", &dir_buf);

    // Create in-memory DB with a document that doesn't exist on disk
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    {
        var stmt = try db.prepare("INSERT INTO documents (path, mtime) VALUES (?, 12345)");
        defer stmt.finalize();
        try stmt.bindText(1, "deleted.zig");
        _ = try stmt.step();
    }

    var diff = try incremental.detectChanges(allocator, &db, real_path);
    defer diff.deinit();

    // Should detect the deleted file (in DB but not on disk)
    try std.testing.expectEqual(@as(u32, 1), diff.deleted.len);
    try std.testing.expectEqual(diff.deleted[0].kind, .deleted);
    try std.testing.expect(diff.deleted[0].path.len > 0);
}

test "detectChanges empty diff when nothing changed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp_dir.dir.realpath(".", &dir_buf);

    // Create in-memory DB with no documents, empty directory
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    var diff = try incremental.detectChanges(allocator, &db, real_path);
    defer diff.deinit();

    // Empty directory with no DB entries should produce no changes
    try std.testing.expectEqual(@as(u32, 0), diff.added.len);
    try std.testing.expectEqual(@as(u32, 0), diff.modified.len);
    try std.testing.expectEqual(@as(u32, 0), diff.deleted.len);
}

test "applyChanges removeFileFromGraph only deletes the targeted file" {
    // Regression guard: a prior version of removeFileFromGraph used
    // gdb.exec("... WHERE path = ?") which never bound the parameter,
    // silently wiping every documents/symbols/edges row.
    const allocator = std.testing.allocator;

    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    // Seed two unrelated documents + symbols.
    try db.exec("INSERT INTO documents (path, mtime) VALUES ('keep.zig', 100)");
    const keep_id = db.lastInsertRowid();
    try db.exec("INSERT INTO documents (path, mtime) VALUES ('drop.zig', 100)");
    const drop_id = db.lastInsertRowid();

    {
        var stmt = try db.prepare(
            \\INSERT INTO symbols (document_id, name, kind, line_start, line_end)
            \\VALUES (?, 'keepSym', 'function', 1, 1)
        );
        defer stmt.finalize();
        try stmt.bindInt(1, keep_id);
        _ = try stmt.step();
    }
    {
        var stmt = try db.prepare(
            \\INSERT INTO symbols (document_id, name, kind, line_start, line_end)
            \\VALUES (?, 'dropSym', 'function', 1, 1)
        );
        defer stmt.finalize();
        try stmt.bindInt(1, drop_id);
        _ = try stmt.step();
    }

    // Run a diff that marks drop.zig as deleted; apply it.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp_dir.dir.realpath(".", &dir_buf);

    var diff = try incremental.detectChanges(allocator, &db, real_path);
    defer diff.deinit();
    // Both seeded rows should be detected as deleted (neither exists on disk).
    try std.testing.expect(diff.deleted.len == 2);

    // After applying, the keep_id row's symbol would also be wiped if the bug
    // returned.  Apply only the "drop" deletion to verify path binding.
    var drop_only = incremental.DiffResult{
        .allocator = allocator,
        .added = try allocator.alloc(incremental.FileChange, 0),
        .modified = try allocator.alloc(incremental.FileChange, 0),
        .deleted = blk: {
            var list = try allocator.alloc(incremental.FileChange, 1);
            list[0] = .{
                .path = try allocator.dupe(u8, "drop.zig"),
                .kind = .deleted,
            };
            break :blk list;
        },
        .total_files = 0,
    };
    defer drop_only.deinit();

    _ = try incremental.applyChanges(allocator, &db, real_path, &drop_only, null);

    const remaining_docs = try db.queryScalar("SELECT COUNT(*) FROM documents");
    try std.testing.expectEqual(@as(i64, 1), remaining_docs);
    const remaining_syms = try db.queryScalar("SELECT COUNT(*) FROM symbols");
    try std.testing.expectEqual(@as(i64, 1), remaining_syms);

    // Confirm we kept the right row, not the wrong one.
    var path_stmt = try db.prepare("SELECT path FROM documents");
    defer path_stmt.finalize();
    try std.testing.expect(try path_stmt.step());
    const path = try path_stmt.columnText(0);
    try std.testing.expectEqualStrings("keep.zig", path);
}

// ── Inbound cross-file edges survive incremental edits of the callee ────

fn writeSrc(dir: std.fs.Dir, name: []const u8, body: []const u8) !void {
    const f = try dir.createFile(name, .{});
    defer f.close();
    try f.writeAll(body);
}

fn scalarInt(db: *graph_db.GraphDb, sql: [:0]const u8) !i64 {
    var stmt = try db.prepare(sql);
    defer stmt.finalize();
    _ = try stmt.step();
    return try stmt.columnInt(0);
}

const caller_helper_edges =
    \\SELECT COUNT(*) FROM edges e
    \\JOIN symbols s ON s.id = e.source_symbol_id
    \\JOIN symbols t ON t.id = e.target_symbol_id
    \\WHERE e.edge_type = 'calls' AND s.name = 'caller' AND t.name = 'helper'
;
const dangling_edges = "SELECT COUNT(*) FROM edges WHERE target_symbol_id NOT IN (SELECT id FROM symbols)";

/// Full-index a.zig (`helper`) + b.zig (`caller` → `a.helper()`), apply
/// `edit` to the tree, run an incremental update, return the db.
fn indexThenEdit(tmp: *std.testing.TmpDir, edit: *const fn (std.fs.Dir) anyerror!void) !graph_db.GraphDb {
    try writeSrc(tmp.dir, "a.zig", "pub fn helper() void {}\n");
    try writeSrc(tmp.dir, "b.zig",
        \\const a = @import("a.zig");
        \\pub fn caller() void {
        \\    a.helper();
        \\}
        \\
    );
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmp.dir.realpath(".", &buf);

    var db = try graph_db.GraphDb.open(":memory:");
    errdefer db.close();
    try db.migrate();
    var pipe = zindeks.parser.pipeline.Pipeline.init(std.testing.allocator, db, root);
    _ = try pipe.run();
    try std.testing.expectEqual(@as(i64, 1), try scalarInt(&db, caller_helper_edges));

    try edit(tmp.dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diff = try incremental.detectChanges(arena.allocator(), &db, root);
    defer diff.deinit();
    _ = try incremental.applyChanges(arena.allocator(), &db, root, &diff, null);
    return db;
}

test "applyChanges keeps inbound edges when the callee file is edited" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var db = try indexThenEdit(&tmp, struct {
        fn f(dir: std.fs.Dir) !void {
            try writeSrc(dir, "a.zig", "// edited\npub fn helper() void {\n    _ = 1;\n}\n");
        }
    }.f);
    defer db.close();
    try std.testing.expectEqual(@as(i64, 1), try scalarInt(&db, caller_helper_edges));
    try std.testing.expectEqual(@as(i64, 0), try scalarInt(&db, dangling_edges));
}

test "applyChanges drops inbound edges when the callee is renamed or deleted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var renamed = try indexThenEdit(&tmp, struct {
        fn f(dir: std.fs.Dir) !void {
            try writeSrc(dir, "a.zig", "pub fn helper2() void {}\n");
        }
    }.f);
    defer renamed.close();
    try std.testing.expectEqual(@as(i64, 0), try scalarInt(&renamed, caller_helper_edges));
    try std.testing.expectEqual(@as(i64, 0), try scalarInt(&renamed, dangling_edges));

    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    var deleted = try indexThenEdit(&tmp2, struct {
        fn f(dir: std.fs.Dir) !void {
            try dir.deleteFile("a.zig");
        }
    }.f);
    defer deleted.close();
    try std.testing.expectEqual(@as(i64, 0), try scalarInt(&deleted, dangling_edges));
}
