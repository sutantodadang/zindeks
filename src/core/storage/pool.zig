//! Connection pool for SQLite database connections.
//!
//! Pre-opens a fixed number of connections on init.  acquire() returns a
//! PooledConnection; release() returns it to the pool.  Thread-safe via mutex.

const std = @import("std");
const GraphDb = @import("graph_db.zig").GraphDb;

pub const PooledConnection = struct {
    db: GraphDb,
    pool: *ConnectionPool,

    pub fn release(self: *PooledConnection) void {
        self.pool.release(self.db);
    }
};

pub const ConnectionPool = struct {
    path: []const u8,
    max_conns: usize,
    available: std.ArrayList(GraphDb),
    mutex: std.Thread.Mutex,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, max_conns: usize) !ConnectionPool {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        var available = std.ArrayList(GraphDb){};
        errdefer available.deinit(allocator);

        // Pre-open connections
        for (0..max_conns) |_| {
            const path_z = try allocator.dupeZ(u8, path);
            errdefer allocator.free(path_z);
            const gdb = GraphDb.open(path_z) catch {
                allocator.free(path_z);
                // If we can't open, deinit what we have and return error
                for (available.items) |*conn| conn.close();
                available.deinit(allocator);
                return error.OpenFailed;
            };
            allocator.free(path_z);
            try available.append(allocator, gdb);
        }

        return .{
            .path = owned_path,
            .max_conns = max_conns,
            .available = available,
            .mutex = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ConnectionPool) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.available.items) |*conn| {
            conn.close();
        }
        self.available.deinit(self.allocator);
        self.allocator.free(self.path);
    }

    /// Acquire a connection from the pool. Blocks if none available.
    pub fn acquire(self: *ConnectionPool) !PooledConnection {
        while (true) {
            self.mutex.lock();
            if (self.available.items.len > 0) {
                const db = self.available.swapRemove(0);
                self.mutex.unlock();
                return .{ .db = db, .pool = self };
            }
            self.mutex.unlock();
            // Spin-wait with a short sleep to avoid busy-waiting
            std.Thread.sleep(1_000_000); // 1ms
        }
    }

    /// Release a connection back to the pool.
    pub fn release(self: *ConnectionPool, db: GraphDb) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.available.append(self.allocator, db) catch {
            // If append fails (OOM), close the connection to avoid leaking
            var leaked = db;
            leaked.close();
        };
    }
};
