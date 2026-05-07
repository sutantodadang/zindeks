//! Cross-platform file system watcher with polling fallback.
//!
//! Uses a polling loop (portable, zero OS deps) to detect changes:
//! scans file metadata every `interval_ms`, compares mtime against
//! the graph DB documents table, and invokes a callback when files
//! are added, modified, or deleted.
//!
//! Future: native OS watchers (inotify, FSEvents, ReadDirectoryChangesW)
//! can be added as optional backends behind the same interface.
const std = @import("std");
const scanner = @import("../core/scanner/scanner.zig");
const graph_db = @import("../core/storage/graph_db.zig");
const incremental = @import("../core/indexer/incremental.zig");

// ██████████████████████████████████████████████████████████████████████████
// Watcher event
// ██████████████████████████████████████████████████████████████████████████

pub const Event = struct {
    path: []const u8,
    kind: enum { added, modified, deleted },
};

/// Called for each batch of changes detected. The allocator is valid for
/// the duration of the callback only — copy any data you need to keep.
pub const Callback = *const fn (ctx: ?*anyopaque, events: []const Event) void;

// ██████████████████████████████████████████████████████████████████████████
// Polling watcher
// ██████████████████████████████████████████████████████████████████████████

pub const PollWatcher = struct {
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    project_path: []const u8,
    interval_ms: u32,
    callback: Callback,
    callback_ctx: ?*anyopaque,
    running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        gdb: *graph_db.GraphDb,
        project_path: []const u8,
        interval_ms: u32,
        callback: Callback,
        callback_ctx: ?*anyopaque,
    ) PollWatcher {
        return .{
            .allocator = allocator,
            .gdb = gdb,
            .project_path = allocator.dupe(u8, project_path) catch @panic("OOM"),
            .interval_ms = interval_ms,
            .callback = callback,
            .callback_ctx = callback_ctx,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    /// Start watching in a background thread.
    pub fn start(self: *PollWatcher) !void {
        if (self.running.load(.acquire)) return;
        self.running.store(true, .release);

        self.thread = try std.Thread.spawn(.{}, pollLoop, .{self});
    }

    /// Stop the watcher and join the background thread.
    pub fn stop(self: *PollWatcher) void {
        self.running.store(false, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    pub fn deinit(self: *PollWatcher) void {
        self.stop();
        self.allocator.free(self.project_path);
    }

    fn pollLoop(self: *PollWatcher) void {
        // Snapshot current mtimes from the DB at startup.
        // We compare these against filesystem mtimes on each poll tick.
        var last_mtimes = std.StringHashMap(i64).init(self.allocator);
        defer {
            var iter = last_mtimes.keyIterator();
            while (iter.next()) |key| self.allocator.free(key.*);
            last_mtimes.deinit(self.allocator);
        }

        while (self.running.load(.acquire)) {
            // ── Scan current filesystem state ────────────────────────
            const current = scanner.scanPathMetadata(self.allocator, self.project_path) catch {
                std.time.sleep(self.interval_ms * std.time.ns_per_ms);
                continue;
            };

            // Build map: path → mtime
            var current_map = std.StringHashMap(i64).init(self.allocator);
            for (current) |meta| {
                current_map.put(meta.path, meta.mtime) catch continue;
            }

            // ── Diff ─────────────────────────────────────────────────
            var events = std.ArrayList(Event).initCapacity(self.allocator, 16) catch {
                scanner.freeMetadata(self.allocator, current);
                std.time.sleep(self.interval_ms * std.time.ns_per_ms);
                continue;
            };

            // Added or modified: in current but not in last, or different mtime
            var cur_iter = current_map.iterator();
            while (cur_iter.next()) |kv| {
                const path = kv.key_ptr.*;
                const mtime = kv.value_ptr.*;
                if (last_mtimes.get(path)) |last_mtime| {
                    if (mtime != last_mtime) {
                        events.append(.{ .path = self.allocator.dupe(u8, path) catch continue, .kind = .modified }) catch {};
                    }
                } else {
                    events.append(.{ .path = self.allocator.dupe(u8, path) catch continue, .kind = .added }) catch {};
                }
            }

            // Deleted: in last but not in current
            var last_iter = last_mtimes.keyIterator();
            while (last_iter.next()) |key| {
                if (!current_map.contains(key.*)) {
                    events.append(.{ .path = self.allocator.dupe(u8, key.*) catch continue, .kind = .deleted }) catch {};
                }
            }

            // ── Notify callback ──────────────────────────────────────
            if (events.items.len > 0) {
                self.callback(self.callback_ctx, events.items);
            }

            // ── Update last_mtimes snapshot ───────────────────────────
            // Clear old
            var old_iter = last_mtimes.keyIterator();
            while (old_iter.next()) |key| self.allocator.free(key.*);
            last_mtimes.clearAndFree(self.allocator);

            // Copy from current
            var copy_iter = current_map.iterator();
            while (copy_iter.next()) |kv| {
                const owned_path = self.allocator.dupe(u8, kv.key_ptr.*) catch continue;
                last_mtimes.put(owned_path, kv.value_ptr.*) catch {
                    self.allocator.free(owned_path);
                    continue;
                };
            }

            // ── Cleanup ──────────────────────────────────────────────
            for (events.items) |ev| self.allocator.free(ev.path);
            events.deinit(self.allocator);

            var clean_iter = current_map.iterator();
            while (clean_iter.next()) |kv| _ = kv;
            current_map.deinit(self.allocator);

            scanner.freeMetadata(self.allocator, current);

            std.time.sleep(self.interval_ms * std.time.ns_per_ms);
        }
    }
};
