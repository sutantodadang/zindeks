//! Parallel indexer using a worker pool + writer thread architecture.
//!
//! Workers parse files and extract symbols concurrently.  A dedicated writer
//! thread receives batches via a mutex-protected queue and writes to SQLite
//! using BatchInserter for high-throughput bulk inserts.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const graph_db = @import("../storage/graph_db.zig");
const batch = @import("../storage/batch.zig");
const symbols = @import("../../parser/symbols.zig");

/// Message sent from a worker to the writer thread.
pub const BatchMessage = struct {
    file_path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
    parsed: []symbols.ParsedSymbol,
};

/// Mutex-protected queue with condition variable for blocking dequeue.
pub const BatchQueue = struct {
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    items: std.ArrayList(BatchMessage),
    closed: bool,

    pub fn init(allocator: std.mem.Allocator) BatchQueue {
        _ = allocator;
        return .{
            .mutex = .{},
            .cond = .{},
            .items = .{},
            .closed = false,
        };
    }

    pub fn deinit(self: *BatchQueue, allocator: std.mem.Allocator) void {
        self.items.deinit(allocator);
    }

    /// Enqueue a batch message. Signals one waiting consumer.
    pub fn push(self: *BatchQueue, allocator: std.mem.Allocator, msg: BatchMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.items.append(allocator, msg);
        self.cond.signal();
    }

    /// Dequeue a batch message. Blocks until available or queue closed.
    /// Returns null if queue is closed and empty.
    pub fn pop(self: *BatchQueue, allocator: std.mem.Allocator) ?BatchMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.items.items.len == 0 and !self.closed) {
            self.cond.wait(&self.mutex);
        }

        if (self.items.items.len == 0) return null;

        const msg = self.items.items[0];
        _ = self.items.orderedRemove(0);
        _ = allocator;
        return msg;
    }

    /// Close the queue — wakes all waiting consumers.
    pub fn close(self: *BatchQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.closed = true;
        self.cond.broadcast();
    }
};

/// Shared state between worker threads and the writer thread.
const WorkersState = struct {
    allocator: std.mem.Allocator,
    entries: []const scanner.FileEntry,
    counter: std.atomic.Value(usize),
    queue: *BatchQueue,
};

/// Parallel indexer with worker pool and writer thread.
pub const ParallelIndexer = struct {
    thread_count: usize,
    workers: []std.Thread,

    pub fn init(allocator: std.mem.Allocator, thread_count: usize) !ParallelIndexer {
        const count = if (thread_count == 0) try std.Thread.getCpuCount() else thread_count;
        const workers = try allocator.alloc(std.Thread, count);
        errdefer allocator.free(workers);
        return .{ .thread_count = count, .workers = workers };
    }

    pub fn deinit(self: *ParallelIndexer, allocator: std.mem.Allocator) void {
        allocator.free(self.workers);
    }

    /// Index all paths using the parallel worker pool.
    pub fn indexPaths(
        self: *ParallelIndexer,
        allocator: std.mem.Allocator,
        paths: []const []const u8,
        store_root: []const u8,
    ) !void {
        try std.fs.cwd().makePath(store_root);

        var writer = try storage.Writer.init(allocator, std.fs.cwd(), store_root);
        defer writer.deinit();

        const graph_path = try std.fs.path.join(allocator, &.{ store_root, "graph.db" });
        defer allocator.free(graph_path);
        const graph_path_z = try allocator.dupeZ(u8, graph_path);
        defer allocator.free(graph_path_z);
        var gdb = try graph_db.GraphDb.open(graph_path_z);
        defer gdb.close();
        try gdb.migrate();

        var inserter = batch.BatchInserter.init(allocator, &gdb, 1000);
        defer inserter.deinit(allocator);

        var queue = BatchQueue.init(allocator);
        defer queue.deinit(allocator);

        for (paths) |repo_path| {
            const entries = try scanner.scanPath(allocator, repo_path);
            defer {
                for (entries) |entry| {
                    allocator.free(entry.path);
                    allocator.free(entry.content);
                }
                allocator.free(entries);
            }

            try self.processEntries(allocator, entries, &writer, &inserter, &queue);
        }

        try writer.finish();
    }

    /// Process file entries with worker threads parsing in parallel,
    /// and the main thread writing results to the database.
    fn processEntries(
        self: *ParallelIndexer,
        allocator: std.mem.Allocator,
        entries: []const scanner.FileEntry,
        writer_ptr: *storage.Writer,
        inserter: *batch.BatchInserter,
        queue: *BatchQueue,
    ) !void {
        if (entries.len == 0) return;

        // Atomic counter for work distribution
        const counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        var state = WorkersState{
            .allocator = allocator,
            .entries = entries,
            .counter = counter,
            .queue = queue,
        };

        const worker_count = @min(self.thread_count, entries.len);
        var actual_workers: usize = 0;

        for (0..worker_count) |i| {
            self.workers[i] = std.Thread.spawn(.{}, workerThread, .{&state}) catch break;
            actual_workers += 1;
        }

        // Writer loop: consume batches and write
        var done: usize = 0;
        while (done < entries.len) {
            const maybe_msg = queue.pop(allocator);
            if (maybe_msg == null) break;
            const msg = maybe_msg.?;
            done += 1;

            // Write to binary index
            _ = try writer_ptr.addFile(msg.file_path, msg.hash, msg.mtime, msg.content);

            // Free message data
            allocator.free(msg.file_path);
            allocator.free(msg.content);
            for (msg.parsed) |sym| allocator.free(sym.name);
            allocator.free(msg.parsed);
        }

        // Close queue to wake workers
        queue.close();

        // Join all workers
        for (0..actual_workers) |i| {
            self.workers[i].join();
        }

        // Flush remaining batch inserts
        try inserter.flush(allocator);
    }
};

/// Worker thread: parse files and push results to the queue.
fn workerThread(state: *WorkersState) void {
    const allocator = state.allocator;

    while (true) {
        const index = state.counter.fetchAdd(1, .monotonic);
        if (index >= state.entries.len) break;

        const entry = state.entries[index];

        const parsed = symbols.parseSymbols(allocator, entry.content) catch continue;

        const file_path = allocator.dupe(u8, entry.path) catch {
            for (parsed) |sym| allocator.free(sym.name);
            allocator.free(parsed);
            continue;
        };
        errdefer allocator.free(file_path);

        const content = allocator.dupe(u8, entry.content) catch {
            allocator.free(file_path);
            for (parsed) |sym| allocator.free(sym.name);
            allocator.free(parsed);
            continue;
        };
        errdefer allocator.free(content);

        const msg = BatchMessage{
            .file_path = file_path,
            .content = content,
            .hash = entry.hash,
            .mtime = entry.mtime,
            .parsed = parsed,
        };

        state.queue.push(allocator, msg) catch {
            allocator.free(file_path);
            allocator.free(content);
            for (parsed) |sym| allocator.free(sym.name);
            allocator.free(parsed);
            continue;
        };
    }
}
