//! HNSW (Hierarchical Navigable Small World) approximate-nearest-neighbor
//! index over int8-quantized embeddings.
//!
//! Built as a *derived artifact*: constructed from the full set of document
//! embeddings after indexing, serialized to `<index_dir>/hnsw.idx`, and loaded
//! on attach.  Semantic search queries it for candidate documents, then
//! re-ranks the candidates with exact f32 cosine.  This keeps the ANN index
//! decoupled from the incremental insert/delete path — it is simply rebuilt
//! when the embedding set changes.
//!
//! Reference: Malkov & Yashunin, "Efficient and robust approximate nearest
//! neighbor search using Hierarchical Navigable Small World graphs" (2016).
//! Neighbor selection uses the simple "M closest" rule rather than the
//! diversity heuristic — adequate recall at our scale, less code to get wrong.

const std = @import("std");
const quant = @import("quantize.zig");

const DIM = quant.DIM;
const MAGIC: u32 = 0x5a484e57; // "ZHNW"

pub const Params = struct {
    /// Target neighbor degree for layers > 0.
    m: usize = 16,
    /// Max neighbor degree at layer 0 (denser bottom layer).
    m0: usize = 32,
    /// Candidate-list size during construction.
    ef_construction: usize = 200,
    /// Default candidate-list size during search.
    ef_search: usize = 64,
};

const Candidate = struct { idx: u32, dist: f32 };

fn cmpNearestFirst(_: void, a: Candidate, b: Candidate) std.math.Order {
    return std.math.order(a.dist, b.dist); // min-heap: pops closest
}
fn cmpFarthestFirst(_: void, a: Candidate, b: Candidate) std.math.Order {
    return std.math.order(b.dist, a.dist); // max-heap: pops farthest
}

const NearestQueue = std.PriorityQueue(Candidate, void, cmpNearestFirst);
const FarthestQueue = std.PriorityQueue(Candidate, void, cmpFarthestFirst);

const Node = struct {
    doc_id: u32,
    codes: [DIM]i8,
    /// neighbors[l] = node indices linked at layer l. len = node level + 1.
    neighbors: []std.ArrayList(u32),
};

pub const Hnsw = struct {
    allocator: std.mem.Allocator,
    params: Params,
    nodes: std.ArrayList(Node),
    entry: ?u32 = null,
    max_level: usize = 0,
    rng: std.Random.DefaultPrng,
    m_l: f32,

    pub fn init(allocator: std.mem.Allocator, params: Params, seed: u64) Hnsw {
        const m_l = 1.0 / std.math.log(f32, std.math.e, @as(f32, @floatFromInt(params.m)));
        return .{
            .allocator = allocator,
            .params = params,
            .nodes = std.ArrayList(Node){},
            .rng = std.Random.DefaultPrng.init(seed),
            .m_l = m_l,
        };
    }

    pub fn deinit(self: *Hnsw) void {
        for (self.nodes.items) |*n| {
            for (n.neighbors) |*lst| lst.deinit(self.allocator);
            self.allocator.free(n.neighbors);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn len(self: *const Hnsw) usize {
        return self.nodes.items.len;
    }

    // ── distance helpers (smaller = closer) ──────────────────────────────
    // Vectors are unit-norm, so higher dot = nearer.  Distance = -similarity.

    fn distCodes(self: *const Hnsw, q: *const [DIM]i8, node_idx: u32) f32 {
        return -quant.similarity(q, &self.nodes.items[node_idx].codes);
    }

    fn distNodes(self: *const Hnsw, a: u32, b: u32) f32 {
        return -quant.similarity(&self.nodes.items[a].codes, &self.nodes.items[b].codes);
    }

    fn randomLevel(self: *Hnsw) usize {
        const r = self.rng.random().float(f32);
        const safe = if (r <= 0) std.math.floatMin(f32) else r;
        const lvl = -std.math.log(f32, std.math.e, safe) * self.m_l;
        return @intFromFloat(@floor(lvl));
    }

    // ── construction ─────────────────────────────────────────────────────

    pub fn insert(self: *Hnsw, doc_id: u32, codes: *const [DIM]i8) !void {
        const level = self.randomLevel();

        // Allocate per-level neighbor lists for the new node.
        const nbrs = try self.allocator.alloc(std.ArrayList(u32), level + 1);
        for (nbrs) |*lst| lst.* = std.ArrayList(u32){};

        try self.nodes.append(self.allocator, .{
            .doc_id = doc_id,
            .codes = codes.*,
            .neighbors = nbrs,
        });
        const new_idx: u32 = @intCast(self.nodes.items.len - 1);

        if (self.entry == null) {
            self.entry = new_idx;
            self.max_level = level;
            return;
        }

        var cur = self.entry.?;
        // Descend the upper layers greedily (ef = 1) down to level+1.
        var lc = self.max_level;
        while (lc > level) : (lc -= 1) {
            cur = try self.greedyClosest(codes, cur, lc);
        }

        // From min(level, max_level) down to 0: connect.
        var entry_points = std.ArrayList(u32){};
        defer entry_points.deinit(self.allocator);
        try entry_points.append(self.allocator, cur);

        var l: usize = @min(level, self.max_level);
        while (true) {
            const w = try self.searchLayer(codes, entry_points.items, self.params.ef_construction, l);
            defer self.allocator.free(w);

            const max_deg = if (l == 0) self.params.m0 else self.params.m;
            const chosen = try self.selectNeighbors(w, max_deg);
            defer self.allocator.free(chosen);

            for (chosen) |nb| {
                try self.nodes.items[new_idx].neighbors[l].append(self.allocator, nb);
                try self.nodes.items[nb].neighbors[l].append(self.allocator, new_idx);
                try self.pruneNeighbors(nb, l, max_deg);
            }

            // Next layer's entry points = the candidate set we just found.
            entry_points.clearRetainingCapacity();
            for (w) |c| try entry_points.append(self.allocator, c.idx);

            if (l == 0) break;
            l -= 1;
        }

        if (level > self.max_level) {
            self.entry = new_idx;
            self.max_level = level;
        }
    }

    /// Greedy 1-NN descent within a single layer.
    fn greedyClosest(self: *Hnsw, q: *const [DIM]i8, entry: u32, level: usize) !u32 {
        var cur = entry;
        var cur_d = self.distCodes(q, cur);
        while (true) {
            var improved = false;
            for (self.nodes.items[cur].neighbors[level].items) |nb| {
                const d = self.distCodes(q, nb);
                if (d < cur_d) {
                    cur_d = d;
                    cur = nb;
                    improved = true;
                }
            }
            if (!improved) return cur;
        }
    }

    /// Beam search within one layer. Returns up to `ef` closest candidates
    /// (caller owns the returned slice).
    fn searchLayer(self: *Hnsw, q: *const [DIM]i8, entry_points: []const u32, ef: usize, level: usize) ![]Candidate {
        var visited = try std.DynamicBitSet.initEmpty(self.allocator, self.nodes.items.len);
        defer visited.deinit();

        var candidates = NearestQueue.init(self.allocator, {});
        defer candidates.deinit();
        var w = FarthestQueue.init(self.allocator, {});
        defer w.deinit();

        for (entry_points) |ep| {
            if (visited.isSet(ep)) continue;
            visited.set(ep);
            const d = self.distCodes(q, ep);
            try candidates.add(.{ .idx = ep, .dist = d });
            try w.add(.{ .idx = ep, .dist = d });
        }

        while (candidates.removeOrNull()) |c| {
            const farthest = w.peek() orelse break;
            if (c.dist > farthest.dist and w.count() >= ef) break;

            for (self.nodes.items[c.idx].neighbors[level].items) |nb| {
                if (visited.isSet(nb)) continue;
                visited.set(nb);
                const d = self.distCodes(q, nb);
                const f = w.peek().?;
                if (d < f.dist or w.count() < ef) {
                    try candidates.add(.{ .idx = nb, .dist = d });
                    try w.add(.{ .idx = nb, .dist = d });
                    if (w.count() > ef) _ = w.removeOrNull(); // drop farthest
                }
            }
        }

        // Drain w into a slice (order unspecified; caller sorts if needed).
        const out = try self.allocator.alloc(Candidate, w.count());
        var i: usize = 0;
        while (w.removeOrNull()) |c| : (i += 1) out[i] = c;
        return out;
    }

    /// Pick the `m` closest candidates (by distance) from a result set.
    fn selectNeighbors(self: *Hnsw, candidates: []const Candidate, m: usize) ![]u32 {
        const sorted = try self.allocator.dupe(Candidate, candidates);
        defer self.allocator.free(sorted);
        std.mem.sort(Candidate, sorted, {}, struct {
            fn less(_: void, a: Candidate, b: Candidate) bool {
                return a.dist < b.dist;
            }
        }.less);
        const take = @min(m, sorted.len);
        const out = try self.allocator.alloc(u32, take);
        for (0..take) |i| out[i] = sorted[i].idx;
        return out;
    }

    /// Trim a node's neighbor list at `level` to its `m` closest neighbors.
    fn pruneNeighbors(self: *Hnsw, node_idx: u32, level: usize, m: usize) !void {
        var list = &self.nodes.items[node_idx].neighbors[level];
        if (list.items.len <= m) return;

        const cands = try self.allocator.alloc(Candidate, list.items.len);
        defer self.allocator.free(cands);
        for (list.items, 0..) |nb, i| {
            cands[i] = .{ .idx = nb, .dist = self.distNodes(node_idx, nb) };
        }
        std.mem.sort(Candidate, cands, {}, struct {
            fn less(_: void, a: Candidate, b: Candidate) bool {
                return a.dist < b.dist;
            }
        }.less);
        list.clearRetainingCapacity();
        for (0..m) |i| try list.append(self.allocator, cands[i].idx);
    }

    // ── query ────────────────────────────────────────────────────────────

    pub const Hit = struct { doc_id: u32, score: f32 };

    /// Approximate k-NN search. Returns up to `k` doc_ids with approximate
    /// similarity scores, nearest first (caller owns the slice).
    pub fn search(self: *Hnsw, q: *const [DIM]i8, k: usize, ef_opt: ?usize) ![]Hit {
        if (self.entry == null or self.nodes.items.len == 0) {
            return self.allocator.alloc(Hit, 0);
        }
        const ef = @max(ef_opt orelse self.params.ef_search, k);

        var cur = self.entry.?;
        var lc = self.max_level;
        while (lc > 0) : (lc -= 1) {
            cur = try self.greedyClosest(q, cur, lc);
        }

        const w = try self.searchLayer(q, &.{cur}, ef, 0);
        defer self.allocator.free(w);

        std.mem.sort(Candidate, w, {}, struct {
            fn less(_: void, a: Candidate, b: Candidate) bool {
                return a.dist < b.dist;
            }
        }.less);

        const take = @min(k, w.len);
        const out = try self.allocator.alloc(Hit, take);
        for (0..take) |i| {
            out[i] = .{ .doc_id = self.nodes.items[w[i].idx].doc_id, .score = -w[i].dist };
        }
        return out;
    }

    // ── persistence ──────────────────────────────────────────────────────

    pub fn serialize(self: *const Hnsw, allocator: std.mem.Allocator) ![]u8 {
        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(allocator);
        const w = buf.writer(allocator);

        try w.writeInt(u32, MAGIC, .little);
        try w.writeInt(u32, @intCast(DIM), .little);
        try w.writeInt(u32, @intCast(self.nodes.items.len), .little);
        try w.writeInt(i64, if (self.entry) |e| @as(i64, e) else -1, .little);
        try w.writeInt(u32, @intCast(self.max_level), .little);
        try w.writeInt(u32, @intCast(self.params.m), .little);
        try w.writeInt(u32, @intCast(self.params.m0), .little);
        try w.writeInt(u32, @intCast(self.params.ef_construction), .little);
        try w.writeInt(u32, @intCast(self.params.ef_search), .little);

        for (self.nodes.items) |n| {
            try w.writeInt(u32, n.doc_id, .little);
            try w.writeInt(u32, @intCast(n.neighbors.len), .little);
            try w.writeAll(std.mem.sliceAsBytes(n.codes[0..]));
            for (n.neighbors) |lst| {
                try w.writeInt(u32, @intCast(lst.items.len), .little);
                for (lst.items) |id| try w.writeInt(u32, id, .little);
            }
        }
        return buf.toOwnedSlice(allocator);
    }

    pub fn deserialize(allocator: std.mem.Allocator, bytes: []const u8) !Hnsw {
        var fbs = std.io.fixedBufferStream(bytes);
        const r = fbs.reader();

        if (try r.readInt(u32, .little) != MAGIC) return error.BadMagic;
        if (try r.readInt(u32, .little) != @as(u32, @intCast(DIM))) return error.DimMismatch;
        const node_count = try r.readInt(u32, .little);
        const entry_raw = try r.readInt(i64, .little);
        const max_level = try r.readInt(u32, .little);
        const params = Params{
            .m = try r.readInt(u32, .little),
            .m0 = try r.readInt(u32, .little),
            .ef_construction = try r.readInt(u32, .little),
            .ef_search = try r.readInt(u32, .little),
        };

        var self = Hnsw.init(allocator, params, 0);
        errdefer self.deinit();
        self.max_level = max_level;
        self.entry = if (entry_raw < 0) null else @intCast(entry_raw);

        try self.nodes.ensureTotalCapacity(allocator, node_count);
        for (0..node_count) |_| {
            const doc_id = try r.readInt(u32, .little);
            const n_levels = try r.readInt(u32, .little);
            var codes: [DIM]i8 = undefined;
            try r.readNoEof(std.mem.sliceAsBytes(codes[0..]));

            const nbrs = try allocator.alloc(std.ArrayList(u32), n_levels);
            for (nbrs) |*lst| lst.* = std.ArrayList(u32){};
            for (nbrs) |*lst| {
                const cnt = try r.readInt(u32, .little);
                try lst.ensureTotalCapacity(allocator, cnt);
                for (0..cnt) |_| try lst.append(allocator, try r.readInt(u32, .little));
            }
            try self.nodes.append(allocator, .{ .doc_id = doc_id, .codes = codes, .neighbors = nbrs });
        }
        return self;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

fn randCodes(r: std.Random) [DIM]i8 {
    var c: [DIM]i8 = undefined;
    for (0..DIM) |i| c[i] = r.intRangeAtMost(i8, -127, 127);
    return c;
}

test "hnsw build and search returns nearest" {
    const allocator = std.testing.allocator;
    var h = Hnsw.init(allocator, .{ .ef_construction = 64 }, 1234);
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(99);
    const r = prng.random();

    // Insert 200 random vectors.
    const N = 200;
    var stored: [N][DIM]i8 = undefined;
    for (0..N) |i| {
        stored[i] = randCodes(r);
        try h.insert(@intCast(i), &stored[i]);
    }
    try std.testing.expectEqual(@as(usize, N), h.len());

    // Query with an existing vector — it should be (near) the top hit.
    const target: u32 = 42;
    const hits = try h.search(&stored[target], 5, 64);
    defer allocator.free(hits);
    try std.testing.expect(hits.len > 0);

    var found = false;
    for (hits) |hit| {
        if (hit.doc_id == target) found = true;
    }
    try std.testing.expect(found);
}

test "hnsw recall vs brute force" {
    const allocator = std.testing.allocator;
    var h = Hnsw.init(allocator, .{ .ef_construction = 100 }, 7);
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(2024);
    const r = prng.random();

    const N = 300;
    var stored: [N][DIM]i8 = undefined;
    for (0..N) |i| {
        stored[i] = randCodes(r);
        try h.insert(@intCast(i), &stored[i]);
    }

    // Brute-force nearest neighbor for a fresh query.
    const q = randCodes(r);
    var best_idx: u32 = 0;
    var best_sim: f32 = -2;
    for (0..N) |i| {
        const s = quant.similarity(&q, &stored[i]);
        if (s > best_sim) {
            best_sim = s;
            best_idx = @intCast(i);
        }
    }

    // ANN top-10 should contain the true nearest (high recall expected).
    const hits = try h.search(&q, 10, 100);
    defer allocator.free(hits);
    var found = false;
    for (hits) |hit| if (hit.doc_id == best_idx) {
        found = true;
    };
    try std.testing.expect(found);
}

test "hnsw serialize round-trip" {
    const allocator = std.testing.allocator;
    var h = Hnsw.init(allocator, .{ .ef_construction = 64 }, 5);
    defer h.deinit();

    var prng = std.Random.DefaultPrng.init(11);
    const r = prng.random();
    const N = 120;
    var stored: [N][DIM]i8 = undefined;
    for (0..N) |i| {
        stored[i] = randCodes(r);
        try h.insert(@intCast(i), &stored[i]);
    }

    const bytes = try h.serialize(allocator);
    defer allocator.free(bytes);

    var h2 = try Hnsw.deserialize(allocator, bytes);
    defer h2.deinit();

    try std.testing.expectEqual(h.len(), h2.len());
    try std.testing.expectEqual(h.max_level, h2.max_level);
    try std.testing.expectEqual(h.entry, h2.entry);

    // Same query yields the same top hit on both.
    const q = randCodes(r);
    const a = try h.search(&q, 1, 64);
    defer allocator.free(a);
    const b = try h2.search(&q, 1, 64);
    defer allocator.free(b);
    try std.testing.expectEqual(a.len, b.len);
    if (a.len > 0) try std.testing.expectEqual(a[0].doc_id, b[0].doc_id);
}
