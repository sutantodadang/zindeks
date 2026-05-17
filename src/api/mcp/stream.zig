//! Streaming JSON response writer.
//!
//! Writes JSON array items one at a time to avoid buffering the entire
//! response in memory.  Call beginArray(), writeItem() for each item,
//! endArray(), then flush().

const std = @import("std");

pub const JsonStreamWriter = struct {
    file: std.fs.File,
    first: bool,
    buf: [4096]u8,
    pos: usize,

    pub fn init(file: std.fs.File) JsonStreamWriter {
        return .{
            .file = file,
            .first = true,
            .buf = undefined,
            .pos = 0,
        };
    }

    /// Begin a JSON array. Writes "[".
    pub fn beginArray(self: *JsonStreamWriter) !void {
        try self.file.writeAll("[");
        self.first = true;
    }

    /// End a JSON array. Writes "]".
    pub fn endArray(self: *JsonStreamWriter) !void {
        try self.file.writeAll("]");
    }

    /// Write a single JSON item into the array.
    /// Handles comma placement between items.
    /// Uses manual formatting for compatibility with Zig 0.15.
    pub fn writeItem(self: *JsonStreamWriter, comptime T: type, value: T) !void {
        if (!self.first) {
            try self.file.writeAll(",");
        }
        self.first = false;

        // Serialize using fixed buffer
        var fbs = std.io.fixedBufferStream(&self.buf);
        self.pos = 0;
        try writeJsonValue(T, fbs.writer(), value);
        try self.file.writeAll(fbs.getWritten());
    }

    /// Flush the underlying writer (no-op for raw File writes which are unbuffered).
    pub fn flush(self: *JsonStreamWriter) !void {
        _ = self;
    }
};

/// Write a value as JSON to a writer. Handles structs, integers, strings, etc.
fn writeJsonValue(comptime T: type, writer: anytype, value: T) !void {
    switch (@typeInfo(T)) {
        .int, .comptime_int => {
            try writer.print("{d}", .{value});
        },
        .float, .comptime_float => {
            try writer.print("{d}", .{value});
        },
        .bool => {
            try writer.writeAll(if (value) "true" else "false");
        },
        .array => {
            try writer.writeAll("[");
            for (value, 0..) |elem, i| {
                if (i > 0) try writer.writeAll(",");
                try writeJsonValue(@TypeOf(elem), writer, elem);
            }
            try writer.writeAll("]");
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.writeAll("\"");
                // Escape special chars
                for (value) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => try writer.writeByte(c),
                    }
                }
                try writer.writeAll("\"");
            } else {
                try writer.writeAll("null");
            }
        },
        .@"struct" => |s| {
            try writer.writeAll("{");
            inline for (s.fields, 0..) |field, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\":", .{field.name});
                try writeJsonValue(field.type, writer, @field(value, field.name));
            }
            try writer.writeAll("}");
        },
        .optional => {
            if (value) |v| {
                try writeJsonValue(@TypeOf(v), writer, v);
            } else {
                try writer.writeAll("null");
            }
        },
        else => {
            try writer.writeAll("null");
        },
    }
}
