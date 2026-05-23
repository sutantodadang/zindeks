//! Parallel indexer using a worker pool + writer thread architecture.
//!
//! Workers parse files and extract symbols concurrently.  A dedicated writer
//! thread receives batches via a lock-free ring buffer and writes both the
//! binary index and the SQLite graph DB.  Graph-DB inserts are wrapped in a
//! single transaction per scan path for throughput.
//!
//! ## Memory strategy (B1 — scanner→worker single-copy)
//!
//! The old design called `scanner.scanPath`, which buffered ALL file contents
//! into an owned ArrayList (one allocation per file).  Each worker then duped
//! the path and content into its arena — a SECOND copy.  Peak RSS was
//! therefore 2 × Σ file_sizes during indexing.
//!
//! The new design drives `scanner.scanPathChunked` from a dedicated producer
//! thread.  The producer dupes each file's path+content into a shared
//! producer arena exactly ONCE, then pushes a `WorkItem` into an input queue.
//! Workers pull `WorkItem`s, parse (no dupe — they read from the producer
//! arena), and push `BatchMessage`s into the output queue.  The writer thread
//! (main) consumes `BatchMessage`s and writes to the binary index and graph DB.
//!
//! The producer arena is destroyed after all workers join and the writer has
//! drained the output queue — so the memory lives only as long as needed, and
//! each byte is copied at most once.
//!
//! For large files (≥ scanner.stream_threshold = 1 MB) the chunked path emits
//! begin/chunk*/end events.  The producer assembles the content into a heap
//! buffer (single allocation), then sends the assembled entry as a normal
//! WorkItem.  Workers skip symbol extraction for large files (they rarely
//! contain meaningful symbol shape) and push an empty parsed slice so the
//! writer still records the document metadata.

const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const storage = @import("../storage/index.zig");
const graph_db = @import("../storage/graph_db.zig");
const symbols = @import("../../parser/symbols.zig");

// ─────────────────────────────────────────────────────────────────────────────
// Types shared between producer, workers, and writer
// ─────────────────────────────────────────────────────────────────────────────

/// A parsed file ready for the writer thread to consume.
pub const BatchMessage = struct {
    file_path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
    parsed: []symbols.ParsedSymbol,
};

/// A raw file entry fed from the producer to workers.
/// `path` and `content` are owned by the producer arena; workers must NOT free
/// them.  Workers copy symbol names into their own arena but do NOT dupe path
/// or content.
const WorkItem = struct {
    path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
    /// True for files that arrived via the large-file streaming path.
    /// Workers skip symbol extraction for these.
    is_large: bool,
};

// ─────────────────────────────────────────────────────────────────────────────
// Bounded MPMC queue (mutex + condition variables)
// ─────────────────────────────────────────────────────────────────────────────

/// Generic bounded MPMC queue protected by a mutex + condition variables.
///
/// Parameterised on the element type so we can share the implementation
/// between the input queue (WorkItem) and output queue (BatchMessage).
fn BoundedQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        items: []T,
        head: usize,
        tail: usize,
        len: usize,
        mutex: std.Thread.Mutex,
        not_empty: std.Thread.Condition,
        not_full: std.Thread.Condition,
        /// When true, no more items will be pushed.  Consumers should drain
        /// remaining items and then stop when the queue becomes empty.
        closed: bool,

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            const real_cap = if (cap == 0) 1 else cap;
            return .{
                .items = try allocator.alloc(T, real_cap),
                .head = 0,
                .tail = 0,
                .len = 0,
                .mutex = .{},
                .not_empty = .{},
                .not_full = .{},
                .closed = false,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.items);
        }

        /// Push an item.  Blocks when the queue is full.  If the queue is
        /// closed while this is blocking (e.g., the consumer errored out),
        /// the push is silently dropped and the item is lost.
        pub fn push(self: *Self, item: T) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == self.items.len and !self.closed) self.not_full.wait(&self.mutex);
            if (self.closed) return; // dropped — consumer is gone
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % self.items.len;
            self.len += 1;
            self.not_empty.signal();
        }

        /// Signal that no more items will be pushed (or that consumers are
        /// done).  Waiting producers and consumers are woken so they can check
        /// the closed flag.
        pub fn close(self: *Self) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.closed = true;
            self.not_empty.broadcast();
            self.not_full.broadcast(); // wake any blocked push() callers
        }

        /// Pop an item without blocking.  Returns null when the queue is
        /// empty.
        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
            self.not_full.signal();
            return item;
        }

        /// Pop an item, blocking until one is available or the queue is both
        /// empty and closed.  Returns null only when drained and closed.
        pub fn popBlocking(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            while (self.len == 0 and !self.closed) self.not_empty.wait(&self.mutex);
            if (self.len == 0) return null;
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.len -= 1;
            self.not_full.signal();
            return item;
        }
    };
}

/// Keep the public alias for existing callers that reference RingQueue.
pub const RingQueue = BoundedQueue(BatchMessage);

// ─────────────────────────────────────────────────────────────────────────────
// Worker context
// ─────────────────────────────────────────────────────────────────────────────

/// Context passed to each worker goroutine.
const WorkerCtx = struct {
    input: *BoundedQueue(WorkItem),
    output: *RingQueue,
    /// Atomic counter shared among all workers.  Decremented on exit;
    /// the worker that brings it to zero closes the output queue so the
    /// writer's popBlocking loop terminates cleanly.
    active_workers: *std.atomic.Value(u32),
    /// Per-worker arena that holds parsed symbol names.  The writer thread
    /// reads these slices after pop but before the arena is torn down — arenas
    /// are destroyed in bulk after all workers join AND the output queue is
    /// fully drained.
    arena: std.heap.ArenaAllocator,
};

// ─────────────────────────────────────────────────────────────────────────────
// Producer context
// ─────────────────────────────────────────────────────────────────────────────

/// Context for the producer thread that drives `scanPathChunked`.
const ProducerCtx = struct {
    allocator: std.mem.Allocator, // arena allocator from the producer arena
    input_queue: *BoundedQueue(WorkItem),
    /// Accumulator for a large file being streamed (≥ stream_threshold).
    streaming_path: ?[]const u8,
    streaming_mtime: i64,
    /// Content accumulation buffer for large files.  The scanner already
    /// computes the hash for us (delivered in ChunkEvent.end.hash), so we
    /// only need to reassemble the raw bytes.
    streaming_buf: std.ArrayList(u8),

    fn onEvent(ctx: *ProducerCtx, event: scanner.ChunkEvent) !void {
        switch (event) {
            .file => |fe| {
                // Small file: single-copy into producer arena; push directly.
                const path = try ctx.allocator.dupe(u8, fe.path);
                const content = try ctx.allocator.dupe(u8, fe.content);
                ctx.input_queue.push(.{
                    .path = path,
                    .content = content,
                    .hash = fe.hash,
                    .mtime = fe.mtime,
                    .is_large = false,
                });
            },
            .begin => |b| {
                // Large file: start accumulating chunks.
                ctx.streaming_path = try ctx.allocator.dupe(u8, b.path);
                ctx.streaming_mtime = b.mtime;
                ctx.streaming_buf.clearRetainingCapacity();
            },
            .chunk => |bytes| {
                // Accumulate chunk bytes for the current large file.
                try ctx.streaming_buf.appendSlice(ctx.allocator, bytes);
            },
            .end => |e| {
                // Large file done: the assembled content goes into producer
                // arena (toOwnedSlice transfers ownership to the arena alloc).
                const path = ctx.streaming_path orelse return;
                ctx.streaming_path = null;
                // Transfer buf ownership into the arena so the slice outlives
                // the producer thread.  Pass ctx.allocator (the arena alloc)
                // so the returned slice is arena-managed.
                const content = try ctx.streaming_buf.toOwnedSlice(ctx.allocator);
                // After toOwnedSlice the ArrayList's internal buffer is
                // surrendered; reinitialise so subsequent large files work.
                ctx.streaming_buf = std.ArrayList(u8){};
                ctx.input_queue.push(.{
                    .path = path,
                    .content = content,
                    .hash = e.hash,
                    .mtime = ctx.streaming_mtime,
                    .is_large = true,
                });
            },
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// ParallelIndexer
// ─────────────────────────────────────────────────────────────────────────────

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
            try self.processPath(allocator, repo_path, &writer, &gdb);
        }

        try writer.finish();
    }

    /// Process one repository path using the chunked scanner.
    ///
    /// Architecture:
    ///   producer thread  →  input_queue  →  worker threads  →  output_queue  →  main (writer)
    ///
    /// The producer drives `scanPathChunked`, duping each file's bytes exactly
    /// once into a producer-owned arena.  Workers parse symbols (no dupe) and
    /// push `BatchMessage`s.  The main thread drains the output queue and
    /// writes to the binary index + graph DB — same single-transaction pattern
    /// as before.
    fn processPath(
        self: *ParallelIndexer,
        allocator: std.mem.Allocator,
        repo_path: []const u8,
        writer_ptr: *storage.Writer,
        gdb: *graph_db.GraphDb,
    ) !void {
        // ── Queues ──────────────────────────────────────────────────────────
        // Capacity: enough headroom so the producer and workers can stay
        // saturated.  4 × thread_count is a generous buffer.
        const queue_cap = @max(self.thread_count * 4, 16);

        var input_queue = try BoundedQueue(WorkItem).init(allocator, queue_cap);
        defer input_queue.deinit(allocator);

        var output_queue = try RingQueue.init(allocator, queue_cap);
        defer output_queue.deinit(allocator);

        // ── Producer arena ───────────────────────────────────────────────────
        // All path + content slices live here.  Freed AFTER the writer has
        // consumed all output messages and all workers have joined.
        var producer_arena = std.heap.ArenaAllocator.init(allocator);
        defer producer_arena.deinit();
        const producer_alloc = producer_arena.allocator();

        // ── Worker arenas ────────────────────────────────────────────────────
        const worker_count = self.thread_count;

        // Shared counter: tracks how many workers are still alive.  Initialised
        // to `worker_count` before spawning.  If fewer workers actually spawn we
        // subtract the difference before starting the producer so no spurious
        // close can race with the correction.  The last worker to exit (the one
        // that decrements from 1 → 0) closes the output queue.
        var active_workers = std.atomic.Value(u32).init(@intCast(worker_count));

        const ctxs = try allocator.alloc(WorkerCtx, worker_count);
        defer allocator.free(ctxs);
        for (ctxs) |*c| {
            c.* = .{
                .input = &input_queue,
                .output = &output_queue,
                .active_workers = &active_workers,
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }
        defer for (ctxs) |*c| c.arena.deinit();

        // ── Spawn workers ────────────────────────────────────────────────────
        var actual_workers: usize = 0;
        for (0..worker_count) |i| {
            self.workers[i] = std.Thread.spawn(.{}, workerThread, .{&ctxs[i]}) catch break;
            actual_workers += 1;
        }

        // Correct the counter for any workers that failed to spawn.  Workers
        // are blocked on `input.popBlocking()` (queue is empty+not-closed until
        // the producer starts, which we haven't spawned yet), so this subtract
        // races with no in-flight decrement.
        const not_spawned: u32 = @intCast(worker_count - actual_workers);
        if (not_spawned > 0) _ = active_workers.fetchSub(not_spawned, .acq_rel);

        // ── Handle zero-worker edge case ─────────────────────────────────────
        // If no workers were spawned, bail immediately — no one will ever close
        // the output queue.
        if (actual_workers == 0) {
            input_queue.close();
            output_queue.close();
            return error.NoWorkersAvailable;
        }

        // ── Spawn producer thread ────────────────────────────────────────────
        var producer_ctx = ProducerCtx{
            .allocator = producer_alloc,
            .input_queue = &input_queue,
            .streaming_path = null,
            .streaming_mtime = 0,
            .streaming_buf = std.ArrayList(u8){},
        };

        // Producer error is captured and reported after the pipeline drains.
        var producer_err: ?anyerror = null;
        const producer_thread = std.Thread.spawn(.{}, producerThread, .{
            &producer_ctx,
            repo_path,
            &producer_err,
        }) catch |err| {
            // If we can't spawn a producer, close the input queue immediately
            // so workers see EOF, then drain workers.
            input_queue.close();
            for (0..actual_workers) |i| self.workers[i].join();
            return err;
        };

        // ── Single transaction wraps all graph-DB inserts ────────────────────
        // If ANY error occurs after the threads are spawned, we MUST still
        // join them before returning.  We use a `threads_joined` flag to
        // avoid double-joining (the normal success path joins explicitly).
        var threads_joined = false;
        errdefer if (!threads_joined) {
            // Signal both queues as closed so blocked push/pop calls can exit.
            input_queue.close();
            output_queue.close();
            producer_thread.join();
            for (0..actual_workers) |j| self.workers[j].join();
        };

        try gdb.exec("BEGIN TRANSACTION");
        errdefer gdb.exec("ROLLBACK") catch {};

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

        // ── Writer loop (main thread) ────────────────────────────────────────
        // We don't know how many files there are in advance (streaming scanner).
        // We stop when the output queue is both closed and empty.
        //
        // The output queue is closed by the last worker to finish.  Workers
        // finish when the input queue is both closed and empty.  The input
        // queue is closed by the producer thread after it has emitted all
        // events.
        //
        // Ordering guarantee:
        //   producer done → input_queue.close() → workers drain → last worker
        //   calls output_queue.close() → writer drains → join producer + workers
        //
        // Error handling: if the writer fails (e.g., OOM), close the input
        // queue so the producer stops, and let workers drain naturally.
        var write_err: ?anyerror = null;
        while (output_queue.popBlocking()) |msg| {
            if (write_err != null) continue; // drain to let workers/producer exit

            // Binary index
            _ = writer_ptr.addFile(msg.file_path, msg.hash, msg.mtime, msg.content) catch |e| {
                write_err = e;
                input_queue.close(); // stop the producer early
                continue;
            };

            // Graph DB: document row, then symbol rows.
            writeToDb(gdb, &doc_stmt, &sym_stmt, msg) catch |e| {
                write_err = e;
                input_queue.close();
                continue;
            };
        }

        if (write_err) |_| {
            gdb.exec("ROLLBACK") catch {};
        } else {
            try gdb.exec("COMMIT");
        }

        // ── Join threads ─────────────────────────────────────────────────────
        threads_joined = true;
        producer_thread.join();
        for (0..actual_workers) |i| self.workers[i].join();

        // Re-raise any write or producer error now that the pipeline is drained.
        if (write_err) |err| return err;
        if (producer_err) |err| return err;
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// DB write helper
// ─────────────────────────────────────────────────────────────────────────────

/// Write one BatchMessage to the graph DB.  Separated from the writer loop
/// so error handling is clean and the loop can use `catch |e|` uniformly.
fn writeToDb(
    gdb: *graph_db.GraphDb,
    doc_stmt: *graph_db.Statement,
    sym_stmt: *graph_db.Statement,
    msg: BatchMessage,
) !void {
    var hash_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &hash_bytes, msg.hash, .little);

    try doc_stmt.bindText(1, msg.file_path);
    try doc_stmt.bindBlob(2, &hash_bytes);
    try doc_stmt.bindInt(3, msg.mtime);
    _ = try doc_stmt.step();
    try doc_stmt.reset();

    const doc_rowid = gdb.lastInsertRowid();

    for (msg.parsed) |sym| {
        if (sym.kind == .module) continue;

        try sym_stmt.bindInt(1, doc_rowid);
        try sym_stmt.bindText(2, sym.name);
        try sym_stmt.bindText(3, @tagName(sym.kind));
        try sym_stmt.bindInt(4, @intCast(sym.line));
        try sym_stmt.bindInt(5, @intCast(sym.line));
        _ = try sym_stmt.step();
        try sym_stmt.reset();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Producer thread
// ─────────────────────────────────────────────────────────────────────────────

/// Drives `scanner.scanPathChunked` and feeds work items into `input_queue`.
/// On completion (or error), closes the input queue so workers see EOF.
fn producerThread(ctx: *ProducerCtx, repo_path: []const u8, err_out: *?anyerror) void {
    scanner.scanPathChunked(ctx.allocator, repo_path, ctx, ProducerCtx.onEvent) catch |err| {
        err_out.* = err;
    };
    // Always close — even on error — so workers don't hang waiting for input.
    ctx.input_queue.close();
}

// ─────────────────────────────────────────────────────────────────────────────
// Worker thread
// ─────────────────────────────────────────────────────────────────────────────

/// Sentinel zero-length slice used when parse fails or is skipped.
/// Lives in static memory so `BatchMessage.parsed` never dangles.
var empty_parsed: [0]symbols.ParsedSymbol = undefined;

/// Worker: pull work items from the input queue, parse symbols, push batch
/// messages to the output queue.  Symbol names are allocated into the worker
/// arena.  Path and content pointers are passed through unchanged (they live
/// in the producer arena).
fn workerThread(ctx: *WorkerCtx) void {
    const arena_alloc = ctx.arena.allocator();

    while (ctx.input.popBlocking()) |item| {
        // Large files: skip symbol extraction to avoid wasting parser time on
        // files that rarely have meaningful symbol shape (generated code, data
        // files, etc.).  We still push an empty parsed slice so the writer
        // records the document metadata.
        //
        // On parse / alloc failure we fall back to the zero-length sentinel;
        // document metadata (path, hash, mtime) is still recorded.
        const parsed: []symbols.ParsedSymbol = if (!item.is_large)
            symbols.parseSymbols(arena_alloc, item.content) catch &empty_parsed
        else
            &empty_parsed;

        ctx.output.push(.{
            .file_path = item.path,
            .content = item.content,
            .hash = item.hash,
            .mtime = item.mtime,
            .parsed = parsed,
        });
    }

    // Decrement the shared worker counter.  The last worker to exit
    // (the one that decrements from 1 to 0) closes the output queue so
    // the writer's popBlocking loop terminates cleanly.  Any earlier
    // worker simply exits.
    const prev = ctx.active_workers.fetchSub(1, .acq_rel);
    if (prev == 1) ctx.output.close();
}
