//! BM25 search engine with IDF-aware scoring and document length normalization.
//!
//! Uses the standard BM25 formula:
//!   score = Σ IDF(qi) * TF(d, qi)
//!   IDF = log(1 + (N - df + 0.5) / (df + 0.5))
//!   TF  = tf * (k1 + 1) / (tf + k1 * (1 - b + b * doc_len / avg_doc_len))
//!
//! Defaults: k1 = 1.5, b = 0.75
//!
//! Hybrid search fuses BM25 keyword scores with semantic similarity
//! using Reciprocal Rank Fusion (RRF): score = Σ 1/(k + rank)  with k=60.

const std = @import("std");
const storage = @import("../storage/index.zig");
const graph_db = @import("../storage/graph_db.zig");
const overlay_mod = @import("../storage/overlay.zig");
const semantic = @import("semantic.zig");
const hnsw = @import("hnsw.zig");
const leiden = @import("../graph/leiden.zig");
const ai_query = @import("../ai/query.zig");

/// BM25 tuning constants.
pub const BM25_DEFAULTS = struct {
    pub const k1: f32 = 1.5;
    pub const b: f32 = 0.75;
};

/// RRF constant — controls the influence of high-ranked vs high-ranked items.
pub const RRF_K: f32 = 60.0;

/// Multi-signal scoring weights.
pub const SIGNAL_WEIGHTS = struct {
    /// Weight for graph-proximity boost (0 = disabled).
    pub const graph_proximity: f32 = 0.15;
    /// Weight for symbol-kind boost (0 = disabled).
    pub const kind_boost: f32 = 0.10;
    /// Minimum edge confidence to follow for graph proximity.
    pub const min_edge_confidence: f32 = 0.3;
    /// Weight for same-community cohesion boost (narrow/cohesion bias).
    pub const community_cohesion: f32 = 0.12;
    /// Weight for repeat-community diversity decay (broad/diversity bias).
    pub const community_diversity: f32 = 0.10;
};

pub const Result = struct {
    doc_id: u32,
    score: f32,
    path: []const u8,
    snippet: []const u8,
};

/// Sentinel `doc_id` for hybrid results that exist only in the semantic
/// id-space (a pure-semantic hit with no BM25 segment id). Never used as an
/// index into any segment — only surfaced in output.
pub const NO_DOC_ID: u32 = std.math.maxInt(u32);

pub const SearchResults = struct {
    items: []Result,

    pub fn deinit(self: *SearchResults, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.items = &.{};
    }
};

/// Hybrid search result with both BM25 and semantic scores.
pub const HybridResult = struct {
    doc_id: u32,
    path: []const u8,
    snippet: []const u8,
    bm25_score: f32,
    semantic_score: f32,
    fused_score: f32,
};

pub const HybridResults = struct {
    items: []HybridResult,

    pub fn deinit(self: *HybridResults, allocator: std.mem.Allocator) void {
        // `path` is owned (duped per item); `snippet` is borrowed (index-stable
        // mmap slice or the empty literal) and is not freed.
        for (self.items) |item| allocator.free(item.path);
        allocator.free(self.items);
        self.items = &.{};
    }
};

/// Multi-signal search result — extends hybrid with graph proximity and kind boost.
pub const MultiSignalResult = struct {
    doc_id: u32,
    path: []const u8,
    snippet: []const u8,
    bm25_score: f32,
    semantic_score: f32,
    fused_score: f32,
    graph_proximity_score: f32,
    kind_boost_score: f32,
    community_score: f32,
    final_score: f32,
};

pub const MultiSignalResults = struct {
    items: []MultiSignalResult,

    pub fn deinit(self: *MultiSignalResults, allocator: std.mem.Allocator) void {
        // `path` is owned (duped per item); `snippet` is borrowed.
        for (self.items) |item| allocator.free(item.path);
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub const SymbolHit = struct {
    doc_id: u32,
    path: []const u8,
    name: []const u8,
    kind: storage.SymbolKind,
    line: u32,
    byte_off: u32,
};

const ScoredDoc = struct {
    doc_id: u32,
    score: f32,
    path: []const u8,
};

// ── B8: Snippet LRU cache ─────────────────────────────────────────────────
//
// Keyed by (doc_id, first 16 bytes of first query term) → content slice.
// Content slices point into the mmap'd index (stable for the engine lifetime),
// so no allocation is needed for the values.
//
// LRU eviction: 256-entry ring buffer tracks insertion order; on overflow,
// the oldest key is removed from the hash map.
//
// Thread safety: Mutex-protected.

pub const SnippetCacheKey = struct {
    doc_id: u32,
    term: [16]u8,
    term_len: u8,

    pub fn init(doc_id: u32, first_term: []const u8) SnippetCacheKey {
        var k = SnippetCacheKey{ .doc_id = doc_id, .term = undefined, .term_len = undefined };
        const n = @min(first_term.len, 16);
        @memcpy(k.term[0..n], first_term[0..n]);
        if (n < 16) @memset(k.term[n..], 0);
        k.term_len = @intCast(n);
        return k;
    }
};

const SNIPPET_LRU_CAP = 256;

pub const SnippetLruCache = struct {
    mu: std.Thread.Mutex,
    map: std.AutoHashMapUnmanaged(SnippetCacheKey, []const u8),
    ring: [SNIPPET_LRU_CAP]SnippetCacheKey,
    ring_head: usize, // next write position (oldest entry)
    count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SnippetLruCache {
        return .{
            .mu = .{},
            .map = .{},
            .ring = undefined,
            .ring_head = 0,
            .count = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SnippetLruCache) void {
        self.map.deinit(self.allocator);
        self.* = undefined;
    }

    /// Look up cached snippet. Returns null on miss.
    pub fn get(self: *SnippetLruCache, key: SnippetCacheKey) ?[]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        return self.map.get(key);
    }

    /// Insert a snippet. Evicts the oldest entry when at capacity.
    pub fn put(self: *SnippetLruCache, key: SnippetCacheKey, value: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();

        // Already cached?
        if (self.map.contains(key)) return;

        if (self.count >= SNIPPET_LRU_CAP) {
            // Evict oldest
            const evict_key = self.ring[self.ring_head];
            _ = self.map.remove(evict_key);
            // count stays the same — we replace
        } else {
            self.count += 1;
        }

        self.ring[self.ring_head] = key;
        self.ring_head = (self.ring_head + 1) % SNIPPET_LRU_CAP;

        self.map.put(self.allocator, key, value) catch {};
    }
};

/// Bounded cache mapping normalized term → (df, postings slice).
///
/// Postings are slices into the mmap'd index file and remain valid for the
/// lifetime of the Index, so caching them across queries is safe.  Eviction
/// strategy is bulk-clear at capacity — same as `cache.StatementCache` —
/// since "hot" search terms re-cache cheaply on the next query.
pub const TermCache = struct {
    map: std.StringHashMapUnmanaged(storage.TermLookup),
    allocator: std.mem.Allocator,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) TermCache {
        return .{ .map = .{}, .allocator = allocator, .capacity = capacity };
    }

    pub fn deinit(self: *TermCache) void {
        self.clear();
        self.map.deinit(self.allocator);
    }

    pub fn clear(self: *TermCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.map.clearRetainingCapacity();
    }

    /// Look up a term, falling back to `index.lookupTerm` on miss and
    /// caching the result.  `normalized` must outlive the call but does not
    /// need to outlive the cache — we dupe on insert.
    pub fn lookup(self: *TermCache, index: *const storage.Index, normalized: []const u8) ?storage.TermLookup {
        if (self.map.get(normalized)) |hit| return hit;
        const result = index.lookupTerm(normalized) orelse return null;
        if (self.map.count() >= self.capacity) self.clear();
        const key = self.allocator.dupe(u8, normalized) catch return result;
        self.map.put(self.allocator, key, result) catch {
            self.allocator.free(key);
        };
        return result;
    }
};

pub const Engine = struct {
    index: *const storage.Index,
    avg_doc_len: f32,
    k1: f32,
    b: f32,
    term_cache: ?*TermCache = null,
    /// Optional BM25 delta overlay produced by incremental updates.  When
    /// present, every base lookup is paired with an overlay lookup, base
    /// hits whose doc-id is tombstoned are dropped, and overlay hits are
    /// scored with their doc-id offset by `base.docCount()` so the merged
    /// result list has unique IDs.
    overlay: ?*overlay_mod.Overlay = null,
    /// Optional HNSW approximate-nearest-neighbor index over document
    /// embeddings.  When present, hybrid/semantic search query it (with an
    /// exact f32 re-rank) instead of scanning every embedding linearly.
    /// Must outlive the engine; owned by the caller (the MCP server).
    ann: ?*hnsw.Hnsw = null,
    /// B8: Optional snippet LRU cache. Owned by the Engine when non-null.
    /// Initialize via Engine.initWithSnippetCache or attach via useSnippetCache.
    snippet_cache: ?*SnippetLruCache = null,
    /// Allocator stored for snippet_cache ownership (used in deinit).
    _snippet_cache_owned: bool = false,
    _snippet_cache_allocator: std.mem.Allocator = undefined,

    pub fn init(index: *const storage.Index) Engine {
        return .{
            .index = index,
            .avg_doc_len = index.avgDocLength(),
            .k1 = BM25_DEFAULTS.k1,
            .b = BM25_DEFAULTS.b,
        };
    }

    /// Create an engine with snippet LRU cache allocated and owned by the engine.
    pub fn initWithSnippetCache(index: *const storage.Index, allocator: std.mem.Allocator) !Engine {
        const cache_ptr = try allocator.create(SnippetLruCache);
        cache_ptr.* = SnippetLruCache.init(allocator);
        return .{
            .index = index,
            .avg_doc_len = index.avgDocLength(),
            .k1 = BM25_DEFAULTS.k1,
            .b = BM25_DEFAULTS.b,
            .snippet_cache = cache_ptr,
            ._snippet_cache_owned = true,
            ._snippet_cache_allocator = allocator,
        };
    }

    /// Attach an externally managed snippet cache.
    pub fn useSnippetCache(self: *Engine, cache: *SnippetLruCache) void {
        self.snippet_cache = cache;
        self._snippet_cache_owned = false;
    }

    /// Free owned resources (snippet cache if owned).
    pub fn deinit(self: *Engine) void {
        if (self._snippet_cache_owned) {
            if (self.snippet_cache) |c| {
                c.deinit();
                self._snippet_cache_allocator.destroy(c);
            }
        }
    }

    /// Create an engine with custom BM25 parameters.
    pub fn initTuned(index: *const storage.Index, k1: f32, b: f32) Engine {
        return .{
            .index = index,
            .avg_doc_len = index.avgDocLength(),
            .k1 = k1,
            .b = b,
        };
    }

    /// Attach a term cache.  The cache must outlive the engine.  When set,
    /// `search` consults the cache before falling through to the binary
    /// search in `Index.lookupTerm`.
    pub fn useTermCache(self: *Engine, cache: *TermCache) void {
        self.term_cache = cache;
    }

    /// Attach a BM25 overlay.  Must outlive the engine.  After this call,
    /// every search reflects the overlay's adds/deletes on top of the base
    /// index — no re-build required.
    pub fn useOverlay(self: *Engine, ov: *overlay_mod.Overlay) void {
        self.overlay = ov;
    }

    /// Attach an HNSW ANN index.  Must outlive the engine.  When set,
    /// hybrid/semantic search use approximate nearest-neighbor lookup with an
    /// exact re-rank instead of a linear embedding scan.
    pub fn useAnn(self: *Engine, index: *hnsw.Hnsw) void {
        self.ann = index;
    }

    /// Internal: lookup with cache when available.
    inline fn lookupTerm(self: *Engine, normalized: []const u8) ?storage.TermLookup {
        if (self.term_cache) |c| return c.lookup(self.index, normalized);
        return self.index.lookupTerm(normalized);
    }

    /// Combined doc count across base and any attached overlay.  Drives the
    /// `N` term in IDF so the formula reflects the current document set,
    /// not just the base snapshot.
    inline fn combinedDocCount(self: *const Engine) u32 {
        const base = self.index.docCount();
        if (self.overlay) |ov| return base + ov.docCount();
        return base;
    }

    /// Resolve a merged doc id (base IDs first, then overlay IDs at offset
    /// `base.docCount()`) back to its `token_count` for BM25 length norm.
    inline fn tokenCount(self: *const Engine, combined_id: u32) u32 {
        const base = self.index.docCount();
        if (combined_id < base) return self.index.docs[combined_id].token_count;
        if (self.overlay) |ov| {
            const local = combined_id - base;
            if (local < ov.sub_index.docCount()) return ov.sub_index.docs[local].token_count;
        }
        return 0;
    }

    /// Resolve a merged doc id to a file path.
    inline fn filePathFor(self: *const Engine, combined_id: u32) []const u8 {
        const base = self.index.docCount();
        if (combined_id < base) return self.index.filePath(combined_id);
        if (self.overlay) |ov| {
            const local = combined_id - base;
            if (local < ov.sub_index.docCount()) return ov.sub_index.filePath(local);
        }
        return "";
    }

    /// Resolve a merged doc id to file content (used by snippet extraction).
    inline fn fileContentFor(self: *const Engine, combined_id: u32) []const u8 {
        const base = self.index.docCount();
        if (combined_id < base) return self.index.fileContent(combined_id);
        if (self.overlay) |ov| {
            const local = combined_id - base;
            if (local < ov.sub_index.docCount()) return ov.sub_index.fileContent(local);
        }
        return "";
    }

    /// Fixed-capacity score buffer using linear probing.  Avoids heap
    /// allocation for the common case of < 512 unique doc ids per query.
    const ScoreBuf = struct {
        const CAP = 512;
        const Entry = struct { doc_id: u32, score: f32, used: bool };
        entries: [CAP]Entry,
        count: usize,
        fallback: ?std.AutoHashMap(u32, f32),
        allocator: std.mem.Allocator,

        fn init(allocator: std.mem.Allocator) ScoreBuf {
            var buf: ScoreBuf = .{
                .entries = undefined,
                .count = 0,
                .fallback = null,
                .allocator = allocator,
            };
            @memset(&buf.entries, .{ .doc_id = 0, .score = 0, .used = false });
            return buf;
        }

        fn deinit(self: *ScoreBuf) void {
            if (self.fallback) |*fb| fb.deinit();
        }

        fn getOrPut(self: *ScoreBuf, doc_id: u32) !*f32 {
            if (self.fallback) |*fb| {
                const entry = try fb.getOrPut(doc_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                return entry.value_ptr;
            }
            if (self.count >= CAP * 3 / 4) {
                // Promote to hash map when load factor exceeds 75%
                var fb = std.AutoHashMap(u32, f32).init(self.allocator);
                for (&self.entries) |*e| {
                    if (!e.used) continue;
                    try fb.put(e.doc_id, e.score);
                }
                self.fallback = fb;
                const entry = try fb.getOrPut(doc_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                return entry.value_ptr;
            }
            var idx = doc_id % CAP;
            for (0..CAP) |_| {
                const e = &self.entries[idx];
                if (!e.used) {
                    e.doc_id = doc_id;
                    e.score = 0;
                    e.used = true;
                    self.count += 1;
                    return &e.score;
                }
                if (e.doc_id == doc_id) return &e.score;
                idx = (idx + 1) % CAP;
            }
            unreachable;
        }

        fn collect(self: *ScoreBuf, allocator: std.mem.Allocator) !std.ArrayList(ScoredDoc) {
            if (self.fallback) |*fb| {
                var scored = std.ArrayList(ScoredDoc).initCapacity(allocator, fb.count()) catch @panic("OOM");
                var it = fb.iterator();
                while (it.next()) |entry| {
                    try scored.append(allocator, .{
                        .doc_id = entry.key_ptr.*,
                        .score = entry.value_ptr.*,
                        .path = "", // filled later
                    });
                }
                return scored;
            }
            var scored = std.ArrayList(ScoredDoc).initCapacity(allocator, self.count) catch @panic("OOM");
            for (&self.entries) |*e| {
                if (!e.used) continue;
                try scored.append(allocator, .{
                    .doc_id = e.doc_id,
                    .score = e.score,
                    .path = "", // filled later
                });
            }
            return scored;
        }
    };

    pub fn search(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        var scores = ScoreBuf.init(allocator);
        defer scores.deinit();

        // N for IDF spans base + overlay so the formula reflects the
        // current document set after incremental updates.
        const n: f32 = @floatFromInt(self.combinedDocCount());
        const base_doc_count = self.index.docCount();
        var term_buf: [256]u8 = undefined;

        var i: usize = 0;
        while (i < query.len) {
            while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
            const start = i;
            while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
            if (start == i) continue;
            const term = storage.normalizeInto(&term_buf, query[start..i]);

            // Combine df across base and overlay before computing IDF so a
            // term that is rare in the base but common in the overlay still
            // gets a fair weighting.
            const base_lookup = self.lookupTerm(term);
            const overlay_lookup: ?storage.TermLookup = if (self.overlay) |ov|
                ov.sub_index.lookupTerm(term)
            else
                null;

            const total_df_u: u32 = (if (base_lookup) |bl| bl.df else 0) +
                (if (overlay_lookup) |ol| ol.df else 0);
            if (total_df_u == 0) continue;
            const df: f32 = @floatFromInt(total_df_u);
            const idf: f32 = @log(1.0 + (n - df + 0.5) / (df + 0.5));

            if (base_lookup) |lookup| {
                for (lookup.postings) |p| {
                    if (self.overlay) |ov| {
                        if (ov.isTombstoned(p.doc_id)) continue;
                    }
                    const tf: f32 = @floatFromInt(p.tf);
                    const doc_len: f32 = @floatFromInt(self.index.docs[p.doc_id].token_count);
                    const norm_len = doc_len / self.avg_doc_len;
                    const tf_score = (tf * (self.k1 + 1.0)) / (tf + self.k1 * (1.0 - self.b + self.b * norm_len));
                    const bm25_score = idf * tf_score;
                    const score_ptr = try scores.getOrPut(p.doc_id);
                    score_ptr.* += bm25_score;
                }
            }

            if (overlay_lookup) |lookup| {
                const ov = self.overlay.?;
                for (lookup.postings) |p| {
                    const combined_id = p.doc_id + base_doc_count;
                    const tf: f32 = @floatFromInt(p.tf);
                    const doc_len: f32 = @floatFromInt(ov.sub_index.docs[p.doc_id].token_count);
                    const norm_len = doc_len / self.avg_doc_len;
                    const tf_score = (tf * (self.k1 + 1.0)) / (tf + self.k1 * (1.0 - self.b + self.b * norm_len));
                    const bm25_score = idf * tf_score;
                    const score_ptr = try scores.getOrPut(combined_id);
                    score_ptr.* += bm25_score;
                }
            }
        }

        var scored = try scores.collect(allocator);
        defer scored.deinit(allocator);

        for (scored.items) |*item| {
            item.path = self.filePathFor(item.doc_id);
        }
        std.mem.sort(ScoredDoc, scored.items, {}, lessScoredDoc);
        if (scored.items.len > limit) scored.shrinkRetainingCapacity(limit);

        const results = try allocator.alloc(Result, scored.items.len);
        for (scored.items, 0..) |item, result_index| {
            results[result_index] = .{
                .doc_id = item.doc_id,
                .score = item.score,
                .path = item.path,
                .snippet = self.snippetFor(item.doc_id, query),
            };
        }
        return .{ .items = results };
    }

    /// Hybrid search: fuse BM25 keyword ranking with semantic similarity
    /// using Reciprocal Rank Fusion (RRF).
    ///
    /// RRF formula: score = Σ 1/(k + rank)  where k = 60 (default).
    ///
    ///   - gdb: Open graph database (must have embeddings stored)
    ///   - query: Search query string
    ///   - limit: Maximum results to return
    ///   - allocator: Memory allocator
    pub fn hybridSearch(
        self: *Engine,
        gdb: *graph_db.GraphDb,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
    ) !HybridResults {
        // Short-circuit when the query is clearly a symbol lookup.  Semantic
        // search adds latency proportional to the embedding-table size and
        // never wins for exact identifier matches.
        if (classifyQuery(query) == .identifier_only) {
            return bm25Only(self, allocator, query, limit);
        }

        // 1+2. Get BM25 and semantic results concurrently.
        // Semantic search touches the gdb connection; BM25 touches the index/overlay.
        // These are disjoint resources so concurrent execution is safe.
        const SemCtx = struct {
            gdb: *graph_db.GraphDb,
            allocator: std.mem.Allocator,
            query: []const u8,
            pool_size: usize,
            ann: ?*hnsw.Hnsw,
            result: ?semantic.SemResults = null,
            err: ?anyerror = null,
            fn run(c: *@This()) void {
                // Prefer the ANN index (approximate + exact re-rank) when one is
                // attached; otherwise fall back to the exact linear scan.
                if (c.ann) |a| {
                    c.result = semantic.searchAnn(c.gdb, a, c.query, c.pool_size, c.allocator) catch |e| {
                        c.err = e;
                        return;
                    };
                } else {
                    c.result = semantic.search(c.gdb, c.query, c.pool_size, c.allocator) catch |e| {
                        c.err = e;
                        return;
                    };
                }
            }
        };
        // The semantic thread and the BM25 search below run concurrently but
        // both allocate from `allocator`, which is not thread-safe (GPA/arena).
        // Concurrent allocations corrupt the heap -> segfault. Serialize the
        // two threads' allocations through a thread-safe wrapper for the
        // concurrent window; everything after join() is single-threaded and
        // can free via the raw `allocator` (same underlying child memory).
        //
        // Exception: when a snippet/term cache is attached, the BM25 side
        // allocates cache nodes via the cache's own allocator (NOT `ca`) on the
        // same heap — those allocations would race the semantic thread's `ca`
        // allocations under a different lock. Fall back to running the two
        // phases sequentially (no spawn, raw allocator) in that case.
        const caches_attached = self.snippet_cache != null or self.term_cache != null;
        var ts_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
        const ca = if (caches_attached) allocator else ts_alloc.allocator();

        const sem_pool_size: usize = @max(limit * 3, 50);
        var sem_ctx = SemCtx{ .gdb = gdb, .allocator = ca, .query = query, .pool_size = sem_pool_size, .ann = self.ann };
        const sem_thread = if (caches_attached)
            null
        else
            std.Thread.spawn(.{}, SemCtx.run, .{&sem_ctx}) catch null;

        const bm25_pool_size: usize = @max(limit * 3, 50);
        var bm25_results = self.search(ca, query, bm25_pool_size) catch |e| {
            if (sem_thread) |t| { t.join(); } else { SemCtx.run(&sem_ctx); }
            if (sem_ctx.result) |*r| r.deinit(allocator);
            return e;
        };
        defer bm25_results.deinit(allocator);

        if (sem_thread) |t| { t.join(); } else { SemCtx.run(&sem_ctx); }
        if (sem_ctx.err) |e| return e;
        var sem_results = sem_ctx.result.?;
        defer sem_results.deinit(allocator);

        // 3. Reciprocal-rank fusion keyed by PATH, carrying the per-path
        //    semantic score in the same entry (one pass over each source — no
        //    separate sem_map). BM25 doc_ids index the combined base+overlay
        //    segment (resolved via filePathFor); semantic doc_ids are gdb
        //    document rowids — DISJOINT id spaces. Fusing by raw doc_id both
        //    crashes (OOB in index.filePath, base-segment only) and mis-merges
        //    colliding ids. The file path is the one shared key. Empty paths
        //    (index/overlay drift) are skipped so unrelated unresolved docs
        //    don't collide under "".
        //    RRF(d) = Σ 1/(k + rank_in_list)
        const FusedScore = struct { rrf: f32 = 0, sem: f32 = 0 };
        var rrf_scores = std.StringHashMap(FusedScore).init(allocator);
        defer rrf_scores.deinit();

        for (bm25_results.items, 0..) |item, rank| {
            if (item.path.len == 0) continue;
            const rrf = 1.0 / (RRF_K + @as(f32, @floatFromInt(rank + 1)));
            const entry = try rrf_scores.getOrPut(item.path);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.rrf += rrf;
        }
        for (sem_results.items, 0..) |item, rank| {
            if (item.document_path.len == 0) continue;
            const rrf = 1.0 / (RRF_K + @as(f32, @floatFromInt(rank + 1)));
            const entry = try rrf_scores.getOrPut(item.document_path);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.rrf += rrf;
            entry.value_ptr.sem = item.score;
        }

        // 4. Index BM25 hits by path for dedup + doc_id/snippet resolution.
        //    First occurrence wins, collapsing a base+overlay duplicate of the
        //    same path into a single output row.
        var bm25_by_path = std.StringHashMap(usize).init(allocator);
        defer bm25_by_path.deinit();
        for (bm25_results.items, 0..) |item, idx| {
            if (item.path.len == 0) continue;
            const gop = try bm25_by_path.getOrPut(item.path);
            if (!gop.found_existing) gop.value_ptr.* = idx;
        }

        // 5. Materialize one candidate per UNIQUE path across BOTH id-spaces —
        //    rrf_scores holds the union of BM25 and semantic paths. BM25-present
        //    paths carry an index-stable doc_id + snippet; pure-semantic hits
        //    carry the sentinel doc_id and an empty snippet (no in-segment
        //    content). This is what keeps semantic-only matches in the result.
        const Cand = struct {
            path: []const u8, // borrowed here; duped into the result in step 6
            doc_id: u32,
            snippet: []const u8,
            bm25_score: f32,
            semantic_score: f32,
            fused_score: f32,
        };
        var cands = std.ArrayList(Cand).initCapacity(allocator, rrf_scores.count()) catch @panic("OOM");
        defer cands.deinit(allocator);
        var rrf_it = rrf_scores.iterator();
        while (rrf_it.next()) |e| {
            const path = e.key_ptr.*;
            const sem_score = e.value_ptr.sem;
            const fused_score = e.value_ptr.rrf;
            if (bm25_by_path.get(path)) |idx| {
                const r = bm25_results.items[idx];
                try cands.append(allocator, .{
                    .path = r.path,
                    .doc_id = r.doc_id,
                    .snippet = r.snippet,
                    .bm25_score = r.score,
                    .semantic_score = sem_score,
                    .fused_score = fused_score,
                });
            } else {
                try cands.append(allocator, .{
                    .path = path,
                    .doc_id = NO_DOC_ID,
                    .snippet = "",
                    .bm25_score = 0,
                    .semantic_score = sem_score,
                    .fused_score = fused_score,
                });
            }
        }
        std.mem.sort(Cand, cands.items, {}, struct {
            fn less(_: void, a: Cand, b: Cand) bool {
                return a.fused_score > b.fused_score;
            }
        }.less);
        if (cands.items.len > limit) cands.shrinkRetainingCapacity(limit);

        // 6. Build results, duping each path so it outlives sem_results (whose
        //    gdb-owned strings back the pure-semantic paths) and bm25_results.
        //    `snippet` stays borrowed (index-stable mmap slice, or the empty
        //    literal for pure-semantic hits).
        const results = try allocator.alloc(HybridResult, cands.items.len);
        var built: usize = 0;
        errdefer {
            for (results[0..built]) |r| allocator.free(r.path);
            allocator.free(results);
        }
        for (cands.items) |c| {
            results[built] = .{
                .doc_id = c.doc_id,
                .path = try allocator.dupe(u8, c.path),
                .snippet = c.snippet,
                .bm25_score = c.bm25_score,
                .semantic_score = c.semantic_score,
                .fused_score = c.fused_score,
            };
            built += 1;
        }

        return .{ .items = results };
    }

    /// Multi-signal search: extends hybrid search (BM25 + semantic RRF) with
    /// graph-proximity and kind-boost signals.
    ///
    ///   - gdb: Open graph database (for graph proximity & kind boosts)
    ///   - allocator: Memory allocator
    ///   - query: Search query string
    ///   - limit: Maximum results to return
    pub fn multiSignalSearch(
        self: *Engine,
        gdb: *graph_db.GraphDb,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
    ) !MultiSignalResults {
        // 1. Baseline hybrid search
        var hybrid = try self.hybridSearch(gdb, allocator, query, limit * 3);
        defer hybrid.deinit(allocator);

        // 1b. Bridge id-spaces: the graph/kind/community signals below are keyed
        //     by gdb document rowid, but hybrid hits carry a BM25 segment id (or
        //     the NO_DOC_ID sentinel for pure-semantic hits) — disjoint spaces.
        //     The shared file path is the only correct join, so map path -> gdb
        //     rowid once and translate per hit.
        var path_to_docid = std.StringHashMap(u32).init(allocator);
        defer {
            var key_it = path_to_docid.keyIterator();
            while (key_it.next()) |k| allocator.free(k.*);
            path_to_docid.deinit();
        }
        {
            var stmt = try gdb.prepare("SELECT id, path FROM documents");
            defer stmt.finalize();
            while (try stmt.step()) {
                const p = try stmt.columnText(1);
                if (p.len == 0) continue;
                const gop = try path_to_docid.getOrPut(p);
                if (!gop.found_existing) {
                    // Intern the key: sqlite's column slice is invalid after the
                    // next step(); dupe over the just-inserted borrowed key.
                    gop.key_ptr.* = try allocator.dupe(u8, p);
                    gop.value_ptr.* = @intCast(try stmt.columnInt(0));
                }
            }
        }

        // 2. Aggregate graph-proximity and kind-boost scores per document
        var graph_scores = std.AutoHashMap(u32, f32).init(allocator);
        defer graph_scores.deinit();
        var kind_scores = std.AutoHashMap(u32, f32).init(allocator);
        defer kind_scores.deinit();

        // Extract query terms and query graph DB for each
        var i: usize = 0;
        while (i < query.len) {
            while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
            const start = i;
            while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
            if (start == i) continue;
            const term = query[start..i];

            // Graph proximity: find related documents via edges
            var like_buf: [258]u8 = undefined;
            const like_pattern = std.fmt.bufPrint(&like_buf, "%{s}%", .{term}) catch continue;

            var related = try gdb.findRelatedDocuments(
                like_pattern,
                SIGNAL_WEIGHTS.min_edge_confidence,
                allocator,
            );
            defer related.deinit();
            var rel_it = related.iterator();
            while (rel_it.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const score = entry.value_ptr.*;
                const g_entry = try graph_scores.getOrPut(doc_id);
                if (!g_entry.found_existing) g_entry.value_ptr.* = 0;
                g_entry.value_ptr.* += score;
            }

            // Kind boost: find matching symbols and their kind boosts
            var boosts = try gdb.findKindBoosts(like_pattern, allocator);
            defer boosts.deinit();
            var boost_it = boosts.iterator();
            while (boost_it.next()) |entry| {
                const doc_id = entry.key_ptr.*;
                const boost = entry.value_ptr.*;
                const k_entry = try kind_scores.getOrPut(doc_id);
                if (!k_entry.found_existing) k_entry.value_ptr.* = 0;
                if (boost > k_entry.value_ptr.*) k_entry.value_ptr.* = boost;
            }
        }

        // 3. Community signal: lazy-detect, classify bias, identify top communities.
        leiden.ensureDetected(allocator, gdb, 1.0) catch {};
        var doc_comm = gdb.docCommunities(allocator) catch std.AutoHashMap(u32, i64).init(allocator);
        defer doc_comm.deinit();

        var bias: ai_query.SearchBias = .neutral;
        if (ai_query.parseQuery(allocator, query)) |parsed| {
            defer parsed.deinit(allocator);
            bias = ai_query.searchBias(parsed.intent);
        } else |_| {}

        // Top-K communities = communities of the highest-fused hybrid hits.
        var top_comms = std.AutoHashMap(i64, void).init(allocator);
        defer top_comms.deinit();
        const topk = @min(hybrid.items.len, 3);
        for (hybrid.items[0..topk]) |h| {
            const rid = path_to_docid.get(h.path) orelse continue;
            if (doc_comm.get(rid)) |c| try top_comms.put(c, {});
        }
        // Track communities already seen in rank order for diversity decay.
        var seen_comm = std.AutoHashMap(i64, u32).init(allocator);
        defer seen_comm.deinit();

        // 4. Build final results with signal blending. Carry path + snippet
        //    straight from the hybrid hit (already overlay-correct) instead of
        //    re-resolving from doc_id with base-only accessors.
        var final_scores = std.ArrayList(struct {
            doc_id: u32,
            path: []const u8, // borrowed from hybrid; duped into the result in step 6
            snippet: []const u8,
            final_score: f32,
            bm25_score: f32,
            semantic_score: f32,
            fused_score: f32,
            graph_score: f32,
            kind_score: f32,
            community_score: f32,
        }).initCapacity(allocator, hybrid.items.len) catch @panic("OOM");
        defer final_scores.deinit(allocator);

        for (hybrid.items) |h| {
            // Translate the hit's path to its gdb rowid for signal lookups; a
            // miss (file not in gdb) leaves every signal at its neutral default.
            const rid_opt = path_to_docid.get(h.path);
            const graph_score = if (rid_opt) |rid| graph_scores.get(rid) orelse 0 else 0;
            const kind_score = if (rid_opt) |rid| kind_scores.get(rid) orelse 1.0 else 1.0;

            // Community signal: cohesion boosts same-community-as-top hits;
            // diversity decays each repeated community in rank order.
            var community_score: f32 = 0;
            if (rid_opt) |rid| {
                if (doc_comm.get(rid)) |c| switch (bias) {
                    .cohesion => if (top_comms.contains(c)) {
                        community_score = SIGNAL_WEIGHTS.community_cohesion;
                    },
                    .diversity => {
                        const e = try seen_comm.getOrPut(c);
                        if (!e.found_existing) e.value_ptr.* = 0;
                        community_score = -SIGNAL_WEIGHTS.community_diversity *
                            @as(f32, @floatFromInt(e.value_ptr.*));
                        e.value_ptr.* += 1;
                    },
                    .neutral => {},
                };
            }

            // Blend: fused_score * (1 + graph + kind + community)
            const graph_bonus = SIGNAL_WEIGHTS.graph_proximity * graph_score;
            const kind_bonus = SIGNAL_WEIGHTS.kind_boost * (kind_score - 1.0);
            const final = h.fused_score * (1.0 + graph_bonus + kind_bonus + community_score);

            try final_scores.append(allocator, .{
                .doc_id = h.doc_id,
                .path = h.path,
                .snippet = h.snippet,
                .final_score = final,
                .bm25_score = h.bm25_score,
                .semantic_score = h.semantic_score,
                .fused_score = h.fused_score,
                .graph_score = graph_score,
                .kind_score = kind_score,
                .community_score = community_score,
            });
        }

        // 5. Sort by final score descending
        std.mem.sort(@TypeOf(final_scores.items[0]), final_scores.items, {}, struct {
            fn less(_: void, a: @TypeOf(final_scores.items[0]), b: @TypeOf(final_scores.items[0])) bool {
                return a.final_score > b.final_score;
            }
        }.less);
        if (final_scores.items.len > limit) final_scores.shrinkRetainingCapacity(limit);

        // 6. Build results. Path is duped (owned; freed by deinit) so it
        //    outlives hybrid.deinit; snippet is borrowed (index-stable, carried
        //    from the hybrid hit — never re-resolved from the segment id, which
        //    could be the NO_DOC_ID sentinel or an overlay id and would OOB).
        const results = try allocator.alloc(MultiSignalResult, final_scores.items.len);
        var built: usize = 0;
        errdefer {
            for (results[0..built]) |r| allocator.free(r.path);
            allocator.free(results);
        }
        for (final_scores.items) |item| {
            results[built] = .{
                .doc_id = item.doc_id,
                .path = try allocator.dupe(u8, item.path),
                .snippet = item.snippet,
                .bm25_score = item.bm25_score,
                .semantic_score = item.semantic_score,
                .fused_score = item.fused_score,
                .graph_proximity_score = item.graph_score,
                .kind_boost_score = item.kind_score,
                .community_score = item.community_score,
                .final_score = item.final_score,
            };
            built += 1;
        }

        return .{ .items = results };
    }

    pub fn lookupSymbol(self: *Engine, name: []const u8) !?SymbolHit {
        const rec = self.index.symbolByName(name) orelse return null;
        return .{
            .doc_id = rec.doc_id,
            .path = self.index.filePath(rec.doc_id),
            .name = self.index.stringAt(rec.name_sid),
            .kind = @enumFromInt(rec.kind),
            .line = rec.line,
            .byte_off = rec.byte_off,
        };
    }

    pub fn context(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        return self.search(allocator, query, limit);
    }

    /// Exact-identifier search path.  Aliases `search` today but is the API
    /// agents should call when they know the query is a symbol (no semantic
    /// fallback, no embedding round-trip).  Stable surface even if
    /// hybridSearch's classifier rules change.
    pub fn fastSearch(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        return self.search(allocator, query, limit);
    }

    /// Extract a query-aware snippet from the document.
    /// Finds the first occurrence of the first query term and returns context
    /// around it (up to SNIPPET_LEN bytes). Falls back to first SNIPPET_LEN bytes
    /// if no match position is available.
    const SNIPPET_LEN: usize = 300;
    const CONTEXT_BEFORE: usize = 80;

    /// Overlay-aware wrapper used by callers that already hold a *merged*
    /// doc id (i.e. ids >= base.docCount() refer to the overlay).
    fn snippetFor(self: *Engine, combined_id: u32, query: []const u8) []const u8 {
        // B8: check snippet LRU cache before scanning content
        if (self.snippet_cache) |cache| {
            const key = SnippetCacheKey.init(combined_id, extractFirstTerm(query));
            if (cache.get(key)) |hit| return hit;
            const result = self.snippetFromContent(self.fileContentFor(combined_id), query);
            cache.put(key, result);
            return result;
        }
        return self.snippetFromContent(self.fileContentFor(combined_id), query);
    }

    fn snippet(self: *Engine, doc_id: u32, query: []const u8) []const u8 {
        // B8: check snippet LRU cache before scanning content
        if (self.snippet_cache) |cache| {
            const key = SnippetCacheKey.init(doc_id, extractFirstTerm(query));
            if (cache.get(key)) |hit| return hit;
            const result = self.snippetFromContent(self.index.fileContent(doc_id), query);
            cache.put(key, result);
            return result;
        }
        return self.snippetFromContent(self.index.fileContent(doc_id), query);
    }

    /// Extract the first alphanumeric token from a query string.
    /// Returns a slice into `query` (zero-length on empty/no-token queries).
    fn extractFirstTerm(query: []const u8) []const u8 {
        var i: usize = 0;
        while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
        const start = i;
        while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
        return query[start..i];
    }

    fn snippetFromContent(self: *Engine, content: []const u8, query: []const u8) []const u8 {
        _ = self;
        if (content.len <= SNIPPET_LEN) return content;

        // Extract first query term
        var i: usize = 0;
        while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
        const start = i;
        while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
        const first_term = query[start..i];
        if (first_term.len == 0) return content[0..@min(content.len, SNIPPET_LEN)];

        // Find first occurrence of normalized first term in normalized content
        var term_buf: [256]u8 = undefined;
        const normalized_term = storage.normalizeInto(&term_buf, first_term);

        var normalize_buf: [1024]u8 = undefined;
        var pos: usize = 0;
        while (pos + normalized_term.len <= content.len and pos < normalize_buf.len) {
            const chunk = content[pos..@min(content.len, pos + normalize_buf.len)];
            const norm_chunk = storage.normalizeInto(&normalize_buf, chunk);
            if (std.mem.indexOf(u8, norm_chunk, normalized_term)) |match_pos| {
                // Found! map back to approximate position in original content
                const actual_pos = pos + match_pos;
                const ctx_start = if (actual_pos > CONTEXT_BEFORE) actual_pos - CONTEXT_BEFORE else 0;
                const ctx_end = @min(content.len, actual_pos + normalized_term.len + SNIPPET_LEN - CONTEXT_BEFORE);

                // Try to start at a line boundary near ctx_start
                var adjusted_start = ctx_start;
                if (ctx_start > 0) {
                    const scan_start = if (ctx_start > 40) ctx_start - 40 else 0;
                    if (std.mem.lastIndexOfScalar(u8, content[scan_start..ctx_start], '\n')) |nl_pos| {
                        adjusted_start = scan_start + nl_pos + 1;
                    }
                }

                return content[adjusted_start..ctx_end];
            }
            pos += normalize_buf.len - normalized_term.len;
        }

        return content[0..@min(content.len, SNIPPET_LEN)];
    }
};

fn lessScoredDoc(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Classifier for query routing.  `identifier_only` queries skip the
/// semantic arm of hybrid search.
pub const QueryShape = enum { identifier_only, natural_language };

/// Heuristic: a query is identifier-only when it's a single contiguous
/// run of identifier characters (letters, digits, `_`).  Anything with
/// whitespace, punctuation, or multiple tokens is treated as natural
/// language and gets the full hybrid pipeline.
pub fn classifyQuery(query: []const u8) QueryShape {
    const trimmed = std.mem.trim(u8, query, " \t\n\r");
    if (trimmed.len == 0) return .natural_language;

    var has_letter = false;
    for (trimmed) |c| {
        if (std.ascii.isAlphabetic(c)) has_letter = true;
        const is_ident_char = std.ascii.isAlphanumeric(c) or c == '_';
        if (!is_ident_char) return .natural_language;
    }
    // A query of only digits is not a useful "identifier" — fall back.
    return if (has_letter) .identifier_only else .natural_language;
}

/// BM25-only path used by hybridSearch when the query is a single
/// identifier.  Materializes the same HybridResult shape (with
/// semantic_score=0, fused_score=bm25_score) so callers see a uniform
/// schema regardless of which arm ran.
fn bm25Only(engine: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !HybridResults {
    var bm25 = try engine.search(allocator, query, limit);
    defer bm25.deinit(allocator);

    const results = try allocator.alloc(HybridResult, bm25.items.len);
    var built: usize = 0;
    errdefer {
        for (results[0..built]) |r| allocator.free(r.path);
        allocator.free(results);
    }
    for (bm25.items) |r| {
        // `path` is owned by the result (HybridResults.deinit frees it); snippet
        // stays borrowed from the index-stable mmap slice.
        results[built] = .{
            .doc_id = r.doc_id,
            .path = try allocator.dupe(u8, r.path),
            .snippet = r.snippet,
            .bm25_score = r.score,
            .semantic_score = 0,
            .fused_score = r.score,
        };
        built += 1;
    }
    return .{ .items = results };
}

