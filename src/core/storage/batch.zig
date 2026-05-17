//! Batch inserter for bulk SQLite writes.
//!
//! Buffers symbol, document, edge, and embedding entries and flushes them
//! in batched INSERT statements inside a transaction.  Reduces SQLite
//! prepare/bind/step round-trips by up to 1000x compared to row-at-a-time.

const std = @import("std");
const GraphDb = @import("graph_db.zig").GraphDb;

/// A single symbol entry for batch insertion.
pub const SymbolEntry = struct {
    document_id: i64,
    name: []const u8,
    kind: []const u8,
    line_start: i64,
    line_end: i64,
    col_start: i64,
    col_end: i64,
    parent_symbol_id: ?i64,
};

/// A single document entry for batch insertion.
pub const DocumentEntry = struct {
    path: []const u8,
    content_hash: ?[]const u8,
    language: ?[]const u8,
    mtime: ?i64,
};

/// A single edge entry for batch insertion.
pub const EdgeEntry = struct {
    source_symbol_id: i64,
    target_symbol_id: i64,
    edge_type: []const u8,
    confidence: f64,
};

/// A single embedding entry for batch insertion.
pub const EmbeddingEntry = struct {
    document_id: i64,
    vector: []const u8,
    dimensions: u32,
    model_name: []const u8,
};

pub const BatchInserter = struct {
    db: *GraphDb,
    symbols: std.ArrayList(SymbolEntry),
    documents: std.ArrayList(DocumentEntry),
    edges: std.ArrayList(EdgeEntry),
    embeddings: std.ArrayList(EmbeddingEntry),
    batch_size: usize,

    pub fn init(allocator: std.mem.Allocator, db: *GraphDb, batch_size: usize) BatchInserter {
        _ = allocator;
        return .{
            .db = db,
            .symbols = .{},
            .documents = .{},
            .edges = .{},
            .embeddings = .{},
            .batch_size = batch_size,
        };
    }

    pub fn deinit(self: *BatchInserter, allocator: std.mem.Allocator) void {
        self.symbols.deinit(allocator);
        self.documents.deinit(allocator);
        self.edges.deinit(allocator);
        self.embeddings.deinit(allocator);
    }

    pub fn addSymbol(self: *BatchInserter, allocator: std.mem.Allocator, entry: SymbolEntry) !void {
        try self.symbols.append(allocator, entry);
        if (self.symbols.items.len >= self.batch_size) {
            try self.flush(allocator);
        }
    }

    pub fn addDocument(self: *BatchInserter, allocator: std.mem.Allocator, entry: DocumentEntry) !void {
        try self.documents.append(allocator, entry);
        if (self.documents.items.len >= self.batch_size) {
            try self.flush(allocator);
        }
    }

    pub fn addEdge(self: *BatchInserter, allocator: std.mem.Allocator, entry: EdgeEntry) !void {
        try self.edges.append(allocator, entry);
        if (self.edges.items.len >= self.batch_size) {
            try self.flush(allocator);
        }
    }

    pub fn addEmbedding(self: *BatchInserter, allocator: std.mem.Allocator, entry: EmbeddingEntry) !void {
        try self.embeddings.append(allocator, entry);
        if (self.embeddings.items.len >= self.batch_size) {
            try self.flush(allocator);
        }
    }

    /// Flush all buffered entries in a single transaction.
    /// Uses multi-row INSERT syntax for each table.
    pub fn flush(self: *BatchInserter, allocator: std.mem.Allocator) !void {
        _ = allocator;

        // BEGIN TRANSACTION
        try self.db.exec("BEGIN TRANSACTION");

        // Flush documents
        if (self.documents.items.len > 0) {
            try self.flushDocuments();
            self.documents.clearRetainingCapacity();
        }

        // Flush symbols
        if (self.symbols.items.len > 0) {
            try self.flushSymbols();
            self.symbols.clearRetainingCapacity();
        }

        // Flush edges
        if (self.edges.items.len > 0) {
            try self.flushEdges();
            self.edges.clearRetainingCapacity();
        }

        // Flush embeddings
        if (self.embeddings.items.len > 0) {
            try self.flushEmbeddings();
            self.embeddings.clearRetainingCapacity();
        }

        // COMMIT
        try self.db.exec("COMMIT");
    }

    /// Execute a null-terminated SQL string built in a fixed buffer.
    fn execBuf(self: *BatchInserter, buf: []u8, len: usize) !void {
        // Ensure null termination
        if (len < buf.len) {
            buf[len] = 0;
            try self.db.exec(buf[0..len :0]);
        }
    }

    fn flushDocuments(self: *BatchInserter) !void {
        const sql = "INSERT INTO documents (path, content_hash, language, mtime) VALUES ";
        var buf: [4096]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();
        try writer.writeAll(sql);

        for (self.documents.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.writeAll("(");
            try insertQuoted(writer, entry.path);
            try writer.writeAll(", ");
            try insertMaybeQuoted(writer, entry.content_hash);
            try writer.writeAll(", ");
            try insertMaybeQuoted(writer, entry.language);
            try writer.writeAll(", ");
            try insertMaybeInt(writer, entry.mtime);
            try writer.writeAll(")");
        }

        try self.execBuf(&buf, buf_stream.pos);
    }

    fn flushSymbols(self: *BatchInserter) !void {
        const sql = "INSERT INTO symbols (document_id, name, kind, line_start, line_end, col_start, col_end, parent_symbol_id) VALUES ";
        var buf: [16384]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();
        try writer.writeAll(sql);

        for (self.symbols.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("({d}, ", .{entry.document_id});
            try insertQuoted(writer, entry.name);
            try writer.writeAll(", ");
            try insertQuoted(writer, entry.kind);
            try writer.print(", {d}, {d}, {d}, {d}, ", .{
                entry.line_start,
                entry.line_end,
                entry.col_start,
                entry.col_end,
            });
            try insertMaybeInt(writer, entry.parent_symbol_id);
            try writer.writeAll(")");
        }

        try self.execBuf(&buf, buf_stream.pos);
    }

    fn flushEdges(self: *BatchInserter) !void {
        const sql = "INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence) VALUES ";
        var buf: [4096]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();
        try writer.writeAll(sql);

        for (self.edges.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("({d}, {d}, ", .{ entry.source_symbol_id, entry.target_symbol_id });
            try insertQuoted(writer, entry.edge_type);
            try writer.print(", {d})", .{entry.confidence});
        }

        try self.execBuf(&buf, buf_stream.pos);
    }

    fn flushEmbeddings(self: *BatchInserter) !void {
        const sql = "INSERT INTO document_embeddings (document_id, vector, dimensions, model_name) VALUES ";
        var buf: [16384]u8 = undefined;
        var buf_stream = std.io.fixedBufferStream(&buf);
        const writer = buf_stream.writer();
        try writer.writeAll(sql);

        for (self.embeddings.items, 0..) |entry, i| {
            if (i > 0) try writer.writeAll(", ");
            try writer.print("({d}, X'", .{entry.document_id});
            for (entry.vector) |byte| {
                try writer.print("{x:0>2}", .{byte});
            }
            try writer.print("', {d}, ", .{entry.dimensions});
            try insertQuoted(writer, entry.model_name);
            try writer.writeAll(")");
        }

        try self.execBuf(&buf, buf_stream.pos);
    }
};

/// Write a quoted SQL string (single-quote escaped).
fn insertQuoted(writer: anytype, value: []const u8) !void {
    try writer.writeAll("'");
    for (value) |c| {
        if (c == '\'') try writer.writeAll("''") else try writer.writeByte(c);
    }
    try writer.writeAll("'");
}

/// Write NULL or a quoted string.
fn insertMaybeQuoted(writer: anytype, value: ?[]const u8) !void {
    if (value) |v| {
        try insertQuoted(writer, v);
    } else {
        try writer.writeAll("NULL");
    }
}

/// Write NULL or an integer.
fn insertMaybeInt(writer: anytype, value: ?i64) !void {
    if (value) |v| {
        try writer.print("{d}", .{v});
    } else {
        try writer.writeAll("NULL");
    }
}
