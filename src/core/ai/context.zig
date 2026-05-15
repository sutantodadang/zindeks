//! Context assembly for AI prompts — builds rich, prioritised markdown-style
//! context from search results, call graph traces, and architecture overviews.
//!
//! Enforces a token budget: sections are ordered by priority, and low-priority
//! sections are dropped (or truncated) when the budget is exceeded.

const std = @import("std");
const window_mod = @import("window.zig");
const search_mod = @import("../search/engine.zig");
const call_graph = @import("../graph/call_graph.zig");
const arch_mod = @import("../analysis/arch.zig");

pub const ContextSection = window_mod.ContextSection;

/// Context builder — collects sections and assembles them into a
/// single AI-friendly markdown document.
pub const ContextBuilder = struct {
    allocator: std.mem.Allocator,
    sections: std.ArrayList(ContextSection),
    token_source: bool, // track whether we have content

    pub fn init(allocator: std.mem.Allocator) ContextBuilder {
        return .{
            .allocator = allocator,
            .sections = std.ArrayList(ContextSection){},
            .token_source = false,
        };
    }

    pub fn deinit(self: *ContextBuilder) void {
        for (self.sections.items) |*sec| {
            self.allocator.free(sec.title);
            self.allocator.free(sec.content);
        }
        self.sections.deinit(self.allocator);
    }

    /// Add BM25 search results as a context section.
    pub fn addSearchResults(
        self: *ContextBuilder,
        query: []const u8,
        results: []const search_mod.Result,
    ) !void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        try buf.appendSlice(self.allocator, "Search query: `");
        try buf.appendSlice(self.allocator, query);
        try buf.appendSlice(self.allocator, "`\n\n");

        for (results, 0..) |result, i| {
            if (i > 0) try buf.appendSlice(self.allocator, "\n---\n\n");
            try buf.writer(self.allocator).print("**{s}**  (score: {d:.2})\n", .{ result.path, result.score });
            if (result.snippet.len > 0) {
                try buf.appendSlice(self.allocator, "```\n");
                try buf.appendSlice(self.allocator, trimLines(result.snippet, 20));
                try buf.appendSlice(self.allocator, "\n```\n");
            }
        }

        if (results.len == 0) {
            try buf.appendSlice(self.allocator, "_No results found._\n");
        }

        const content = try buf.toOwnedSlice(self.allocator);
        const title = try std.fmt.allocPrint(self.allocator, "Search Results for '{s}'", .{query});

        try self.sections.append(self.allocator, .{
            .title = title,
            .content = content,
            .priority = 9,
            .estimated_tokens = window_mod.estimateTokens(content),
        });
        self.token_source = true;
    }

    /// Add call graph context for a traced symbol.
    pub fn addCallGraphContext(
        self: *ContextBuilder,
        symbol: []const u8,
        trace_result: call_graph.TraceResult,
    ) !void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        try buf.writer(self.allocator).print("Call graph for `{s}`:\n\n", .{symbol});

        if (trace_result.has_cycle) {
            try buf.appendSlice(self.allocator, "⚠ **Cycle detected** in the call graph.\n\n");
        }

        if (trace_result.nodes.len > 0) {
            try buf.appendSlice(self.allocator, "| Name | Kind | File | Depth |\n");
            try buf.appendSlice(self.allocator, "|------|------|------|-------|\n");
            for (trace_result.nodes) |node| {
                try buf.writer(self.allocator).print("| `{s}` | {s} | {s} | {d} |\n", .{
                    truncateStr(node.name, 40),
                    node.kind,
                    truncateStr(node.file_path, 50),
                    node.depth,
                });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        if (trace_result.edges.len > 0) {
            try buf.appendSlice(self.allocator, "**Edges:**\n");
            for (trace_result.edges) |edge| {
                try buf.writer(self.allocator).print("- `{s}` → `{s}`  ({s})\n", .{
                    truncateStr(edge.source_name, 30),
                    truncateStr(edge.target_name, 30),
                    edge.edge_type,
                });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        const content = try buf.toOwnedSlice(self.allocator);
        const title = try std.fmt.allocPrint(self.allocator, "Call Graph: {s}", .{symbol});

        try self.sections.append(self.allocator, .{
            .title = title,
            .content = content,
            .priority = 7,
            .estimated_tokens = window_mod.estimateTokens(content),
        });
        self.token_source = true;
    }

    /// Add an architecture overview section.
    pub fn addArchitectureOverview(
        self: *ContextBuilder,
        arch: arch_mod.ArchitectureView,
    ) !void {
        var buf = std.ArrayList(u8){};
        defer buf.deinit(self.allocator);

        try buf.writer(self.allocator).print(
            \\**Project statistics:** {d} symbols, {d} edges, {d} files
            \\
            \\
        , .{ arch.total_symbols, arch.total_edges, arch.total_files });

        if (arch.modules.len > 0) {
            try buf.appendSlice(self.allocator, "### Modules\n\n");
            try buf.appendSlice(self.allocator, "| Module | Files | Symbols |\n");
            try buf.appendSlice(self.allocator, "|--------|-------|----------|\n");
            for (arch.modules) |mod| {
                try buf.writer(self.allocator).print("| {s} | {d} | {d} |\n", .{
                    truncateStr(mod.module, 50),
                    mod.file_count,
                    mod.symbol_count,
                });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        if (arch.entry_points.len > 0) {
            try buf.appendSlice(self.allocator, "### Entry Points\n\n");
            for (arch.entry_points) |ep| {
                try buf.writer(self.allocator).print("- `{s}` ({s}) → {s}\n", .{
                    ep.name, ep.kind, truncateStr(ep.file_path, 50),
                });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        if (arch.high_fan_out.len > 0) {
            try buf.appendSlice(self.allocator, "### High Fan-Out Symbols\n\n");
            for (arch.high_fan_out[0..@min(arch.high_fan_out.len, 10)]) |h| {
                try buf.writer(self.allocator).print("- `{s}` ({s}, fan-out: {d})\n", .{ h.name, h.kind, h.fan_out });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        if (arch.high_fan_in.len > 0) {
            try buf.appendSlice(self.allocator, "### High Fan-In Symbols\n\n");
            for (arch.high_fan_in[0..@min(arch.high_fan_in.len, 10)]) |h| {
                try buf.writer(self.allocator).print("- `{s}` ({s}, fan-in: {d})\n", .{ h.name, h.kind, h.fan_in });
            }
            try buf.appendSlice(self.allocator, "\n");
        }

        const content = try buf.toOwnedSlice(self.allocator);
        const title = try self.allocator.dupe(u8, "Architecture Overview");

        try self.sections.append(self.allocator, .{
            .title = title,
            .content = content,
            .priority = 8,
            .estimated_tokens = window_mod.estimateTokens(content),
        });
        self.token_source = true;
    }

    /// Build the final context string within a token budget.
    ///
    /// Sorts sections by priority (highest first), drops low-priority
    /// sections that don't fit, and truncates remaining sections from
    /// the tail to stay within the budget.
    pub fn build(self: *ContextBuilder, max_tokens: usize) ![]const u8 {
        const budget = window_mod.TokenBudget.init(max_tokens, 0);

        var sorted = try window_mod.prioritizeSections(self.allocator, self.sections.items, budget);
        defer {
            for (sorted.items) |sec| {
                self.allocator.free(sec.title);
                self.allocator.free(sec.content);
            }
            sorted.deinit(self.allocator);
        }
        // Clear sections without freeing - ownership transferred to sorted
        self.sections.clearRetainingCapacity();

        var buf = std.ArrayList(u8){};
        errdefer buf.deinit(self.allocator);

        for (sorted.items) |sec| {
            try buf.writer(self.allocator).print("## {s}\n\n{s}\n\n", .{ sec.title, sec.content });
        }

        if (buf.items.len == 0) {
            try buf.appendSlice(self.allocator, "_No context available._\n");
        }

        return buf.toOwnedSlice(self.allocator);
    }

    /// Estimated token count for all accumulated sections.
    pub fn estimateTotal(self: *ContextBuilder) usize {
        var total: usize = 0;
        for (self.sections.items) |sec| {
            total += sec.estimated_tokens;
        }
        return total;
    }
};

// ── Helpers ────────────────────────────────────────────────────────

fn trimLines(s: []const u8, max_lines: usize) []const u8 {
    var count: usize = 0;
    var end: usize = 0;
    var lines = std.mem.splitAny(u8, s, "\n\r");
    while (lines.next()) |line| {
        if (count >= max_lines) break;
        end += line.len + 1; // + 1 for the separator
        count += 1;
    }
    return if (end <= s.len) s[0..@min(end, s.len)] else s;
}

fn truncateStr(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// ── Tests ──────────────────────────────────────────────────────────

test "ContextBuilder empty build" {
    var builder = ContextBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const ctx = try builder.build(1000);
    defer std.testing.allocator.free(ctx);

    try std.testing.expect(ctx.len > 0);
}

test "ContextBuilder addSearchResults" {
    var builder = ContextBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const results = [_]search_mod.Result{
        .{
            .doc_id = 1,
            .score = 0.95,
            .path = "src/auth.zig",
            .snippet = "pub fn loginMiddleware() void { validateSession(); }",
        },
        .{
            .doc_id = 2,
            .score = 0.72,
            .path = "src/session.zig",
            .snippet = "pub fn validateSession() !Session { ... }",
        },
    };

    try builder.addSearchResults("auth middleware", &results);

    const ctx = try builder.build(2000);
    defer std.testing.allocator.free(ctx);

    try std.testing.expect(std.mem.indexOf(u8, ctx, "auth middleware") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "loginMiddleware") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "src/auth.zig") != null);
}

test "ContextBuilder addCallGraphContext" {
    var builder = ContextBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const nodes = try std.testing.allocator.alloc(call_graph.CallNode, 2);
    nodes[0] = .{
        .name = "main",
        .kind = "function",
        .file_path = "src/main.zig",
        .depth = 0,
    };
    nodes[1] = .{
        .name = "initLogger",
        .kind = "function",
        .file_path = "src/log.zig",
        .depth = 1,
    };

    const edges = try std.testing.allocator.alloc(call_graph.CallEdge, 1);
    edges[0] = .{
        .source_name = "main",
        .target_name = "initLogger",
        .edge_type = "calls",
        .confidence = 1.0,
    };

    const trace = call_graph.TraceResult{
        .nodes = nodes,
        .edges = edges,
        .has_cycle = false,
    };

    try builder.addCallGraphContext("main", trace);

    const ctx = try builder.build(2000);
    defer std.testing.allocator.free(ctx);

    try std.testing.expect(std.mem.indexOf(u8, ctx, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "initLogger") != null);
}

test "ContextBuilder addArchitectureOverview" {
    var builder = ContextBuilder.init(std.testing.allocator);
    defer builder.deinit();

    const arch = arch_mod.ArchitectureView{
        .modules = &.{},
        .entry_points = &.{},
        .high_fan_out = &.{},
        .high_fan_in = &.{},
        .total_symbols = 150,
        .total_edges = 320,
        .total_files = 45,
    };

    try builder.addArchitectureOverview(arch);

    const ctx = try builder.build(2000);
    defer std.testing.allocator.free(ctx);

    try std.testing.expect(std.mem.indexOf(u8, ctx, "150 symbols") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx, "320 edges") != null);
}

test "ContextBuilder token budget enforcement" {
    var builder = ContextBuilder.init(std.testing.allocator);
    defer builder.deinit();

    // Add two search result batches
    var results1 = [_]search_mod.Result{
        .{ .doc_id = 1, .score = 0.9, .path = "a.zig", .snippet = "fn one() {}" },
        .{ .doc_id = 2, .score = 0.8, .path = "b.zig", .snippet = "fn two() {}" },
    };
    var results2 = [_]search_mod.Result{
        .{ .doc_id = 3, .score = 0.7, .path = "c.zig", .snippet = "fn three() {}" },
        .{ .doc_id = 4, .score = 0.6, .path = "d.zig", .snippet = "fn four() {}" },
    };

    try builder.addSearchResults("q1", &results1);
    try builder.addSearchResults("q2", &results2);

    const total_estimate = builder.estimateTotal();
    // Budget to only 20% of total — should drop low-priority sections
    const small_budget = @max(50, total_estimate / 5);
    const ctx = try builder.build(small_budget);
    defer std.testing.allocator.free(ctx);

    // Should produce non-empty output within budget
    try std.testing.expect(ctx.len > 0);
    try std.testing.expect(window_mod.estimateTokens(ctx) <= small_budget + 10); // +10 for header overhead
}
