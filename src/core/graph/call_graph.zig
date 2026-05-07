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
                \\SELECT s.name, s.kind, e.edge_type
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

                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, caller_name),
                    .target_name = try allocator.dupe(u8, fn_name),
                    .edge_type = try allocator.dupe(u8, edge_type),
                });

                if (item.depth < max_depth) {
                    try queue.append(allocator, .{ .name = caller_name, .depth = item.depth + 1 });
                }
            }
        }

        // Outbound: what does this symbol call?
        if (direction == .outbound or direction == .both) {
            var out_stmt = try gdb.prepare(
                \\SELECT s.name, s.kind, e.edge_type
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

                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, fn_name),
                    .target_name = try allocator.dupe(u8, callee_name),
                    .edge_type = try allocator.dupe(u8, edge_type),
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
