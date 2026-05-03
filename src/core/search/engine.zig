const std = @import("std");
const storage = @import("../storage/index.zig");

pub const Result = struct {
    doc_id: u32,
    score: f32,
    path: []const u8,
    snippet: []const u8,
};

pub const SearchResults = struct {
    items: []Result,

    pub fn deinit(self: *SearchResults, allocator: std.mem.Allocator) void {
        allocator.free(self.items);
        self.items = &.{};
    }
};

pub const SymbolHit = struct {
    doc_id: u32,
    path: []const u8,
    name: []const u8,
    kind: storage.SymbolKind,
    line: u32,
    byte_off: u32,
};

pub const Engine = struct {
    index: *const storage.Index,

    pub fn init(index: *const storage.Index) Engine {
        return .{ .index = index };
    }

    pub fn search(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        var scores = std.AutoHashMap(u32, f32).init(allocator);
        defer scores.deinit();

        var term_buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < query.len) {
            while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
            const start = i;
            while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
            if (start == i) continue;
            const term = storage.normalizeInto(&term_buf, query[start..i]);
            const postings = self.index.postingsForTerm(term);
            for (postings) |p| {
                const tf_score = 1.0 + @log(@as(f32, @floatFromInt(p.tf)));
                const entry = try scores.getOrPut(p.doc_id);
                if (!entry.found_existing) entry.value_ptr.* = 0;
                entry.value_ptr.* += tf_score;
            }
        }

        var results: std.ArrayList(Result) = .{};
        defer results.deinit(allocator);
        var it = scores.iterator();
        while (it.next()) |entry| {
            const doc_id = entry.key_ptr.*;
            try results.append(allocator, .{
                .doc_id = doc_id,
                .score = entry.value_ptr.*,
                .path = self.index.filePath(doc_id),
                .snippet = self.snippet(doc_id, query),
            });
        }
        std.mem.sort(Result, results.items, {}, lessResult);
        if (results.items.len > limit) results.shrinkRetainingCapacity(limit);
        return .{ .items = try results.toOwnedSlice(allocator) };
    }

    pub fn lookupSymbol(self: *Engine, name: []const u8) !?SymbolHit {
        const rec = self.index.symbolByName(name) orelse return null;
        return .{
            .doc_id = rec.doc_id,
            .path = self.index.filePath(rec.doc_id),
            .name = self.index.stringAt(rec.name_sid),
            .kind = @enumFromInt(rec.kind),
            .line = rec.line,
            .byte_off = rec.byte_off,
        };
    }

    pub fn context(self: *Engine, allocator: std.mem.Allocator, query: []const u8, limit: usize) !SearchResults {
        return self.search(allocator, query, limit);
    }

    fn snippet(self: *Engine, doc_id: u32, query: []const u8) []const u8 {
        const content = self.index.fileContent(doc_id);
        if (content.len <= 240) return content;

        var needle_buf: [256]u8 = undefined;
        var i: usize = 0;
        while (i < query.len and !std.ascii.isAlphanumeric(query[i])) i += 1;
        const start = i;
        while (i < query.len and std.ascii.isAlphanumeric(query[i])) i += 1;
        const needle = storage.normalizeInto(&needle_buf, query[start..i]);
        if (needle.len == 0) return content[0..@min(content.len, 240)];

        var lower_buf: [512]u8 = undefined;
        const prefix = content[0..@min(content.len, lower_buf.len)];
        const normalized_prefix = storage.normalizeInto(&lower_buf, prefix);
        if (std.mem.indexOf(u8, normalized_prefix, needle)) |_| {
            return content[0..@min(content.len, 240)];
        }
        return content[0..@min(content.len, 240)];
    }
};

fn lessResult(_: void, a: Result, b: Result) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.path, b.path);
}
