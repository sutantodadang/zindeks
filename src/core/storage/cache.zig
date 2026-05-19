//! Statement cache — reuses prepared SQLite statements.
//!
//! Stores prepared statements keyed by SQL string.  Calling prepare() with
//! a previously-seen SQL string returns the same statement pointer, avoiding
//! repeated sqlite3_prepare_v2/finalize cycles.

const std = @import("std");
const sqlite3 = @cImport({
    @cInclude("sqlite3.h");
});

pub const StatementCache = struct {
    db_ptr: *anyopaque, // actually *sqlite3.sqlite3
    cache: std.StringHashMapUnmanaged(*anyopaque),
    max_size: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, db_ptr: *anyopaque, max_size: usize) StatementCache {
        return .{
            .db_ptr = db_ptr,
            .cache = .{},
            .max_size = max_size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *StatementCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            _ = sqlite3.sqlite3_finalize(@ptrCast(entry.value_ptr.*));
        }
        self.cache.deinit(self.allocator);
    }

    /// Prepare a SQL statement, using the cache if available.
    /// Returns an opaque pointer to the prepared statement. The caller must NOT
    /// finalize the returned statement — the cache owns it.
    pub fn prepare(self: *StatementCache, sql: []const u8) !*anyopaque {
        // Check cache first
        if (self.cache.get(sql)) |stmt| {
            _ = sqlite3.sqlite3_reset(@ptrCast(stmt));
            _ = sqlite3.sqlite3_clear_bindings(@ptrCast(stmt));
            return stmt;
        }

        // Evict if at capacity (simple: clear all)
        if (self.cache.count() >= self.max_size) {
            self.clear();
        }

        // Prepare new statement
        var out: ?*sqlite3.sqlite3_stmt = undefined;
        const zsql = self.allocator.dupeZ(u8, sql) catch return error.PrepareFailed;
        defer self.allocator.free(zsql);
        const rc = sqlite3.sqlite3_prepare_v2(@ptrCast(self.db_ptr), zsql.ptr, @intCast(zsql.len), &out, null);
        if (rc != sqlite3.SQLITE_OK) return error.PrepareFailed;

        const stmt = out orelse return error.PrepareFailed;

        // Store in cache. The key is the SQL string — since callers typically
        // pass string literals or long-lived strings, we store a copy.
        const key = self.allocator.dupe(u8, sql) catch {
            _ = sqlite3.sqlite3_finalize(stmt);
            return error.PrepareFailed;
        };
        errdefer self.allocator.free(key);

        try self.cache.put(self.allocator, key, @ptrCast(stmt));
        return @ptrCast(stmt);
    }

    /// Clear all cached statements.
    pub fn clear(self: *StatementCache) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            _ = sqlite3.sqlite3_finalize(@ptrCast(entry.value_ptr.*));
        }
        self.cache.clearAndFree(self.allocator);
    }
};
