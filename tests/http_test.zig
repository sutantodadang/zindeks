//! Integration tests for the transport-independent MCP execution path that
//! backs the HTTP server (`Server.executeMessageToBuffer`).  Exercises the
//! JSON-RPC method routing + response/no-response semantics without opening a
//! socket; the HTTP framing itself is covered by unit tests in http.zig.

const std = @import("std");
const zindeks = @import("zindeks");
const server_mod = zindeks.api.mcp.server;

test "executeMessageToBuffer routes core MCP methods" {
    const allocator = std.testing.allocator;

    // Point the store root at an empty temp dir so the initialize handler's
    // auto-attach finds no warm project — keeps the test hermetic.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const store = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(store);

    var srv = server_mod.Server.init(allocator, .{ .store_root = store });
    defer srv.deinit();

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);

    // initialize → response carrying the negotiated protocol version + id.
    {
        const has = try srv.executeMessageToBuffer(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}",
            &out,
        );
        try std.testing.expect(has);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"protocolVersion\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"id\":1") != null);
    }

    // tools/list → array containing a known tool name.
    {
        const has = try srv.executeMessageToBuffer(
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
            &out,
        );
        try std.testing.expect(has);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "search") != null);
    }

    // ping → result object.
    {
        const has = try srv.executeMessageToBuffer(
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"ping\"}",
            &out,
        );
        try std.testing.expect(has);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"result\"") != null);
    }

    // notification (no id) → no response emitted.
    {
        const has = try srv.executeMessageToBuffer(
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            &out,
        );
        try std.testing.expect(!has);
    }

    // tools/call with no project loaded → still a well-formed envelope.
    {
        const has = try srv.executeMessageToBuffer(
            "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"health_check\",\"arguments\":{}}}",
            &out,
        );
        try std.testing.expect(has);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"result\"") != null);
    }

    // garbage input → parse error response.
    {
        const has = try srv.executeMessageToBuffer("not json", &out);
        try std.testing.expect(has);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"error\"") != null);
    }
}
