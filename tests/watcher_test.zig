//! Tests for the file system watcher (PollWatcher).
const std = @import("std");
const zindeks = @import("zindeks");
const watcher = zindeks.project.watcher;
const graph_db = zindeks.storage.graph_db;

test "PollWatcher init creates valid struct" {
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    var w = watcher.PollWatcher.init(
        std.testing.allocator,
        &db,
        ".",
        1000,
        testCallback,
        null,
    );
    defer w.deinit();

    try std.testing.expectEqual(@as(u32, 1000), w.interval_ms);
    try std.testing.expect(!w.running.load(.acquire));
    try std.testing.expect(w.thread == null);
}

test "PollWatcher start/stop lifecycle" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Create in-memory DB and migrate so documents table exists
    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp_dir.sub_path,
    });
    defer std.testing.allocator.free(tmp_path);

    var w = watcher.PollWatcher.init(
        std.testing.allocator,
        &db,
        tmp_path,
        5000,
        testCallback,
        null,
    );
    defer w.deinit();

    try w.start();
    try std.testing.expect(w.running.load(.acquire));

    // Stop immediately - don't wait for poll loop to run
    // (poll loop uses non-thread-safe testing allocator)
    w.stop();
    try std.testing.expect(!w.running.load(.acquire));
    try std.testing.expect(w.thread == null);
}

test "PollWatcher callback receives events" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var db = try graph_db.GraphDb.open(":memory:");
    defer db.close();
    try db.migrate();

    var event_count: u32 = 0;

    const CallbackCtx = struct {
        count: *u32,
    };

    const cb = struct {
        fn callback(ctx: ?*anyopaque, events: []const watcher.Event) void {
            const c: *CallbackCtx = @ptrCast(@alignCast(ctx));
            c.count.* += @intCast(events.len);
        }
    }.callback;

    var ctx = CallbackCtx{ .count = &event_count };

    const tmp_path = try std.fs.path.join(std.testing.allocator, &.{
        ".zig-cache", "tmp", &tmp_dir.sub_path,
    });
    defer std.testing.allocator.free(tmp_path);

    var w = watcher.PollWatcher.init(
        std.testing.allocator,
        &db,
        tmp_path,
        5000,
        cb,
        &ctx,
    );
    defer w.deinit();

    // Verify the callback and context are stored correctly
    try std.testing.expect(w.callback_ctx != null);
    try std.testing.expectEqual(@as(u32, 5000), w.interval_ms);

    // Invoke callback manually to verify the wiring works
    const test_events = [_]watcher.Event{
        .{ .path = "test.zig", .kind = .added },
    };
    w.callback(w.callback_ctx, &test_events);
    try std.testing.expectEqual(@as(u32, 1), event_count);
}

fn testCallback(ctx: ?*anyopaque, events: []const watcher.Event) void {
    _ = ctx;
    _ = events;
}
