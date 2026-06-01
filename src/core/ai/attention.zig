//! Attention scoring — derive a relevance-ordered file list from a working set.
//!
//! Used by the `score_relevance` MCP tool and the `attention` CLI command.
//! Index once; both callers share this single implementation.

const std = @import("std");
const engine_mod = @import("../search/engine.zig");

pub const Scored = struct { path: []const u8, score: f32 };

/// Derive a search term from a working-set item: strip path separators and extension.
fn deriveTerm(item: []const u8) []const u8 {
    const base = std.fs.path.basename(item);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) return base[0..dot];
    }
    return base;
}

/// Score indexed files by relevance to a working set. Returns an owned slice;
/// caller MUST free via freeScored. Each Scored.path is duped with `allocator`.
pub fn score(
    allocator: std.mem.Allocator,
    engine: *engine_mod.Engine,
    working_set: []const []const u8,
    query: []const u8,
    budget: usize,
) ![]Scored {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var scores = std.StringHashMap(f32).init(aa);

    for (working_set) |item| {
        const term = deriveTerm(item);
        if (term.len == 0) continue;
        var r = engine.search(allocator, term, 20) catch continue;
        defer r.deinit(allocator);
        for (r.items) |result| {
            if (scores.getEntry(result.path)) |e| {
                e.value_ptr.* = @max(e.value_ptr.*, result.score);
            } else {
                try scores.put(try aa.dupe(u8, result.path), result.score);
            }
        }
    }

    if (query.len > 0) {
        if (engine.search(allocator, query, 20)) |rq_val| {
            var rq = rq_val;
            defer rq.deinit(allocator);
            for (rq.items) |result| {
                const boosted = result.score * 1.5;
                if (scores.getEntry(result.path)) |e| {
                    e.value_ptr.* = @max(e.value_ptr.*, boosted);
                } else {
                    try scores.put(try aa.dupe(u8, result.path), boosted);
                }
            }
        } else |_| {}
    }

    var max_score: f32 = 0.0;
    var it = scores.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* > max_score) max_score = e.value_ptr.*;
    }

    // Collect + normalize into arena slice
    const Entry = struct { path: []const u8, score: f32 };
    var entries = std.ArrayList(Entry){};
    it = scores.iterator();
    while (it.next()) |e| {
        const norm = if (max_score > 0.0) e.value_ptr.* / max_score else 0.0;
        try entries.append(aa, .{ .path = e.key_ptr.*, .score = norm });
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn desc(_: void, a: Entry, b: Entry) bool {
            return a.score > b.score;
        }
    }.desc);

    const take = @min(entries.items.len, budget);
    const out = try allocator.alloc(Scored, take);
    errdefer allocator.free(out);
    var n: usize = 0;
    errdefer {
        var i: usize = 0;
        while (i < n) : (i += 1) allocator.free(out[i].path);
    }
    while (n < take) : (n += 1) {
        out[n] = .{ .path = try allocator.dupe(u8, entries.items[n].path), .score = entries.items[n].score };
    }
    return out;
}

pub fn freeScored(allocator: std.mem.Allocator, scored: []Scored) void {
    for (scored) |s| allocator.free(s.path);
    allocator.free(scored);
}

/// Collect modified/added/untracked paths from `git status --porcelain` run
/// in `repo_root`. Returns an owned slice of owned strings; caller must free
/// each string and then the slice. Returns an empty slice on any git failure
/// (fail-open — never propagates errors to the caller).
pub fn gitWorkingSet(allocator: std.mem.Allocator, repo_root: []const u8) ![][]const u8 {
    var child = std.process.Child.init(&.{ "git", "status", "--porcelain" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.cwd = repo_root;
    child.spawn() catch return try allocator.alloc([]const u8, 0);

    const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 1024) catch {
        _ = child.wait() catch {};
        return try allocator.alloc([]const u8, 0);
    };
    defer allocator.free(stdout);
    _ = child.wait() catch {};

    var paths = std.ArrayList([]const u8){};
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }

    var lines_it = std.mem.splitScalar(u8, stdout, '\n');
    while (lines_it.next()) |line| {
        if (line.len < 3) continue;
        var path = line[3..];
        // Handle rename: "old -> new"
        if (std.mem.indexOf(u8, path, " -> ")) |arrow| {
            path = path[arrow + 4 ..];
        }
        path = std.mem.trim(u8, path, " \t\r\"");
        if (path.len > 0) {
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
    }

    return try paths.toOwnedSlice(allocator);
}

test "deriveTerm strips path and extension" {
    try std.testing.expectEqualStrings("tools", deriveTerm("src/api/mcp/tools.zig"));
    try std.testing.expectEqualStrings("foo", deriveTerm("foo"));
    try std.testing.expectEqualStrings("engine", deriveTerm("src/core/search/engine.zig"));
}
