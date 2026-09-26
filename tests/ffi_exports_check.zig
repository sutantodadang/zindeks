//! Platform export check for the embedded shared library.
//!
//! `zig build ffi-exports` builds this, passes the freshly built library path
//! as argv[1], and asserts that exactly the ABI-1 symbols are reachable while
//! SQLite / tree-sitter / grammar symbols are not.  This is the explicit check
//! that the shared library isolates vendored symbols rather than assuming the
//! platform linker does.

const std = @import("std");

const required = [_][*:0]const u8{
    "zindeks_abi_version",
    "zindeks_open",
    "zindeks_request",
    "zindeks_buffer_free",
    "zindeks_close",
};

const forbidden = [_][*:0]const u8{
    "sqlite3_open",
    "sqlite3_libversion",
    "sqlite3_exec",
    "ts_parser_new",
    "ts_parser_delete",
    "tree_sitter_zig",
    "tree_sitter_c",
    "tree_sitter_python",
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);
    if (argv.len < 2) {
        std.debug.print("usage: ffi_exports_check <path-to-library>\n", .{});
        std.process.exit(2);
    }
    const lib_path = argv[1];

    var lib = try std.DynLib.open(lib_path);
    defer lib.close();

    var failures: usize = 0;
    for (required) |name| {
        if (lib.lookup(*anyopaque, std.mem.span(name)) == null) {
            std.debug.print("MISSING required export: {s}\n", .{name});
            failures += 1;
        }
    }
    for (forbidden) |name| {
        if (lib.lookup(*anyopaque, std.mem.span(name)) != null) {
            std.debug.print("FORBIDDEN export leaked: {s}\n", .{name});
            failures += 1;
        }
    }

    if (failures != 0) {
        std.debug.print("ffi_exports_check: {d} failure(s)\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("ffi_exports_check: OK ({s})\n", .{lib_path});
}
