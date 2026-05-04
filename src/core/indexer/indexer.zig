const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const symbols = @import("../../parser/symbols.zig");

pub fn indexPath(allocator: std.mem.Allocator, repo_path: []const u8, index_path: []const u8) !void {
    try std.fs.cwd().makePath(index_path);

    var writer = try storage.Writer.init(allocator, std.fs.cwd(), index_path);
    defer writer.deinit();

    const Context = struct {
        allocator: std.mem.Allocator,
        writer: *storage.Writer,

        fn onFile(self: *@This(), entry: scanner.FileEntry) !void {
            const doc_id = try self.writer.addFile(entry.path, entry.hash, entry.mtime, entry.content);
            const parsed = try symbols.parseSymbols(self.allocator, entry.content);
            defer {
                for (parsed) |sym| self.allocator.free(sym.name);
                self.allocator.free(parsed);
            }
            for (parsed) |sym| {
                if (sym.kind == .module) {
                    try self.writer.addImport(doc_id, sym.name);
                } else {
                    try self.writer.addSymbol(doc_id, sym.name, sym.kind, sym.line, sym.byte_off);
                }
            }
        }
    };

    var context = Context{ .allocator = allocator, .writer = &writer };
    try scanner.scanPathStreaming(allocator, repo_path, &context, Context.onFile);

    try writer.finish();
}

pub fn indexEntries(allocator: std.mem.Allocator, entries: []const scanner.FileEntry, index_path: []const u8) !void {
    try std.fs.cwd().makePath(index_path);

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
