//! BM25 search engine with IDF-aware scoring and document length normalization.
//!
//! Uses the standard BM25 formula:
//!   score = Σ IDF(qi) * TF(d, qi)
//!   IDF = log(1 + (N - df + 0.5) / (df + 0.5))
//!   TF  = tf * (k1 + 1) / (tf + k1 * (1 - b + b * doc_len / avg_doc_len))
//!
//! Defaults: k1 = 1.5, b = 0.75

const std = @import("std");
const storage = @import("../storage/index.zig");

/// BM25 tuning constants.
pub const BM25_DEFAULTS = struct {
    pub const k1: f32 = 1.5;
    pub const b: f32 = 0.75;
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

pub const Engine = struct {
    index: *const storage.Index,
    avg_doc_len: f32,
    k1: f32,
    b: f32,

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

    pub fn search(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        var scores = std.AutoHashMap(u32, f32).init(allocator);
        defer scores.deinit();

        const n: f32 = @floatFromInt(self.index.docCount());
        var term_buf: [256]u8 = undefined;

        var i: usize = 0;
        while (i < query.len) {
            while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
            const start = i;
            while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
            if (start == i) continue;
            const term = storage.normalizeInto(&term_buf, query[start..i]);

            // df = document frequency (how many docs contain this term)
            const df: f32 = @floatFromInt(self.index.postingsLenForTerm(term));
            if (df == 0) continue;

            // Robertson-Sparck Jones IDF
            const idf: f32 = @log(1.0 + (n - df + 0.5) / (df + 0.5));

            const postings = self.index.postingsForTerm(term);
            for (postings) |p| {
                const tf: f32 = @floatFromInt(p.tf);
                const doc_len: f32 = @floatFromInt(self.index.docs[p.doc_id].token_count);
                const norm_len = doc_len / self.avg_doc_len;

                // BM25 TF component with document length normalization
                const tf_score = (tf * (self.k1 + 1.0)) / (tf + self.k1 * (1.0 - self.b + self.b * norm_len));
                const bm25_score = idf * tf_score;

                const entry = try scores.getOrPut(p.doc_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += bm25_score;
            }
        }

        var scored = std.ArrayList(ScoredDoc).initCapacity(allocator, scores.count()) catch @panic("OOM");
        defer scored.deinit(allocator);
        var it = scores.iterator();
        while (it.next()) |entry| {
            try scored.append(allocator, .{
                .doc_id = entry.key_ptr.*,
                .score = entry.value_ptr.*,
                .path = self.index.filePath(entry.key_ptr.*),
            });
        }
        std.mem.sort(ScoredDoc, scored.items, {}, lessScoredDoc);
        if (scored.items.len > limit) scored.shrinkRetainingCapacity(limit);

        const results = try allocator.alloc(Result, scored.items.len);
        for (scored.items, 0..) |item, result_index| {
            results[result_index] = .{
                .doc_id = item.doc_id,
                .score = item.score,
                .path = item.path,
                .snippet = self.snippet(item.doc_id, query),
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

    /// Extract a query-aware snippet from the document.
    /// Finds the first occurrence of the first query term and returns context
    /// around it (up to SNIPPET_LEN bytes). Falls back to first SNIPPET_LEN bytes
    /// if no match position is available.
    const SNIPPET_LEN: usize = 300;
    const CONTEXT_BEFORE: usize = 80;

    fn snippet(self: *Engine, doc_id: u32, query: []const u8) []const u8 {
        const content = self.index.fileContent(doc_id);
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
                // This is a rough approximation — for production you'd want byte-level mapping
                const actual_pos = pos + match_pos;
                const ctx_start = if (actual_pos > CONTEXT_BEFORE) actual_pos - CONTEXT_BEFORE else 0;
                const ctx_end = @min(content.len, actual_pos + normalized_term.len + SNIPPET_LEN - CONTEXT_BEFORE);

                // Try to start at a line boundary near ctx_start
                var adjusted_start = ctx_start;
                if (ctx_start > 0) {
                    // Find previous newline within 40 bytes
                    const scan_start = if (ctx_start > 40) ctx_start - 40 else 0;
                    if (std.mem.lastIndexOfScalar(u8, content[scan_start..ctx_start], '\n')) |nl_pos| {
                        adjusted_start = scan_start + nl_pos + 1;
                    }
                }

                return content[adjusted_start..ctx_end];
            }
            // Advance by chunk size minus term length to handle straddling occurrences
            pos += normalize_buf.len - normalized_term.len;
        }

        return content[0..@min(content.len, SNIPPET_LEN)];
    }
};

fn lessScoredDoc(_: void, a: ScoredDoc, b: ScoredDoc) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.path, b.path);
}
