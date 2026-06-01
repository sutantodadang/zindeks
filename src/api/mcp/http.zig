//! Minimal MCP Streamable HTTP transport.
//!
//! Serves the Model Context Protocol over HTTP/1.1 so multiple agents (or a
//! single pipelining client) can issue tool calls CONCURRENTLY against one
//! warm, shared `Server` — unlike stdio, where one process serves one client
//! and the single read loop paces requests.
//!
//! Each accepted connection runs on its own thread; all threads share the
//! Server and rely on its fine-grained rwlocks for safety.  Read-only tools
//! run truly in parallel (shared locks + pooled SQLite connections); mutating
//! tools take exclusive locks (the rwlock drains concurrent readers).
//!
//! Scope: the request/response half of MCP Streamable HTTP — POST one
//! JSON-RPC message to `/mcp`, get a JSON-RPC response as `application/json`.
//! SSE server-push (GET /mcp) is not implemented; every tool result is
//! returned inline, which covers all current tools.  Connections are
//! one-request, `Connection: close` (concurrency comes from many connections,
//! not keep-alive pipelining).

const std = @import("std");
const Server = @import("server.zig").Server;

// Socket I/O via recv/send rather than std.net.Stream.read/write: on Windows
// the latter use ReadFile/WriteFile, which fail on socket handles
// (GetLastError 87).  recv/send map to the WinSock calls and work on every
// platform.

fn recvSome(stream: std.net.Stream, buf: []u8) !usize {
    return std.posix.recv(stream.handle, buf, 0);
}

fn sendAll(stream: std.net.Stream, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = try std.posix.send(stream.handle, bytes[off..], 0);
        if (n == 0) return error.ConnectionResetByPeer;
        off += n;
    }
}

const MAX_HEADER = 16 * 1024;
const MAX_BODY = 16 * 1024 * 1024;

/// Listen on `address` and serve MCP-over-HTTP until the process exits.
/// Spawns one detached thread per connection against the shared `server`.
pub fn serve(allocator: std.mem.Allocator, server: *Server, address: std.net.Address) !void {
    var listener = try address.listen(.{ .reuse_address = true });
    defer listener.deinit();
    while (true) {
        const conn = listener.accept() catch |err| {
            std.log.err("http accept failed: {s}", .{@errorName(err)});
            continue;
        };
        const t = std.Thread.spawn(.{}, handleConn, .{ allocator, server, conn.stream }) catch |err| {
            std.log.err("http spawn failed: {s}", .{@errorName(err)});
            conn.stream.close();
            continue;
        };
        t.detach();
    }
}

fn handleConn(allocator: std.mem.Allocator, server: *Server, stream: std.net.Stream) void {
    defer stream.close();
    handleConnInner(allocator, server, stream) catch |err| {
        std.log.debug("http conn ended: {s}", .{@errorName(err)});
    };
}

fn handleConnInner(allocator: std.mem.Allocator, server: *Server, stream: std.net.Stream) !void {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(allocator);

    const header_end = try readUntilDoubleCRLF(allocator, stream, &buf);
    const head = buf.items[0..header_end];

    var line_it = std.mem.splitSequence(u8, head, "\r\n");
    const request_line = line_it.next() orelse return error.BadRequest;
    var rl = std.mem.tokenizeScalar(u8, request_line, ' ');
    const method = rl.next() orelse return error.BadRequest;
    const target = rl.next() orelse return error.BadRequest;

    var content_length: usize = 0;
    while (line_it.next()) |hline| {
        if (hline.len == 0) continue;
        if (headerKeyEql(hline, "content-length")) {
            content_length = parseHeaderUint(hline) orelse 0;
        }
    }

    // CORS preflight.
    if (std.mem.eql(u8, method, "OPTIONS")) {
        try writeResponse(allocator, stream, 204, "No Content", "", null);
        return;
    }
    if (std.mem.eql(u8, method, "GET")) {
        // No SSE server-push channel; direct clients to POST.
        try writeResponse(allocator, stream, 405, "Method Not Allowed", "{\"error\":\"use POST for MCP\"}", "application/json");
        return;
    }
    if (std.mem.eql(u8, method, "DELETE")) {
        // Session teardown — state is process-global, nothing to free.
        try writeResponse(allocator, stream, 200, "OK", "", null);
        return;
    }
    if (!std.mem.eql(u8, method, "POST")) {
        try writeResponse(allocator, stream, 405, "Method Not Allowed", "", null);
        return;
    }

    const path = pathOnly(target);
    if (!(std.mem.eql(u8, path, "/mcp") or std.mem.eql(u8, path, "/"))) {
        try writeResponse(allocator, stream, 404, "Not Found", "{\"error\":\"unknown path\"}", "application/json");
        return;
    }
    if (content_length == 0 or content_length > MAX_BODY) {
        try writeResponse(allocator, stream, 400, "Bad Request", "{\"error\":\"missing or invalid Content-Length\"}", "application/json");
        return;
    }

    // Ensure the full body is buffered (the header read may have pulled part
    // or all of it already).
    while (buf.items.len - header_end < content_length) {
        var tmp: [4096]u8 = undefined;
        const n = try recvSome(stream, &tmp);
        if (n == 0) return error.UnexpectedEof;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
    const body = buf.items[header_end .. header_end + content_length];

    var out = std.ArrayList(u8){};
    defer out.deinit(allocator);
    const has_response = server.executeMessageToBuffer(body, &out) catch |err| {
        std.log.err("http execute failed: {s}", .{@errorName(err)});
        const msg = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32603,\"message\":\"internal error\"}}";
        try writeResponse(allocator, stream, 500, "Internal Server Error", msg, "application/json");
        return;
    };

    if (has_response) {
        try writeResponse(allocator, stream, 200, "OK", out.items, "application/json");
    } else {
        try writeResponse(allocator, stream, 202, "Accepted", "", null);
    }
}

/// Read from `stream` into `buf` until the end-of-headers `\r\n\r\n` marker.
/// Returns the index just past the marker (the body start).
fn readUntilDoubleCRLF(allocator: std.mem.Allocator, stream: std.net.Stream, buf: *std.ArrayList(u8)) !usize {
    while (true) {
        if (std.mem.indexOf(u8, buf.items, "\r\n\r\n")) |idx| return idx + 4;
        if (buf.items.len > MAX_HEADER) return error.HeaderTooLarge;
        var tmp: [4096]u8 = undefined;
        const n = try recvSome(stream, &tmp);
        if (n == 0) return error.UnexpectedEof;
        try buf.appendSlice(allocator, tmp[0..n]);
    }
}

fn writeResponse(
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    code: u16,
    reason: []const u8,
    body: []const u8,
    content_type: ?[]const u8,
) !void {
    var h = std.ArrayList(u8){};
    defer h.deinit(allocator);
    const hw = h.writer(allocator);
    try hw.print("HTTP/1.1 {d} {s}\r\n", .{ code, reason });
    if (content_type) |ct| try hw.print("Content-Type: {s}\r\n", .{ct});
    try hw.print("Content-Length: {d}\r\n", .{body.len});
    try hw.writeAll("Access-Control-Allow-Origin: *\r\n");
    try hw.writeAll("Access-Control-Allow-Methods: POST, GET, OPTIONS, DELETE\r\n");
    try hw.writeAll("Access-Control-Allow-Headers: Content-Type, Mcp-Session-Id, Authorization\r\n");
    try hw.writeAll("Mcp-Session-Id: zindeks-http\r\n");
    try hw.writeAll("Connection: close\r\n\r\n");
    try sendAll(stream, h.items);
    if (body.len > 0) try sendAll(stream, body);
}

fn headerKeyEql(line: []const u8, name: []const u8) bool {
    const ci = std.mem.indexOfScalar(u8, line, ':') orelse return false;
    const key = std.mem.trim(u8, line[0..ci], " \t");
    return std.ascii.eqlIgnoreCase(key, name);
}

fn parseHeaderUint(line: []const u8) ?usize {
    const ci = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    const val = std.mem.trim(u8, line[ci + 1 ..], " \t");
    return std.fmt.parseUnsigned(usize, val, 10) catch null;
}

fn pathOnly(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |q| return target[0..q];
    return target;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "headerKeyEql case-insensitive" {
    try std.testing.expect(headerKeyEql("Content-Length: 42", "content-length"));
    try std.testing.expect(headerKeyEql("content-length:42", "content-length"));
    try std.testing.expect(!headerKeyEql("Content-Type: x", "content-length"));
}

test "parseHeaderUint" {
    try std.testing.expectEqual(@as(?usize, 42), parseHeaderUint("Content-Length: 42"));
    try std.testing.expectEqual(@as(?usize, 7), parseHeaderUint("content-length:   7  "));
    try std.testing.expectEqual(@as(?usize, null), parseHeaderUint("Content-Length: abc"));
}

test "pathOnly strips query" {
    try std.testing.expectEqualStrings("/mcp", pathOnly("/mcp?x=1"));
    try std.testing.expectEqualStrings("/mcp", pathOnly("/mcp"));
}
