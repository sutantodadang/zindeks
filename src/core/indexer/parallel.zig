//! Parallel indexer using a worker pool + writer thread architecture.
//!
//! Workers parse files and extract symbols concurrently.  A dedicated writer
//! thread receives batches via a lock-free ring buffer and writes both the
//! binary index and the SQLite graph DB.  Graph-DB inserts are wrapped in a
//! single transaction per scan path for throughput.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const graph_db = @import("../storage/graph_db.zig");
const symbols = @import("../../parser/symbols.zig");

/// Message sent from a worker to the writer thread.
pub const BatchMessage = struct {
    file_path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
    parsed: []symbols.ParsedSymbol,
};

/// Bounded MPMC queue protected by a mutex + condition variable.
///
/// File dispatch is per-file (millisecond scale), so mutex contention is
/// not a real concern at the worker counts we target.  Correctness and
/// simplicity matter more than lock-free throughput here.
pub const RingQueue = struct {
    items: []BatchMessage,
    head: usize,
    tail: usize,
    len: usize,
    mutex: std.Thread.Mutex,
    not_empty: std.Thread.Condition,
    not_full: std.Thread.Condition,
    closed: bool,

    pub fn init(allocator: std.mem.Allocator, cap: usize) !RingQueue {
        const real_cap = if (cap == 0) 1 else cap;
        return .{
            .items = try allocator.alloc(BatchMessage, real_cap),
            .head = 0,
            .tail = 0,
            .len = 0,
            .mutex = .{},
            .not_empty = .{},
            .not_full = .{},
            .closed = false,
        };
    }

    pub fn deinit(self: *RingQueue, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
    }

    /// Enqueue a batch message.  Blocks if the queue is full.
    pub fn push(self: *RingQueue, msg: BatchMessage) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.len == self.items.len) self.not_full.wait(&self.mutex);
        self.items[self.tail] = msg;
        self.tail = (self.tail + 1) % self.items.len;
        self.len += 1;
        self.not_empty.signal();
    }

    /// Dequeue a batch message without blocking.  Returns null if empty.
    pub fn pop(self: *RingQueue) ?BatchMessage {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.len == 0) return null;
        const msg = self.items[self.head];
        self.head = (self.head + 1) % self.items.len;
        self.len -= 1;
        self.not_full.signal();
        return msg;
    }
};

/// Shared state between worker threads and the writer thread.
const WorkersState = struct {
    entries: []const scanner.FileEntry,
    counter: std.atomic.Value(usize),
    queue: *RingQueue,
};

/// Per-worker context: shared state pointer + the worker's own arena.
/// Arena memory holds all duped paths/content/symbol names produced by
/// this worker.  The writer thread reads from these slices but never frees;
/// arenas are destroyed in bulk after all workers join.
const WorkerCtx = struct {
    state: *WorkersState,
    arena: std.heap.ArenaAllocator,
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

        for (paths) |repo_path| {
            const entries = try scanner.scanPath(allocator, repo_path);
            defer {
                for (entries) |entry| {
                    allocator.free(entry.path);
                    allocator.free(entry.content);
                }
                allocator.free(entries);
            }

            try self.processEntries(allocator, entries, &writer, &gdb);
        }

        try writer.finish();
    }

    /// Process file entries with worker threads parsing in parallel,
    /// and the main thread writing results to both the binary index and
    /// the graph DB.  All graph-DB inserts are wrapped in a single
    /// transaction for throughput.
    fn processEntries(
        self: *ParallelIndexer,
        allocator: std.mem.Allocator,
        entries: []const scanner.FileEntry,
        writer_ptr: *storage.Writer,
        gdb: *graph_db.GraphDb,
    ) !void {
        if (entries.len == 0) return;

        var queue = try RingQueue.init(allocator, entries.len * 2);
        defer queue.deinit(allocator);

        // Atomic counter for work distribution
        const counter: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

        var state = WorkersState{
            .entries = entries,
            .counter = counter,
            .queue = &queue,
        };

        const worker_count = @min(self.thread_count, entries.len);

        // Per-worker arenas: each worker dupes paths / content / symbol names
        // into its own arena.  Arenas live until all messages have been
        // consumed by the writer and all workers have joined.
        const ctxs = try allocator.alloc(WorkerCtx, worker_count);
        defer allocator.free(ctxs);
        for (ctxs) |*c| {
            c.* = .{
                .state = &state,
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }
        defer for (ctxs) |*c| c.arena.deinit();

        var actual_workers: usize = 0;
        for (0..worker_count) |i| {
            self.workers[i] = std.Thread.spawn(.{}, workerThread, .{&ctxs[i]}) catch break;
            actual_workers += 1;
        }

        // Single transaction wraps all graph-DB inserts for this scan path.
        try gdb.exec("BEGIN TRANSACTION");
        errdefer gdb.exec("ROLLBACK") catch {};

        // Prepared statements reused across all rows.
        var doc_stmt = try gdb.prepare(
            \\INSERT OR REPLACE INTO documents (path, content_hash, mtime)
            \\VALUES (?, ?, ?)
        );
        defer doc_stmt.finalize();

        var sym_stmt = try gdb.prepare(
            \\INSERT INTO symbols (document_id, name, kind, line_start, line_end, col_start, col_end)
            \\VALUES (?, ?, ?, ?, ?, 0, 0)
        );
        defer sym_stmt.finalize();

        // Writer loop: consume batches and write
        var done: usize = 0;
        while (done < entries.len) {
            if (queue.pop()) |msg| {
                done += 1;

                // Binary index
                _ = try writer_ptr.addFile(msg.file_path, msg.hash, msg.mtime, msg.content);

                // Graph DB: insert document, then its symbols using the rowid.
                var hash_bytes: [8]u8 = undefined;
                std.mem.writeInt(u64, &hash_bytes, msg.hash, .little);

                try doc_stmt.bindText(1, msg.file_path);
                try doc_stmt.bindBlob(2, &hash_bytes);
                try doc_stmt.bindInt(3, msg.mtime);
                _ = try doc_stmt.step();
                try doc_stmt.reset();

                const doc_rowid = gdb.lastInsertRowid();

                for (msg.parsed) |sym| {
                    // Skip imports — they need symbol-target resolution which
                    // belongs to a dedicated edge pass.
                    if (sym.kind == .module) continue;

                    try sym_stmt.bindInt(1, doc_rowid);
                    try sym_stmt.bindText(2, sym.name);
                    try sym_stmt.bindText(3, @tagName(sym.kind));
                    try sym_stmt.bindInt(4, @intCast(sym.line));
                    try sym_stmt.bindInt(5, @intCast(sym.line));
                    _ = try sym_stmt.step();
                    try sym_stmt.reset();
                }
                // msg slices point into the producing worker's arena —
                // the writer never frees per-message.
            } else {
                std.atomic.spinLoopHint();
            }
        }

        try gdb.exec("COMMIT");

        // Join all workers
        for (0..actual_workers) |i| {
            self.workers[i].join();
        }
    }
};

/// Worker thread: parse files and push results to the queue.
/// All per-message allocations go into the worker's own arena.
fn workerThread(ctx: *WorkerCtx) void {
    const state = ctx.state;
    const arena_alloc = ctx.arena.allocator();

    while (true) {
        const index = state.counter.fetchAdd(1, .monotonic);
        if (index >= state.entries.len) break;

        const entry = state.entries[index];

        const parsed = symbols.parseSymbols(arena_alloc, entry.content) catch continue;
        const file_path = arena_alloc.dupe(u8, entry.path) catch continue;
        const content = arena_alloc.dupe(u8, entry.content) catch continue;

        state.queue.push(.{
            .file_path = file_path,
            .content = content,
            .hash = entry.hash,
            .mtime = entry.mtime,
            .parsed = parsed,
        });
    }
}
