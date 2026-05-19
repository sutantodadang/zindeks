//! Integration test for the parallel indexer's graph-DB write path.
//!
//! Phase 0 regression guard: ensures ParallelIndexer.indexPaths populates
//! the documents and symbols tables in graph.db.  Before the fix, the
//! parallel pipeline silently dropped every parsed symbol.

const std = @import("std");
const zindeks = @import("zindeks");
const parallel = zindeks.indexer.parallel;
const graph_db = zindeks.storage.graph_db;

test "ParallelIndexer populates documents and symbols in graph.db" {
    const allocator = std.testing.allocator;

    var src_dir = std.testing.tmpDir(.{});
    defer src_dir.cleanup();

    const a_zig =
        \\const std = @import("std");
        \\
        \\pub fn alpha() void {}
        \\pub fn beta() void {}
        \\const C = struct { x: u32 };
        \\
    ;
    const b_zig =
        \\pub fn gamma() void {}
        \\var counter: u32 = 0;
        \\
    ;

    try src_dir.dir.writeFile(.{ .sub_path = "a.zig", .data = a_zig });
    try src_dir.dir.writeFile(.{ .sub_path = "b.zig", .data = b_zig });

    var src_buf: [std.fs.max_path_bytes]u8 = undefined;
    const src_path = try src_dir.dir.realpath(".", &src_buf);

    var store_dir = std.testing.tmpDir(.{});
    defer store_dir.cleanup();
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const store_path = try store_dir.dir.realpath(".", &store_buf);

    var idx = try parallel.ParallelIndexer.init(allocator, 2);
    defer idx.deinit(allocator);

    const paths = [_][]const u8{src_path};
    try idx.indexPaths(allocator, &paths, store_path);

    const graph_path = try std.fs.path.join(allocator, &.{ store_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);

    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();

    const doc_count = try gdb.queryScalar("SELECT COUNT(*) FROM documents");
    try std.testing.expect(doc_count >= 2);

    const sym_count = try gdb.queryScalar("SELECT COUNT(*) FROM symbols");
    try std.testing.expect(sym_count >= 3);

    const fn_count = try gdb.queryScalar("SELECT COUNT(*) FROM symbols WHERE kind = 'function'");
    try std.testing.expect(fn_count >= 3);
}
