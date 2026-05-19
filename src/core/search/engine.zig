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
};

pub const Result = struct {
    doc_id: u32,
    score: f32,
    path: []const u8,
    snippet: []const u8,
};

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
    final_score: f32,
};

pub const MultiSignalResults = struct {
    items: []MultiSignalResult,

    pub fn deinit(self: *MultiSignalResults, allocator: std.mem.Allocator) void {
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

    pub fn init(index: *const storage.Index) Engine {
        return .{
            .index = index,
            .avg_doc_len = index.avgDocLength(),
            .k1 = BM25_DEFAULTS.k1,
            .b = BM25_DEFAULTS.b,
        };
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

        // 1. Get BM25 results (use a larger pool for better fusion)
        const bm25_pool_size: usize = @max(limit * 3, 50);
        var bm25_results = try self.search(allocator, query, bm25_pool_size);
        defer bm25_results.deinit(allocator);

        // 2. Get semantic results
        const sem_pool_size: usize = @max(limit * 3, 50);
        var sem_results = try semantic.search(gdb, query, sem_pool_size, allocator);
        defer sem_results.deinit(allocator);

        // 3. Build RRF scores
        //    RRF(d) = Σ 1/(k + rank_in_list)
        var rrf_scores = std.AutoHashMap(u32, f32).init(allocator);
        defer rrf_scores.deinit();

        // Add BM25 contributions
        for (bm25_results.items, 0..) |item, rank| {
            const rrf = 1.0 / (RRF_K + @as(f32, @floatFromInt(rank + 1)));
            const entry = try rrf_scores.getOrPut(item.doc_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += rrf;
        }

        // Add semantic contributions
        for (sem_results.items, 0..) |item, rank| {
            const rrf = 1.0 / (RRF_K + @as(f32, @floatFromInt(rank + 1)));
            const entry = try rrf_scores.getOrPut(item.doc_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* += rrf;
        }

        // 4. Build lookup maps for per-source scores
        var bm25_map = std.AutoHashMap(u32, f32).init(allocator);
        defer bm25_map.deinit();
        for (bm25_results.items) |item| {
            try bm25_map.put(item.doc_id, item.score);
        }

        var sem_map = std.AutoHashMap(u32, f32).init(allocator);
        defer sem_map.deinit();
        for (sem_results.items) |item| {
            try sem_map.put(item.doc_id, item.score);
        }

        // 5. Sort by fused RRF score
        var fused = std.ArrayList(struct {
            doc_id: u32,
            fused_score: f32,
        }).initCapacity(allocator, rrf_scores.count()) catch @panic("OOM");
        defer fused.deinit(allocator);

        var rrf_it = rrf_scores.iterator();
        while (rrf_it.next()) |entry| {
            try fused.append(allocator, .{
                .doc_id = entry.key_ptr.*,
                .fused_score = entry.value_ptr.*,
            });
        }
        std.mem.sort(@TypeOf(fused.items[0]), fused.items, {}, struct {
            fn less(_: void, a: @TypeOf(fused.items[0]), b: @TypeOf(fused.items[0])) bool {
                return a.fused_score > b.fused_score;
            }
        }.less);
        if (fused.items.len > limit) fused.shrinkRetainingCapacity(limit);

        // 6. Build results
        const results = try allocator.alloc(HybridResult, fused.items.len);
        for (fused.items, 0..) |item, result_idx| {
            results[result_idx] = .{
                .doc_id = item.doc_id,
                .path = self.index.filePath(item.doc_id),
                .snippet = self.snippet(item.doc_id, query),
                .bm25_score = bm25_map.get(item.doc_id) orelse 0,
                .semantic_score = sem_map.get(item.doc_id) orelse 0,
                .fused_score = item.fused_score,
            };
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

        // 3. Build final results with signal blending
        var final_scores = std.ArrayList(struct {
            doc_id: u32,
            final_score: f32,
            bm25_score: f32,
            semantic_score: f32,
            fused_score: f32,
            graph_score: f32,
            kind_score: f32,
        }).initCapacity(allocator, hybrid.items.len) catch @panic("OOM");
        defer final_scores.deinit(allocator);

        for (hybrid.items) |h| {
            const graph_score = graph_scores.get(h.doc_id) orelse 0;
            const kind_score = kind_scores.get(h.doc_id) orelse 1.0;

            // Blend: fused_score * (1 + graph_weight * graph_score + kind_weight * (kind_score - 1))
            const graph_bonus = SIGNAL_WEIGHTS.graph_proximity * graph_score;
            const kind_bonus = SIGNAL_WEIGHTS.kind_boost * (kind_score - 1.0);
            const final = h.fused_score * (1.0 + graph_bonus + kind_bonus);

            try final_scores.append(allocator, .{
                .doc_id = h.doc_id,
                .final_score = final,
                .bm25_score = h.bm25_score,
                .semantic_score = h.semantic_score,
                .fused_score = h.fused_score,
                .graph_score = graph_score,
                .kind_score = kind_score,
            });
        }

        // 4. Sort by final score descending
        std.mem.sort(@TypeOf(final_scores.items[0]), final_scores.items, {}, struct {
            fn less(_: void, a: @TypeOf(final_scores.items[0]), b: @TypeOf(final_scores.items[0])) bool {
                return a.final_score > b.final_score;
            }
        }.less);
        if (final_scores.items.len > limit) final_scores.shrinkRetainingCapacity(limit);

        // 5. Build results
        const results = try allocator.alloc(MultiSignalResult, final_scores.items.len);
        for (final_scores.items, 0..) |item, idx| {
            results[idx] = .{
                .doc_id = item.doc_id,
                .path = self.index.filePath(item.doc_id),
                .snippet = self.snippet(item.doc_id, query),
                .bm25_score = item.bm25_score,
                .semantic_score = item.semantic_score,
                .fused_score = item.fused_score,
                .graph_proximity_score = item.graph_score,
                .kind_boost_score = item.kind_score,
                .final_score = item.final_score,
            };
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
        return self.snippetFromContent(self.fileContentFor(combined_id), query);
    }

    fn snippet(self: *Engine, doc_id: u32, query: []const u8) []const u8 {
        return self.snippetFromContent(self.index.fileContent(doc_id), query);
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
    for (bm25.items, 0..) |r, i| {
        results[i] = .{
            .doc_id = r.doc_id,
            .path = r.path,
            .snippet = r.snippet,
            .bm25_score = r.score,
            .semantic_score = 0,
            .fused_score = r.score,
        };
    }
    return .{ .items = results };
}

