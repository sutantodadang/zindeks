const std = @import("std");
const zindeks = @import("zindeks");

const testing = std.testing;

test "storage writer creates mmap-readable document, symbol, content, posting, and graph files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("idx");

    var writer = try zindeks.storage.Writer.init(testing.allocator, tmp.dir, "idx");
    defer writer.deinit();

    const doc_id = try writer.addFile(
        "src/auth.zig",
        0x12345678,
        42,
        "const std = @import(\"std\");\npub fn loginMiddleware() void {}\n",
    );
    try writer.addSymbol(doc_id, "loginMiddleware", .function, 1, 7);
    try writer.addImport(doc_id, "std");
    try writer.finish();

    var index = try zindeks.storage.Index.open(testing.allocator, tmp.dir, "idx");
    defer index.close();

    try testing.expectEqual(@as(u32, 1), index.docCount());
    try testing.expectEqualStrings("src/auth.zig", index.filePath(doc_id));
    try testing.expect(std.mem.indexOf(u8, index.fileContent(doc_id), "loginMiddleware") != null);

    const symbols = index.symbolsForDoc(doc_id);
    try testing.expectEqual(@as(usize, 1), symbols.len);
    try testing.expectEqualStrings("loginMiddleware", index.stringAt(symbols[0].name_sid));

    const postings = index.postingsForTerm("loginmiddleware");
    try testing.expectEqual(@as(usize, 1), postings.len);
    try testing.expectEqual(doc_id, postings[0].doc_id);

    const imports = index.importsForDoc(doc_id);
    try testing.expectEqual(@as(usize, 1), imports.len);
    try testing.expectEqualStrings("std", index.stringAt(imports[0].target_sid));
}

test "search ranks keyword hits and returns deterministic context" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("idx");

    var writer = try zindeks.storage.Writer.init(testing.allocator, tmp.dir, "idx");
    defer writer.deinit();

    const auth_doc = try writer.addFile(
        "src/auth.zig",
        1,
        10,
        "pub fn authMiddleware() void { validateSession(); }\n",
    );
    try writer.addSymbol(auth_doc, "authMiddleware", .function, 0, 7);

    const db_doc = try writer.addFile(
        "src/db.zig",
        2,
        10,
        "pub fn databaseConnection() void {}\n",
    );
    try writer.addSymbol(db_doc, "databaseConnection", .function, 0, 7);
    try writer.finish();

    var index = try zindeks.storage.Index.open(testing.allocator, tmp.dir, "idx");
    defer index.close();

    var engine = zindeks.search.Engine.init(&index);
    var results = try engine.search(testing.allocator, "auth middleware", 4);
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("src/auth.zig", results.items[0].path);
    try testing.expect(std.mem.indexOf(u8, results.items[0].snippet, "authMiddleware") != null);

    const symbol = try engine.lookupSymbol("databaseConnection");
    try testing.expect(symbol != null);
    try testing.expectEqualStrings("src/db.zig", symbol.?.path);
}

test "mcp server handles JSON-RPC search and get_context deterministically" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("idx");

    var writer = try zindeks.storage.Writer.init(testing.allocator, tmp.dir, "idx");
    defer writer.deinit();

    const doc_id = try writer.addFile(
        "src/main.zig",
        3,
        12,
        "pub fn main() void { authMiddleware(); }\npub fn authMiddleware() void {}\n",
    );
    try writer.addSymbol(doc_id, "main", .function, 0, 7);
    try writer.addSymbol(doc_id, "authMiddleware", .function, 1, 7);
    try writer.finish();

    var index = try zindeks.storage.Index.open(testing.allocator, tmp.dir, "idx");
    defer index.close();

    var engine = zindeks.search.Engine.init(&index);

    var response: std.ArrayList(u8) = .{};
    defer response.deinit(testing.allocator);

    try zindeks.api.mcp.handleRequest(
        testing.allocator,
        &engine,
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"search\",\"params\":{\"query\":\"auth middleware\",\"limit\":5}}",
        response.writer(testing.allocator),
    );

    try testing.expect(std.mem.indexOf(u8, response.items, "\"jsonrpc\":\"2.0\"") != null);
    try testing.expect(std.mem.indexOf(u8, response.items, "\"src/main.zig\"") != null);
    try testing.expect(std.mem.indexOf(u8, response.items, "\"authMiddleware\"") != null);

    response.clearRetainingCapacity();
    try zindeks.api.mcp.handleRequest(
        testing.allocator,
        &engine,
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"get_context\",\"params\":{\"query\":\"auth\",\"limit\":1}}",
        response.writer(testing.allocator),
    );

    try testing.expect(std.mem.indexOf(u8, response.items, "\"symbols\"") != null);
    try testing.expect(std.mem.indexOf(u8, response.items, "\"authMiddleware\"") != null);
}

test "project store writes current segment outside the project tree" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("repo");
    try tmp.dir.makeDir("store");
    {
        var repo = try tmp.dir.openDir("repo", .{});
        defer repo.close();
        try repo.writeFile(.{ .sub_path = "main.zig", .data = "pub fn globalIndexSearch() void {}\n" });
    }

    const repo_abs = try tmp.dir.realpathAlloc(testing.allocator, "repo");
    defer testing.allocator.free(repo_abs);
    const store_abs = try tmp.dir.realpathAlloc(testing.allocator, "store");
    defer testing.allocator.free(store_abs);

    var write_location = try zindeks.project_store.prepareWrite(testing.allocator, repo_abs, .{ .store_root = store_abs });
    defer write_location.deinit();
    try zindeks.indexer.indexPath(testing.allocator, repo_abs, write_location.index_dir);
    try write_location.commit();

    var read_location = try zindeks.project_store.resolveRead(testing.allocator, repo_abs, .{ .store_root = store_abs });
    defer read_location.deinit();

    try testing.expect(!std.mem.startsWith(u8, read_location.index_dir, repo_abs));

    var index = try zindeks.storage.Index.open(testing.allocator, tmp.dir, read_location.index_dir);
    defer index.close();

    var engine = zindeks.search.Engine.init(&index);
    var results = try engine.search(testing.allocator, "global index search", 5);
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("main.zig", results.items[0].path);
}

test "streaming scanner releases file buffers after callback" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "one.zig", .data = "pub fn oneToken() void {}\n" });
    try tmp.dir.writeFile(.{ .sub_path = "two.txt", .data = "ignored\n" });

    const root_abs = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root_abs);

    const Context = struct {
        count: usize = 0,
        total_bytes: usize = 0,

        fn onFile(self: *@This(), entry: zindeks.scanner.FileEntry) !void {
            self.count += 1;
            self.total_bytes += entry.content.len;
            try testing.expectEqualStrings("one.zig", entry.path);
        }
    };

    var context = Context{};
    try zindeks.scanner.scanPathStreaming(testing.allocator, root_abs, &context, Context.onFile);

    try testing.expectEqual(@as(usize, 1), context.count);
    try testing.expect(context.total_bytes > 0);
}
