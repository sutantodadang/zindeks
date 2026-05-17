//! Identifier tokenizer: splits camelCase and snake_case identifiers
//! into their constituent words for better search recall.
//!
//! Examples:
//!   "userRepo"   → "user", "repo"
//!   "user_repo"  → "user", "repo"
//!   "GetUserById" → "get", "user", "by", "id"
//!
//! Each token is returned lowercased.

const std = @import("std");

/// Maximum sub-tokens a single identifier can be split into.
pub const MAX_SPLITS: usize = 16;

/// Character class for boundary detection.
const CharClass = enum(u2) { lower, upper, digit, other };

/// Split an identifier into sub-tokens via camelCase and snake_case
/// boundaries. Returns the number of tokens written into `tokens_out`.
/// Each token is a slice of the identifier (lowercased in-place via a
/// caller-provided buffer).
///
/// Caller should ensure id and tokens_out cover the same length.
pub fn splitIdentifier(id: []const u8, tokens_out: [][]const u8) usize {
    if (id.len == 0) return 0;

    var count: usize = 0;
    var start: usize = 0;
    var i: usize = 0;

    // State machine: prev_type tracks the last character class seen
    var prev: CharClass = classify(id[0]);

    i = 1;
    while (i < id.len) : (i += 1) {
        const cur = classify(id[i]);
        if (isBoundary(prev, cur)) {
            if (count < MAX_SPLITS) {
                tokens_out[count] = id[start..i];
                count += 1;
            }
            start = i;
        }
        prev = cur;
    }

    // Emit final token
    if (start < id.len and count < MAX_SPLITS) {
        tokens_out[count] = id[start..];
        count += 1;
    }

    return count;
}

/// Split an identifier and write lowercased sub-tokens into a caller-owned
/// ArrayList. This is the convenience API for callers that don't want to
/// manage a fixed buffer.
pub fn splitInto(
    allocator: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    id: []const u8,
) !void {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier(id, &buf);
    for (buf[0..n]) |tok| {
        const lowered = try allocator.dupe(u8, tok);
        for (lowered) |*c| c.* = std.ascii.toLower(c.*);
        try list.append(lowered);
    }
}

/// Split an identifier and write lowercased sub-tokens into a buffer.
/// Returns the number of tokens written.
pub fn splitIntoBuffer(
    id: []const u8,
    buf: *[MAX_SPLITS * 64]u8,
    buf_len: *usize,
    tokens_out: [][]const u8,
) usize {
    var splits: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier(id, &splits);
    var count: usize = 0;
    for (splits[0..n]) |tok| {
        if (tok.len == 0) continue;
        const end = buf_len.* + tok.len;
        if (end > buf.len) continue;
        for (tok, 0..) |c, j| {
            buf[buf_len.* + j] = std.ascii.toLower(c);
        }
        tokens_out[count] = buf[buf_len.* .. end];
        buf_len.* = end;
        count += 1;
    }
    return count;
}

/// Classify a byte by character class for boundary detection.
fn classify(c: u8) CharClass {
    if (std.ascii.isLower(c)) return .lower;
    if (std.ascii.isUpper(c)) return .upper;
    if (std.ascii.isDigit(c)) return .digit;
    return .other;
}

/// Returns true if there is a token boundary between `prev` and `cur`.
fn isBoundary(prev: CharClass, cur: CharClass) bool {
    // Transition from non-alpha to alpha (snake_case / other delimiters)
    if (prev == .other and cur != .other) return true;

    // Transition from alpha to non-alpha (end of word)
    if (prev != .other and cur == .other) return true;

    // camelCase: lower → upper (e.g. "userRepo")
    if (prev == .lower and cur == .upper) return true;

    // Upper → lower after an upper sequence: e.g. "HTTPServer" → "HTTP", "Server"
    // Detected when we see upper→lower transition but the next check is tricky here
    // so we also catch upper→lower when preceded by upper (handled later)
    if (prev == .upper and cur == .lower) return true;

    return false;
}

test "camelCase split" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("userRepo", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("user", buf[0]);
    try std.testing.expectEqualStrings("Repo", buf[1]);
}

test "snake_case split" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("user_repo", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("user", buf[0]);
    try std.testing.expectEqualStrings("repo", buf[1]);
}

test "mixed case split" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("getUserById", &buf);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("get", buf[0]);
    try std.testing.expectEqualStrings("User", buf[1]);
    try std.testing.expectEqualStrings("By", buf[2]);
    try std.testing.expectEqualStrings("Id", buf[3]);
}

test "simple word" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("main", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("main", buf[0]);
}

test "empty input" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("", &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "all uppercase" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("HTTP", &buf);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "mixed digits" {
    var buf: [MAX_SPLITS][]const u8 = undefined;
    const n = splitIdentifier("file123Name", &buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("file123", buf[0]);
    try std.testing.expectEqualStrings("Name", buf[1]);
}
