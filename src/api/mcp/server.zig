//! MCP-compliant JSON-RPC server over stdio.
//!
//! Handles the initialize handshake, tools/list, tools/call dispatch,
//! and ping.  Maintains optional project state (binary index + graph DB).

const std = @import("std");
const protocol = @import("protocol.zig");
const tools = @import("tools.zig");
const result_cache_mod = @import("result_cache.zig");
const storage = @import("../../core/storage/index.zig");
const overlay_mod = @import("../../core/storage/overlay.zig");
const search = @import("../../core/search/engine.zig");
const graph_db = @import("../../core/storage/graph_db.zig");
const pool = @import("../../core/storage/pool.zig");
const project_store = @import("../../core/project_store.zig");
const version = @import("../../version.zig");
const incremental = @import("../../core/indexer/incremental.zig");
const ParserPool = incremental.ParserPool;
const hnsw = @import("../../core/search/hnsw.zig");
const semantic = @import("../../core/search/semantic.zig");
const watcher_mod = @import("../../project/watcher.zig");

const ServerInfo = struct {
    name: []const u8 = "zindeks",
    version: []const u8 = version.version,
    store_root: ?[]const u8 = null,
    pool_conns: u32 = 4,
    worker_threads: u32 = 4,
};

// ─────────────────────────────────────────────────────────────────────────────
// Lock-mode classification (B2 — fine-grained MCP locks)
//
// Lock acquisition order (MUST be respected on every code path that holds
// more than one lock, to prevent deadlock):
//
//   attach_mutex → meta_lock → overlay_rwlock → gdb_rwlock
//
// ─────────────────────────────────────────────────────────────────────────────

/// How a tool needs to acquire each of the three sub-locks.
const LockKind = enum { none, shared, exclusive };

const LockMode = struct {
    /// Does this tool need the top-level attach_mutex?
    attach: bool = false,
    /// Does this tool touch project_path / index_dir (meta_lock)?
    meta: LockKind = .none,
    /// Does this tool touch idx / overlay / engine (BM25 path)?
    overlay: LockKind = .none,
    /// Does this tool touch gdb / pool (graph path)?
    gdb: LockKind = .none,

    /// True when the tool should be run inline (holding state) rather than
    /// dispatched to the thread pool.  Exclusive-lock holders run inline so
    /// they don't block the pool indefinitely.
    fn isInline(self: LockMode) bool {
        return self.attach or
            self.meta == .exclusive or
            self.overlay == .exclusive or
            self.gdb == .exclusive;
    }
};

fn lockMode(name: []const u8) LockMode {
    // ── Full re-attach (index_repository, delete_project) ─────────────────
    // Need attach_mutex + all sub-locks exclusive.
    if (std.mem.eql(u8, name, "index_repository") or
        std.mem.eql(u8, name, "delete_project"))
    {
        return .{ .attach = true, .meta = .exclusive, .overlay = .exclusive, .gdb = .exclusive };
    }
    // ── BM25 overlay writer (update_index) ────────────────────────────────
    if (std.mem.eql(u8, name, "update_index")) {
        return .{ .meta = .shared, .overlay = .exclusive };
    }
    // ── Graph writer (rename_symbol) ──────────────────────────────────────
    if (std.mem.eql(u8, name, "rename_symbol")) {
        return .{ .gdb = .exclusive };
    }
    // ── ADR create/update — graph writer ─────────────────────────────────
    // manage_adr with action=create/update mutates the DB; we conservatively
    // treat all manage_adr calls as graph-write so we don't have to inspect
    // the arguments here.
    if (std.mem.eql(u8, name, "manage_adr")) {
        return .{ .gdb = .exclusive };
    }
    // ── ingest_traces — graph writer ─────────────────────────────────────
    if (std.mem.eql(u8, name, "ingest_traces")) {
        return .{ .gdb = .exclusive };
    }
    // ── save_reasoning — graph writer (inserts a reasoning row) ──────────
    if (std.mem.eql(u8, name, "save_reasoning")) {
        return .{ .gdb = .exclusive };
    }
    // ── batch: read-only fan-out; holds same locks as its sub-tools ─────
    if (std.mem.eql(u8, name, "batch")) {
        return .{ .overlay = .shared, .gdb = .shared };
    }
    // ── search: keyword/semantic (overlay reader), hybrid (overlay+gdb) ──
    if (std.mem.eql(u8, name, "search")) {
        // Hybrid needs both; keyword/semantic only need overlay.
        // Use overlay+gdb shared to cover all modes conservatively.
        return .{ .overlay = .shared, .gdb = .shared };
    }
    if (std.mem.eql(u8, name, "score_relevance")) {
        return .{ .overlay = .shared, .gdb = .shared };
    }
    if (std.mem.eql(u8, name, "get_context")) {
        return .{ .overlay = .shared, .gdb = .shared };
    }
    // ── Pure meta reads (no DB, no engine) ───────────────────────────────
    if (std.mem.eql(u8, name, "list_projects") or
        std.mem.eql(u8, name, "config") or
        std.mem.eql(u8, name, "health_check"))
    {
        return .{ .meta = .shared };
    }
    // ── Graph readers (all remaining registered tools) ────────────────────
    // Default: graph shared.  Unknown tools get graph-shared which is safe
    // (it only prevents concurrent graph writes, not reads or overlay ops).
    return .{ .gdb = .shared };
}

fn isMutatingTool(name: []const u8) bool {
    const mode = lockMode(name);
    return mode.isInline();
}

fn isCacheable(name: []const u8) bool {
    if (isMutatingTool(name)) return false;
    if (std.mem.eql(u8, name, "health_check")) return false;
    if (std.mem.eql(u8, name, "config")) return false;
    if (std.mem.eql(u8, name, "batch")) return false;
    return true;
}

pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: protocol.Transport,
    info: ServerInfo,
    store_root: ?[]const u8,
    initialized: bool,
    // ── Guarded by meta_lock ─────────────────────────────────────────────
    project_path: ?[]const u8,
    /// Resolved index directory for the currently loaded project — needed
    /// so `update_index` knows where to rebuild the overlay.
    index_dir: ?[]const u8,
    // ── Guarded by overlay_rwlock ────────────────────────────────────────
    idx: ?storage.Index,
    overlay: ?overlay_mod.Overlay,
    engine: ?search.Engine,
    /// Owned HNSW ANN index.  Loaded from `<index_dir>/hnsw.idx` when a
    /// project is opened; null when none exists or embeddings < MIN_ANN_DOCS.
    ann: ?hnsw.Hnsw,
    // ── Guarded by gdb_rwlock ────────────────────────────────────────────
    /// Single graph-DB handle used when no pool is available (initialize-
    /// time, schema migrations).  When `pool` is non-null, read-only
    /// handlers acquire from it instead.
    gdb: ?graph_db.GraphDb,
    pool: ?pool.ConnectionPool,
    /// Worker pool for concurrent read-only tool dispatch.  Mutating tools
    /// run inline on the main loop so they can hold their sub-lock(s)
    /// exclusively without blocking all workers.
    thread_pool: std.Thread.Pool,
    thread_pool_initialized: bool,

    // ── Fine-grained locks (B2) ──────────────────────────────────────────
    //
    // Lock acquisition order (MUST be respected — see lockMode() above):
    //   attach_mutex → meta_lock → overlay_rwlock → gdb_rwlock
    //
    // attach_mutex: held during full project attach/detach (index_repository,
    //   delete_project).  Serialize these top-level operations; while held,
    //   acquire all sub-locks exclusively in order.
    attach_mutex: std.Thread.Mutex,
    // meta_lock: guards project_path, index_dir.  Only touched on attach/
    //   detach and by tools that need to read the active project path.
    meta_lock: std.Thread.Mutex,
    // overlay_rwlock: guards idx, overlay, engine (BM25 search path).
    //   Writers: update_index, index_repository, delete_project.
    //   Readers: search (all modes: keyword, semantic, hybrid).
    overlay_rwlock: std.Thread.RwLock,
    // gdb_rwlock: guards gdb, pool (graph DB path).
    //   Writers: rename_symbol, manage_adr, ingest_traces, index_repository,
    //     delete_project.
    //   Readers: all remaining graph-read tools.
    gdb_rwlock: std.Thread.RwLock,

    // ── In-flight worker counter (Condition-based, replaces busy-wait) ────
    /// Counts in-flight worker jobs.  Protected by `inflight_mu`.
    inflight: u32,
    inflight_mu: std.Thread.Mutex,
    inflight_cv: std.Thread.Condition,

    response_buf: std.ArrayList(u8),

    /// Session-scoped cache of read-only tool result bodies.
    /// Invalidated on any mutating tool call.
    result_cache: result_cache_mod.ResultCache,

    /// Optional background file watcher; non-null only when ZINDEKS_WATCH is
    /// set and a project is attached. Auto-applies incremental updates.
    watcher: ?*watcher_mod.PollWatcher = null,

    /// Long-lived parser pool — reuses TSParser instances across incremental
    /// index updates so we avoid alloc/free of TSParser + grammar binding per
    /// file.  Created in init, destroyed in deinit.
    parser_pool: ParserPool,

    /// Per-call pool size — small enough to stay light, big enough to let
    /// a few concurrent search calls actually overlap.  Bumped up by
    /// daemon mode if needed.
    pub const DEFAULT_POOL_CONNS: usize = 4;
    pub const DEFAULT_WORKER_THREADS: usize = 4;

    pub fn init(allocator: std.mem.Allocator, info: ServerInfo) Server {
        return initWithTransport(allocator, info, protocol.Transport.init(allocator));
    }

    pub fn initWithTransport(allocator: std.mem.Allocator, info: ServerInfo, transport: protocol.Transport) Server {
        return .{
            .allocator = allocator,
            .transport = transport,
            .info = info,
            .store_root = info.store_root,
            .initialized = false,
            .project_path = null,
            .index_dir = null,
            .idx = null,
            .overlay = null,
            .engine = null,
            .ann = null,
            .gdb = null,
            .pool = null,
            .thread_pool = undefined,
            .thread_pool_initialized = false,
            .attach_mutex = .{},
            .meta_lock = .{},
            .overlay_rwlock = .{},
            .gdb_rwlock = .{},
            .inflight = 0,
            .inflight_mu = .{},
            .inflight_cv = .{},
            .response_buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch @panic("OOM"),
            .result_cache = result_cache_mod.ResultCache.init(allocator),
            .parser_pool = ParserPool.init(allocator),
            .watcher = null,
        };
    }

    pub fn deinit(self: *Server) void {
        // Stop the file watcher first — it holds a reference to gdb/project_path
        // and its thread must be joined before those resources are freed.
        self.stopWatcher();
        // Drain any in-flight workers before closing shared resources.
        self.waitForInflight();
        if (self.thread_pool_initialized) {
            self.thread_pool.deinit();
            self.thread_pool_initialized = false;
        }
        if (self.pool) |*p| p.deinit();
        if (self.gdb) |*gdb| gdb.close();
        if (self.ann) |*a| a.deinit();
        if (self.overlay) |*ov| ov.close();
        if (self.idx) |*idx| idx.close();
        if (self.project_path) |p| self.allocator.free(p);
        if (self.index_dir) |p| self.allocator.free(p);
        self.result_cache.deinit();
        self.parser_pool.deinit();
        self.response_buf.deinit(self.allocator);
        self.transport.deinit();
    }

    fn ensureThreadPool(self: *Server) !void {
        if (self.thread_pool_initialized) return;
        try self.thread_pool.init(.{ .allocator = self.allocator, .n_jobs = self.info.worker_threads });
        self.thread_pool_initialized = true;
    }

    fn waitForInflight(self: *Server) void {
        // Condition-based drain: wake immediately when the last in-flight
        // worker signals the condition variable.  No polling, no sleep.
        self.inflight_mu.lock();
        defer self.inflight_mu.unlock();
        while (self.inflight > 0) self.inflight_cv.wait(&self.inflight_mu);
    }

    fn inflightIncrement(self: *Server) void {
        self.inflight_mu.lock();
        defer self.inflight_mu.unlock();
        self.inflight += 1;
    }

    fn inflightDecrement(self: *Server) void {
        self.inflight_mu.lock();
        defer self.inflight_mu.unlock();
        self.inflight -= 1;
        if (self.inflight == 0) self.inflight_cv.signal();
    }

    /// Run the server event loop.  Blocks until stdin closes.
    pub fn serve(self: *Server) !void {
        while (try self.transport.readMessage()) |raw| {
            defer self.allocator.free(raw);
            self.handleMessage(raw) catch |err| {
                std.log.err("MCP handler error: {s}", .{@errorName(err)});
                self.respondErrorMaybe(raw, .internal_error) catch |e| {
                    std.log.err("Failed to send error response: {s}", .{@errorName(e)});
                };
                continue;
            };
        }
    }

    fn handleMessage(self: *Server, raw: []const u8) !void {
        var req = (try protocol.parseRequest(self.allocator, raw)) orelse {
            // Not a valid JSON-RPC request — send parse error if id present
            try self.respondErrorMaybe(raw, .parse_error);
            return;
        };
        // Ownership: read-only tool dispatch can hand `req` off to a worker
        // thread, which then deinits.  `handleInitialized` returns true in
        // that case so we skip the local cleanup.
        var owned_locally = true;
        defer if (owned_locally) req.deinit();

        const is_notification = protocol.isNotification(req);

        if (self.initialized) {
            owned_locally = !(try self.handleInitialized(&req, is_notification));
        } else {
            try self.handlePreInit(req, is_notification);
        }
    }

    // ██████████████████████████████████████████████████████████████████████
    // Pre-initialize: only accept "initialize"
    // ██████████████████████████████████████████████████████████████████████

    fn handlePreInit(self: *Server, req: protocol.ParsedRequest, is_notification: bool) !void {
        if (is_notification) return;

        if (std.mem.eql(u8, req.method, "initialize")) {
            try self.handleInitialize(req);
        } else {
            try self.respondError(req.id, .invalid_request);
        }
    }

    fn handleInitialize(self: *Server, req: protocol.ParsedRequest) !void {
        // Honor the client's requested protocol version when it is one
        // we have been validated against; otherwise fall back to our
        // default.  Per MCP spec, the client decides whether to proceed
        // after seeing our reply, so echoing the request is a safe win.
        const requested: ?[]const u8 = blk: {
            if (req.params) |p| {
                if (p.get("protocolVersion")) |pv| {
                    if (pv == .string) break :blk pv.string;
                }
            }
            break :blk null;
        };
        const negotiated = protocol.negotiateProtocolVersion(requested);

        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeInitializeResultV(writer, req.id, self.info.name, self.info.version, negotiated);
        try self.transport.writeMessage(self.response_buf.items);
        self.initialized = true;
        // Best-effort auto-detect: pick up an explicit `projectRoots`/`rootUri`
        // from the initialize params, else walk up cwd looking for a project
        // marker.  Auto-attach the warm index if the project store has one.
        // All failures are silent — the client can still call index_repository.
        self.tryAutoAttach(req.params) catch |err| {
            std.log.debug("auto-attach skipped: {s}", .{@errorName(err)});
        };
    }

    /// Auto-detect the active project at initialize time.  Resolution
    /// order:
    ///   1. params.projectRoots[0] / params.rootPath (explicit override)
    ///   2. params.clientInfo.rootUri (`file://` scheme)
    ///   3. walk up from cwd until we find a `.git` directory
    ///
    /// Once a path is chosen, attempt `project_store.resolveRead` — if a
    /// warm index exists, attach via `openProjectByPath`.  If not, do
    /// nothing; the agent's first `index_repository` call will create one.
    fn tryAutoAttach(self: *Server, params: ?std.json.ObjectMap) !void {
        // Resolve a path that actually has a warm index.  If none is found,
        // leave the server in its no-project state and let the agent call
        // index_repository.
        const project_path = (try self.resolveWarmProject(params)) orelse return;
        defer self.allocator.free(project_path);

        // Auto-attach at initialize time: acquire all sub-locks exclusively
        // in documented order (no in-flight workers yet at this point, so
        // waitForInflight is a no-op, but we call it for correctness).
        self.waitForInflight();
        self.attach_mutex.lock();
        defer self.attach_mutex.unlock();
        self.meta_lock.lock();
        defer self.meta_lock.unlock();
        self.overlay_rwlock.lock();
        defer self.overlay_rwlock.unlock();
        self.gdb_rwlock.lock();
        defer self.gdb_rwlock.unlock();
        try self.openProjectByPath(project_path);
    }

    /// Pick a project path that has a warm index in the store.  Resolution:
    ///   1. The explicit candidate (params / ZINDEKS_PROJECT env / git-walk)
    ///      — used only if it actually has a warm index.
    ///   2. Otherwise the nearest indexed ancestor of cwd.  This handles an
    ///      umbrella directory that holds several child repos but is not a
    ///      git repo itself: cwd resolves to a child via git-walk (no warm
    ///      index there), so we walk up cwd until we hit the indexed umbrella.
    /// Returns an owned path with a confirmed warm index, or null.
    fn resolveWarmProject(self: *Server, params: ?std.json.ObjectMap) !?[]u8 {
        if (try self.resolveInitialProject(params)) |candidate| {
            if (self.hasWarmIndex(candidate)) return candidate;
            self.allocator.free(candidate);
        }
        return self.findWarmAncestor();
    }

    /// Return true when `path` resolves to a warm (indexed) project in the
    /// store.  Cheap probe — reads the project's `current` marker.
    fn hasWarmIndex(self: *Server, path: []const u8) bool {
        var loc = project_store.resolveRead(
            self.allocator,
            path,
            .{ .store_root = self.store_root },
        ) catch return false;
        loc.deinit();
        return true;
    }

    /// Walk upward from cwd, returning the nearest ancestor directory that has
    /// a warm index in the store.  Returns an owned path, or null if no
    /// ancestor up to the filesystem root is indexed.
    fn findWarmAncestor(self: *Server) !?[]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = std.fs.cwd().realpath(".", &buf) catch return null;
        var current = try self.allocator.dupe(u8, cwd);
        errdefer self.allocator.free(current);

        while (true) {
            if (self.hasWarmIndex(current)) return current; // ownership transferred

            const parent = std.fs.path.dirname(current) orelse {
                self.allocator.free(current);
                return null;
            };
            if (std.mem.eql(u8, parent, current)) {
                self.allocator.free(current);
                return null;
            }
            const parent_owned = try self.allocator.dupe(u8, parent);
            self.allocator.free(current);
            current = parent_owned;
        }
    }

    fn resolveInitialProject(self: *Server, params: ?std.json.ObjectMap) !?[]u8 {
        if (params) |p| {
            // Custom extension: `projectRoots: [string]` array.
            if (p.get("projectRoots")) |roots_val| {
                if (roots_val == .array and roots_val.array.items.len > 0) {
                    const first = roots_val.array.items[0];
                    if (first == .string) return try self.allocator.dupe(u8, first.string);
                }
            }
            // Custom extension: scalar `rootPath`.
            if (p.get("rootPath")) |rp| {
                if (rp == .string) return try self.allocator.dupe(u8, rp.string);
            }
            // MCP standard: clientInfo.rootUri (file:// URL).
            if (p.get("clientInfo")) |ci| {
                if (ci == .object) {
                    if (ci.object.get("rootUri")) |ru| {
                        if (ru == .string) {
                            if (fileUriToPath(self.allocator, ru.string)) |path| return path else |_| {}
                        }
                    }
                }
            }
        }
        // Explicit override via environment.  Needed when the indexed root
        // is NOT a git repo itself — e.g. an umbrella directory holding
        // several child repos.  Without this, `walkUpForGit` resolves to a
        // child `.git` (or nothing), the store probe misses the umbrella's
        // warm index, and every session is forced to re-run the exclusive
        // `index_repository` attach.  `ZINDEKS_PROJECT` is the preferred
        // name; `ZINDEKS_ROOT` is accepted as an alias.
        if (envOwnedNonEmpty(self.allocator, "ZINDEKS_PROJECT")) |path| return path;
        if (envOwnedNonEmpty(self.allocator, "ZINDEKS_ROOT")) |path| return path;

        // Fall back to walking up cwd for a `.git` marker.
        return try walkUpForGit(self.allocator);
    }

    // ██████████████████████████████████████████████████████████████████████
    // Post-initialize: tools/list, tools/call, ping, notifications
    // ██████████████████████████████████████████████████████████████████████

    /// Returns true when the worker pool took ownership of `req` (caller
    /// must NOT deinit it).  Returns false when the request was handled
    /// inline and the caller retains ownership.
    fn handleInitialized(self: *Server, req: *protocol.ParsedRequest, is_notification: bool) !bool {
        if (std.mem.eql(u8, req.method, "notifications/initialized")) return false;

        if (is_notification) return false;

        if (std.mem.eql(u8, req.method, "tools/list")) {
            try self.handleToolsList(req.*);
            return false;
        } else if (std.mem.eql(u8, req.method, "tools/call")) {
            return try self.handleToolsCall(req);
        } else if (std.mem.eql(u8, req.method, "ping")) {
            try self.handlePing(req.*);
            return false;
        } else {
            try self.respondError(req.id, .method_not_found);
            return false;
        }
    }

    fn handleToolsList(self: *Server, req: protocol.ParsedRequest) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);

        // Write tools JSON into a temp buffer
        var tools_buf = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("OOM");
        defer tools_buf.deinit(self.allocator);
        try tools.writeToolsListJson(tools_buf.writer(self.allocator));

        try protocol.writeToolsList(writer, req.id, tools_buf.items);
        try self.transport.writeMessage(self.response_buf.items);
    }

    fn handleToolsCall(self: *Server, req: *protocol.ParsedRequest) !bool {
        const params = req.params orelse {
            try self.respondError(req.id, .invalid_params);
            return false;
        };

        const tool_name_val = params.get("name") orelse {
            try self.respondError(req.id, .invalid_params);
            return false;
        };
        const tool_name = switch (tool_name_val) {
            .string => |s| s,
            else => {
                try self.respondError(req.id, .invalid_params);
                return false;
            },
        };

        const args_val = params.get("arguments");
        const args = if (args_val) |a| switch (a) {
            .object => |o| o,
            else => null,
        } else null;

        if (isMutatingTool(tool_name)) {
            try self.runMutatingTool(req, tool_name, args);
            return false; // caller still owns req
        }
        // Read-only. With a connection pool, dispatch to the worker thread
        // pool so concurrent agent queries overlap — each worker owns a private
        // pooled connection.  Without a pool, workers would share the single
        // `self.gdb` handle concurrently, which is unsafe even under
        // SQLITE_THREADSAFE=2, so run inline (serialized) instead.  `self.pool`
        // is only mutated on this (main) thread during attach, so reading it
        // here needs no lock.
        if (self.pool == null) {
            try self.runReadOnlyInline(req, tool_name, args);
            return false; // caller still owns req
        }
        // Worker takes ownership of req and deinits when done.
        self.dispatchReadOnly(req.*, tool_name, args) catch |err| {
            std.log.err("Read-only dispatch failed ({s}); falling back inline", .{@errorName(err)});
            try self.runReadOnlyInline(req, tool_name, args);
            return false;
        };
        return true; // worker now owns req
    }

    /// Inline-tool path: acquire the tool's required sub-lock(s), drain any
    /// concurrent workers, run the handler, run post-call hooks (project load /
    /// overlay reattach), then release the locks.
    ///
    /// Lock acquisition follows the documented order:
    ///   attach_mutex → meta_lock → overlay_rwlock → gdb_rwlock
    fn runMutatingTool(self: *Server, req: *protocol.ParsedRequest, tool_name: []const u8, args: ?std.json.ObjectMap) !void {
        const mode = lockMode(tool_name);

        // Drain workers first so no concurrent reader holds a sub-lock we
        // are about to acquire exclusively.
        self.waitForInflight();

        // Acquire in documented order, release in reverse via defer.
        if (mode.attach) self.attach_mutex.lock();
        defer if (mode.attach) self.attach_mutex.unlock();

        if (mode.meta != .none) self.meta_lock.lock();
        defer if (mode.meta != .none) self.meta_lock.unlock();

        switch (mode.overlay) {
            .none => {},
            .shared => self.overlay_rwlock.lockShared(),
            .exclusive => self.overlay_rwlock.lock(),
        }
        defer {
            switch (mode.overlay) {
                .none => {},
                .shared => self.overlay_rwlock.unlockShared(),
                .exclusive => self.overlay_rwlock.unlock(),
            }
        }

        switch (mode.gdb) {
            .none => {},
            .shared => self.gdb_rwlock.lockShared(),
            .exclusive => self.gdb_rwlock.lock(),
        }
        defer {
            switch (mode.gdb) {
                .none => {},
                .shared => self.gdb_rwlock.unlockShared(),
                .exclusive => self.gdb_rwlock.unlock(),
            }
        }

        // Dispatch into a body buffer first, then wrap with the
        // MCP-compliant `content[0].text = <JSON-escaped string>`
        // envelope.  Failures set `result.isError = true` per spec.
        var body_buf = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("OOM");
        defer body_buf.deinit(self.allocator);
        const body_writer = body_buf.writer(self.allocator);

        var call_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer call_arena.deinit();
        var ctx = tools.Context{
            .allocator = call_arena.allocator(),
            .engine = if (self.engine != null) &self.engine.? else null,
            .gdb = if (self.gdb != null) &self.gdb.? else null,
            .project_path = self.project_path,
            .index_dir = self.index_dir,
            .store_root = self.store_root,
            .transport = &self.transport,
            .request_id = req.id,
            .parser_pool = &self.parser_pool,
            .result_cache = &self.result_cache,
        };
        var is_error = false;
        tools.dispatch(&ctx, tool_name, args, body_writer) catch |err| {
            is_error = true;
            body_buf.shrinkRetainingCapacity(0);
            body_writer.print("{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {};
        };

        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeToolResultEnvelope(writer, req.id, body_buf.items, is_error);
        try self.transport.writeMessage(self.response_buf.items);

        if (std.mem.eql(u8, tool_name, "index_repository")) {
            self.loadProjectLocked(args) catch |err| {
                std.log.err("Failed to load project after indexing: {s}", .{@errorName(err)});
            };
        } else if (std.mem.eql(u8, tool_name, "update_index")) {
            self.reattachOverlayLocked() catch |err| {
                std.log.err("Failed to reattach overlay after update_index: {s}", .{@errorName(err)});
            };
        }
        self.result_cache.clear();
    }

    /// Synchronous fallback for read-only tools when the thread pool
    /// dispatch fails (e.g., OOM under load).  Keeps the loop usable.
    fn runReadOnlyInline(self: *Server, req: *protocol.ParsedRequest, tool_name: []const u8, args: ?std.json.ObjectMap) !void {
        const mode = lockMode(tool_name);
        acquireSharedLocks(self, mode);
        defer releaseSharedLocks(self, mode);
        try self.runReadOnly(req.id, tool_name, args, &self.response_buf);
    }

    /// Core read-only execution path.  Acquires a pooled connection when
    /// available, otherwise falls back to the shared `self.gdb` handle.
    /// Writes the response through `Transport.writeMessage`, which is
    /// mutex-guarded so concurrent workers do not interleave bytes.
    fn runReadOnly(
        self: *Server,
        id: ?std.json.Value,
        tool_name: []const u8,
        args: ?std.json.ObjectMap,
        out_buf: *std.ArrayList(u8),
    ) !void {
        var pooled: ?pool.PooledConnection = null;
        defer if (pooled) |*pc| pc.release();
        if (self.pool) |*p| {
            pooled = p.acquire() catch null;
        }
        const gdb_ptr: ?*graph_db.GraphDb = if (pooled) |*pc|
            &pc.db
        else if (self.gdb != null) &self.gdb.? else null;

        // Body buffer: handler emits raw JSON; we wrap with MCP-compliant
        // envelope (text-as-string + isError flag) after dispatch returns.
        var body_buf = std.ArrayList(u8).initCapacity(self.allocator, 4096) catch @panic("OOM");
        defer body_buf.deinit(self.allocator);
        const body_writer = body_buf.writer(self.allocator);

        const cacheable = isCacheable(tool_name);
        const cache_key: u64 = if (cacheable)
            result_cache_mod.ResultCache.computeKey(tool_name, args, self.allocator)
        else
            0;
        var is_error = false;
        const served_from_cache = cacheable and self.result_cache.getInto(cache_key, &body_buf);
        if (!served_from_cache) {
            var call_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer call_arena.deinit();
            var ctx = tools.Context{
                .allocator = call_arena.allocator(),
                .engine = if (self.engine != null) &self.engine.? else null,
                .gdb = gdb_ptr,
                .project_path = self.project_path,
                .index_dir = self.index_dir,
                .store_root = self.store_root,
                .transport = &self.transport,
                .request_id = id,
                .parser_pool = &self.parser_pool,
                .result_cache = &self.result_cache,
            };
            tools.dispatch(&ctx, tool_name, args, body_writer) catch |err| {
                is_error = true;
                body_buf.shrinkRetainingCapacity(0);
                body_writer.print("{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {};
            };
            if (cacheable and !is_error) self.result_cache.put(cache_key, body_buf.items);
        }

        out_buf.shrinkRetainingCapacity(0);
        const writer = out_buf.writer(self.allocator);
        try protocol.writeToolResultEnvelope(writer, id, body_buf.items, is_error);
        try self.transport.writeMessage(out_buf.items);
    }

    fn dispatchReadOnly(self: *Server, req: protocol.ParsedRequest, tool_name: []const u8, args: ?std.json.ObjectMap) !void {
        try self.ensureThreadPool();
        self.inflightIncrement();
        const owned_name = self.allocator.dupe(u8, tool_name) catch |err| {
            self.inflightDecrement();
            return err;
        };
        const job = WorkerJob{
            .server = self,
            .req = req,
            .tool_name = owned_name,
            .args = args,
        };
        self.thread_pool.spawn(workerEntry, .{job}) catch |err| {
            self.allocator.free(owned_name);
            self.inflightDecrement();
            return err;
        };
    }

    const WorkerJob = struct {
        server: *Server,
        req: protocol.ParsedRequest,
        /// Owned copy of the tool name.  The parsed JSON inside `req` owns
        /// the original; we dupe to avoid lifetime entanglement if the
        /// dispatch races with the main loop freeing the parse.
        tool_name: []u8,
        args: ?std.json.ObjectMap,
    };

    fn workerEntry(job: WorkerJob) void {
        var mut = job;
        defer {
            mut.req.deinit();
            mut.server.allocator.free(mut.tool_name);
            mut.server.inflightDecrement();
        }

        const mode = lockMode(mut.tool_name);
        acquireSharedLocks(mut.server, mode);
        defer releaseSharedLocks(mut.server, mode);

        var local_buf = std.ArrayList(u8).initCapacity(mut.server.allocator, 4096) catch return;
        defer local_buf.deinit(mut.server.allocator);
        mut.server.runReadOnly(mut.req.id, mut.tool_name, mut.args, &local_buf) catch |err| {
            std.log.err("worker tool dispatch failed: {s}", .{@errorName(err)});
        };
    }

    fn handlePing(self: *Server, req: protocol.ParsedRequest) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writePingResult(writer, req.id);
        try self.transport.writeMessage(self.response_buf.items);
    }

    // ██████████████████████████████████████████████████████████████████████
    // Project loading / error responders
    // ██████████████████████████████████████████████████████████████████████

    /// Public entry point: acquires all locks exclusively and loads the
    /// project named in `args.path`.  Safe to call from the main loop's
    /// initialize path or from auto-detect.
    pub fn loadProject(self: *Server, args: ?std.json.ObjectMap) !void {
        self.waitForInflight();
        self.attach_mutex.lock();
        defer self.attach_mutex.unlock();
        self.meta_lock.lock();
        defer self.meta_lock.unlock();
        self.overlay_rwlock.lock();
        defer self.overlay_rwlock.unlock();
        self.gdb_rwlock.lock();
        defer self.gdb_rwlock.unlock();
        try self.loadProjectLocked(args);
    }

    /// State-lock-already-held variant invoked from the mutating-tool path
    /// (which holds the write lock for the full duration of the tool +
    /// post-call effect).
    fn loadProjectLocked(self: *Server, args: ?std.json.ObjectMap) !void {
        const path_val = if (args) |a| a.get("path") else null;
        const path = if (path_val) |v| switch (v) {
            .string => |s| s,
            else => return,
        } else return;
        try self.openProjectByPath(path);
    }

    /// Shared inner implementation used by both `loadProjectLocked` and
    /// the auto-detect path on `initialize`.  Tears down any currently
    /// loaded project, opens the new one, and primes the engine + overlay.
    fn openProjectByPath(self: *Server, path: []const u8) !void {
        // Stop the watcher first — it references the old gdb/project_path and
        // its thread must be joined before those resources are torn down.
        self.stopWatcher();

        var loc = project_store.resolveRead(self.allocator, path, .{ .store_root = self.store_root }) catch {
            return;
        };
        defer loc.deinit();

        // Tear down any previously loaded project (and its pool).
        if (self.pool) |*p| p.deinit();
        self.pool = null;
        if (self.gdb) |*gdb| gdb.close();
        if (self.ann) |*a| a.deinit();
        self.ann = null;
        if (self.overlay) |*ov| ov.close();
        if (self.idx) |*idx| idx.close();
        if (self.project_path) |p| self.allocator.free(p);
        if (self.index_dir) |p| self.allocator.free(p);

        self.gdb = null;
        self.idx = null;
        self.overlay = null;
        self.engine = null;
        self.project_path = null;
        self.index_dir = null;

        // Open binary index
        var idx = storage.Index.open(self.allocator, std.fs.cwd(), loc.index_dir) catch return;
        errdefer idx.close();

        // Open graph DB (single handle for migrations + non-pooled paths).
        const graph_path = std.fs.path.join(self.allocator, &.{ loc.index_dir, "graph.db" }) catch return;
        defer self.allocator.free(graph_path);
        const gpz = self.allocator.dupeZ(u8, graph_path) catch return;
        defer self.allocator.free(gpz);

        var gdb = graph_db.GraphDb.open(gpz) catch {
            idx.close();
            return;
        };

        // Apply migrations on attach so schema added in newer zindeks versions
        // (e.g. the `reasoning` thinking-cache table) self-heals onto projects
        // indexed by an older binary, without requiring a full re-index.
        // Idempotent (CREATE ... IF NOT EXISTS); non-fatal on failure.
        gdb.migrate() catch |err| {
            std.log.warn("migrate on attach failed: {s}", .{@errorName(err)});
        };

        const projected_path = self.allocator.dupe(u8, path) catch {
            gdb.close();
            idx.close();
            return;
        };
        const index_dir_dup = self.allocator.dupe(u8, loc.index_dir) catch {
            self.allocator.free(projected_path);
            gdb.close();
            idx.close();
            return;
        };

        self.idx = idx;
        self.gdb = gdb;
        self.project_path = projected_path;
        self.index_dir = index_dir_dup;

        // Initialize the read-only connection pool.  Failure is non-fatal:
        // handlers fall back to `self.gdb` when no pool is available.
        if (pool.ConnectionPool.init(self.allocator, graph_path, self.info.pool_conns)) |p| {
            self.pool = p;
        } else |err| {
            std.log.warn("Failed to init connection pool: {s} — single-connection fallback", .{@errorName(err)});
        }

        // Engine first so we can attach an overlay onto it.
        self.engine = search.Engine.init(&self.idx.?);

        if (overlay_mod.Overlay.open(self.allocator, std.fs.cwd(), loc.index_dir, &self.idx.?) catch null) |ov| {
            self.overlay = ov;
            self.engine.?.useOverlay(&self.overlay.?);
        }

        // Load the persisted ANN index (if any) and attach it to the engine.
        // Absent or below-threshold projects simply use the linear scan.
        if (semantic.loadAnn(loc.index_dir, self.allocator) catch null) |loaded| {
            self.ann = loaded;
            self.engine.?.useAnn(&self.ann.?);
        }

        // Start the background file watcher if ZINDEKS_WATCH is set.
        // Called after full attach so all resources are stable.
        self.startWatcherIfEnabled();
    }

    /// Re-open the on-disk overlay (after `update_index` rewrites it) and
    /// re-attach it to the engine so subsequent searches see the delta.
    /// Also reloads the ANN index in case the embedding set changed.
    fn reattachOverlayLocked(self: *Server) !void {
        const idx_dir = self.index_dir orelse return;
        const base = if (self.idx != null) &self.idx.? else return;

        if (self.overlay) |*ov| ov.close();
        self.overlay = null;
        if (self.engine) |*e| e.overlay = null;

        if (overlay_mod.Overlay.open(self.allocator, std.fs.cwd(), idx_dir, base) catch null) |ov| {
            self.overlay = ov;
            if (self.engine) |*e| e.useOverlay(&self.overlay.?);
        }

        // Reload the ANN index — update_index may have changed the embeddings.
        if (self.ann) |*a| a.deinit();
        self.ann = null;
        if (semantic.loadAnn(idx_dir, self.allocator) catch null) |loaded| {
            self.ann = loaded;
            if (self.engine) |*e| e.useAnn(&self.ann.?);
        }
    }

    // ██████████████████████████████████████████████████████████████████████
    // File-watcher driven auto-refresh (E1)
    // ██████████████████████████████████████████████████████████████████████

    /// Apply an incremental index refresh triggered by the file watcher.
    /// Runs on the watcher thread. Acquires sub-locks in the documented order
    /// (meta -> overlay -> gdb) so it never deadlocks against request handlers.
    fn refreshIndexLocked(self: *Server) void {
        // Non-blocking acquisition is mandatory: the watcher thread must never
        // block on a project lock. A concurrent index_repository joins this
        // thread (via stopWatcher in openProjectByPath) WHILE holding these
        // locks exclusively — a blocking acquire here would deadlock the join.
        // On contention we skip; the next poll tick retries. Exclusive locks
        // also exclude in-flight readers, so no waitForInflight is needed.
        if (!self.meta_lock.tryLock()) return;
        defer self.meta_lock.unlock();
        if (!self.overlay_rwlock.tryLock()) return;
        defer self.overlay_rwlock.unlock();
        if (!self.gdb_rwlock.tryLock()) return;
        defer self.gdb_rwlock.unlock();

        if (self.gdb == null) return;

        var body_buf = std.ArrayList(u8).initCapacity(self.allocator, 1024) catch return;
        defer body_buf.deinit(self.allocator);
        const body_writer = body_buf.writer(self.allocator);

        var call_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer call_arena.deinit();
        var ctx = tools.Context{
            .allocator = call_arena.allocator(),
            .engine = if (self.engine != null) &self.engine.? else null,
            .gdb = if (self.gdb != null) &self.gdb.? else null,
            .project_path = self.project_path,
            .index_dir = self.index_dir,
            .store_root = self.store_root,
            .transport = &self.transport,
            .request_id = null,
            .parser_pool = &self.parser_pool,
            .result_cache = &self.result_cache,
        };
        tools.dispatch(&ctx, "update_index", null, body_writer) catch |err| {
            std.log.err("watcher refresh failed: {s}", .{@errorName(err)});
            return;
        };
        self.reattachOverlayLocked() catch |err| {
            std.log.err("watcher overlay reattach failed: {s}", .{@errorName(err)});
        };
        self.result_cache.clear();
    }

    fn watcherCallback(ctx: ?*anyopaque, events: []const watcher_mod.Event) void {
        _ = events; // refresh re-detects the full delta itself
        const self: *Server = @ptrCast(@alignCast(ctx orelse return));
        self.refreshIndexLocked();
    }

    fn stopWatcher(self: *Server) void {
        if (self.watcher) |w| {
            w.deinit(); // stops thread + frees its owned project_path copy
            self.allocator.destroy(w);
            self.watcher = null;
        }
    }

    /// Start the background watcher if ZINDEKS_WATCH is set and a project is
    /// loaded. Idempotent: stops any existing watcher first.
    fn startWatcherIfEnabled(self: *Server) void {
        self.stopWatcher();
        const enabled = envOwnedNonEmpty(self.allocator, "ZINDEKS_WATCH") orelse return;
        // envOwnedNonEmpty returns an owned slice — free it after use.
        self.allocator.free(enabled);
        const pp = self.project_path orelse return;
        if (self.gdb == null) return;
        var interval_ms: u32 = 2000;
        if (envOwnedNonEmpty(self.allocator, "ZINDEKS_WATCH_INTERVAL_MS")) |iv| {
            defer self.allocator.free(iv);
            interval_ms = std.fmt.parseInt(u32, iv, 10) catch 2000;
        }
        const w = self.allocator.create(watcher_mod.PollWatcher) catch return;
        w.* = watcher_mod.PollWatcher.init(self.allocator, &self.gdb.?, pp, interval_ms, watcherCallback, self);
        w.start() catch {
            w.deinit();
            self.allocator.destroy(w);
            return;
        };
        self.watcher = w;
        std.log.info("file watcher enabled (interval {d}ms)", .{interval_ms});
    }

    fn respondError(self: *Server, id: ?std.json.Value, code: protocol.ErrorCode) !void {
        self.response_buf.shrinkRetainingCapacity(0);
        const writer = self.response_buf.writer(self.allocator);
        try protocol.writeErrorNoData(writer, id, code);
        try self.transport.writeMessage(self.response_buf.items);
    }

    fn respondErrorMaybe(self: *Server, raw: []const u8, code: protocol.ErrorCode) !void {
        const id: ?std.json.Value = if (std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{})) |parsed| blk: {
            defer parsed.deinit();
            break :blk parsed.value.object.get("id");
        } else |_| null;
        try self.respondError(id, code);
    }

    // ██████████████████████████████████████████████████████████████████████
    // Transport-independent execution (HTTP front-end)
    //
    // `executeMessageToBuffer` runs one JSON-RPC message synchronously on the
    // caller's thread and writes the reply into `out` (no transport, no worker
    // pool).  An HTTP server can call this from many connection threads at
    // once: shared state is guarded by the same fine-grained rwlocks the stdio
    // path uses, read-only tools take shared locks (true concurrency), and
    // mutating tools take exclusive locks (the rwlock drains concurrent
    // readers — no inflight counter needed since no worker pool is running).
    // ██████████████████████████████████████████████████████████████████████

    /// Attach a warm project resolved from env / cwd-git-walk (params=null).
    /// Idempotent; safe to call at HTTP startup and lazily on first initialize.
    pub fn autoAttach(self: *Server) void {
        self.tryAutoAttach(null) catch |err| {
            std.log.debug("auto-attach skipped: {s}", .{@errorName(err)});
        };
    }

    /// Execute one raw JSON-RPC message, writing the response into `out`.
    /// Returns true when `out` holds a response, false for notifications
    /// (which get no reply).  Transport-independent and thread-safe against a
    /// shared `Server`.
    pub fn executeMessageToBuffer(self: *Server, raw: []const u8, out: *std.ArrayList(u8)) !bool {
        out.clearRetainingCapacity();
        const w = out.writer(self.allocator);

        var req = (try protocol.parseRequest(self.allocator, raw)) orelse {
            try protocol.writeErrorNoData(w, null, .parse_error);
            return true;
        };
        defer req.deinit();

        if (std.mem.eql(u8, req.method, "initialize")) {
            const requested: ?[]const u8 = blk: {
                if (req.params) |p| {
                    if (p.get("protocolVersion")) |pv| {
                        if (pv == .string) break :blk pv.string;
                    }
                }
                break :blk null;
            };
            const negotiated = protocol.negotiateProtocolVersion(requested);
            try protocol.writeInitializeResultV(w, req.id, self.info.name, self.info.version, negotiated);
            self.initialized = true;
            // Lazily attach a warm project if none is bound yet.
            self.meta_lock.lock();
            const need_attach = self.project_path == null;
            self.meta_lock.unlock();
            if (need_attach) self.autoAttach();
            return true;
        }

        if (protocol.isNotification(req)) return false;

        if (std.mem.eql(u8, req.method, "tools/list")) {
            var tbuf = std.ArrayList(u8){};
            defer tbuf.deinit(self.allocator);
            try tools.writeToolsListJson(tbuf.writer(self.allocator));
            try protocol.writeToolsList(w, req.id, tbuf.items);
            return true;
        }
        if (std.mem.eql(u8, req.method, "ping")) {
            try protocol.writePingResult(w, req.id);
            return true;
        }
        if (std.mem.eql(u8, req.method, "tools/call")) {
            try self.executeToolCallToBuffer(&req, out);
            return true;
        }
        try protocol.writeErrorNoData(w, req.id, .method_not_found);
        return true;
    }

    fn executeToolCallToBuffer(self: *Server, req: *protocol.ParsedRequest, out: *std.ArrayList(u8)) !void {
        const w = out.writer(self.allocator);
        const params = req.params orelse {
            try protocol.writeErrorNoData(w, req.id, .invalid_params);
            return;
        };
        const tool_name_val = params.get("name") orelse {
            try protocol.writeErrorNoData(w, req.id, .invalid_params);
            return;
        };
        const tool_name = switch (tool_name_val) {
            .string => |s| s,
            else => {
                try protocol.writeErrorNoData(w, req.id, .invalid_params);
                return;
            },
        };
        const args_val = params.get("arguments");
        const args = if (args_val) |a| switch (a) {
            .object => |o| o,
            else => null,
        } else null;

        const mode = lockMode(tool_name);

        var body_buf = std.ArrayList(u8){};
        defer body_buf.deinit(self.allocator);
        const body_writer = body_buf.writer(self.allocator);

        if (isMutatingTool(tool_name)) {
            // Exclusive locks in the documented order; the rwlock's exclusive
            // side waits for concurrent readers to drain.
            if (mode.attach) self.attach_mutex.lock();
            defer if (mode.attach) self.attach_mutex.unlock();
            if (mode.meta != .none) self.meta_lock.lock();
            defer if (mode.meta != .none) self.meta_lock.unlock();
            switch (mode.overlay) {
                .none => {},
                .shared => self.overlay_rwlock.lockShared(),
                .exclusive => self.overlay_rwlock.lock(),
            }
            defer switch (mode.overlay) {
                .none => {},
                .shared => self.overlay_rwlock.unlockShared(),
                .exclusive => self.overlay_rwlock.unlock(),
            };
            switch (mode.gdb) {
                .none => {},
                .shared => self.gdb_rwlock.lockShared(),
                .exclusive => self.gdb_rwlock.lock(),
            }
            defer switch (mode.gdb) {
                .none => {},
                .shared => self.gdb_rwlock.unlockShared(),
                .exclusive => self.gdb_rwlock.unlock(),
            };

            var call_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer call_arena.deinit();
            var ctx = tools.Context{
                .allocator = call_arena.allocator(),
                .engine = if (self.engine != null) &self.engine.? else null,
                .gdb = if (self.gdb != null) &self.gdb.? else null,
                .project_path = self.project_path,
                .index_dir = self.index_dir,
                .store_root = self.store_root,
                .transport = null,
                .request_id = req.id,
                .parser_pool = &self.parser_pool,
                .result_cache = &self.result_cache,
            };
            var is_error = false;
            tools.dispatch(&ctx, tool_name, args, body_writer) catch |err| {
                is_error = true;
                body_buf.clearRetainingCapacity();
                body_writer.print("{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {};
            };
            try protocol.writeToolResultEnvelope(w, req.id, body_buf.items, is_error);

            if (std.mem.eql(u8, tool_name, "index_repository")) {
                self.loadProjectLocked(args) catch |err| {
                    std.log.err("Failed to load project after indexing: {s}", .{@errorName(err)});
                };
            } else if (std.mem.eql(u8, tool_name, "update_index")) {
                self.reattachOverlayLocked() catch |err| {
                    std.log.err("Failed to reattach overlay after update_index: {s}", .{@errorName(err)});
                };
            }
            self.result_cache.clear();
            return;
        }

        // Read-only: shared locks + a pooled connection for true concurrency.
        acquireSharedLocks(self, mode);
        defer releaseSharedLocks(self, mode);

        var pooled: ?pool.PooledConnection = null;
        defer if (pooled) |*pc| pc.release();
        if (self.pool) |*p| {
            pooled = p.acquire() catch null;
        }
        const gdb_ptr: ?*graph_db.GraphDb = if (pooled) |*pc|
            &pc.db
        else if (self.gdb != null) &self.gdb.? else null;

        const cacheable = isCacheable(tool_name);
        const cache_key: u64 = if (cacheable)
            result_cache_mod.ResultCache.computeKey(tool_name, args, self.allocator)
        else
            0;
        var is_error = false;
        const served_from_cache = cacheable and self.result_cache.getInto(cache_key, &body_buf);
        if (!served_from_cache) {
            var call_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer call_arena.deinit();
            var ctx = tools.Context{
                .allocator = call_arena.allocator(),
                .engine = if (self.engine != null) &self.engine.? else null,
                .gdb = gdb_ptr,
                .project_path = self.project_path,
                .index_dir = self.index_dir,
                .store_root = self.store_root,
                .transport = null,
                .request_id = req.id,
                .parser_pool = &self.parser_pool,
                .result_cache = &self.result_cache,
            };
            tools.dispatch(&ctx, tool_name, args, body_writer) catch |err| {
                is_error = true;
                body_buf.clearRetainingCapacity();
                body_writer.print("{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch {};
            };
            if (cacheable and !is_error) self.result_cache.put(cache_key, body_buf.items);
        }
        try protocol.writeToolResultEnvelope(w, req.id, body_buf.items, is_error);
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Fine-grained lock helpers (B2)
// ██████████████████████████████████████████████████████████████████████████

/// Acquire the shared (reader) sides of whichever sub-locks `mode` requires.
/// Lock acquisition order: meta_lock → overlay_rwlock → gdb_rwlock.
/// (attach_mutex is never needed for read-only paths.)
fn acquireSharedLocks(server: *Server, mode: LockMode) void {
    if (mode.meta != .none) server.meta_lock.lock();
    if (mode.overlay != .none) server.overlay_rwlock.lockShared();
    if (mode.gdb != .none) server.gdb_rwlock.lockShared();
}

/// Release the shared sides of whichever sub-locks `mode` requires.
/// Release order is reverse of acquisition (meta last, gdb first).
fn releaseSharedLocks(server: *Server, mode: LockMode) void {
    if (mode.gdb != .none) server.gdb_rwlock.unlockShared();
    if (mode.overlay != .none) server.overlay_rwlock.unlockShared();
    if (mode.meta != .none) server.meta_lock.unlock();
}

// ██████████████████████████████████████████████████████████████████████████
// Auto-detect helpers
// ██████████████████████████████████████████████████████████████████████████

/// Convert a `file://` URI to a filesystem path.  Handles both POSIX and
/// Windows variants (`file:///C:/foo`).  Returns an owned slice on success.
fn fileUriToPath(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.NotAFileUri;
    var rest = uri[prefix.len..];
    // Strip the optional empty host segment.
    if (rest.len > 0 and rest[0] == '/') rest = rest;
    // Windows: `file:///C:/foo` → `/C:/foo` → `C:/foo`.
    if (rest.len >= 3 and rest[0] == '/' and std.ascii.isAlphabetic(rest[1]) and rest[2] == ':') {
        rest = rest[1..];
    }
    return try allocator.dupe(u8, rest);
}

/// Read an environment variable into an owned slice, returning null when it
/// is unset or empty.  Caller owns the returned memory.
fn envOwnedNonEmpty(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    const val = std.process.getEnvVarOwned(allocator, key) catch return null;
    if (val.len == 0) {
        allocator.free(val);
        return null;
    }
    return val;
}

/// Walk upward from cwd looking for a directory containing `.git`.  Returns
/// an owned absolute path on success, or null if none is found before the
/// filesystem root.
fn walkUpForGit(allocator: std.mem.Allocator) !?[]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);
    var current = try allocator.dupe(u8, cwd);
    errdefer allocator.free(current);

    while (true) {
        const marker = try std.fs.path.join(allocator, &.{ current, ".git" });
        defer allocator.free(marker);
        if (std.fs.accessAbsolute(marker, .{})) {
            return current;
        } else |_| {}

        const parent = std.fs.path.dirname(current) orelse {
            allocator.free(current);
            return null;
        };
        if (std.mem.eql(u8, parent, current)) {
            allocator.free(current);
            return null;
        }
        const parent_owned = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = parent_owned;
    }
}
