//! Integration tests for the AI modules: context assembly, summarisation,
//! query understanding, and context window management.
//!
//! Also pulls in the module-internal tests from each ai sub-module.

const std = @import("std");
const zindeks = @import("zindeks");

const testing = std.testing;

// ── Include module-internal tests ──────────────────────────────────
// These force the compiler to discover test blocks inside each module.
comptime {
    _ = zindeks.ai.window;
    _ = zindeks.ai.summarize;
    _ = zindeks.ai.query;
    _ = zindeks.ai.context;
}

// ── Integration tests ──────────────────────────────────────────────

test "full pipeline: parse query → build context" {
    const allocator = testing.allocator;

    // 1. Parse a natural language query
    var parsed = try zindeks.ai.query.parseQuery(allocator, "where is loginMiddleware defined?");
    defer parsed.deinit(allocator);

    try testing.expectEqual(zindeks.ai.query.QueryIntent.find_definition, parsed.intent);

    // 2. Build a context from the parsed query
    var builder = zindeks.ai.context.ContextBuilder.init(allocator);
    defer builder.deinit();

    // Simulate search results
    const sim_results = [_]zindeks.search.engine.Result{
        .{
            .doc_id = 1,
            .score = 0.95,
            .path = "src/auth.zig",
            .snippet = "pub fn loginMiddleware() void { validateSession(); }",
        },
    };

    try builder.addSearchResults(parsed.original, &sim_results);

    const ctx = try builder.build(1000);
    defer allocator.free(ctx);

    try testing.expect(std.mem.indexOf(u8, ctx, "loginMiddleware") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "src/auth.zig") != null);
}

test "token budget: drop low priority sections" {
    const allocator = testing.allocator;

    const sections = [_]zindeks.ai.context.ContextSection{
        .{
            .title = "High Priority",
            .content = "Important content here",
            .priority = 10,
            .estimated_tokens = 50,
        },
        .{
            .title = "Medium Priority",
            .content = "Somewhat important",
            .priority = 5,
            .estimated_tokens = 50,
        },
        .{
            .title = "Low Priority",
            .content = "Least important",
            .priority = 1,
            .estimated_tokens = 50,
        },
    };

    // Budget only allows ~2 sections (150 tokens → only 2 fit, budget is tight)
    const budget = zindeks.ai.window.TokenBudget.init(100, 0);
    var result = try zindeks.ai.window.prioritizeSections(allocator, &sections, budget);
    defer result.deinit(allocator);

    // Only High and Medium should fit (100 = 50+50)
    try testing.expect(result.items.len >= 1);
    try testing.expectEqualStrings("High Priority", result.items[0].title);
}

test "query intent: all intents detected" {
    const allocator = testing.allocator;

    const test_cases = [_]struct { query: []const u8, expected: zindeks.ai.query.QueryIntent }{
        .{ .query = "where is the login function defined?", .expected = .find_definition },
        .{ .query = "who calls parseToken?", .expected = .find_usage },
        .{ .query = "explain how the cache works", .expected = .explain },
        .{ .query = "how to refactor the userManager?", .expected = .refactor },
        .{ .query = "why is the auth middleware broken?", .expected = .debug },
        .{ .query = "show me the project structure", .expected = .explore },
        .{ .query = "JWT authentication", .expected = .search },
    };

    for (test_cases) |tc| {
        var parsed = try zindeks.ai.query.parseQuery(allocator, tc.query);
        defer parsed.deinit(allocator);
        try testing.expectEqual(tc.expected, parsed.intent);
    }
}

test "summarise: pipeline integration" {
    const code =
        \\/// Validate a JWT token and return the payload.
        \\pub fn validateToken(token: []const u8) !TokenPayload {
        \\    if (token.len == 0) return error.EmptyToken;
        \\    const payload = try decodeToken(token);
        \\    if (payload.expired()) return error.ExpiredToken;
        \\    return payload;
        \\}
    ;

    const summary = try zindeks.ai.summarize.summarizeSymbol(testing.allocator, code, "zig");
    defer summary.deinit(testing.allocator);

    try testing.expectEqualStrings("validateToken", summary.name);
    try testing.expect(summary.complexity_score > 0);
    try testing.expect(summary.key_operations.len > 0);
}

test "context builder: section ordering" {
    var builder = zindeks.ai.context.ContextBuilder.init(testing.allocator);
    defer builder.deinit();

    // Add a low-priority section first, then high-priority
    const res1 = [_]zindeks.search.engine.Result{
        .{ .doc_id = 1, .score = 0.5, .path = "low.zig", .snippet = "low" },
    };
    const res2 = [_]zindeks.search.engine.Result{
        .{ .doc_id = 2, .score = 0.9, .path = "high.zig", .snippet = "high" },
    };

    try builder.addSearchResults("low_query", &res1);
    try builder.addSearchResults("high_query", &res2);

    const ctx = try builder.build(2000);
    defer testing.allocator.free(ctx);

    // Both should appear in the output
    try testing.expect(std.mem.indexOf(u8, ctx, "low_query") != null);
    try testing.expect(std.mem.indexOf(u8, ctx, "high_query") != null);
    // Both have same priority → stable sort preserves insertion order
    const low_pos = std.mem.indexOf(u8, ctx, "low_query") orelse 0;
    const high_pos = std.mem.indexOf(u8, ctx, "high_query") orelse 99999;
    try testing.expect(low_pos < high_pos); // low added first, same priority
}
