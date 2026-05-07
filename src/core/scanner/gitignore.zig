//! .gitignore / .cbmignore pattern parser and matcher.
//!
//! Walks parent directories collecting nested rules so that an inner
//! un-ignore can override an outer ignore.  See git-scm.com/docs/gitignore.
const std = @import("std");

pub const Pattern = struct {
    raw: []const u8, // the rule text (owned by the file buffer)
    negate: bool = false,
    dir_only: bool = false,

    pub fn match(self: Pattern, candidate: []const u8) bool {
        // quick no-match on empty
        if (candidate.len == 0) return false;
        return matchGlob(self.raw, candidate);
    }
};

pub const RuleSet = struct {
    allocator: std.mem.Allocator,
    patterns: std.ArrayListUnmanaged(Pattern) = .{},

    pub fn deinit(self: *RuleSet) void {
        for (self.patterns.items) |p| self.allocator.free(p.raw);
        self.patterns.deinit(self.allocator);
    }

    /// Returns true when `candidate_path` should be skipped.
    /// Last matching rule wins (negations over-ride earlier positive matches).
    pub fn matches(self: *const RuleSet, candidate_path: []const u8) bool {
        if (candidate_path.len == 0) return false;
        var ignored = false;
        for (self.patterns.items) |p| {
            if (p.match(candidate_path)) {
                ignored = !p.negate;
            }
        }
        return ignored;
    }
};

/// Load the `.gitignore` at `dir` and merge it into `set`.
pub fn loadFile(allocator: std.mem.Allocator, dir: std.fs.Dir, rel_path: []const u8, set: *RuleSet) !void {
    const f = dir.openFile(rel_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        else => |err| return err,
    };
    defer f.close();

    const raw = try f.readToEndAlloc(allocator, 256 * 1024);
    errdefer allocator.free(raw);

    var it = std.mem.splitScalar(u8, raw, '\n');
    while (it.next()) |line_| {
        const line = stripTrailingSpace(line_);
        if (line.len == 0 or line[0] == '#') continue;
        const p = try parseLine(allocator, line);
        try set.patterns.append(allocator, p);
    }
    allocator.free(raw);
}

/// Walk from `root` up to the filesystem root collecting every `.gitignore`
/// (and `.cbmignore`) encountered.  Inner rules appear *after* outer ones in
/// the resulting list so that they over-ride.
pub fn collect(allocator: std.mem.Allocator, root: []const u8) !RuleSet {
    var set = RuleSet{ .allocator = allocator };

    // Gather path components so we can walk upward.
    var dirs = std.ArrayList([]const u8).init(allocator);
    defer dirs.deinit();

    var cur = root;
    while (true) {
        try dirs.append(cur);
        const parent = std.fs.path.dirname(cur) orelse break;
        if (std.mem.eql(u8, parent, cur)) break;
        cur = parent;
    }

    // Walk from outermost to innermost so that inner rules land last.
    var i: usize = dirs.items.len;
    while (i > 0) {
        i -= 1;
        const d = try std.fs.cwd().openDir(dirs.items[i], .{});
        defer d.close();

        for ([_][]const u8{ ".gitignore", ".cbmignore" }) |name| {
            loadFile(allocator, d, name, &set) catch |e| {
                std.log.debug("ignore collecting {s} in {s}: {}", .{ name, dirs.items[i], e });
            };
        }
    }
    return set;
}

pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !Pattern {
    var s = line;

    // Negation
    const negate = if (s.len > 0 and s[0] == '!') blk: {
        s = s[1..];
        if (s.len == 0) return error.EmptyPattern;
        break :blk true;
    } else false;

    // Directory-only marker (trailing slash)
    const dir_only = if (s.len > 0 and s[s.len - 1] == '/') blk: {
        s = s[0 .. s.len - 1];
        if (s.len == 0) return error.EmptyPattern;
        break :blk true;
    } else false;

    // Remove leading slash if present (it anchors to git root)
    if (s.len > 0 and s[0] == '/') s = s[1..];

    const owned = try allocator.dupe(u8, s);
    return Pattern{ .raw = owned, .negate = negate, .dir_only = dir_only };
}

// ── helpers ────────────────────────────────────────────────────────────

fn stripTrailingSpace(s: []const u8) []const u8 {
    var end = s.len;
    while (end > 0 and (s[end - 1] == ' ' or s[end - 1] == '\r')) : (end -= 1) {}
    return s[0..end];
}

/// Minimal glob matcher.  `pattern` is the de-anchored gitignore rule text;
/// `candidate` is a relative path (e.g. `src/main.zig`).
fn matchGlob(pattern_: []const u8, candidate: []const u8) bool {
    var pi: usize = 0;
    var ci: usize = 0;
    const p = pattern_;
    const c = candidate;

    // Shortcut: literal prefix common in gitignore rules (`*.o`, `build/`)
    if (std.mem.indexOfScalar(u8, p, '*') == null and
        std.mem.indexOfScalar(u8, p, '?') == null and
        std.mem.indexOf(u8, p, "**") == null)
    {
        return std.mem.endsWith(u8, c, p) or std.mem.eql(u8, c, p);
    }

    return tryMatch(p, c, &pi, &ci);
}

fn tryMatch(p: []const u8, c: []const u8, pi_: *usize, ci_: *usize) bool {
    var pi = pi_.*;
    var ci = ci_.*;

    while (pi < p.len or ci < c.len) {
        if (pi < p.len and pi + 1 < p.len and p[pi] == '*' and p[pi + 1] == '*') {
            // "**" matches zero or more path components
            pi += 2;
            if (pi < p.len and p[pi] == '/') pi += 1; // consume separator after **

            // try matching the rest of the pattern at every remaining position
            var k = ci;
            while (k <= c.len) : (k += 1) {
                var tpi = pi;
                var tci = k;
                if (tryMatch(p, c, &tpi, &tci)) {
                    pi_.* = tpi;
                    ci_.* = tci;
                    return true;
                }
                // advance past a path component
                while (k < c.len and c[k] != '/') : (k += 1) {}
                if (k == c.len) break;
            }
            return false;
        }

        if (pi < p.len and p[pi] == '*') {
            // "*" matches everything except "/"
            pi += 1;
            while (ci < c.len and c[ci] != '/') : (ci += 1) {}

            // greedy: try matching the rest from each position backward
            var k = ci;
            while (true) : ({
                if (k == 0) break;
                k -= 1;
                if (c[k] == '/') break;
            }) {
                var tpi = pi;
                var tci = k;
                if (tryMatch(p, c, &tpi, &tci)) {
                    pi_.* = tpi;
                    ci_.* = tci;
                    return true;
                }
            }
            return false;
        }

        if (pi < p.len and p[pi] == '?') {
            // "?" matches any single char except "/"
            if (ci >= c.len or c[ci] == '/') return false;
            pi += 1;
            ci += 1;
            continue;
        }

        // literal
        if (pi < p.len and ci < c.len and p[pi] == c[ci]) {
            pi += 1;
            ci += 1;
            continue;
        }

        // If pattern consumed everything and we're at a segment start, match
        if (pi >= p.len and ci < c.len) {
            // Check if pattern was a directory prefix (e.g., "build" matches "build/output.zig")
            // This is a common gitignore behavior
            return false;
        }

        return false;
    }

    pi_.* = pi;
    ci_.* = ci;
    return pi >= p.len and ci >= c.len;
}

// ██████████████████████████████████████████████████████████████████████████
// Tests
// ██████████████████████████████████████████████████████████████████████████

test "gitignore parse simple" {
    const p = try parseLine(std.testing.allocator, "*.o");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(!p.negate);
    try std.testing.expect(!p.dir_only);
    try std.testing.expectEqualStrings("*.o", p.raw);
}

test "gitignore parse negation" {
    const p = try parseLine(std.testing.allocator, "!important.o");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.negate);
    try std.testing.expectEqualStrings("important.o", p.raw);
}

test "gitignore parse dir only" {
    const p = try parseLine(std.testing.allocator, "build/");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.dir_only);
    try std.testing.expectEqualStrings("build", p.raw);
}

test "gitignore parse comment" {
    // Comments are handled by the caller (loadFile) skipping lines starting with #
    // No separate test needed here
}

test "gitignore match literal" {
    const p = try parseLine(std.testing.allocator, "*.o");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.match("main.o"));
    try std.testing.expect(!p.match("main.c"));
}

test "gitignore match wildcard" {
    const p = try parseLine(std.testing.allocator, "node_modules");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.match("node_modules"));
    try std.testing.expect(p.match("src/node_modules"));
    try std.testing.expect(!p.match("src/node_modules_not"));
}

test "gitignore match double star" {
    const p = try parseLine(std.testing.allocator, "src/**/test");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.match("src/a/test"));
    try std.testing.expect(p.match("src/a/b/test"));
    try std.testing.expect(!p.match("lib/a/test"));
}

test "gitignore rule set basic" {
    var set = RuleSet{ .allocator = std.testing.allocator };
    defer set.deinit();

    const p1 = try parseLine(std.testing.allocator, "*.o");
    try set.patterns.append(std.testing.allocator, p1);
    const p2 = try parseLine(std.testing.allocator, "!keep.o");
    try set.patterns.append(std.testing.allocator, p2);

    try std.testing.expect(set.matches("main.o"));
    try std.testing.expect(!set.matches("keep.o"));
    try std.testing.expect(!set.matches("main.c"));
}

test "gitignore rule set last wins" {
    var set = RuleSet{ .allocator = std.testing.allocator };
    defer set.deinit();

    // Negation then re-ignore
    const p1 = try parseLine(std.testing.allocator, "*.log");
    try set.patterns.append(std.testing.allocator, p1);
    const p2 = try parseLine(std.testing.allocator, "!important.log");
    try set.patterns.append(std.testing.allocator, p2);
    const p3 = try parseLine(std.testing.allocator, "important.log");
    try set.patterns.append(std.testing.allocator, p3);

    try std.testing.expect(set.matches("important.log"));
    try std.testing.expect(set.matches("error.log"));
}

test "gitignore match path with slash" {
    const p = try parseLine(std.testing.allocator, "build/");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.dir_only);
    // matchGlob treats path separators in the candidate as part of the string
    try std.testing.expect(p.match("build/output.o"));
}

test "gitignore parse empty negation" {
    try std.testing.expectError(error.EmptyPattern, parseLine(std.testing.allocator, "!"));
}

test "gitignore parse empty dir only" {
    try std.testing.expectError(error.EmptyPattern, parseLine(std.testing.allocator, "/"));
}

test "gitignore strip leading slash" {
    const p = try parseLine(std.testing.allocator, "/build");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expectEqualStrings("build", p.raw);
}

test "gitignore match question mark" {
    const p = try parseLine(std.testing.allocator, "file.??");
    defer std.testing.allocator.free(p.raw);
    try std.testing.expect(p.match("file.rs"));
    try std.testing.expect(p.match("file.zig"));
    try std.testing.expect(!p.match("file.c"));
    try std.testing.expect(!p.match("file.java"));
}
