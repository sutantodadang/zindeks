const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const symbols = @import("../../parser/symbols.zig");
const embeddings = @import("../search/embeddings.zig");
const graph_db = @import("../storage/graph_db.zig");
const parallel = @import("parallel.zig");

pub fn indexPath(allocator: std.mem.Allocator, repo_path: []const u8, index_path: []const u8) !void {
    try std.fs.cwd().makePath(index_path);

    var writer = try storage.Writer.init(allocator, std.fs.cwd(), index_path);
    defer writer.deinit();

    // Open graph DB for embedding storage
    const graph_path = try std.fs.path.join(allocator, &.{ index_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);
    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();
    try gdb.migrate();

    const Context = struct {
        allocator: std.mem.Allocator,
        writer: *storage.Writer,
        gdb: *graph_db.GraphDb,
        stream: ?storage.Writer.StreamHandle = null,

        fn onEvent(self: *@This(), event: scanner.ChunkEvent) !void {
            switch (event) {
                .file => |entry| try self.handleSmallFile(entry),
                .begin => |b| {
                    self.stream = try self.writer.beginStreamFile(b.path, b.mtime);
                },
                .chunk => |bytes| {
                    try self.writer.appendStreamChunk(&self.stream.?, bytes);
                },
                .end => {
                    try self.writer.endStreamFile(&self.stream.?);
                    self.stream = null;
                    // Streamed (large) files are token-indexed only — no
                    // symbol or embedding pass.  Symbol extraction operates
                    // on full file content, which would defeat the streaming
                    // memory budget, and these files are usually generated
                    // or vendored where symbol-level navigation is low value.
                },
            }
        }

        fn handleSmallFile(self: *@This(), entry: scanner.FileEntry) !void {
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
            generateEmbedding(self.allocator, self.gdb, @intCast(doc_id), entry, parsed) catch {};
        }
    };

    var context = Context{ .allocator = allocator, .writer = &writer, .gdb = &gdb };
    try scanner.scanPathChunked(allocator, repo_path, &context, Context.onEvent);

    try writer.finish();
}

pub fn indexEntries(allocator: std.mem.Allocator, entries: []const scanner.FileEntry, index_path: []const u8) !void {
    try std.fs.cwd().makePath(index_path);

    var writer = try storage.Writer.init(allocator, std.fs.cwd(), index_path);
    defer writer.deinit();

    // Open graph DB for embedding storage
    const graph_path = try std.fs.path.join(allocator, &.{ index_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);
    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();
    try gdb.migrate();

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

        // Generate and store document embedding
        generateEmbedding(allocator, &gdb, @intCast(doc_id), entry, parsed) catch {};
    }

    try writer.finish();
}

/// Index a repository using the parallel worker pool.
/// Falls back to sequential indexPath() if thread_count is 1.
pub fn indexParallel(
    allocator: std.mem.Allocator,
    repo_path: []const u8,
    index_path: []const u8,
    thread_count: usize,
) !void {
    if (thread_count <= 1) {
        return indexPath(allocator, repo_path, index_path);
    }

    var idx = try parallel.ParallelIndexer.init(allocator, thread_count);
    defer idx.deinit(allocator);

    const paths = [_][]const u8{repo_path};
    try idx.indexPaths(allocator, &paths, index_path);
}

/// Generate an embedding for a document and store it in the graph database.
/// The document must have been inserted into the documents table first
/// (typically by the pipeline). Falls back silently on failure.
fn generateEmbedding(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    _: i64,
    entry: scanner.FileEntry,
    parsed: []const symbols.ParsedSymbol,
) !void {
    // Collect symbol names
    var symbol_names = try std.ArrayList([]const u8).initCapacity(allocator, 0);
    defer symbol_names.deinit(allocator);
    for (parsed) |sym| {
        if (sym.kind != .module) {
            try symbol_names.append(allocator, sym.name);
        }
    }

    // Extract comments (simple heuristic: lines starting with // or /*)
    var comments_buf: [4096]u8 = undefined;
    var comments_len: usize = 0;
    var line_it = std.mem.splitScalar(u8, entry.content, '\n');
    while (line_it.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//") or std.mem.startsWith(u8, trimmed, "/*") or std.mem.startsWith(u8, trimmed, "*")) {
            const remaining = comments_buf.len - comments_len;
            if (remaining > trimmed.len + 1) {
                @memcpy(comments_buf[comments_len..][0..trimmed.len], trimmed);
                comments_len += trimmed.len;
                comments_buf[comments_len] = ' ';
                comments_len += 1;
            }
        }
    }

    // Extract code tokens (non-comment, non-string alphanumeric tokens)
    var code_tokens_buf: [4096]u8 = undefined;
    var code_tokens_len: usize = 0;
    for (entry.content) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            if (code_tokens_len < code_tokens_buf.len) {
                code_tokens_buf[code_tokens_len] = std.ascii.toLower(c);
                code_tokens_len += 1;
            }
        } else if (code_tokens_len > 0 and code_tokens_buf[code_tokens_len - 1] != ' ') {
            if (code_tokens_len < code_tokens_buf.len) {
                code_tokens_buf[code_tokens_len] = ' ';
                code_tokens_len += 1;
            }
        }
    }

    // Generate document embedding
    const emb = embeddings.embedDocument(
        symbol_names.items,
        comments_buf[0..comments_len],
        code_tokens_buf[0..code_tokens_len],
    );

    // Find the document record in the graph DB to get the correct document_id
    // The document_id from the binary index is different from SQLite's autoincrement id
    // We need to insert into documents table first, or look up by path
    const path_z = try allocator.dupeZ(u8, entry.path);
    defer allocator.free(path_z);

    var find_stmt = try gdb.prepare(
        "SELECT id FROM documents WHERE path = ?",
    );
    defer find_stmt.finalize();
    try find_stmt.bindText(1, entry.path);

    const graph_doc_id: i64 = if (try find_stmt.step())
        try find_stmt.columnInt(0)
    else blk: {
        // Document not yet in graph DB — insert it
        var ins_stmt = try gdb.prepare(
            "INSERT INTO documents (path, content_hash, mtime) VALUES (?, ?, ?)",
        );
        defer ins_stmt.finalize();
        try ins_stmt.bindText(1, entry.path);
        try ins_stmt.bindInt(2, @bitCast(entry.hash));
        try ins_stmt.bindInt(3, entry.mtime);
        _ = try ins_stmt.step();
        break :blk gdb.lastInsertRowid();
    };

    // Remove old embeddings if re-indexing
    gdb.deleteEmbeddings(graph_doc_id) catch {};

    // Serialize and store
    const vec_bytes = emb.asBytes();
    try gdb.insertEmbedding(graph_doc_id, vec_bytes, @intCast(emb.dim), "fasttext-subword-384");
}
