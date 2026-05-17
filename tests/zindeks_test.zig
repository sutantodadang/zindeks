const std = @import("std");
const zindeks = @import("zindeks");

const testing = std.testing;

test "storage writer creates mmap-readable document, symbol, content, posting, and graph files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makeDir("idx");

    var writer = try zindeks.storage.index.Writer.init(testing.allocator, tmp.dir, "idx");
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

    var index = try zindeks.storage.index.Index.open(testing.allocator, tmp.dir, "idx");
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

    var writer = try zindeks.storage.index.Writer.init(testing.allocator, tmp.dir, "idx");
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

    var index = try zindeks.storage.index.Index.open(testing.allocator, tmp.dir, "idx");
    defer index.close();

    var engine = zindeks.search.engine.Engine.init(&index);
    var results = try engine.search(testing.allocator, "auth middleware", 4);
    defer results.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), results.items.len);
    try testing.expectEqualStrings("src/auth.zig", results.items[0].path);
    try testing.expect(std.mem.indexOf(u8, results.items[0].snippet, "authMiddleware") != null);

    const symbol = try engine.lookupSymbol("databaseConnection");
    try testing.expect(symbol != null);
    try testing.expectEqualStrings("src/db.zig", symbol.?.path);
}

test "mcp protocol parses initialize request json-rpc 2.0" {
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{},\"clientInfo\":{\"name\":\"test\",\"version\":\"1.0\"}}}";

    var req = (try zindeks.api.mcp.protocol.parseRequest(testing.allocator, raw)).?;
    defer req.deinit();

    try testing.expect(req.id != null);
    try testing.expectEqualStrings("initialize", req.method);
}

test "mcp protocol parseRequest rejects missing jsonrpc" {
    const maybe_req = zindeks.api.mcp.protocol.parseRequest(testing.allocator, "{\"id\":1,\"method\":\"ping\"}") catch @panic("unexpected error");
    try testing.expect(maybe_req == null);
}

// NOTE: writeMessage test removed — it writes to stdout which corrupts
// Zig's test-runner JSON-RPC protocol (zig test --listen=-).
// writeMessage is implicitly tested by integration tests.

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
    try zindeks.indexer.indexer.indexPath(testing.allocator, repo_abs, write_location.index_dir);
    try write_location.commit();

    var read_location = try zindeks.project_store.resolveRead(testing.allocator, repo_abs, .{ .store_root = store_abs });
    defer read_location.deinit();

    try testing.expect(!std.mem.startsWith(u8, read_location.index_dir, repo_abs));

    var index = try zindeks.storage.index.Index.open(testing.allocator, tmp.dir, read_location.index_dir);
    defer index.close();

    var engine = zindeks.search.engine.Engine.init(&index);
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

        fn onFile(self: *@This(), entry: zindeks.scanner.scanner.FileEntry) !void {
            self.count += 1;
            self.total_bytes += entry.content.len;
            try testing.expectEqualStrings("one.zig", entry.path);
        }
    };

    var context = Context{};
    try zindeks.scanner.scanner.scanPathStreaming(testing.allocator, root_abs, &context, Context.onFile);

    try testing.expectEqual(@as(usize, 1), context.count);
    try testing.expect(context.total_bytes > 0);
}

test "zig extractor extracts functions and types from source" {
    const source =
        \\const std = @import("std");
        \\
        \\pub fn main() !void {
        \\    std.debug.print("hello\n", .{});
        \\}
        \\
        \\const MyStruct = struct {
        \\    x: u32,
        \\
        \\    pub fn method(self: *MyStruct) void {
        \\        _ = self;
        \\    }
        \\};
        \\
        \\const MyEnum = enum { a, b, c };
        \\
        \\var global_var: u32 = 42;
    ;

    const result = try zindeks.parser.zig_extractor.extract(testing.allocator, source, .zig);
    defer {
        var mut_result = result;
        mut_result.deinit(testing.allocator);
    }

    // Should find: main, MyStruct, MyEnum, method, global_var, + @import edge
    try testing.expect(result.symbols.len >= 4); // main, MyStruct, MyEnum, global_var at minimum
    try testing.expect(result.edges.len >= 1); // at least one @import edge

    // Check for specific symbols
    var found_main = false;
    var found_struct = false;
    var found_enum = false;
    for (result.symbols) |sym| {
        if (std.mem.eql(u8, sym.name, "main") and sym.kind == .function) found_main = true;
        if (std.mem.eql(u8, sym.name, "MyStruct") and sym.kind == .struct_type) found_struct = true;
        if (std.mem.eql(u8, sym.name, "MyEnum") and sym.kind == .enum_type) found_enum = true;
    }
    try testing.expect(found_main);
    try testing.expect(found_struct);
    try testing.expect(found_enum);
}
