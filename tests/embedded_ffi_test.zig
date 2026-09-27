//! Embedded (in-process) server + C ABI tests.
//!
//! Covers the pieces the `zindeks serve` CLI does not: `Server.initEmbedded`
//! with an inert transport and per-instance watcher options, the SQLite
//! runtime floor, the health_check version fields, and the `src/ffi.zig`
//! ABI entry points (the same five functions the C smoke test drives, called
//! here directly so they also run under `zig build test`).

const std = @import("std");
const zindeks = @import("zindeks");
const server_mod = zindeks.api.mcp.server;
const tools = zindeks.api.mcp.tools;
const graph_db = zindeks.storage.graph_db;
const ffi = zindeks.ffi;

test "linked SQLite satisfies the ABI runtime floor" {
    try std.testing.expect(graph_db.sqliteVersionSatisfiesFloor());
    try std.testing.expect(graph_db.sqliteVersionNumber() >= graph_db.MIN_SQLITE_VERSION_NUMBER);
    try std.testing.expect(graph_db.sqliteVersion().len > 0);
}

test "initEmbedded binds options without touching stdio" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo);
    const store = try std.fs.path.join(allocator, &.{ repo, "store" });
    defer allocator.free(store);
    try std.fs.makeDirAbsolute(store);

    var srv: server_mod.Server = undefined;
    try srv.initEmbedded(allocator, .{
        .repository = repo,
        .store_root = store,
        .watch = true,
        .watch_interval_ms = 50,
    });
    defer srv.deinit();

    try std.testing.expect(srv.embedded);
    try std.testing.expectEqualStrings(store, srv.store_root.?);

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const has = try srv.executeMessageToBuffer(
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
        &out,
    );
    try std.testing.expect(has);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"result\"") != null);
}

test "health_check reports the SQLite runtime version" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const db_path = try std.fs.path.join(allocator, &.{ dir, "graph.db" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var gdb = try graph_db.GraphDb.open(db_path_z);
    defer gdb.close();
    gdb.setAllocator(allocator);

    var ctx = tools.Context{ .allocator = allocator, .gdb = &gdb };
    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    try tools.dispatch(&ctx, "health_check", null, out.writer(allocator));

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"sqlite_version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"sqlite_version_number\"") != null);
}

test "ABI: open / request / errors / notification / free / close" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo);
    const store = try std.fs.path.join(allocator, &.{ repo, "store" });
    defer allocator.free(store);
    try std.fs.makeDirAbsolute(store);

    try std.testing.expectEqual(@as(u32, 1), ffi.zindeks_abi_version());

    // Null options -> invalid input, cleared outputs.
    {
        var out: ?*ffi.Handle = null;
        var err = ffi.ZindeksBuffer{};
        const rc = ffi.zindeks_open(null, 0, &out, &err);
        try std.testing.expectEqual(@as(i32, 1), rc);
        try std.testing.expect(out == null);
        try std.testing.expect(err.ptr != null);
        ffi.zindeks_buffer_free(&err);
        try std.testing.expect(err.ptr == null and err.len == 0);
    }

    const options = try std.fmt.allocPrint(
        allocator,
        "{{\"repository\":{f},\"store_root\":{f}}}",
        .{ std.json.fmt(repo, .{}), std.json.fmt(store, .{}) },
    );
    defer allocator.free(options);

    var handle: ?*ffi.Handle = null;
    var err = ffi.ZindeksBuffer{};
    const rc = ffi.zindeks_open(options.ptr, options.len, &handle, &err);
    try std.testing.expectEqual(@as(i32, 0), rc);
    try std.testing.expect(handle != null);
    defer ffi.zindeks_close(handle);

    // initialize
    {
        var resp = ffi.ZindeksBuffer{};
        const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}";
        try std.testing.expectEqual(@as(i32, 0), ffi.zindeks_request(handle, json.ptr, json.len, &resp));
        try std.testing.expect(resp.ptr != null and resp.len > 0);
        ffi.zindeks_buffer_free(&resp);
    }

    // notification -> success, empty response
    {
        var resp = ffi.ZindeksBuffer{};
        const json = "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}";
        try std.testing.expectEqual(@as(i32, 0), ffi.zindeks_request(handle, json.ptr, json.len, &resp));
        try std.testing.expect(resp.ptr == null and resp.len == 0);
    }

    // invalid JSON -> invalid input
    {
        var resp = ffi.ZindeksBuffer{};
        const json = "{not json";
        try std.testing.expectEqual(@as(i32, 1), ffi.zindeks_request(handle, json.ptr, json.len, &resp));
        try std.testing.expect(resp.ptr == null);
    }

    // null handle -> invalid input
    {
        var resp = ffi.ZindeksBuffer{};
        const json = "{}";
        try std.testing.expectEqual(@as(i32, 1), ffi.zindeks_request(null, json.ptr, json.len, &resp));
    }

    ffi.zindeks_buffer_free(null);
    ffi.zindeks_close(null);
}

test "ABI: 100 open/request/close cycles and watcher teardown" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const repo = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(repo);
    const store = try std.fs.path.join(allocator, &.{ repo, "store" });
    defer allocator.free(store);
    try std.fs.makeDirAbsolute(store);
    try tmp.dir.writeFile(.{ .sub_path = "answer.rs", .data = "pub fn answer() -> u32 { 42 }\n" });

    const options = try std.fmt.allocPrint(
        allocator,
        "{{\"repository\":{f},\"store_root\":{f},\"watch\":true,\"watch_interval_ms\":50}}",
        .{ std.json.fmt(repo, .{}), std.json.fmt(store, .{}) },
    );
    defer allocator.free(options);

    for (0..100) |cycle| {
        var handle: ?*ffi.Handle = null;
        var err = ffi.ZindeksBuffer{};
        const rc = ffi.zindeks_open(options.ptr, options.len, &handle, &err);
        if (rc != 0) {
            ffi.zindeks_buffer_free(&err);
            return error.UnexpectedOpenFailure;
        }
        if (cycle == 0) {
            // Seed a real index. Subsequent opens must attach it and start
            // a watcher with pointers into the final, immovable server.
            const index_json = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"index_repository\",\"arguments\":{{\"path\":{f}}}}}}}", .{std.json.fmt(repo, .{})});
            defer allocator.free(index_json);
            var indexed = ffi.ZindeksBuffer{};
            try std.testing.expectEqual(@as(i32, 0), ffi.zindeks_request(handle, index_json.ptr, index_json.len, &indexed));
            const body = indexed.ptr.?[0..indexed.len];
            const indexed_ok = std.mem.indexOf(u8, body, "\"isError\":true") == null;
            ffi.zindeks_buffer_free(&indexed);
            try std.testing.expect(indexed_ok);
        }
        var resp = ffi.ZindeksBuffer{};
        if (handle.?.server.watcher) |watcher| {
            try std.testing.expectEqual(@intFromPtr(&handle.?.server), @intFromPtr(watcher.callback_ctx.?));
            try std.testing.expectEqual(@intFromPtr(&handle.?.server.gdb.?), @intFromPtr(watcher.gdb));
        } else {
            return error.ExpectedActiveWatcher;
        }
        const json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"get_context\",\"arguments\":{\"query\":\"answer\",\"max_tokens\":500}}}";
        try std.testing.expectEqual(@as(i32, 0), ffi.zindeks_request(handle, json.ptr, json.len, &resp));
        const found = std.mem.indexOf(u8, resp.ptr.?[0..resp.len], "answer") != null;
        ffi.zindeks_buffer_free(&resp);
        try std.testing.expect(found);
        // Closes with an active watcher; it must join before freeing the server.
        ffi.zindeks_close(handle);
    }
}
