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
/// SQLite never calls this function pointer; it merely checks that it is non-null.
fn sqliteTransient(_: ?*anyopaque) callconv(.c) void {
    @panic("SQLITE_TRANSIENT called — this should never happen");
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
};

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
    try std.testing.expectEqual(@as(i64, 5), tables);

    const indexes: i64 = try db.queryScalar(
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'",
    );
    try std.testing.expectEqual(@as(i64, 9), indexes);
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
