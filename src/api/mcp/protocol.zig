//! MCP (Model Context Protocol) transport layer.
//!
//! Handles Content-Length-framed stdio transport, initialize handshake,
//! and JSON-RPC 2.0 message dispatch per the 2024-11-05 protocol spec.

const std = @import("std");

/// Standard JSON-RPC 2.0 error codes.
pub const ErrorCode = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,

    pub fn asStr(self: ErrorCode) []const u8 {
        return switch (self) {
            .parse_error => "Parse error",
            .invalid_request => "Invalid Request",
            .method_not_found => "Method not found",
            .invalid_params => "Invalid params",
            .internal_error => "Internal error",
        };
    }
};

pub const McpError = error{
    ProtocolViolation,
    MissingJsonRpc,
    InvalidProtocolVersion,
    NotInitialized,
    OutOfMemory,
};

pub const ServerInfo = struct {
    name: []const u8,
    version: []const u8,
};

pub const ToolCapabilities = struct {
    listChanged: bool = false,
};

pub const ServerCapabilities = struct {
    tools: ?ToolCapabilities = null,
};

// ██████████████████████████████████████████████████████████████████████████
// Transport — Content-Length-framed I/O over stdio or sockets
// ██████████████████████████████████████████████████████████████████████████
//
// All MCP messages share the LSP-style Content-Length framing.  The only
// thing that varies between the stdio mode (default) and the daemon socket
// modes (TCP / Unix) is the underlying byte stream.  We model that with a
// tagged union so handlers can be written once and dispatched per-variant.
//
// `write_mutex` serializes outbound writes so worker threads producing
// streaming notifications can safely share one connection.

pub const Transport = union(enum) {
    stdio: Stdio,
    socket: Socket,

    pub const MAX_HEADER_LEN = 4096;
    pub const MAX_BODY_LEN = 16 * 1024 * 1024; // 16 MiB

    /// Persistent read buffer.  `readUntilDelimiter` historically called
    /// `read` directly and only returned the byte range up to the first
    /// `\n` — anything past that delimiter in the same read was thrown
    /// away.  Over TCP this rarely mattered because each line arrived in
    /// its own packet, but a pipe (e.g. `cat | zindeks serve`) drains the
    /// whole frame in one read and the framing parser would lose the
    /// body.  We now buffer all reads and carve out lines / fixed-size
    /// bodies from the buffer.
    pub const ReadBuf = struct {
        data: std.ArrayList(u8) = .{},
        consumed: usize = 0,
    };

    pub const Stdio = struct {
        allocator: std.mem.Allocator,
        stdin: std.fs.File,
        stdout: std.fs.File,
        read_buf: ReadBuf,
        write_mutex: std.Thread.Mutex,
    };

    pub const Socket = struct {
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        read_buf: ReadBuf,
        write_mutex: std.Thread.Mutex,
    };

    pub fn init(allocator: std.mem.Allocator) Transport {
        return initStdio(allocator);
    }

    pub fn initStdio(allocator: std.mem.Allocator) Transport {
        return .{ .stdio = .{
            .allocator = allocator,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .read_buf = .{},
            .write_mutex = .{},
        } };
    }

    pub fn initSocket(allocator: std.mem.Allocator, stream: std.net.Stream) Transport {
        return .{ .socket = .{
            .allocator = allocator,
            .stream = stream,
            .read_buf = .{},
            .write_mutex = .{},
        } };
    }

    pub fn deinit(self: *Transport) void {
        switch (self.*) {
            .stdio => |*s| s.read_buf.data.deinit(s.allocator),
            .socket => |*s| {
                s.read_buf.data.deinit(s.allocator);
                s.stream.close();
            },
        }
    }

    /// Read the next JSON-RPC message.  Returns the raw JSON body
    /// (allocated, caller owns) or null on EOF / framing error.
    pub fn readMessage(self: *Transport) !?[]u8 {
        switch (self.*) {
            .stdio => |*s| return readFramed(s.allocator, .{ .file = s.stdin }, &s.read_buf),
            .socket => |*s| return readFramed(s.allocator, .{ .stream = s.stream }, &s.read_buf),
        }
    }

    /// Write a JSON-RPC message with Content-Length framing.  Holds the
    /// transport's write mutex so concurrent writers do not interleave.
    pub fn writeMessage(self: *Transport, json: []const u8) !void {
        switch (self.*) {
            .stdio => |*s| {
                s.write_mutex.lock();
                defer s.write_mutex.unlock();
                var header_buf: [256]u8 = undefined;
                const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{json.len});
                try s.stdout.writeAll(header);
                try s.stdout.writeAll(json);
                s.stdout.sync() catch {};
            },
            .socket => |*s| {
                s.write_mutex.lock();
                defer s.write_mutex.unlock();
                var header_buf: [256]u8 = undefined;
                const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{json.len});
                try s.stream.writeAll(header);
                try s.stream.writeAll(json);
            },
        }
    }

    /// Direct access to the write mutex for callers that want to stream a
    /// payload built one piece at a time (e.g., zero-copy result streaming
    /// that writes directly into the transport's underlying file/stream
    /// instead of going through `writeMessage`).
    pub fn writeMutex(self: *Transport) *std.Thread.Mutex {
        return switch (self.*) {
            .stdio => |*s| &s.write_mutex,
            .socket => |*s| &s.write_mutex,
        };
    }

    /// Write `bytes` to the underlying stream while holding the write
    /// mutex.  Intended for the streaming/zero-copy path that frames the
    /// payload manually.
    pub fn writeRawLocked(self: *Transport, bytes: []const u8) !void {
        switch (self.*) {
            .stdio => |*s| try s.stdout.writeAll(bytes),
            .socket => |*s| try s.stream.writeAll(bytes),
        }
    }

    pub fn syncLocked(self: *Transport) void {
        switch (self.*) {
            .stdio => |*s| s.stdout.sync() catch {},
            .socket => {},
        }
    }
};

/// Reader abstraction over either a File or a net.Stream — both expose
/// `read([]u8) !usize`, so we tag-dispatch at each call site rather than
/// type-erase.
const ReaderSource = union(enum) {
    file: std.fs.File,
    stream: std.net.Stream,

    fn read(self: ReaderSource, dst: []u8) !usize {
        return switch (self) {
            .file => |f| f.read(dst),
            .stream => |s| s.read(dst),
        };
    }
};

/// Read more bytes from the underlying source into the persistent read
/// buffer.  Compacts already-consumed prefix to keep `read_buf.data`
/// bounded across long-lived sessions.
fn refill(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf) !void {
    if (rb.consumed > 0) {
        const remaining = rb.data.items.len - rb.consumed;
        if (remaining > 0) {
            std.mem.copyForwards(u8, rb.data.items[0..remaining], rb.data.items[rb.consumed..]);
        }
        rb.data.shrinkRetainingCapacity(remaining);
        rb.consumed = 0;
    }
    var tmp: [4096]u8 = undefined;
    const n = try src.read(&tmp);
    if (n == 0) return error.EndOfStream;
    try rb.data.appendSlice(allocator, tmp[0..n]);
}

/// Read one `\n`-terminated line from the buffered source.  Returns the
/// slice excluding the delimiter; the trailing `\r` (if any) is left in
/// place so `parseContentLength` can trim it.  Refills the buffer as
/// needed; errors with `error.EndOfStream` when the source is drained
/// without producing a full line, or `error.LineTooLong` past `max_len`.
fn readLineBuffered(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf, max_len: usize) ![]const u8 {
    while (true) {
        const slice = rb.data.items[rb.consumed..];
        if (std.mem.indexOfScalar(u8, slice, '\n')) |pos| {
            const line_end = rb.consumed + pos;
            const line = rb.data.items[rb.consumed..line_end];
            rb.consumed = line_end + 1;
            return line;
        }
        if (rb.data.items.len - rb.consumed >= max_len) return error.LineTooLong;
        try refill(allocator, src, rb);
    }
}

/// Read exactly `dst.len` bytes from the buffered source.  Refills as
/// needed.
fn readExactBuffered(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf, dst: []u8) !void {
    var written: usize = 0;
    while (written < dst.len) {
        const avail = rb.data.items.len - rb.consumed;
        if (avail == 0) {
            try refill(allocator, src, rb);
            continue;
        }
        const take = @min(avail, dst.len - written);
        @memcpy(dst[written..][0..take], rb.data.items[rb.consumed..][0..take]);
        rb.consumed += take;
        written += take;
    }
}

fn readFramed(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf) !?[]u8 {
    // Skip any leading blank lines (defensive against clients that emit
    // a trailing CRLF after the previous frame).
    var content_length: usize = 0;
    while (true) {
        const header_line = readLineBuffered(allocator, src, rb, Transport.MAX_HEADER_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const trimmed = std.mem.trimRight(u8, header_line, " \t\r");
        if (trimmed.len == 0) continue;
        content_length = parseContentLength(trimmed) orelse continue;
        break;
    }
    if (content_length == 0 or content_length > Transport.MAX_BODY_LEN) return null;

    // Consume header lines + the blank separator.
    while (true) {
        const line = readLineBuffered(allocator, src, rb, Transport.MAX_HEADER_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) break;
        // Additional header line (e.g., Content-Type) — ignored.
    }

    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    readExactBuffered(allocator, src, rb, body) catch {
        allocator.free(body);
        return null;
    };
    return body;
}

fn parseContentLength(line: []const u8) ?usize {
    const trimmed = std.mem.trimRight(u8, line, " \r\n\t");
    const prefix = "Content-Length:";
    if (trimmed.len < prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(trimmed[0..prefix.len], prefix)) return null;
    const rest = std.mem.trimLeft(u8, trimmed[prefix.len..], " \t");
    return std.fmt.parseUnsigned(usize, rest, 10) catch null;
}

// ██████████████████████████████████████████████████████████████████████████
// JSON-RPC envelope helpers
// ██████████████████████████████████████████████████████████████████████████

pub const ParsedRequest = struct {
    parsed: std.json.Parsed(std.json.Value),
    id: ?std.json.Value,
    method: []const u8,
    params: ?std.json.ObjectMap,

    pub fn deinit(self: *ParsedRequest) void {
        self.parsed.deinit();
    }
};

/// Fast-parse a JSON-RPC 2.0 request from raw bytes.
/// Returns null if the message is not a valid JSON-RPC request.
/// Caller must call req.deinit() to free memory.
pub fn parseRequest(allocator: std.mem.Allocator, raw: []const u8) !?ParsedRequest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;

    const root = parsed.value;
    const obj = root.object;

    if (obj.get("jsonrpc")) |jr| {
        if (jr != .string or !std.mem.eql(u8, jr.string, "2.0")) {
            parsed.deinit();
            return null;
        }
    } else {
        // Missing jsonrpc field — not a valid JSON-RPC 2.0 request
        parsed.deinit();
        return null;
    }

    const method_val = obj.get("method") orelse {
        parsed.deinit();
        return null;
    };
    const method = method_val.string;

    const id = obj.get("id");
    const params = if (obj.get("params")) |p| switch (p) {
        .object => |o| o,
        else => null,
    } else null;

    return ParsedRequest{
        .parsed = parsed,
        .id = id,
        .method = method,
        .params = params,
    };
}

/// Check if a parsed request is a notification (no id field).
pub fn isNotification(req: ParsedRequest) bool {
    return req.id == null or req.id.? == .null;
}

// ██████████████████████████████████████████████████████████████████████████
// JSON output helpers
// ██████████████████████████████████████████████████████████████████████████

pub fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x00...0x08, 0x0B...0x0C, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

pub fn writeJsonInt(writer: anytype, n: anytype) !void {
    try writer.print("{d}", .{n});
}

pub fn writeJsonFloat(writer: anytype, f: anytype) !void {
    try writer.print("{d}", .{f});
}

pub fn writeJsonBool(writer: anytype, b: bool) !void {
    try writer.writeAll(if (b) "true" else "false");
}

pub fn writeJsonNull(writer: anytype) !void {
    try writer.writeAll("null");
}

pub fn writeJsonPair(writer: anytype, comptime key: []const u8, value: []const u8) !void {
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writer.writeAll(value);
}

// ██████████████████████████████████████████████████████████████████████████
// Response writers
// ██████████████████████████████████████████████████████████████████████████

pub fn writeSuccessBegin(writer: anytype, id: ?std.json.Value) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":");
}

pub fn writeSuccessEnd(writer: anytype) !void {
    try writer.writeByte('}');
}

pub fn writeError(writer: anytype, id: ?std.json.Value, code: ErrorCode, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.print(",\"error\":{{\"code\":{d},\"message\":", .{@intFromEnum(code)});
    try writeJsonString(writer, message);
    try writer.writeAll("}}");
}

pub fn writeErrorNoData(writer: anytype, id: ?std.json.Value, code: ErrorCode) !void {
    try writeError(writer, id, code, code.asStr());
}

pub fn writeInitializeResult(writer: anytype, id: ?std.json.Value, name: []const u8, version: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":");
    try writeJsonString(writer, name);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, version);
    try writer.writeAll("}}}");
}

pub fn writeToolsList(writer: anytype, id: ?std.json.Value, tools_json: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"tools\":");
    try writer.writeAll(tools_json);
    try writer.writeAll("}}");
}

pub fn writePingResult(writer: anytype, id: ?std.json.Value) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{}}");
}

pub fn writeToolResultBegin(writer: anytype, id: ?std.json.Value) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
}

pub fn writeToolResultEnd(writer: anytype) !void {
    try writer.writeAll("}]}}");
}

fn writeId(writer: anytype, id: ?std.json.Value) !void {
    if (id == null or id.? == .null) return;
    try writer.writeAll(",\"id\":");
    const v = id.?;
    switch (v) {
        .null => try writer.writeAll("null"),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string, .number_string => |s| try writeJsonString(writer, s),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        else => try writer.writeAll("null"),
    }
}
