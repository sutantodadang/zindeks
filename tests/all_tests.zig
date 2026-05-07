// Single test entry point — includes all tests.
// All tests now require SQLite + tree-sitter C libraries linked.
test {
    _ = @import("zindeks");
    _ = @import("zindeks_test.zig");
    _ = @import("graph_db_test.zig");
}
