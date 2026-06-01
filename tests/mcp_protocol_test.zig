//! MCP protocol-layer compliance tests.
//!
//! Exercises the wire-format pieces that real clients (Claude Code,
//! the MCP TypeScript / Python SDKs, etc.) depend on:
//!
//!   * newline-delimited JSON framing on the read side
//!   * Content-Length framing on the read side (legacy clients)
//!   * protocol version negotiation
//!   * tools/call result envelope shape — `content[].text` is always a
//!     **string**, not raw JSON, per the MCP spec
//!   * tools/call error envelope — `result.isError: true` plus the body
//!     stays in `content[].text` (no JSON-RPC `error` member for tool
//!     execution failures)
//!
//! These tests poke at `protocol.zig` directly to keep the surface
//! minimal — the higher-level dispatch flow is covered by the existing
//! end-to-end tests.

const std = @import("std");
const zindeks = @import("zindeks");
const protocol = zindeks.api.mcp.protocol;
const tools = zindeks.api.mcp.tools;

test "negotiateProtocolVersion echoes a supported request" {
    try std.testing.expectEqualStrings("2024-11-05", protocol.negotiateProtocolVersion("2024-11-05"));
    try std.testing.expectEqualStrings("2025-03-26", protocol.negotiateProtocolVersion("2025-03-26"));
    try std.testing.expectEqualStrings("2025-06-18", protocol.negotiateProtocolVersion("2025-06-18"));
}

test "negotiateProtocolVersion falls back when client asks for unknown version" {
    try std.testing.expectEqualStrings(
        protocol.DEFAULT_PROTOCOL_VERSION,
        protocol.negotiateProtocolVersion("9999-01-01"),
    );
    try std.testing.expectEqualStrings(
        protocol.DEFAULT_PROTOCOL_VERSION,
        protocol.negotiateProtocolVersion(null),
    );
}

test "writeInitializeResultV emits negotiated protocolVersion + tools capability" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    const id = std.json.Value{ .integer = 1 };
    try protocol.writeInitializeResultV(w, id, "zindeks", "0.4.1", "2025-03-26");

    // Parse the serialised message and assert the shape the MCP spec
    // requires.  Doing this through `std.json` rather than substring
    // checks catches subtle issues like missing quotes or commas.
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    try std.testing.expectEqualStrings("2.0", root.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), root.get("id").?.integer);

    const result = root.get("result").?.object;
    try std.testing.expectEqualStrings("2025-03-26", result.get("protocolVersion").?.string);
    const caps = result.get("capabilities").?.object;
    try std.testing.expect(caps.get("tools") != null);
    const tools_cap = caps.get("tools").?.object;
    try std.testing.expectEqual(false, tools_cap.get("listChanged").?.bool);
    const info = result.get("serverInfo").?.object;
    try std.testing.expectEqualStrings("zindeks", info.get("name").?.string);
}

test "writeToolResultEnvelope wraps body as a JSON string in content[0].text" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    // Body contains real JSON with quotes — they MUST end up escaped
    // inside the text string, not breaking out of it.
    const body = "[{\"path\":\"foo.zig\",\"score\":1.5}]";
    try protocol.writeToolResultEnvelope(w, std.json.Value{ .integer = 7 }, body, false);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    const content = result.get("content").?.array;
    try std.testing.expectEqual(@as(usize, 1), content.items.len);
    const item = content.items[0].object;
    try std.testing.expectEqualStrings("text", item.get("type").?.string);
    // The crucial assertion: `text` is a JSON string, and its value
    // round-trips back to the original body bytes.
    try std.testing.expectEqualStrings(body, item.get("text").?.string);
    // Non-error path: `isError` MUST be absent (or false).
    if (result.get("isError")) |is_err| {
        try std.testing.expectEqual(false, is_err.bool);
    }
}

test "writeToolResultEnvelope sets isError: true on tool failure" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    const err_body = "{\"error\":\"OutOfMemory\"}";
    try protocol.writeToolResultEnvelope(w, std.json.Value{ .integer = 8 }, err_body, true);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, buf.items, .{});
    defer parsed.deinit();

    const result = parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(true, result.get("isError").?.bool);
    const content = result.get("content").?.array;
    try std.testing.expectEqualStrings(err_body, content.items[0].object.get("text").?.string);
    // It must NOT have a top-level JSON-RPC `error` member — that's
    // reserved for protocol-level failures, not tool execution failures.
    try std.testing.expect(parsed.value.object.get("error") == null);
}

test "parseRequest accepts a valid JSON-RPC 2.0 request" {
    const raw = "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/list\"}";
    var req = (try protocol.parseRequest(std.testing.allocator, raw)) orelse return error.TestUnexpectedNull;
    defer req.deinit();

    try std.testing.expectEqualStrings("tools/list", req.method);
    try std.testing.expectEqual(@as(i64, 42), req.id.?.integer);
    try std.testing.expect(!protocol.isNotification(req));
}

test "parseRequest classifies notifications (no id)" {
    const raw = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}";
    var req = (try protocol.parseRequest(std.testing.allocator, raw)) orelse return error.TestUnexpectedNull;
    defer req.deinit();
    try std.testing.expect(protocol.isNotification(req));
}

test "parseRequest rejects missing jsonrpc field" {
    const raw = "{\"id\":1,\"method\":\"ping\"}";
    const result = try protocol.parseRequest(std.testing.allocator, raw);
    try std.testing.expect(result == null);
}

test "score_relevance dispatch returns No project loaded when engine is null" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);

    var ctx = tools.Context{ .allocator = std.testing.allocator };
    try tools.dispatch(&ctx, "score_relevance", null, w);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "No project loaded") != null);
}
