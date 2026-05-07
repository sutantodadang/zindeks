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
// Transport — Content-Length-framed stdio
// ██████████████████████████████████████████████████████████████████████████

pub const Transport = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdout: std.fs.File,
    buf: std.ArrayList(u8),

    const MAX_HEADER_LEN = 4096;
    const MAX_BODY_LEN = 16 * 1024 * 1024; // 16 MiB

    pub fn init(allocator: std.mem.Allocator) Transport {
        return .{
            .allocator = allocator,
            .stdin = std.fs.File.stdin(),
            .stdout = std.fs.File.stdout(),
            .buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch @panic("OOM"),
        };
    }

    pub fn deinit(self: *Transport) void {
        self.buf.deinit(self.allocator);
    }

    /// Read bytes until delimiter, appending to writer (excludes delimiter).
    /// Returns the number of bytes read (up to max_len). Returns EndOfStream if
    /// EOF reached before delimiter.
    fn readUntilDelimiter(file: std.fs.File, writer: anytype, delimiter: u8, max_len: usize) !usize {
        var chunk_buf: [4096]u8 = undefined;
        var total: usize = 0;
        while (total < max_len) {
            const remaining = @min(4096, max_len - total);
            const n = file.read(chunk_buf[0..remaining]) catch |err| {
                return err;
            };
            if (n == 0) return if (total > 0) error.EndOfStream else error.EndOfStream;
            const chunk = chunk_buf[0..n];
            if (std.mem.indexOfScalar(u8, chunk, delimiter)) |pos| {
                try writer.writeAll(chunk[0..pos]);
                return total + pos;
            }
            try writer.writeAll(chunk);
            total += n;
        }
        return total;
    }

    /// Read exactly N bytes from stdin.
    fn readExact(file: std.fs.File, buf: []u8) !bool {
        const nread = file.readAll(buf) catch |err| {
            return err;
        };
        return nread == buf.len;
    }

    /// Read the next JSON-RPC message from stdin.  Returns the raw JSON body
    /// (allocated, caller owns) or null on EOF / framing error.
    pub fn readMessage(self: *Transport) !?[]u8 {
        // Read Content-Length: <N>\r\n
        self.buf.shrinkRetainingCapacity(0);
        _ = readUntilDelimiter(self.stdin, self.buf.writer(self.allocator), '\n', MAX_HEADER_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };

        const header_line = self.buf.items;
        if (header_line.len == 0) return null;

        const content_length = parseContentLength(header_line) orelse {
            self.buf.shrinkRetainingCapacity(0);
            _ = readUntilDelimiter(self.stdin, self.buf.writer(self.allocator), '\n', MAX_HEADER_LEN) catch |err| switch (err) {
                error.EndOfStream => return null,
                else => |e| return e,
            };
            return null; // skip malformed header
        };

        if (content_length == 0 or content_length > MAX_BODY_LEN) return null;

        // Consume the blank line after header
        self.buf.shrinkRetainingCapacity(0);
        _ = readUntilDelimiter(self.stdin, self.buf.writer(self.allocator), '\n', MAX_HEADER_LEN) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => |e| return e,
        };

        // Read exactly content_length bytes
        const body = try self.allocator.alloc(u8, content_length);
        errdefer self.allocator.free(body);
        if (!try readExact(self.stdin, body)) {
            self.allocator.free(body);
            return null;
        }
        return body;
    }

    /// Write a JSON-RPC message with Content-Length framing.
    pub fn writeMessage(self: *Transport, json: []const u8) !void {
        var header_buf: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_buf, "Content-Length: {}\r\n\r\n", .{json.len});
        try self.stdout.writeAll(header);
        try self.stdout.writeAll(json);
    }
};

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
