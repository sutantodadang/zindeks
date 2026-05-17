//! Smart context window management — token budget estimation and
//! section prioritisation for AI prompt assembly.
//!
//! Estimates tokens as ceil(chars / 4), a rough approximation
//! sufficient for budget enforcement without a real tokeniser.

const std = @import("std");

/// Rough token estimation: characters / CHARS_PER_TOKEN.
pub const CHARS_PER_TOKEN: usize = 4;

/// Token budget with reserved overhead (system prompt, etc.).
pub const TokenBudget = struct {
    max_tokens: usize,
    reserved_tokens: usize,

    /// Tokens available after subtracting reserved overhead.
    pub fn available(self: TokenBudget) usize {
        return if (self.max_tokens > self.reserved_tokens)
            self.max_tokens - self.reserved_tokens
        else
            0;
    }

    /// Create a budget for a given maximum, optionally reserving
    /// overhead for system prompts or framing.
    pub fn init(max_tokens: usize, reserved_tokens: usize) TokenBudget {
        return .{
            .max_tokens = max_tokens,
            .reserved_tokens = reserved_tokens,
        };
    }
};

/// Estimate token count from a UTF-8 string.
pub fn estimateTokens(text: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += len;
        count += 1;
    }
    return (count + CHARS_PER_TOKEN - 1) / CHARS_PER_TOKEN;
}

/// Context section used by the context assembler.
pub const ContextSection = struct {
    title: []const u8,
    content: []const u8,
    priority: u8, // 1-10, higher = more important
    estimated_tokens: usize,
};

/// Prioritise and truncate sections to fit within a token budget.
///
/// Returns a new ArrayList of sections (the caller .deinit()s it with allocator).
pub fn prioritizeSections(
    allocator: std.mem.Allocator,
    sections: []const ContextSection,
    budget: TokenBudget,
) !std.ArrayList(ContextSection) {
    const avail = budget.available();

    // Copy and sort by priority descending.
    const sorted = try allocator.dupe(ContextSection, sections);
    defer allocator.free(sorted);

    std.mem.sort(ContextSection, sorted, {}, cmpByPriorityDesc);

    // Pack sections into budget.
    var result = std.ArrayList(ContextSection){};
    errdefer result.deinit(allocator);

    var remaining: usize = avail;
    for (sorted) |*sec| {
        if (remaining == 0) break;

        if (sec.estimated_tokens <= remaining) {
            try result.append(allocator, sec.*);
            remaining -= sec.estimated_tokens;
        } else {
            const max_chars = remaining * CHARS_PER_TOKEN;
            var truncated = sec.content;
            if (truncated.len > max_chars) {
                truncated = truncated[0..max_chars];
            }
            try result.append(allocator, .{
                .title = sec.title,
                .content = truncated,
                .priority = sec.priority,
                .estimated_tokens = estimateTokens(truncated),
            });
            remaining = 0;
        }
    }

    return result;
}

fn cmpByPriorityDesc(_: void, a: ContextSection, b: ContextSection) bool {
    return a.priority > b.priority;
}

// ── Tests ──────────────────────────────────────────────────────────

test "TokenBudget available" {
    const tb = TokenBudget.init(4000, 200);
    try std.testing.expectEqual(@as(usize, 3800), tb.available());
}

test "TokenBudget zero when reserved > max" {
    const tb = TokenBudget.init(100, 200);
    try std.testing.expectEqual(@as(usize, 0), tb.available());
}

test "estimateTokens ascii" {
    try std.testing.expectEqual(@as(usize, 2), estimateTokens("hello"));
}

test "estimateTokens multi-byte" {
    const s = "cafe" ++ "\u{0301}";
    try std.testing.expectEqual(@as(usize, 2), estimateTokens(s));
}

test "estimateTokens empty" {
    try std.testing.expectEqual(@as(usize, 0), estimateTokens(""));
}

test "prioritizeSections fits all" {
    const sections = [_]ContextSection{
        .{ .title = "Low", .content = "aa", .priority = 1, .estimated_tokens = 1 },
        .{ .title = "High", .content = "bb", .priority = 10, .estimated_tokens = 1 },
    };
    const budget = TokenBudget.init(100, 0);
    var result = try prioritizeSections(std.testing.allocator, &sections, budget);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), result.items.len);
    try std.testing.expectEqualStrings("High", result.items[0].title);
    try std.testing.expectEqualStrings("Low", result.items[1].title);
}

test "prioritizeSections drops low priority" {
    const sections = [_]ContextSection{
        .{ .title = "Low", .content = "aa", .priority = 1, .estimated_tokens = 50 },
        .{ .title = "High", .content = "bb", .priority = 10, .estimated_tokens = 10 },
    };
    const budget = TokenBudget.init(20, 0);
    var result = try prioritizeSections(std.testing.allocator, &sections, budget);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expectEqualStrings("High", result.items[0].title);
}

test "prioritizeSections truncates when partial fit" {
    const sections = [_]ContextSection{
        .{ .title = "S1", .content = "A" ** 20, .priority = 5, .estimated_tokens = 5 },
    };
    const budget = TokenBudget.init(3, 0);
    var result = try prioritizeSections(std.testing.allocator, &sections, budget);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.items.len);
    try std.testing.expect(result.items[0].content.len <= 12);
}
