//! Cypher executor — translates parsed Cypher AST to SQL queries against
//! the symbols/edges/documents tables.
//!
//! ~160 LOC.

const std = @import("std");
const graph_db = @import("../../storage/graph_db.zig");
const parser = @import("parser.zig");

const QueryNode = parser.QueryNode;
const ExprKind = parser.ExprKind;

// B7: Static alias constants — eliminates allocPrint("t{d}", idx) / allocPrint("e{d}", idx)
// in the MATCH clause loop (2 mallocs per clause → 0).
// Supports up to 16 MATCH clauses; any query with more falls back to the old path.
const MAX_STATIC_ALIASES = 16;
const table_aliases: [MAX_STATIC_ALIASES][]const u8 = .{
    "t0", "t1", "t2",  "t3",  "t4",  "t5",  "t6",  "t7",
    "t8", "t9", "t10", "t11", "t12", "t13", "t14", "t15",
};
const edge_aliases: [MAX_STATIC_ALIASES][]const u8 = .{
    "e0", "e1", "e2",  "e3",  "e4",  "e5",  "e6",  "e7",
    "e8", "e9", "e10", "e11", "e12", "e13", "e14", "e15",
};

/// Execute a parsed Cypher query and return a JSON array of result rows.
pub fn execute(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    query: *const QueryNode,
    writer: anytype,
) !void {
    if (query.match_clauses.len == 0) {
        try writer.writeAll("{\"error\":\"No MATCH clause\"}");
        return;
    }

    var sql_buf = std.ArrayList(u8).initCapacity(allocator, 512) catch @panic("OOM");
    defer sql_buf.deinit(allocator);

    // Build SELECT clause from RETURN items
    try sql_buf.appendSlice(allocator, "SELECT ");
    const num_return = query.return_clause.items.len;
    for (query.return_clause.items, 0..) |item, i| {
        try writeExprToSQL(allocator, &item.expression, &sql_buf, "s");
        if (item.alias) |a| {
            try sql_buf.writer(allocator).print(" AS \"{s}\"", .{a});
        }
        if (i + 1 < num_return) try sql_buf.append(allocator, ',');
    }

    // Build FROM/JOIN clauses from MATCH clauses
    try sql_buf.appendSlice(allocator, " FROM symbols s");

    // For each MATCH clause, join edges + target symbols
    // B7: use pre-allocated static aliases to avoid allocPrint per iteration.
    // Baseline (before B7): ~2 allocs * match_clauses.len per execute call removed.
    for (query.match_clauses, 0..) |mc, idx| {
        const tn: []const u8 = if (idx < MAX_STATIC_ALIASES)
            table_aliases[idx]
        else blk: {
            // Rare: more than 16 match clauses — fall back to heap.
            break :blk try std.fmt.allocPrint(allocator, "t{d}", .{idx});
        };
        const en: []const u8 = if (idx < MAX_STATIC_ALIASES)
            edge_aliases[idx]
        else blk: {
            break :blk try std.fmt.allocPrint(allocator, "e{d}", .{idx});
        };
        // Only free if we heap-allocated (idx >= MAX_STATIC_ALIASES)
        defer if (idx >= MAX_STATIC_ALIASES) {
            allocator.free(tn);
            allocator.free(en);
        };

        try sql_buf.writer(allocator).print(
            " JOIN edges {s} ON {s}.source_symbol_id = s.id AND {s}.edge_type = '",
            .{ en, en, en },
        );
        if (mc.edge_type.len > 0) {
            try sql_buf.appendSlice(allocator, mc.edge_type);
        } else {
            try sql_buf.appendSlice(allocator, "calls");
        }
        try sql_buf.writer(allocator).print(
            "' JOIN symbols {s} ON {s}.id = {s}.target_symbol_id",
            .{ tn, tn, en },
        );
    }

    // WHERE clause
    if (query.where_clause) |wc| {
        const where_sql = try buildWhereSQL(allocator, &wc.expression, "s");
        defer allocator.free(where_sql);
        if (where_sql.len > 0) {
            try sql_buf.appendSlice(allocator, " WHERE ");
            try sql_buf.appendSlice(allocator, where_sql);
        }
    }

    // ORDER BY
    if (query.order_by) |ob| {
        if (ob.items.len > 0) {
            try sql_buf.appendSlice(allocator, " ORDER BY ");
            for (ob.items, 0..) |oi, i| {
                try writeExprToSQL(allocator, &oi.expression, &sql_buf, "s");
                if (oi.descending) try sql_buf.appendSlice(allocator, " DESC");
                if (i + 1 < ob.items.len) try sql_buf.append(allocator, ',');
            }
        }
    }

    // LIMIT
    const limit = query.limit orelse 100;
    try sql_buf.writer(allocator).print(" LIMIT {d}", .{@min(limit, 200)});

    // Execute SQL
    const sql_z = try allocator.dupeZ(u8, sql_buf.items);
    defer allocator.free(sql_z);
    var stmt = try gdb.prepare(sql_z);
    defer stmt.finalize();

    const col_count = stmt.columnCount();
    try writer.writeByte('[');

    var first_row = true;
    while (try stmt.step()) {
        if (!first_row) try writer.writeByte(',');
        first_row = false;
        try writer.writeByte('{');

        for (0..col_count) |ci| {
            if (ci > 0) try writer.writeByte(',');
            const col_name = stmt.columnName(@intCast(ci)) orelse "?";
            try writer.print("\"{s}\":", .{col_name});

            const ct = stmt.columnType(@intCast(ci));
            switch (ct) {
                .integer => try writer.print("{d}", .{try stmt.columnInt(@intCast(ci))}),
                .float => try writer.print("{d}", .{try stmt.columnFloat(@intCast(ci))}),
                .text => try writer.print("\"{s}\"", .{try stmt.columnText(@intCast(ci))}),
                .null => try writer.writeAll("null"),
                .blob => try writer.writeAll("null"),
            }
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

/// Build a WHERE SQL expression from an ExprNode tree.
fn buildWhereSQL(allocator: std.mem.Allocator, expr: *const parser.ExprNode, default_table: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(allocator, 256) catch @panic("OOM");
    try writeWhereExpr(allocator, expr, &buf, default_table);
    return try buf.toOwnedSlice(allocator);
}

fn writeWhereExpr(allocator: std.mem.Allocator, expr: *const parser.ExprNode, buf: *std.ArrayList(u8), table: []const u8) !void {
    switch (expr.kind) {
        .@"and", .@"or" => {
            if (expr.left) |l| try writeWhereExpr(allocator, l, buf, table);
            try buf.writer(allocator).print(" {s} ", .{if (expr.kind == .@"and") "AND" else "OR"});
            if (expr.right) |r| try writeWhereExpr(allocator, r, buf, table);
        },
        .@"not" => {
            try buf.appendSlice(allocator, "NOT ");
            if (expr.left) |l| try writeWhereExpr(allocator, l, buf, table);
        },
        .identifier => try buf.appendSlice(allocator, expr.value),
        .string_literal => try buf.writer(allocator).print("'{s}'", .{expr.value}),
        .integer_literal => try buf.writer(allocator).print("{d}", .{expr.value_int}),
        .property_access => {
            if (expr.left) |l| {
                try writeWhereExpr(allocator, l, buf, table);
                try buf.writer(allocator).print(".{s}", .{expr.value});
            }
        },
        .eq => {
            if (expr.left) |l| try writeWhereExpr(allocator, l, buf, table);
            try buf.appendSlice(allocator, " = ");
            if (expr.right) |r| try writeWhereExpr(allocator, r, buf, table);
        },
        .neq => {
            if (expr.left) |l| try writeWhereExpr(allocator, l, buf, table);
            try buf.appendSlice(allocator, " <> ");
            if (expr.right) |r| try writeWhereExpr(allocator, r, buf, table);
        },
        .lt, .gt, .lte, .gte => {
            if (expr.left) |l| try writeWhereExpr(allocator, l, buf, table);
            const op = switch (expr.kind) {
                .lt => "<", .gt => ">", .lte => "<=", .gte => ">=", else => unreachable,
            };
            try buf.writer(allocator).print(" {s} ", .{op});
            if (expr.right) |r| try writeWhereExpr(allocator, r, buf, table);
        },
    }
}

/// Write an expression to SQL for SELECT columns.
fn writeExprToSQL(allocator: std.mem.Allocator, expr: *const parser.ExprNode, buf: *std.ArrayList(u8), table: []const u8) !void {
    switch (expr.kind) {
        .identifier => try buf.writer(allocator).print("{s}.{s}", .{ table, expr.value }),
        .property_access => {
            if (expr.left) |l| {
                try writeExprToSQL(allocator, l, buf, table);
                try buf.writer(allocator).print(".{s}", .{expr.value});
            }
        },
        .string_literal => try buf.writer(allocator).print("'{s}'", .{expr.value}),
        .integer_literal => try buf.writer(allocator).print("{d}", .{expr.value_int}),
        else => try buf.writer(allocator).print("{s}.{s}", .{ table, expr.value }),
    }
}
