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

    /// Wire-level framing for one MCP session.
    ///
    /// The MCP spec for the stdio transport mandates **newline-delimited
    /// JSON-RPC** — one JSON object per line, no embedded newlines.  An
    /// earlier draft of this server (and many LSP-derived stacks) used
    /// **Content-Length** framing instead, so we keep both readers and
    /// auto-detect on the first message: if the first non-whitespace byte
    /// is `{` or `[`, the session is newline-delimited; if it looks like
    /// `Content-Length:`, the session uses LSP framing.  The choice is
    /// then mirrored on writes so the client sees consistent framing.
    pub const Framing = enum { unknown, newline, content_length };

    /// Persistent read buffer.  Pipe reads can drain the entire frame in
    /// one syscall, so a framing parser that only consumes up to the
    /// first `\n` per call would lose everything after it.  Reads go
    /// through this buffer; consumers carve out lines / fixed-size
    /// bodies, and any remainder stays available for the next call.
    pub const ReadBuf = struct {
        data: std.ArrayList(u8) = .{},
        consumed: usize = 0,
    };

    pub const Stdio = struct {
        allocator: std.mem.Allocator,
        stdin: std.fs.File,
        stdout: std.fs.File,
        read_buf: ReadBuf,
        framing: Framing,
        write_mutex: std.Thread.Mutex,
    };

    pub const Socket = struct {
        allocator: std.mem.Allocator,
        stream: std.net.Stream,
        read_buf: ReadBuf,
        framing: Framing,
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
            .framing = .unknown,
            .write_mutex = .{},
        } };
    }

    pub fn initSocket(allocator: std.mem.Allocator, stream: std.net.Stream) Transport {
        return .{ .socket = .{
            .allocator = allocator,
            .stream = stream,
            .read_buf = .{},
            .framing = .unknown,
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
            .stdio => |*s| return readFramed(s.allocator, .{ .file = s.stdin }, &s.read_buf, &s.framing),
            .socket => |*s| return readFramed(s.allocator, .{ .stream = s.stream }, &s.read_buf, &s.framing),
        }
    }

    /// Write a JSON-RPC message using the framing detected from the
    /// client.  Holds the transport's write mutex so concurrent writers
    /// (worker threads streaming partial results) do not interleave.
    pub fn writeMessage(self: *Transport, json: []const u8) !void {
        switch (self.*) {
            .stdio => |*s| {
                s.write_mutex.lock();
                defer s.write_mutex.unlock();
                try writeFramed(.{ .file = s.stdout }, s.framing, json);
                s.stdout.sync() catch {};
            },
            .socket => |*s| {
                s.write_mutex.lock();
                defer s.write_mutex.unlock();
                try writeFramed(.{ .stream = s.stream }, s.framing, json);
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

const WriterSink = union(enum) {
    file: std.fs.File,
    stream: std.net.Stream,

    fn writeAll(self: WriterSink, bytes: []const u8) !void {
        switch (self) {
            .file => |f| try f.writeAll(bytes),
            .stream => |s| try s.writeAll(bytes),
        }
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

/// Peek at the first non-whitespace byte in the buffered input without
/// consuming it.  Used to auto-detect framing on the first message.
/// Returns `null` on EOF.
fn peekFirstByte(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf) !?u8 {
    while (true) {
        // Skip leading whitespace (incl. CR/LF carried over from a prior
        // frame) without consuming the framing-significant byte.
        while (rb.consumed < rb.data.items.len) {
            const c = rb.data.items[rb.consumed];
            switch (c) {
                ' ', '\t', '\r', '\n' => rb.consumed += 1,
                else => return c,
            }
        }
        refill(allocator, src, rb) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
    }
}

fn readFramed(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf, framing: *Transport.Framing) !?[]u8 {
    // Auto-detect on first message; lock in for the rest of the session.
    if (framing.* == .unknown) {
        const first = (try peekFirstByte(allocator, src, rb)) orelse return null;
        framing.* = if (first == '{' or first == '[') .newline else .content_length;
    }
    return switch (framing.*) {
        .newline => try readNewlineFrame(allocator, src, rb),
        .content_length => try readContentLengthFrame(allocator, src, rb),
        .unknown => unreachable,
    };
}

/// Read one newline-delimited JSON message (the MCP-spec stdio framing).
fn readNewlineFrame(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf) !?[]u8 {
    while (true) {
        const line = readLineBuffered(allocator, src, rb, Transport.MAX_BODY_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) continue; // tolerate keep-alive newlines
        return try allocator.dupe(u8, trimmed);
    }
}

/// Read one LSP-style Content-Length-framed message.
fn readContentLengthFrame(allocator: std.mem.Allocator, src: ReaderSource, rb: *Transport.ReadBuf) !?[]u8 {
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

    while (true) {
        const line = readLineBuffered(allocator, src, rb, Transport.MAX_HEADER_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };
        const trimmed = std.mem.trimRight(u8, line, " \t\r");
        if (trimmed.len == 0) break;
    }

    const body = try allocator.alloc(u8, content_length);
    errdefer allocator.free(body);
    readExactBuffered(allocator, src, rb, body) catch {
        allocator.free(body);
        return null;
    };
    return body;
}

/// Write a single response using the negotiated framing.  Falls back to
/// newline-delimited when no client message has been processed yet (which
/// is the MCP-spec default).
fn writeFramed(sink: WriterSink, framing: Transport.Framing, json: []const u8) !void {
    switch (framing) {
        .content_length => {
            var header_buf: [256]u8 = undefined;
            const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{json.len});
            try sink.writeAll(header);
            try sink.writeAll(json);
        },
        .newline, .unknown => {
            try sink.writeAll(json);
            try sink.writeAll("\n");
        },
    }
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

/// Versions of the MCP base protocol this server has been validated
/// against.  When the client's `protocolVersion` matches one of these we
/// echo it back; otherwise we fall back to the server default so the
/// handshake still succeeds (per spec the client decides whether the
/// negotiated version is acceptable).
pub const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{
    "2024-11-05",
    "2025-03-26",
    "2025-06-18",
};
pub const DEFAULT_PROTOCOL_VERSION: []const u8 = "2024-11-05";

pub fn negotiateProtocolVersion(client_requested: ?[]const u8) []const u8 {
    if (client_requested) |req| {
        for (SUPPORTED_PROTOCOL_VERSIONS) |v| {
            if (std.mem.eql(u8, v, req)) return v;
        }
    }
    return DEFAULT_PROTOCOL_VERSION;
}

pub fn writeInitializeResult(writer: anytype, id: ?std.json.Value, name: []const u8, version: []const u8) !void {
    try writeInitializeResultV(writer, id, name, version, DEFAULT_PROTOCOL_VERSION);
}

const INIT_INSTRUCTIONS = "zindeks code knowledge graph. Call index_repository with an absolute repo path to bind a project; already-indexed repos auto-attach (list_projects shows them). If any tool returns code NO_PROJECT, call index_repository first. Prefer get_context for task-scoped context, search for lookup, trace_call_path for callers/callees, and read_file/list_files/file_outline over raw filesystem access. Compact row keys in search/search_graph/file_outline results: p=path, f=file, n=name, k=kind, l=line, e=line_end, s=score, x=snippet, cs=col_start, ce=col_end.";

pub fn writeInitializeResultV(writer: anytype, id: ?std.json.Value, name: []const u8, version: []const u8, protocol_version: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"protocolVersion\":");
    try writeJsonString(writer, protocol_version);
    try writer.writeAll(",\"capabilities\":{\"tools\":{\"listChanged\":false}},\"serverInfo\":{\"name\":");
    try writeJsonString(writer, name);
    try writer.writeAll(",\"version\":");
    try writeJsonString(writer, version);
    try writer.writeAll("},\"instructions\":");
    try writeJsonString(writer, INIT_INSTRUCTIONS);
    try writer.writeAll("}}");
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

/// Emit a full MCP-compliant `tools/call` response in one shot.
///
/// The MCP spec requires `result.content[].text` to be a **string**, but
/// our handlers produce JSON bodies.  We JSON-escape the body into the
/// `text` field so strict clients accept the response.  When `is_error`
/// is true, the spec's `result.isError: true` flag is set instead of a
/// JSON-RPC `error` envelope (the request is well-formed; the tool's
/// execution is what failed).
pub fn writeToolResultEnvelope(writer: anytype, id: ?std.json.Value, body: []const u8, is_error: bool) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\"");
    try writeId(writer, id);
    try writer.writeAll(",\"result\":{\"content\":[{\"type\":\"text\",\"text\":");
    try writeJsonString(writer, body);
    try writer.writeAll("}]");
    if (is_error) try writer.writeAll(",\"isError\":true");
    try writer.writeAll("}}");
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
