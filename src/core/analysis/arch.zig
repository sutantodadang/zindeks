//! Architecture analysis — derives high-level structural views from the
//! knowledge graph.
//!
//! Computes fan-in/fan-out per symbol, identifies entry points (symbols with
//! zero inbound calls), high-churn modules, and provides a structural summary.

const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");

// ██████████████████████████████████████████████████████████████████████████
// Types
// ██████████████████████████████████████████████████████████████████████████

pub const ArchSymbol = struct {
    name: []const u8,
    kind: []const u8,
    file_path: []const u8,
    fan_in: u32,
    fan_out: u32,

    pub fn deinit(self: *ArchSymbol, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.kind);
        allocator.free(self.file_path);
    }
};

pub const ArchModule = struct {
    module: []const u8,
    file_count: u32,
    symbol_count: u32,

    pub fn deinit(self: *ArchModule, allocator: std.mem.Allocator) void {
        allocator.free(self.module);
    }
};

pub const ArchitectureView = struct {
    modules: []ArchModule,
    entry_points: []ArchSymbol,
    high_fan_out: []ArchSymbol, // top symbols by outgoing calls
    high_fan_in: []ArchSymbol, // top symbols by incoming calls
    total_symbols: u32,
    total_edges: u32,
    total_files: u32,

    pub fn deinit(self: *ArchitectureView, allocator: std.mem.Allocator) void {
        for (self.modules) |*m| m.deinit(allocator);
        allocator.free(self.modules);
        for (self.entry_points) |*e| e.deinit(allocator);
        allocator.free(self.entry_points);
        for (self.high_fan_out) |*h| h.deinit(allocator);
        allocator.free(self.high_fan_out);
        for (self.high_fan_in) |*h| h.deinit(allocator);
        allocator.free(self.high_fan_in);
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Analysis
// ██████████████████████████████████████████████████████████████████████████

/// Compute a comprehensive architecture view from the graph database.
pub fn getArchitecture(allocator: std.mem.Allocator, gdb: *graph_db.GraphDb) !ArchitectureView {
    const total_symbols: u32 = @intCast(try gdb.queryScalar("SELECT COUNT(*) FROM symbols"));
    const total_edges: u32 = @intCast(try gdb.queryScalar("SELECT COUNT(*) FROM edges"));
    const total_files: u32 = @intCast(try gdb.queryScalar("SELECT COUNT(*) FROM documents"));

    // ── Modules by directory ──────────────────────────────────────────
    var mod_stmt = try gdb.prepare(
        \\SELECT
        \\  CASE
        \\    WHEN instr(d.path, '/') > 0 THEN rtrim(d.path, replace(d.path, '/', ''))
        \\    ELSE '.'
        \\  END AS module,
        \\  COUNT(DISTINCT d.id) AS file_count,
        \\  COUNT(s.id) AS symbol_count
        \\FROM documents d
        \\LEFT JOIN symbols s ON s.document_id = d.id
        \\GROUP BY module
        \\ORDER BY symbol_count DESC
        \\LIMIT 20
    );
    defer mod_stmt.finalize();

    var modules = std.ArrayList(ArchModule).initCapacity(allocator, 16) catch @panic("OOM");

    while (try mod_stmt.step()) {
        const mod_name = try mod_stmt.columnText(0);
        const file_cnt: u32 = @intCast(try mod_stmt.columnInt(1));
        const sym_cnt: u32 = @intCast(try mod_stmt.columnInt(2));
        try modules.append(allocator, .{
            .module = try allocator.dupe(u8, mod_name),
            .file_count = file_cnt,
            .symbol_count = sym_cnt,
        });
    }

    // ── Entry points (no inbound calls) ───────────────────────────────
    var entry_stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\LEFT JOIN edges e ON e.target_symbol_id = s.id AND e.edge_type = 'calls'
        \\WHERE s.kind = 'function' OR s.kind = 'method'
        \\GROUP BY s.id
        \\HAVING COUNT(e.id) = 0
        \\ORDER BY s.name
        \\LIMIT 20
    );
    defer entry_stmt.finalize();

    var entry_points = std.ArrayList(ArchSymbol).initCapacity(allocator, 16) catch @panic("OOM");

    while (try entry_stmt.step()) {
        try entry_points.append(allocator, .{
            .name = try allocator.dupe(u8, try entry_stmt.columnText(0)),
            .kind = try allocator.dupe(u8, try entry_stmt.columnText(1)),
            .file_path = try allocator.dupe(u8, try entry_stmt.columnText(2)),
            .fan_in = 0,
            .fan_out = 0,
        });
    }

    // ── High fan-out (most outgoing calls) ────────────────────────────
    var fanout_stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path,
        \\  COUNT(e.id) AS fan_out
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\JOIN edges e ON e.source_symbol_id = s.id AND e.edge_type = 'calls'
        \\GROUP BY s.id
        \\ORDER BY fan_out DESC
        \\LIMIT 10
    );
    defer fanout_stmt.finalize();

    var high_fan_out = std.ArrayList(ArchSymbol).initCapacity(allocator, 10) catch @panic("OOM");

    while (try fanout_stmt.step()) {
        const fo: u32 = @intCast(try fanout_stmt.columnInt(3));
        try high_fan_out.append(allocator, .{
            .name = try allocator.dupe(u8, try fanout_stmt.columnText(0)),
            .kind = try allocator.dupe(u8, try fanout_stmt.columnText(1)),
            .file_path = try allocator.dupe(u8, try fanout_stmt.columnText(2)),
            .fan_in = 0,
            .fan_out = fo,
        });
    }

    // ── High fan-in (most incoming calls) ─────────────────────────────
    var fanin_stmt = try gdb.prepare(
        \\SELECT s.name, s.kind, d.path,
        \\  COUNT(e.id) AS fan_in
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\JOIN edges e ON e.target_symbol_id = s.id AND e.edge_type = 'calls'
        \\GROUP BY s.id
        \\ORDER BY fan_in DESC
        \\LIMIT 10
    );
    defer fanin_stmt.finalize();

    var high_fan_in = std.ArrayList(ArchSymbol).initCapacity(allocator, 10) catch @panic("OOM");

    while (try fanin_stmt.step()) {
        const fi: u32 = @intCast(try fanin_stmt.columnInt(3));
        try high_fan_in.append(allocator, .{
            .name = try allocator.dupe(u8, try fanin_stmt.columnText(0)),
            .kind = try allocator.dupe(u8, try fanin_stmt.columnText(1)),
            .file_path = try allocator.dupe(u8, try fanin_stmt.columnText(2)),
            .fan_in = fi,
            .fan_out = 0,
        });
    }

    return .{
        .modules = try modules.toOwnedSlice(allocator),
        .entry_points = try entry_points.toOwnedSlice(allocator),
        .high_fan_out = try high_fan_out.toOwnedSlice(allocator),
        .high_fan_in = try high_fan_in.toOwnedSlice(allocator),
        .total_symbols = total_symbols,
        .total_edges = total_edges,
        .total_files = total_files,
    };
}
