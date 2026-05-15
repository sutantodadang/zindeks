//! Call graph tracing — BFS traversal over CALLS edges in the graph database.
//!
//! Provides inbound (who calls this function?), outbound (what does this
//! function call?), and bidirectional tracing with configurable depth and
//! cycle detection.

const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");

// ██████████████████████████████████████████████████████████████████████████
// Types
// ██████████████████████████████████████████████████████████████████████████

/// Direction for call graph traversal.
pub const Direction = enum { inbound, outbound, both };

/// A single node in the traced call graph.
pub const CallNode = struct {
    name: []const u8,
    kind: []const u8,
    file_path: []const u8,
    depth: u32,

    pub fn deinit(self: *CallNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.file_path);
    }
};

/// An edge (call relationship) in the traced graph.
pub const CallEdge = struct {
    source_name: []const u8,
    target_name: []const u8,
    edge_type: []const u8,
    confidence: f64,

    pub fn deinit(self: *CallEdge, allocator: std.mem.Allocator) void {
        allocator.free(self.source_name);
        allocator.free(self.target_name);
        allocator.free(self.edge_type);
    }
};

/// Result of a call graph trace operation.
pub const TraceResult = struct {
    nodes: []CallNode,
    edges: []CallEdge,
    has_cycle: bool,

    pub fn deinit(self: *TraceResult, allocator: std.mem.Allocator) void {
        for (self.nodes) |*n| n.deinit(allocator);
        allocator.free(self.nodes);
        for (self.edges) |*e| e.deinit(allocator);
        allocator.free(self.edges);
    }
};

/// A node along a traced path between two symbols.
pub const PathNode = struct {
    name: []const u8,
    kind: []const u8,
    file_path: []const u8,

    pub fn deinit(self: *PathNode, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.file_path);
    }
};

/// Result of a path trace between two symbols.
pub const PathResult = struct {
    path: []PathNode,
    total_confidence: f64,
    found: bool,

    pub fn deinit(self: *PathResult, allocator: std.mem.Allocator) void {
        for (self.path) |*n| n.deinit(allocator);
        allocator.free(self.path);
    }
};

/// A centrality score entry — symbol and its total degree (fan-in + fan-out).
pub const CentralityEntry = struct {
    name: []const u8,
    kind: []const u8,
    file_path: []const u8,
    centrality: u32,

    pub fn deinit(self: *CentralityEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.file_path);
    }
};

// ██████████████████████████████████████████████████████████████████████████
// BFS traversal
// ██████████████████████████████████████████████████████████████████████████

/// Trace a call path from a starting symbol name.
/// Returns all reachable nodes and edges up to max_depth (default 5).
pub fn trace(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    symbol_name: []const u8,
    direction: Direction,
    max_depth: u32,
) !TraceResult {
    if (max_depth == 0) return error.ZeroDepth;

    var nodes = std.ArrayList(CallNode).initCapacity(allocator, 64) catch @panic("OOM");
    var edges = std.ArrayList(CallEdge).initCapacity(allocator, 64) catch @panic("OOM");
    var has_cycle = false;

    var visited = std.StringHashMap(void).init(allocator);
    defer visited.deinit();

    const QueueItem = struct { name: []const u8, depth: u32 };
    var queue = std.ArrayList(QueueItem).initCapacity(allocator, 32) catch @panic("OOM");
    defer queue.deinit(allocator);

    try queue.append(allocator, .{ .name = symbol_name, .depth = 0 });

    while (queue.items.len > 0) {
        const item = queue.orderedRemove(0);
        if (item.depth > max_depth) continue;
        if (visited.contains(item.name)) {
            has_cycle = true;
            continue;
        }
        try visited.put(item.name, {});

        var sym_stmt = try gdb.prepare(
            \\SELECT s.id, s.name, s.kind, d.path
            \\FROM symbols s
            \\JOIN documents d ON d.id = s.document_id
            \\WHERE s.name = ?
            \\LIMIT 1
        );
        defer sym_stmt.finalize();
        try sym_stmt.bindText(1, item.name);

        const sym_id: ?i64 = blk: {
            if (!(try sym_stmt.step())) break :blk null;
            break :blk try sym_stmt.columnInt(0);
        };
        if (sym_id == null) continue;

        const sym_id_val = sym_id.?;
        const fn_name = try sym_stmt.columnText(1);
        const fn_kind = try sym_stmt.columnText(2);
        const fn_path = try sym_stmt.columnText(3);

        try nodes.append(allocator, .{
            .name = try allocator.dupe(u8, fn_name),
            .kind = try allocator.dupe(u8, fn_kind),
            .file_path = try allocator.dupe(u8, fn_path),
            .depth = item.depth,
        });

        // Inbound: who calls this symbol?
        if (direction == .inbound or direction == .both) {
            var in_stmt = try gdb.prepare(
                \\SELECT s.name, s.kind, e.edge_type, e.confidence
                \\FROM edges e
                \\JOIN symbols s ON s.id = e.source_symbol_id
                \\WHERE e.target_symbol_id = ? AND e.edge_type = 'calls'
                \\LIMIT 50
            );
            defer in_stmt.finalize();
            try in_stmt.bindInt(1, sym_id_val);

            while (try in_stmt.step()) {
                const caller_name = try in_stmt.columnText(0);
                const edge_type = try in_stmt.columnText(2);
                const confidence = try in_stmt.columnFloat(3);

                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, caller_name),
                    .target_name = try allocator.dupe(u8, fn_name),
                    .edge_type = try allocator.dupe(u8, edge_type),
                    .confidence = confidence,
                });

                if (item.depth < max_depth) {
                    try queue.append(allocator, .{ .name = caller_name, .depth = item.depth + 1 });
                }
            }
        }

        // Outbound: what does this symbol call?
        if (direction == .outbound or direction == .both) {
            var out_stmt = try gdb.prepare(
                \\SELECT s.name, s.kind, e.edge_type, e.confidence
                \\FROM edges e
                \\JOIN symbols s ON s.id = e.target_symbol_id
                \\WHERE e.source_symbol_id = ? AND e.edge_type = 'calls'
                \\LIMIT 50
            );
            defer out_stmt.finalize();
            try out_stmt.bindInt(1, sym_id_val);

            while (try out_stmt.step()) {
                const callee_name = try out_stmt.columnText(0);
                const edge_type = try out_stmt.columnText(2);
                const confidence = try out_stmt.columnFloat(3);

                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, fn_name),
                    .target_name = try allocator.dupe(u8, callee_name),
                    .edge_type = try allocator.dupe(u8, edge_type),
                    .confidence = confidence,
                });

                if (item.depth < max_depth) {
                    try queue.append(allocator, .{ .name = callee_name, .depth = item.depth + 1 });
                }
            }
        }
    }

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
        .has_cycle = has_cycle,
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Path tracing — bidirectional BFS with confidence weighting
// ██████████████████████████████████████████████████████████████████████████

/// Find the shortest path between two symbols using bidirectional BFS.
/// Uses confidence as edge weight — higher confidence edges are preferred
/// when multiple paths of the same length exist (maximizes confidence product).
pub fn tracePath(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    from_name: []const u8,
    to_name: []const u8,
    max_depth: u32,
) !PathResult {
    if (max_depth == 0) return error.ZeroDepth;

    // Resolve node IDs
    const from_id = try resolveSymbolId(gdb, from_name) orelse {
        return PathResult{ .path = &.{}, .total_confidence = 0, .found = false };
    };
    const to_id = try resolveSymbolId(gdb, to_name) orelse {
        return PathResult{ .path = &.{}, .total_confidence = 0, .found = false };
    };

    if (from_id == to_id) {
        var nodes = std.ArrayList(PathNode).initCapacity(allocator, 8) catch @panic("OOM");
        try nodes.append(allocator, try loadPathNode(allocator, gdb, from_id));
        return PathResult{
            .path = try nodes.toOwnedSlice(allocator),
            .total_confidence = 1.0,
            .found = true,
        };
    }

    // ── Forward BFS from source ──────────────────────────────────────
    var forward_dist = std.AutoHashMap(i64, u32).init(allocator);
    defer forward_dist.deinit();
    var forward_pred = std.AutoHashMap(i64, i64).init(allocator);
    defer forward_pred.deinit();
    var forward_conf = std.AutoHashMap(i64, f64).init(allocator);
    defer forward_conf.deinit();

    // ── Backward BFS from target (following incoming edges) ─────────
    var backward_dist = std.AutoHashMap(i64, u32).init(allocator);
    defer backward_dist.deinit();
    var backward_succ = std.AutoHashMap(i64, i64).init(allocator);
    defer backward_succ.deinit();
    var backward_conf = std.AutoHashMap(i64, f64).init(allocator);
    defer backward_conf.deinit();

    const FQueueItem = struct { id: i64, depth: u32 };
    {
        var queue = std.ArrayList(FQueueItem).initCapacity(allocator, 32) catch @panic("OOM");
        defer queue.deinit(allocator);
        try queue.append(allocator, .{ .id = from_id, .depth = 0 });
        try forward_dist.put(from_id, 0);
        try forward_conf.put(from_id, 1.0);

        while (queue.items.len > 0) {
            const item = queue.orderedRemove(0);
            if (item.depth >= max_depth) continue;

            var stmt = try gdb.prepare(
                \\SELECT e.target_symbol_id, e.confidence
                \\FROM edges e
                \\WHERE e.source_symbol_id = ? AND e.edge_type = 'calls'
                \\LIMIT 50
            );
            defer stmt.finalize();
            try stmt.bindInt(1, item.id);

            while (try stmt.step()) {
                const neighbor = try stmt.columnInt(0);
                const conf: f64 = @floatCast(try stmt.columnFloat(1));
                if (forward_dist.contains(neighbor)) continue;

                const new_dist = item.depth + 1;
                try forward_dist.put(neighbor, new_dist);
                try forward_pred.put(neighbor, item.id);
                const prev_conf = forward_conf.get(item.id) orelse 1.0;
                try forward_conf.put(neighbor, prev_conf * conf);

                if (neighbor == to_id) break;
                try queue.append(allocator, .{ .id = neighbor, .depth = new_dist });
            }
        }
    }

    // ── Backward BFS ─────────────────────────────────────────────────
    {
        var queue = std.ArrayList(FQueueItem).initCapacity(allocator, 32) catch @panic("OOM");
        defer queue.deinit(allocator);
        try queue.append(allocator, .{ .id = to_id, .depth = 0 });
        try backward_dist.put(to_id, 0);
        try backward_conf.put(to_id, 1.0);

        while (queue.items.len > 0) {
            const item = queue.orderedRemove(0);
            if (item.depth >= max_depth) continue;

            var stmt = try gdb.prepare(
                \\SELECT e.source_symbol_id, e.confidence
                \\FROM edges e
                \\WHERE e.target_symbol_id = ? AND e.edge_type = 'calls'
                \\LIMIT 50
            );
            defer stmt.finalize();
            try stmt.bindInt(1, item.id);

            while (try stmt.step()) {
                const neighbor = try stmt.columnInt(0);
                const conf: f64 = @floatCast(try stmt.columnFloat(1));
                if (backward_dist.contains(neighbor)) continue;

                const new_dist = item.depth + 1;
                try backward_dist.put(neighbor, new_dist);
                try backward_succ.put(neighbor, item.id);
                const prev_conf = backward_conf.get(item.id) orelse 1.0;
                try backward_conf.put(neighbor, prev_conf * conf);

                if (neighbor == from_id) break;
                try queue.append(allocator, .{ .id = neighbor, .depth = new_dist });
            }
        }
    }

    // ── Find best meeting point ───────────────────────────────────────
    var best_meet: ?i64 = null;
    var best_total_dist: u32 = max_depth * 2 + 1;
    var best_conf_product: f64 = 0.0;

    var fiter = forward_dist.iterator();
    while (fiter.next()) |entry| {
        const node_id = entry.key_ptr.*;
        const f_dist = entry.value_ptr.*;
        const b_dist = backward_dist.get(node_id) orelse continue;
        const total_dist = f_dist + b_dist;

        if (total_dist < best_total_dist) {
            best_total_dist = total_dist;
            best_meet = node_id;
            const f_conf = forward_conf.get(node_id) orelse 1.0;
            const b_conf = backward_conf.get(node_id) orelse 1.0;
            best_conf_product = f_conf * b_conf;
        } else if (total_dist == best_total_dist) {
            const f_conf = forward_conf.get(node_id) orelse 1.0;
            const b_conf = backward_conf.get(node_id) orelse 1.0;
            const prod = f_conf * b_conf;
            if (prod > best_conf_product) {
                best_meet = node_id;
                best_conf_product = prod;
            }
        }
    }

    const meet_id = best_meet orelse {
        return PathResult{ .path = &.{}, .total_confidence = 0, .found = false };
    };

    // ── Reconstruct path: forward to meet + backward from meet ────────
    var path_ids = std.ArrayList(i64).initCapacity(allocator, 16) catch @panic("OOM");
    defer path_ids.deinit(allocator);

    // Collect forward portion (from -> meet), excluding meet (added later)
    {
        var seg = std.ArrayList(i64).initCapacity(allocator, 16) catch @panic("OOM");
        defer seg.deinit(allocator);
        var cur: ?i64 = meet_id;
        while (cur) |c| {
            if (c == from_id) break;
            try seg.append(allocator, c);
            cur = forward_pred.get(c);
        }
        // seg is [meet, ..., predecessor of from]
        // Reverse to get [from's successor, ..., meet]
        var i: usize = seg.items.len;
        while (i > 0) {
            i -= 1;
            try path_ids.append(allocator, seg.items[i]);
        }
    }

    // Collect backward portion (meet -> to), excluding meet (already added)
    {
        var cur = backward_succ.get(meet_id);
        while (cur) |c| {
            if (c == to_id) break;
            try path_ids.append(allocator, c);
            cur = backward_succ.get(c);
        }
    }

    // Separate forward and backward so we can construct: from, ..., meet, ..., to
    // Actually the above is: [successor of from, ..., meet, successor of meet, ..., predecessor of to]
    // But we need from at start and to at end. Let me reconsider.
    // Forward pred: meet -> ... -> from (in reverse). We reversed to get from->...->meet.
    // Backward succ: meet -> ... -> to. We follow to get meet->...->to.
    // So path_ids should be: [from's successor, ..., meet, meet's successor, ..., to's predecessor]
    // We still need from and to.

    var nodes_list = std.ArrayList(PathNode).initCapacity(allocator, 16) catch @panic("OOM");

    // Add source
    try nodes_list.append(allocator, try loadPathNode(allocator, gdb, from_id));

    // Add intermediate nodes
    for (path_ids.items) |nid| {
        try nodes_list.append(allocator, try loadPathNode(allocator, gdb, nid));
    }

    // Add target (if not already there)
    if (path_ids.items.len == 0 or path_ids.items[path_ids.items.len - 1] != to_id) {
        try nodes_list.append(allocator, try loadPathNode(allocator, gdb, to_id));
    }

    return PathResult{
        .path = try nodes_list.toOwnedSlice(allocator),
        .total_confidence = best_conf_product,
        .found = true,
    };
}

/// Resolve a symbol name to its database ID. Returns null if not found.
fn resolveSymbolId(gdb: *graph_db.GraphDb, name: []const u8) !?i64 {
    var stmt = try gdb.prepare("SELECT id FROM symbols WHERE name = ? LIMIT 1");
    defer stmt.finalize();
    try stmt.bindText(1, name);
    if (!(try stmt.step())) return null;
    return try stmt.columnInt(0);
}

/// Load a PathNode from the database by symbol ID.
fn loadPathNode(allocator: std.mem.Allocator, gdb: *graph_db.GraphDb, id: i64) !PathNode {
    var stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path
        \\FROM symbols s JOIN documents d ON d.id = s.document_id
        \\WHERE s.id = ?
    );
    defer stmt.finalize();
    try stmt.bindInt(1, id);
    _ = try stmt.step();
    return PathNode{
        .name = try allocator.dupe(u8, try stmt.columnText(0)),
        .kind = try allocator.dupe(u8, try stmt.columnText(1)),
        .file_path = try allocator.dupe(u8, try stmt.columnText(2)),
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Centrality computation
// ██████████████████████████████████████████████████████████████████████████

/// Compute degree centrality (fan-in + fan-out) for all symbols,
/// returning the top N most central symbols.
pub fn computeCentrality(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    top_n: u32,
) ![]CentralityEntry {
    var stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path,
        \\  (SELECT COUNT(*) FROM edges e WHERE e.source_symbol_id = s.id AND e.edge_type = 'calls') AS fan_out,
        \\  (SELECT COUNT(*) FROM edges e WHERE e.target_symbol_id = s.id AND e.edge_type = 'calls') AS fan_in
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE fan_out > 0 OR fan_in > 0
        \\ORDER BY (fan_out + fan_in) DESC
        \\LIMIT ?
    );
    defer stmt.finalize();
    try stmt.bindInt(1, @as(i64, @intCast(top_n)));

    var results = std.ArrayList(CentralityEntry).initCapacity(allocator, 16) catch @panic("OOM");
    while (try stmt.step()) {
        const fo: u32 = @intCast(try stmt.columnInt(3));
        const fi: u32 = @intCast(try stmt.columnInt(4));
        try results.append(allocator, .{
            .name = try allocator.dupe(u8, try stmt.columnText(0)),
            .kind = try allocator.dupe(u8, try stmt.columnText(1)),
            .file_path = try allocator.dupe(u8, try stmt.columnText(2)),
            .centrality = fo + fi,
        });
    }

    return results.toOwnedSlice(allocator);
}
