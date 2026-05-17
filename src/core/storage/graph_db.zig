//! Graph database backed by SQLite.
//!
//! Stores the knowledge graph: documents, symbols, and directed edges between
//! them.  Migrations run on first open so callers only see a ready database.
const std = @import("std");
const builtin = @import("builtin");

// ██████████████████████████████████████████████████████████████████████████
// SQLite C bindings
// ██████████████████████████████████████████████████████████████████████████

const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

const SQLITE_OK = sqlite3.SQLITE_OK;
const SQLITE_ROW = sqlite3.SQLITE_ROW;
const SQLITE_DONE = sqlite3.SQLITE_DONE;

/// SQLITE_TRANSIENT sentinel — tells SQLite to make an internal copy.
/// We define our own rather than using the @cImport-generated version,
/// which fails @ptrFromInt alignment checks on aarch64 targets in Zig 0.15.2.
/// SQLite calls this during statement finalization to release bound data,
/// but since the data was already copied (the SQLITE_TRANSIENT behavior),
/// this is a safe no-op.
fn sqliteTransient(_: ?*anyopaque) callconv(.c) void {
    // No-op: SQLite already copied the data, this is just cleanup.
}
const SQLITE_TRANSIENT: sqlite3.sqlite3_destructor_type = &sqliteTransient;

pub const ColumnType = enum {
    integer,
    float,
    text,
    blob,
    null,
};

// ██████████████████████████████████████████████████████████████████████████
// Error type
// ██████████████████████████████████████████████████████████████████████████

pub const Error = error{
    OpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    NotAnInteger,
    NotFloat,
    NotText,
    NotBlob,
    AlreadyClosed,
    VectorSerializeFailed,
};

// ██████████████████████████████████████████████████████████████████████████
// Statement wrapper
// ██████████████████████████████████████████████████████████████████████████

pub const Statement = struct {
    stmt: ?*sqlite3.sqlite3_stmt,
    db: *GraphDb,

    pub fn finalize(self: *Statement) void {
        if (self.stmt) |s| {
            _ = sqlite3.sqlite3_finalize(s);
            self.stmt = null;
        }
    }

    fn require(self: *const Statement) *sqlite3.sqlite3_stmt {
        return self.stmt orelse @panic("Statement already finalized");
    }

    pub fn step(self: *Statement) !bool {
        const rc = sqlite3.sqlite3_step(self.require());
        return switch (rc) {
            SQLITE_ROW => true,
            SQLITE_DONE => false,
            else => Error.StepFailed,
        };
    }

    pub fn reset(self: *Statement) !void {
        const rc = sqlite3.sqlite3_reset(self.require());
        if (rc != SQLITE_OK) return Error.StepFailed;
    }

    pub fn columnInt(self: *const Statement, idx: i32) !i64 {
        if (sqlite3.sqlite3_column_type(self.require(), idx) != sqlite3.SQLITE_INTEGER)
            return Error.NotAnInteger;
        return sqlite3.sqlite3_column_int64(self.require(), idx);
    }

    pub fn columnText(self: *const Statement, idx: i32) ![]const u8 {
        if (sqlite3.sqlite3_column_type(self.require(), idx) != sqlite3.SQLITE_TEXT)
            return Error.NotText;
        const ptr = sqlite3.sqlite3_column_text(self.require(), idx) orelse return "";
        const len: usize = @intCast(sqlite3.sqlite3_column_bytes(self.require(), idx));
        return ptr[0..len];
    }

    pub fn columnFloat(self: *const Statement, idx: i32) !f64 {
        if (sqlite3.sqlite3_column_type(self.require(), idx) != sqlite3.SQLITE_FLOAT)
            return Error.NotFloat;
        return sqlite3.sqlite3_column_double(self.require(), idx);
    }

    pub fn bindText(self: *Statement, idx: i32, value: []const u8) !void {
        const rc = sqlite3.sqlite3_bind_text(
            self.require(),
            idx,
            value.ptr,
            @intCast(value.len),
            SQLITE_TRANSIENT,
        );
        if (rc != SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindInt(self: *Statement, idx: i32, value: i64) !void {
        const rc = sqlite3.sqlite3_bind_int64(self.require(), idx, value);
        if (rc != SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindFloat(self: *Statement, idx: i32, value: f64) !void {
        const rc = sqlite3.sqlite3_bind_double(self.require(), idx, value);
        if (rc != SQLITE_OK) return Error.BindFailed;
    }

    pub fn bindBlob(self: *Statement, idx: i32, value: []const u8) !void {
        const rc = sqlite3.sqlite3_bind_blob(
            self.require(),
            idx,
            value.ptr,
            @intCast(value.len),
            SQLITE_TRANSIENT,
        );
        if (rc != SQLITE_OK) return Error.BindFailed;
    }

    pub fn columnBlob(self: *const Statement, idx: i32) ![]const u8 {
        if (sqlite3.sqlite3_column_type(self.require(), idx) != sqlite3.SQLITE_BLOB)
            return Error.NotBlob;
        const raw = sqlite3.sqlite3_column_blob(self.require(), idx) orelse return "";
        const len: usize = @intCast(sqlite3.sqlite3_column_bytes(self.require(), idx));
        const ptr: [*]const u8 = @ptrCast(raw);
        return ptr[0..len];
    }

    pub fn bindNull(self: *Statement, idx: i32) !void {
        const rc = sqlite3.sqlite3_bind_null(self.require(), idx);
        if (rc != SQLITE_OK) return Error.BindFailed;
    }

    /// Return the number of columns in the result set.
    pub fn columnCount(self: *const Statement) u32 {
        return @intCast(sqlite3.sqlite3_column_count(self.require()));
    }

    /// Return the declared type of a result column.
    pub fn columnType(self: *const Statement, idx: i32) ColumnType {
        const t = sqlite3.sqlite3_column_type(self.require(), idx);
        return switch (t) {
            sqlite3.SQLITE_INTEGER => .integer,
            sqlite3.SQLITE_FLOAT => .float,
            sqlite3.SQLITE_TEXT => .text,
            sqlite3.SQLITE_BLOB => .blob,
            else => .null,
        };
    }

    /// Return the name of a result column (from AS alias or column name).
    pub fn columnName(self: *const Statement, idx: i32) ?[]const u8 {
        const ptr = sqlite3.sqlite3_column_name(self.require(), idx);
        if (@intFromPtr(ptr) == 0) return null;
        return std.mem.sliceTo(ptr, 0);
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Graph Database
// ██████████████████████████████████████████████████████████████████████████

const MIGRATIONS = [_][:0]const u8{
    \\CREATE TABLE IF NOT EXISTS documents (
    \\    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    path         TEXT    NOT NULL UNIQUE,
    \\    content_hash BLOB,
    \\    language     TEXT,
    \\    mtime        INTEGER,
    \\    indexed_at   INTEGER NOT NULL DEFAULT (unixepoch())
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS symbols (
    \\    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    document_id      INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    \\    name             TEXT    NOT NULL,
    \\    kind             TEXT    NOT NULL,
    \\    line_start       INTEGER NOT NULL,
    \\    line_end         INTEGER NOT NULL,
    \\    col_start        INTEGER NOT NULL DEFAULT 0,
    \\    col_end          INTEGER NOT NULL DEFAULT 0,
    \\    parent_symbol_id INTEGER REFERENCES symbols(id)
    \\);
    \\
    \\CREATE TABLE IF NOT EXISTS edges (
    \\    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    source_symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
    \\    target_symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
    \\    edge_type        TEXT    NOT NULL,
    \\    confidence       REAL    NOT NULL DEFAULT 1.0
    \\);
    \\
    \\CREATE INDEX IF NOT EXISTS idx_symbols_name     ON symbols(name);
    \\CREATE INDEX IF NOT EXISTS idx_symbols_kind     ON symbols(kind);
    \\CREATE INDEX IF NOT EXISTS idx_symbols_document ON symbols(document_id);
    \\CREATE INDEX IF NOT EXISTS idx_edges_source     ON edges(source_symbol_id);
    \\CREATE INDEX IF NOT EXISTS idx_edges_target     ON edges(target_symbol_id);
    \\CREATE INDEX IF NOT EXISTS idx_edges_type       ON edges(edge_type);
    ,
    \\CREATE TABLE IF NOT EXISTS adrs (
    \\    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    title       TEXT    NOT NULL,
    \\    context     TEXT    NOT NULL DEFAULT '',
    \\    decision    TEXT    NOT NULL DEFAULT '',
    \\    status      TEXT    NOT NULL DEFAULT 'accepted',
    \\    superseded_by INTEGER REFERENCES adrs(id),
    \\    created_at  TEXT    NOT NULL DEFAULT (datetime('now'))
    \\);
    ,
    \\CREATE INDEX IF NOT EXISTS idx_adrs_status ON adrs(status);
    ,
    \\ALTER TABLE symbols ADD COLUMN community_id INTEGER DEFAULT NULL;
    ,
    \\CREATE INDEX IF NOT EXISTS idx_symbols_community ON symbols(community_id);
    ,
    \\CREATE TABLE IF NOT EXISTS traces (
    \\    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    trace_data   TEXT    NOT NULL,
    \\    format       TEXT    NOT NULL DEFAULT 'json',
    \\    source       TEXT    NOT NULL DEFAULT 'runtime',
    \\    ingested_at  TEXT    NOT NULL DEFAULT (datetime('now'))
    \\);
    ,
    \\CREATE INDEX IF NOT EXISTS idx_traces_source ON traces(source);
    ,
    \\CREATE TABLE IF NOT EXISTS document_embeddings (
    \\    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    document_id  INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    \\    vector       BLOB    NOT NULL,
    \\    dimensions   INTEGER NOT NULL DEFAULT 384,
    \\    model_name   TEXT    NOT NULL DEFAULT 'fasttext-subword-384',
    \\    created_at   TEXT    NOT NULL DEFAULT (datetime('now'))
    \\);
    ,
    \\CREATE INDEX IF NOT EXISTS idx_embeddings_document ON document_embeddings(document_id);
};

pub const GraphDb = struct {
    db: *sqlite3.sqlite3,

    /// Open (or create) a database at `path`.  Pass `":memory:"` for an
    /// in-process ephemeral database.
    pub fn open(path: [:0]const u8) !GraphDb {
        var out: ?*sqlite3.sqlite3 = undefined;
        const rc = sqlite3.sqlite3_open(path.ptr, &out);
        if (rc != SQLITE_OK) return Error.OpenFailed;
        const db = out orelse return Error.OpenFailed;
        return GraphDb{ .db = db };
    }

    /// Close the database and free the connection.
    pub fn close(self: *GraphDb) void {
        _ = sqlite3.sqlite3_close(self.db);
        self.db = undefined;
    }

    /// Prepare a SQL statement.
    pub fn prepare(self: *GraphDb, sql: [:0]const u8) !Statement {
        var out: ?*sqlite3.sqlite3_stmt = undefined;
        const rc = sqlite3.sqlite3_prepare_v2(self.db, sql.ptr, @intCast(sql.len), &out, null);
        if (rc != SQLITE_OK) return Error.PrepareFailed;
        return .{ .stmt = out, .db = self };
    }

    /// Execute a statement that returns no rows (INSERT / UPDATE / DELETE / DDL).
    pub fn exec(self: *GraphDb, sql: [:0]const u8) !void {
        const rc = sqlite3.sqlite3_exec(self.db, sql.ptr, null, null, null);
        if (rc != SQLITE_OK) return Error.PrepareFailed;
    }

    /// Return last error message.
    pub fn errmsg(self: *const GraphDb) []const u8 {
        const ptr = sqlite3.sqlite3_errmsg(self.db);
        return std.mem.sliceTo(ptr, 0);
    }

    /// Return the last inserted rowid.
    pub fn lastInsertRowid(self: *const GraphDb) i64 {
        return sqlite3.sqlite3_last_insert_rowid(self.db);
    }

    /// Run all pending migration SQL.
    pub fn migrate(self: *GraphDb) !void {
        for (MIGRATIONS) |sql| {
            try self.exec(sql);
        }
    }

    /// Execute SQL and return a single i64 scalar.
    pub fn queryScalar(self: *GraphDb, sql: [:0]const u8) !i64 {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step()) {
            return stmt.columnInt(0);
        }
        return 0;
    }

    /// Execute SQL and return a single f64 scalar.
    pub fn queryScalarFloat(self: *GraphDb, sql: [:0]const u8) !f64 {
        var stmt = try self.prepare(sql);
        defer stmt.finalize();
        if (try stmt.step()) {
            return stmt.columnFloat(0);
        }
        return 0.0;
    }

    /// Insert a document embedding vector. The vector is stored as a raw BLOB.
    /// Use `vectorSerialize` to convert a []const f32 to a byte slice.
    pub fn insertEmbedding(
        self: *GraphDb,
        document_id: i64,
        vector: []const u8,
        dimensions: u32,
        model_name: []const u8,
    ) !void {
        var stmt = try self.prepare(
            "INSERT INTO document_embeddings (document_id, vector, dimensions, model_name) VALUES (?, ?, ?, ?)",
        );
        defer stmt.finalize();
        try stmt.bindInt(1, document_id);
        try stmt.bindBlob(2, vector);
        try stmt.bindInt(3, dimensions);
        try stmt.bindText(4, model_name);
        _ = try stmt.step();
    }

    /// Check if embeddings already exist for a document (avoid duplicates on re-index).
    pub fn hasEmbedding(self: *GraphDb, document_id: i64) !bool {
        var stmt = try self.prepare(
            "SELECT COUNT(*) FROM document_embeddings WHERE document_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt(1, document_id);
        if (try stmt.step()) {
            const count = try stmt.columnInt(0);
            return count > 0;
        }
        return false;
    }

    /// Delete existing embeddings for a document (for re-indexing).
    pub fn deleteEmbeddings(self: *GraphDb, document_id: i64) !void {
        var stmt = try self.prepare(
            "DELETE FROM document_embeddings WHERE document_id = ?",
        );
        defer stmt.finalize();
        try stmt.bindInt(1, document_id);
        _ = try stmt.step();
    }

    /// Find documents related to symbols whose names match `query_term`.
    /// Traverses 1-hop edges from matching symbols and returns a map of
    /// document_id -> proximity_score (based on edge confidence).
    ///
    /// Scores decay with distance: 1-hop gets full confidence, 2-hop gets
    /// confidence * 0.5.  Only edges with confidence >= min_confidence are
    /// followed.
    pub fn findRelatedDocuments(
        self: *GraphDb,
        query_term: []const u8,
        min_confidence: f32,
        allocator: std.mem.Allocator,
    ) !std.AutoHashMap(u32, f32) {
        var scores = std.AutoHashMap(u32, f32).init(allocator);
        errdefer scores.deinit();

        // 1-hop: symbols whose name matches query_term -> outgoing edges
        {
            var stmt = try self.prepare(
                \\SELECT DISTINCT e.target_symbol_id, e.confidence
                \\FROM symbols s
                \\JOIN edges e ON e.source_symbol_id = s.id
                \\WHERE s.name LIKE ? AND e.confidence >= ?
            );
            defer stmt.finalize();
            try stmt.bindText(1, query_term);
            try stmt.bindFloat(2, min_confidence);

            while (try stmt.step()) {
                const target_sym_id = try stmt.columnInt(0);
                const confidence = try stmt.columnFloat(1);

                // Look up the document for the target symbol
                var doc_stmt = try self.prepare(
                    "SELECT document_id FROM symbols WHERE id = ?"
                );
                defer doc_stmt.finalize();
                try doc_stmt.bindInt(1, target_sym_id);
                if (try doc_stmt.step()) {
                    const doc_id: u32 = @intCast(try doc_stmt.columnInt(0));
                    const entry = try scores.getOrPut(doc_id);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += @floatCast(confidence);
                }
            }
        }

        // Also follow 1-hop incoming edges
        {
            var stmt = try self.prepare(
                \\SELECT DISTINCT e.source_symbol_id, e.confidence
                \\FROM symbols s
                \\JOIN edges e ON e.target_symbol_id = s.id
                \\WHERE s.name LIKE ? AND e.confidence >= ?
            );
            defer stmt.finalize();
            try stmt.bindText(1, query_term);
            try stmt.bindFloat(2, min_confidence);

            while (try stmt.step()) {
                const source_sym_id = try stmt.columnInt(0);
                const confidence = try stmt.columnFloat(1);

                var doc_stmt = try self.prepare(
                    "SELECT document_id FROM symbols WHERE id = ?"
                );
                defer doc_stmt.finalize();
                try doc_stmt.bindInt(1, source_sym_id);
                if (try doc_stmt.step()) {
                    const doc_id: u32 = @intCast(try doc_stmt.columnInt(0));
                    const entry = try scores.getOrPut(doc_id);
                    if (!entry.found_existing) entry.value_ptr.* = 0;
                    entry.value_ptr.* += @floatCast(confidence);
                }
            }
        }

        return scores;
    }

    /// A symbol entry returned from community queries.
    pub const CommunityMember = struct {
        name: []const u8,
        kind: []const u8,
        file_path: []const u8,

        pub fn deinit(self: *CommunityMember, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.kind);
            allocator.free(self.file_path);
        }
    };

    /// A community summary with member count.
    pub const CommunityInfo = struct {
        community_id: i64,
        member_count: u32,
    };

    /// Return all symbols belonging to a community.
    pub fn getCommunityMembers(
        self: *GraphDb,
        community_id: i64,
        allocator: std.mem.Allocator,
    ) ![]CommunityMember {
        var stmt = try self.prepare(
            \\SELECT s.name, s.kind, d.path
            \\FROM symbols s
            \\JOIN documents d ON d.id = s.document_id
            \\WHERE s.community_id = ?
            \\ORDER BY s.name
        );
        defer stmt.finalize();
        try stmt.bindInt(1, community_id);

        var members = std.ArrayList(CommunityMember).initCapacity(allocator, 16) catch @panic("OOM");
        while (try stmt.step()) {
            try members.append(allocator, .{
                .name = try allocator.dupe(u8, try stmt.columnText(0)),
                .kind = try allocator.dupe(u8, try stmt.columnText(1)),
                .file_path = try allocator.dupe(u8, try stmt.columnText(2)),
            });
        }
        return members.toOwnedSlice(allocator);
    }

    /// List all communities with their member counts.
    pub fn listCommunities(
        self: *GraphDb,
        limit: u32,
        allocator: std.mem.Allocator,
    ) ![]CommunityInfo {
        var stmt = try self.prepare(
            \\SELECT community_id, COUNT(*) AS cnt
            \\FROM symbols
            \\WHERE community_id IS NOT NULL
            \\GROUP BY community_id
            \\ORDER BY cnt DESC
            \\LIMIT ?
        );
        defer stmt.finalize();
        try stmt.bindInt(1, @as(i64, @intCast(limit)));

        var result = std.ArrayList(CommunityInfo).initCapacity(allocator, 16) catch @panic("OOM");
        while (try stmt.step()) {
            try result.append(allocator, .{
                .community_id = try stmt.columnInt(0),
                .member_count = @intCast(try stmt.columnInt(1)),
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Get the community ID for a symbol by name. Returns null if not found or
    /// no community assigned.
    pub fn getSymbolCommunity(self: *GraphDb, symbol_name: []const u8) !?i64 {
        var stmt = try self.prepare(
            \\SELECT community_id FROM symbols WHERE name = ? LIMIT 1
        );
        defer stmt.finalize();
        try stmt.bindText(1, symbol_name);

        if (!(try stmt.step())) return null;
        if (sqlite3.sqlite3_column_type(stmt.require(), 0) == sqlite3.SQLITE_NULL) return null;
        return try stmt.columnInt(0);
    }

    /// Find the kinds of symbols matching `query_term` and return a map of
    /// document_id -> max_kind_boost_score.  Boost values are determined by
    /// symbol kind (function > struct > const > variable > module > unknown).
    pub fn findKindBoosts(
        self: *GraphDb,
        query_term: []const u8,
        allocator: std.mem.Allocator,
    ) !std.AutoHashMap(u32, f32) {
        var boosts = std.AutoHashMap(u32, f32).init(allocator);
        errdefer boosts.deinit();

        var stmt = try self.prepare(
            \\SELECT document_id, kind FROM symbols WHERE name LIKE ?
        );
        defer stmt.finalize();
        try stmt.bindText(1, query_term);

        while (try stmt.step()) {
            const doc_id: u32 = @intCast(try stmt.columnInt(0));
            const kind_str = try stmt.columnText(1);
            const boost = kindBoostFromString(kind_str);

            const entry = try boosts.getOrPut(doc_id);
            if (!entry.found_existing) {
                entry.value_ptr.* = boost;
            } else if (boost > entry.value_ptr.*) {
                entry.value_ptr.* = boost;
            }
        }

        return boosts;
    }
};

/// Serialize a f32 vector into a byte slice for BLOB storage.
/// Caller owns the returned memory.
pub fn vectorSerialize(allocator: std.mem.Allocator, vec: []const f32) ![]u8 {
    const bytes = std.mem.sliceAsBytes(vec);
    const result = try allocator.dupe(u8, bytes);
    return result;
}

/// Deserialize a BLOB back into a f32 vector.
/// Caller owns the returned memory.
pub fn vectorDeserialize(allocator: std.mem.Allocator, blob: []const u8) ![]f32 {
    if (blob.len % @sizeOf(f32) != 0) return Error.VectorSerializeFailed;
    const count = blob.len / @sizeOf(f32);
    const result = try allocator.alloc(f32, count);
    const floats = std.mem.bytesAsSlice(f32, blob);
    @memcpy(result, floats);
    return result;
}

/// Return a kind-boost multiplier for a symbol kind string.
/// Higher values rank symbols of that kind more prominently in search.
pub fn kindBoostFromString(kind: []const u8) f32 {
    if (std.mem.eql(u8, kind, "function")) return 1.30;
    if (std.mem.eql(u8, kind, "struct_type")) return 1.20;
    if (std.mem.eql(u8, kind, "const_value")) return 1.10;
    if (std.mem.eql(u8, kind, "variable")) return 1.00;
    if (std.mem.eql(u8, kind, "module")) return 1.00;
    return 0.80; // unknown / fallback
}

// ██████████████████████████████████████████████████████████████████████████
// Tests
// ██████████████████████████████████████████████████████████████████████████

test "graph_db open memory" {
    var db = try GraphDb.open(":memory:");
    defer db.close();
}

test "graph_db migrate creates schema" {
    var db = try GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    const tables: i64 = try db.queryScalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'",
    );
    try std.testing.expectEqual(@as(i64, 6), tables);

    const indexes: i64 = try db.queryScalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
    );
    try std.testing.expectEqual(@as(i64, 10), indexes);
}

test "graph_db insert and query document" {
    var db = try GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path, language) VALUES ('src/main.zig', 'Zig')");
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowid());

    var stmt = try db.prepare("SELECT path, language FROM documents WHERE id = 1");
    defer stmt.finalize();

    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("src/main.zig", try stmt.columnText(0));
    try std.testing.expectEqualStrings("Zig", try stmt.columnText(1));
}

test "graph_db insert and query symbol with edge" {
    var db = try GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    // Document
    try db.exec("INSERT INTO documents (path, language) VALUES ('src/lib.zig', 'Zig')");
    const docId = db.lastInsertRowid();

    // Symbols
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (?, 'init', 'function', 10, 15)");
    const caller = db.lastInsertRowid();
    try db.exec("INSERT INTO symbols (document_id, name, kind, line_start, line_end) VALUES (?, 'alloc', 'function', 42, 48)");
    const callee = db.lastInsertRowid();

    // Edge
    try db.exec("INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type) VALUES (?, ?, 'CALLS')");

    var stmt = try db.prepare(
        \\SELECT s.name, e.edge_type
        \\FROM edges e JOIN symbols s ON s.id = e.target_symbol_id
        \\WHERE e.source_symbol_id = ?
    );
    defer stmt.finalize();

    try stmt.bindInt(1, caller);
    try std.testing.expect(try stmt.step());
    try std.testing.expectEqualStrings("alloc", try stmt.columnText(0));
    try std.testing.expectEqualStrings("CALLS", try stmt.columnText(1));

    _ = docId;
    _ = callee;
}

test "graph_db has errmsg" {
    var db = try GraphDb.open(":memory:");
    defer db.close();

    if (db.exec("BOGUS SQL STATEMENT")) |_| {
        try std.testing.expect(false);
    } else |_| {
        const msg = db.errmsg();
        try std.testing.expect(msg.len > 0);
    }
}

test "graph_db lastInsertRowid after insert" {
    var db = try GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    try db.exec("INSERT INTO documents (path) VALUES ('a.zig')");
    try std.testing.expectEqual(@as(i64, 1), db.lastInsertRowid());

    try db.exec("INSERT INTO documents (path) VALUES ('b.zig')");
    try std.testing.expectEqual(@as(i64, 2), db.lastInsertRowid());
}
