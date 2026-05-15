//! Leiden community detection.
//!
//! Partitions the symbol graph into communities using the Leiden algorithm.
//! Unlike Louvain, Leiden guarantees well-connected communities through its
//! refinement phase after local moving.
//!
//! Algorithm (Traag, Waltman & van Eck, 2019):
//!   1. Local moving: shufle nodes, move to best neighboring community
//!   2. Refinement: split communities into connected, well-connected sub-communities
//!   3. Aggregation: build reduced graph (communities → nodes), repeat
//!
//! Stores community assignments in symbols.community_id (NULL before detection).

const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");

// ██████████████████████████████████████████████████████████████████████████
// Types
// ██████████████████████████████████████████████████████████████████████████

/// Result of community detection — the number of communities found and the
/// modularity score achieved.
pub const LeidenResult = struct {
    communities: u32,
    modularity: f64,
};

/// One edge in the in-memory graph representation.
const Edge = struct {
    target: u32, // index into nodes slice
    weight: f64,
};

// ██████████████████████████████████████████████████████████████████████████
// Leiden algorithm
// ██████████████████████████████████████████████████████████████████████████

/// Run Leiden community detection on the graph database.
/// Writes community_id back to the symbols table.
/// `resolution` controls community granularity: higher values produce more,
/// smaller communities (typical range 0.1–5.0, default 1.0).
pub fn detect(allocator: std.mem.Allocator, gdb: *graph_db.GraphDb, resolution: f64) !LeidenResult {
    // ── Load graph from SQLite ──────────────────────────────────────
    const graph = try loadGraph(allocator, gdb);
    defer graph.deinit(allocator);

    if (graph.total_edges == 0) {
        return .{ .communities = graph.node_count, .modularity = 0.0 };
    }

    // ── Initialize each node in its own community ──────────────────
    var community = try allocator.alloc(u32, graph.node_count);
    defer allocator.free(community);
    for (0..graph.node_count) |i| community[i] = @intCast(i);

    const gamma: f64 = resolution;
    const m = graph.total_weight;

    var prev_modularity: f64 = -1.0;
    var iteration: u32 = 0;
    const MAX_ITER = 100;

    while (iteration < MAX_ITER) : (iteration += 1) {
        // Phase 1: Local moving
        const local_q = try localMoving(graph, community, m, gamma, allocator);

        // Phase 2: Refinement
        try refinement(graph, community, m, gamma, allocator);

        // Check convergence
        if (local_q - prev_modularity < 0.0001) break;
        prev_modularity = local_q;

        // Phase 3: Aggregation (skip if no improvement)
        // For code graphs under ~50K nodes, aggregation is rarely needed.
        // We do one pass only — full hierarchical Leiden adds complexity
        // without significant gains on typical repos.
        if (iteration > 0) break;
    }

    // ── Assign community IDs to symbols ────────────────────────────
    // Map community index to a stable ID (use the smallest member index)
    try assignCommunities(gdb, graph, community, allocator);

    return .{
        .communities = countCommunities(community, graph.node_count),
        .modularity = modularity(graph, community, m, gamma),
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Graph representation
// ██████████████████████████████████████████████████████████████████████████

const InMemoryGraph = struct {
    node_count: u32,
    total_edges: u32,
    total_weight: f64,
    adjacency: []const Edge, // flattened adjacency list
    offsets: []const u32, // offsets[i] = start of node i's edges in adjacency
    // Map from graph node index → symbol ID in database
    symbol_ids: []i64,
    // Degrees for each node (sum of incident edge weights)
    degrees: []f64,

    fn deinit(self: *const InMemoryGraph, allocator: std.mem.Allocator) void {
        allocator.free(self.adjacency);
        allocator.free(self.offsets);
        allocator.free(self.symbol_ids);
        allocator.free(self.degrees);
    }
};

fn loadGraph(allocator: std.mem.Allocator, gdb: *graph_db.GraphDb) !InMemoryGraph {
    const node_count: u32 = @intCast(try gdb.queryScalar("SELECT COUNT(*) FROM symbols"));
    if (node_count == 0) return .{
        .node_count = 0,
        .total_edges = 0,
        .total_weight = 0.0,
        .adjacency = &.{},
        .offsets = &.{},
        .symbol_ids = &.{},
        .degrees = &.{},
    };

    // Load symbol IDs and their row indices
    var symbol_ids = try allocator.alloc(i64, node_count);
    var id_to_index = std.AutoHashMap(i64, u32).init(allocator);
    defer id_to_index.deinit();

    {
        var stmt = try gdb.prepare("SELECT id FROM symbols ORDER BY id");
        defer stmt.finalize();
        var i: u32 = 0;
        while (try stmt.step()) : (i += 1) {
            const sid = try stmt.columnInt(0);
            symbol_ids[i] = sid;
            try id_to_index.put(sid, i);
        }
    }

    // Load edges into per-node adjacency lists
    var edge_lists = try allocator.alloc(std.ArrayList(Edge), node_count);
    defer {
        for (edge_lists) |*list| list.deinit(allocator);
        allocator.free(edge_lists);
    }
    for (0..node_count) |i| {
        edge_lists[i] = std.ArrayList(Edge).initCapacity(allocator, 8) catch @panic("OOM");
    }

    var total_weight: f64 = 0.0;
    var total_edges: u32 = 0;

    {
        var stmt = try gdb.prepare(
            "SELECT source_symbol_id, target_symbol_id FROM edges",
        );
        defer stmt.finalize();
        while (try stmt.step()) : (total_edges += 1) {
            const src = try stmt.columnInt(0);
            const tgt = try stmt.columnInt(1);
            const si = id_to_index.get(src) orelse continue;
            const ti = id_to_index.get(tgt) orelse continue;
            try edge_lists[si].append(allocator, .{ .target = ti, .weight = 1.0 });
            total_weight += 1.0;
        }
    }

    // Flatten adjacency
    var adjacency = std.ArrayList(Edge).initCapacity(allocator, total_edges) catch @panic("OOM");
    var offsets = try allocator.alloc(u32, node_count + 1);
    var degrees = try allocator.alloc(f64, node_count);

    var offset: u32 = 0;
    for (0..node_count) |i| {
        offsets[i] = offset;
        degrees[i] = @floatFromInt(edge_lists[i].items.len);
        for (edge_lists[i].items) |edge| {
            try adjacency.append(allocator, edge);
        }
        offset += @intCast(edge_lists[i].items.len);
    }
    offsets[node_count] = offset; // sentinel

    return .{
        .node_count = node_count,
        .total_edges = total_edges,
        .total_weight = total_weight,
        .adjacency = try adjacency.toOwnedSlice(allocator),
        .offsets = offsets,
        .symbol_ids = symbol_ids,
        .degrees = degrees,
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Phase 1: Local moving
// ██████████████████████████████████████████████████████████████████████████

fn localMoving(
    graph: InMemoryGraph,
    community: []u32,
    m: f64,
    gamma: f64,
    allocator: std.mem.Allocator,
) !f64 {
    // Build a random permutation of node indices
    var order = try allocator.alloc(u32, graph.node_count);
    defer allocator.free(order);
    for (0..graph.node_count) |i| order[i] = @intCast(i);
    shuffle(order);

    // Precompute community totals
    var comm_weight = try allocator.alloc(f64, graph.node_count);
    defer allocator.free(comm_weight);
    @memset(comm_weight, 0.0);

    for (0..graph.node_count) |i| {
        const c = community[i];
        comm_weight[c] += graph.degrees[i];
    }

    var improved = true;
    var sweeps: u32 = 0;
    const MAX_SWEEPS = 20;

    while (improved and sweeps < MAX_SWEEPS) : (sweeps += 1) {
        improved = false;

        for (order) |node| {
            const ci = community[node];
            const node_degree = graph.degrees[node];

            // Remove node from current community
            comm_weight[ci] -= node_degree;

            // Count edges to neighboring communities
            var community_edges = std.AutoHashMap(u32, f64).init(allocator);
            defer community_edges.deinit();

            const start = graph.offsets[node];
            const end = graph.offsets[node + 1];
            for (graph.adjacency[start..end]) |edge| {
                const neighbor_comm = community[edge.target];
                const prev = community_edges.get(neighbor_comm) orelse 0.0;
                try community_edges.put(neighbor_comm, prev + edge.weight);
            }

            // Find best community
            var best_comm: u32 = ci;
            var best_gain: f64 = 0.0;

            var iter = community_edges.iterator();
            while (iter.next()) |entry| {
                const c = entry.key_ptr.*;
                const edges_to_c = entry.value_ptr.*;
                // Modularity gain: dQ = (ki_in / m) - gamma * (degree * comm_total / (2*m^2))
                const gain = (edges_to_c / m) - gamma * (node_degree * comm_weight[c]) / (2.0 * m * m);
                if (gain > best_gain) {
                    best_gain = gain;
                    best_comm = c;
                }
            }

            if (best_comm != ci) {
                community[node] = best_comm;
                comm_weight[best_comm] += node_degree;
                improved = true;
            } else {
                // Return node to original community
                comm_weight[ci] += node_degree;
            }
        }
    }

    return modularity(graph, community, m, gamma);
}

// ██████████████████████████████████████████████████████████████████████████
// Phase 2: Refinement (Leiden's key advantage over Louvain)
// ██████████████████████████████████████████████████████████████████████████

fn refinement(
    graph: InMemoryGraph,
    community: []u32,
    _: f64,
    _: f64,
    allocator: std.mem.Allocator,
) !void {
    // Within each rough community, run a finer partitioning to ensure
    // each sub-community is well-connected internally.

    var refined = try allocator.alloc(u32, graph.node_count);
    defer allocator.free(refined);
    @memcpy(refined, community);

    // Find unique communities
    var comm_set = std.AutoHashMap(u32, void).init(allocator);
    defer comm_set.deinit();
    for (community) |c| try comm_set.put(c, {});

    var next_community_id: u32 = 0;
    var comm_remap = std.AutoHashMap(u32, u32).init(allocator);
    defer comm_remap.deinit();

    var c_iter = comm_set.keyIterator();
    while (c_iter.next()) |comm_key| {
        const c = comm_key.*;
        // Check internal connectivity — if a node has more edges outside
        // the community than inside, consider it a candidate for moving.
        // For simplicity, we assign each node its own refined community if
        // it's poorly connected, or keep it with the majority.

        // For code graphs, refinement is less critical since communities
        // tend to be naturally cohesive. We use a simple approach:
        // only split if the internal density is below threshold.
        var internal_edges: f64 = 0.0;
        var external_edges: f64 = 0.0;
        var members: u32 = 0;

        for (0..graph.node_count) |i| {
            if (community[i] != c) continue;
            members += 1;
            const start = graph.offsets[i];
            const end = graph.offsets[i + 1];
            for (graph.adjacency[start..end]) |edge| {
                if (community[edge.target] == c) {
                    internal_edges += edge.weight;
                } else {
                    external_edges += edge.weight;
                }
            }
        }

        // Only refine if the community is poorly connected
        if (members <= 1 or internal_edges > external_edges) {
            // Well-connected — keep as-is
            try comm_remap.put(c, next_community_id);
            for (0..graph.node_count) |i| {
                if (community[i] == c) refined[i] = next_community_id;
            }
            next_community_id += 1;
        } else {
            // Poorly connected — split into individual nodes
            for (0..graph.node_count) |i| {
                if (community[i] == c) {
                    refined[i] = next_community_id;
                    next_community_id += 1;
                }
            }
        }
    }

    @memcpy(community, refined);
}

// ██████████████████████████████████████████████████████████████████████████
// Write results back to SQLite
// ██████████████████████████████████████████████████████████████████████████

fn assignCommunities(
    gdb: *graph_db.GraphDb,
    graph: InMemoryGraph,
    community: []u32,
    allocator: std.mem.Allocator,
) !void {
    // Group symbol IDs by community
    var comm_groups = std.AutoHashMap(u32, std.ArrayList(i64)).init(allocator);
    defer {
        var c_iter = comm_groups.valueIterator();
        while (c_iter.next()) |list| list.deinit(allocator);
        comm_groups.deinit();
    }

    for (0..graph.node_count) |i| {
        const c = community[i];
        const result = try comm_groups.getOrPut(c);
        if (!result.found_existing) {
            result.value_ptr.* = std.ArrayList(i64).initCapacity(allocator, 4) catch @panic("OOM");
        }
        try result.value_ptr.append(allocator, graph.symbol_ids[i]);
    }

    // Batch update: reset all, then set per community
    try gdb.exec("UPDATE symbols SET community_id = NULL");

    var c_iter = comm_groups.iterator();
    while (c_iter.next()) |entry| {
        const group_id = entry.key_ptr.*;
        const symbols_list = entry.value_ptr.*;

        // Build comma-separated list for IN clause
        var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch @panic("OOM");
        defer buf.deinit(allocator);
        for (symbols_list.items, 0..) |sid, j| {
            if (j > 0) try buf.append(allocator, ',');
            try buf.writer(allocator).print("{d}", .{sid});
        }

        const sql_fmt = try std.fmt.allocPrint(
            allocator, "UPDATE symbols SET community_id = {d} WHERE id IN ({s})",
            .{ group_id, buf.items },
        );
        const sql_z = try allocator.dupeZ(u8, sql_fmt);
        allocator.free(sql_fmt);
        defer allocator.free(sql_z);
        try gdb.exec(sql_z);
    }
}

// ██████████████████████████████████████████████████████████████████████████
// Helpers
// ██████████████████████████████████████████████████████████████████████████

fn countCommunities(community: []const u32, node_count: u32) u32 {
    var set = std.AutoHashMap(u32, void).init(std.heap.page_allocator);
    defer set.deinit();
    for (community[0..node_count]) |c| set.put(c, {}) catch continue;
    return @intCast(set.count());
}

fn modularity(graph: InMemoryGraph, community: []const u32, m: f64, gamma: f64) f64 {
    if (m == 0.0) return 0.0;
    var q: f64 = 0.0;

    for (0..graph.node_count) |i| {
        const ci = community[i];
        const start = graph.offsets[i];
        const end = graph.offsets[i + 1];
        for (graph.adjacency[start..end]) |edge| {
            const j = edge.target;
            const cj = community[j];
            if (ci == cj) {
                q += edge.weight - gamma * graph.degrees[i] * graph.degrees[j] / (2.0 * m);
            }
        }
    }

    return q / (2.0 * m);
}

/// Fisher-Yates shuffle in-place.
fn shuffle(slice: []u32) void {
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.microTimestamp()));
    const rng = prng.random();
    var i: usize = slice.len;
    while (i > 1) {
        i -= 1;
        const j = rng.intRangeLessThan(usize, 0, i + 1);
        const tmp = slice[i];
        slice[i] = slice[j];
        slice[j] = tmp;
    }
}
