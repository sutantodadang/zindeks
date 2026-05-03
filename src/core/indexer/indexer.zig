const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const symbols = @import("../../parser/symbols.zig");

pub fn indexPath(allocator: std.mem.Allocator, repo_path: []const u8, index_path: []const u8) !void {
    std.fs.cwd().makeDir(index_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const entries = try scanner.scanPath(allocator, repo_path);
    defer scanner.freeEntries(allocator, entries);

    var writer = try storage.Writer.init(allocator, std.fs.cwd(), index_path);
    defer writer.deinit();

    for (entries) |entry| {
        const doc_id = try writer.addFile(entry.path, entry.hash, entry.mtime, entry.content);
        const parsed = try symbols.parseSymbols(allocator, entry.content);
        defer {
            for (parsed) |sym| allocator.free(sym.name);
            allocator.free(parsed);
        }
        for (parsed) |sym| {
            if (sym.kind == .module) {
                try writer.addImport(doc_id, sym.name);
            } else {
                try writer.addSymbol(doc_id, sym.name, sym.kind, sym.line, sym.byte_off);
            }
        }
    }

    try writer.finish();
}
