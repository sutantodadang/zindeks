//! Statement cache — reuses prepared SQLite statements.
//!
//! Stores prepared statements keyed by SQL string.  Calling prepare() with
//! a previously-seen SQL string returns the same statement pointer, avoiding
//! repeated sqlite3_prepare_v2/finalize cycles.

const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});
const GraphDb = @import("graph_db.zig").GraphDb;

pub const StatementCache = struct {
    db: *GraphDb,
    cache: std.StringHashMapUnmanaged(*sqlite3.sqlite3_stmt),
    max_size: usize,

    pub fn init(allocator: std.mem.Allocator, db: *GraphDb, max_size: usize) StatementCache {
        _ = allocator;
        return .{
            .db = db,
            .cache = .{},
            .max_size = max_size,
        };
    }

    pub fn deinit(self: *StatementCache, allocator: std.mem.Allocator) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            _ = sqlite3.sqlite3_finalize(entry.value_ptr.*);
        }
        self.cache.deinit(allocator);
    }

    /// Prepare a SQL statement, using the cache if available.
    /// Returns a pointer to a prepared statement. The caller must NOT
    /// finalize the returned statement — the cache owns it.
    pub fn prepare(self: *StatementCache, allocator: std.mem.Allocator, sql: []const u8) !*sqlite3.sqlite3_stmt {
        // Check cache first
        if (self.cache.get(sql)) |stmt| {
            _ = sqlite3.sqlite3_reset(stmt);
            _ = sqlite3.sqlite3_clear_bindings(stmt);
            return stmt;
        }

        // Evict if at capacity (simple: clear all)
        if (self.cache.count() >= self.max_size) {
            self.clear(allocator);
        }

        // Prepare new statement
        var out: ?*sqlite3.sqlite3_stmt = undefined;
        const zsql = allocator.dupeZ(u8, sql) catch return error.PrepareFailed;
        defer allocator.free(zsql);
        const rc = sqlite3.sqlite3_prepare_v2(@ptrCast(self.db.db), zsql.ptr, @intCast(zsql.len), &out, null);
        if (rc != sqlite3.SQLITE_OK) return error.PrepareFailed;

        const stmt = out orelse return error.PrepareFailed;

        // Store in cache. The key is the SQL string — since callers typically
        // pass string literals or long-lived strings, we store a copy.
        const key = allocator.dupe(u8, sql) catch {
            _ = sqlite3.sqlite3_finalize(stmt);
            return error.PrepareFailed;
        };
        errdefer allocator.free(key);

        try self.cache.put(allocator, key, stmt);
        return stmt;
    }

    /// Clear all cached statements.
    pub fn clear(self: *StatementCache, allocator: std.mem.Allocator) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            _ = sqlite3.sqlite3_finalize(entry.value_ptr.*);
        }
        self.cache.clearAndFree(allocator);
    }
};
