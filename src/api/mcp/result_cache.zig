const std = @import("std");

/// Session-scoped memoization of read-only MCP tool result bodies.
/// Bounded FIFO; concurrency-safe (all ops take the internal mutex).
pub const ResultCache = struct {
    // ponytail: flat cap, not config-driven — bump the constant if a session
    // needs more. 256 small JSON bodies is cheap and covers far more distinct
    // read queries per session than the old 64. Make it configurable only if
    // measured hit-rate (see health_check) shows churn at this size.
    pub const MAX_ENTRIES: usize = 256;

    const Entry = struct { key: u64, body: []u8 };

    allocator: std.mem.Allocator,
    mu: std.Thread.Mutex = .{},
    entries: std.ArrayList(Entry) = .{},
    hits: u64 = 0,
    misses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ResultCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ResultCache) void {
        for (self.entries.items) |e| self.allocator.free(e.body);
        self.entries.deinit(self.allocator);
    }

    /// Stable key for (tool_name, args). `scratch` is used transiently.
    pub fn computeKey(tool_name: []const u8, args: ?std.json.ObjectMap, scratch: std.mem.Allocator) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(tool_name);
        h.update("\x00");
        if (args) |o| {
            var buf = std.ArrayList(u8){};
            defer buf.deinit(scratch);
            // Deterministic: ObjectMap preserves insertion order, identical
            // client input → identical serialization → identical key.
            const v = std.json.Value{ .object = o };
            // Canonical JSON serialization (std.json.fmt). Plain "{}" on a
            // json.Value renders the ArrayHashMap's internal fields (pointers/
            // capacity) → non-deterministic key → every lookup misses.
            buf.writer(scratch).print("{f}", .{std.json.fmt(v, .{})}) catch {};
            h.update(buf.items);
        }
        return h.final();
    }

    /// On hit: append cached body bytes to `out`, bump hits, return true.
    /// On miss: bump misses, return false. Locked throughout (safe copy-out).
    pub fn getInto(self: *ResultCache, key: u64, out: *std.ArrayList(u8)) bool {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |e| {
            if (e.key == key) {
                out.appendSlice(self.allocator, e.body) catch {
                    self.misses += 1;
                    return false;
                };
                self.hits += 1;
                return true;
            }
        }
        self.misses += 1;
        return false;
    }

    /// Store a body under key (dupes bytes). No-op if key already present.
    /// Evicts oldest (FIFO) when full.
    pub fn put(self: *ResultCache, key: u64, body: []const u8) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |e| if (e.key == key) return;
        const dup = self.allocator.dupe(u8, body) catch return;
        if (self.entries.items.len >= MAX_ENTRIES) {
            const old = self.entries.orderedRemove(0);
            self.allocator.free(old.body);
        }
        self.entries.append(self.allocator, .{ .key = key, .body = dup }) catch {
            self.allocator.free(dup);
        };
    }

    /// Drop all cached bodies (called on any mutation). Stats preserved.
    pub fn clear(self: *ResultCache) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.entries.items) |e| self.allocator.free(e.body);
        self.entries.clearRetainingCapacity();
    }
};

test "result cache miss then hit then clear" {
    const a = std.testing.allocator;
    var c = ResultCache.init(a);
    defer c.deinit();
    var out = std.ArrayList(u8){};
    defer out.deinit(a);
    try std.testing.expect(!c.getInto(42, &out)); // miss
    c.put(42, "hello");
    out.clearRetainingCapacity();
    try std.testing.expect(c.getInto(42, &out)); // hit
    try std.testing.expectEqualStrings("hello", out.items);
    try std.testing.expectEqual(@as(u64, 1), c.hits);
    c.clear();
    out.clearRetainingCapacity();
    try std.testing.expect(!c.getInto(42, &out)); // miss after clear
}

test "result cache evicts oldest when full" {
    const a = std.testing.allocator;
    var c = ResultCache.init(a);
    defer c.deinit();
    var i: u64 = 0;
    while (i < ResultCache.MAX_ENTRIES + 5) : (i += 1) c.put(i, "x");
    try std.testing.expect(c.entries.items.len <= ResultCache.MAX_ENTRIES);
}
