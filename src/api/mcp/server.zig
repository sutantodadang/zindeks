const std = @import("std");
const search = @import("../../core/search/engine.zig");

pub fn serve(allocator: std.mem.Allocator, engine: *search.Engine) !void {
    const stdin = std.fs.File.stdin().deprecatedReader();
    const stdout = std.fs.File.stdout().deprecatedWriter();
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    while (true) {
        buf.clearRetainingCapacity();
        stdin.streamUntilDelimiter(buf.writer(allocator), '\n', 1024 * 1024) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (buf.items.len == 0) continue;
        try handleRequest(allocator, engine, buf.items, stdout);
        try stdout.writeByte('\n');
    }
}

pub fn handleRequest(allocator: std.mem.Allocator, engine: *search.Engine, request: []const u8, writer: anytype) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const obj = root.object;
    const id = obj.get("id") orelse std.json.Value.null;
    const method = (obj.get("method") orelse return writeError(writer, id, -32600, "missing method")).string;
    const params = if (obj.get("params")) |p| p.object else std.json.ObjectMap.init(allocator);

    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(writer, id);
    try writer.writeAll(",\"result\":");

    if (std.mem.eql(u8, method, "search")) {
        const query = getString(&params, "query") orelse "";
        const limit = getLimit(&params, 10);
        var results = try engine.search(allocator, query, limit);
        defer results.deinit(allocator);
        try writeSearchResults(engine, writer, results.items);
    } else if (std.mem.eql(u8, method, "get_context")) {
        const query = getString(&params, "query") orelse "";
        const limit = getLimit(&params, 5);
        var results = try engine.context(allocator, query, limit);
        defer results.deinit(allocator);
        try writeContextResults(engine, writer, results.items);
    } else if (std.mem.eql(u8, method, "get_file")) {
        const path = getString(&params, "path") orelse "";
        try writeFileByPath(engine, writer, path);
    } else if (std.mem.eql(u8, method, "get_symbols")) {
        const path = getString(&params, "path") orelse "";
        try writeSymbolsByPath(engine, writer, path);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeByte('}');
}

fn writeError(writer: anytype, id: std.json.Value, code: i32, message: []const u8) !void {
    try writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try writeJsonValue(writer, id);
    try writer.print(",\"error\":{{\"code\":{},\"message\":", .{code});
    try writeJsonString(writer, message);
    try writer.writeAll("}}");
}

fn writeSearchResults(engine: *search.Engine, writer: anytype, items: []const search.Result) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, item.path);
        try writer.print(",\"score\":{d:.3},\"snippet\":", .{item.score});
        try writeJsonString(writer, item.snippet);
        try writer.writeAll(",\"symbols\":[");
        const syms = engine.index.symbolsForDoc(item.doc_id);
        for (syms, 0..) |sym, j| {
            if (j != 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, engine.index.stringAt(sym.name_sid));
            try writer.print(",\"line\":{},\"kind\":{}}}", .{ sym.line, sym.kind });
        }
        try writer.writeByte(']');
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

fn writeContextResults(engine: *search.Engine, writer: anytype, items: []const search.Result) !void {
    try writer.writeByte('[');
    for (items, 0..) |item, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.writeAll("{\"path\":");
        try writeJsonString(writer, item.path);
        try writer.writeAll(",\"snippet\":");
        try writeJsonString(writer, item.snippet);
        try writer.writeAll(",\"symbols\":[");
        const syms = engine.index.symbolsForDoc(item.doc_id);
        for (syms, 0..) |sym, j| {
            if (j != 0) try writer.writeByte(',');
            try writer.writeAll("{\"name\":");
            try writeJsonString(writer, engine.index.stringAt(sym.name_sid));
            try writer.print(",\"line\":{},\"kind\":{}}}", .{ sym.line, sym.kind });
        }
        try writer.writeAll("]}");
    }
    try writer.writeByte(']');
}

fn writeFileByPath(engine: *search.Engine, writer: anytype, path: []const u8) !void {
    for (engine.index.docs, 0..) |_, doc_id| {
        if (std.mem.eql(u8, engine.index.filePath(@intCast(doc_id)), path)) {
            try writer.writeAll("{\"path\":");
            try writeJsonString(writer, path);
            try writer.writeAll(",\"content\":");
            try writeJsonString(writer, engine.index.fileContent(@intCast(doc_id)));
            try writer.writeByte('}');
            return;
        }
    }
    try writer.writeAll("null");
}

fn writeSymbolsByPath(engine: *search.Engine, writer: anytype, path: []const u8) !void {
    for (engine.index.docs, 0..) |_, doc_id| {
        if (std.mem.eql(u8, engine.index.filePath(@intCast(doc_id)), path)) {
            const syms = engine.index.symbolsForDoc(@intCast(doc_id));
            try writer.writeByte('[');
            for (syms, 0..) |sym, i| {
                if (i != 0) try writer.writeByte(',');
                try writer.writeAll("{\"name\":");
                try writeJsonString(writer, engine.index.stringAt(sym.name_sid));
                try writer.print(",\"line\":{},\"kind\":{}}}", .{ sym.line, sym.kind });
            }
            try writer.writeByte(']');
            return;
        }
    }
    try writer.writeAll("[]");
}

fn getString(params: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = params.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn getLimit(params: *const std.json.ObjectMap, default: usize) usize {
    const value = params.get("limit") orelse return default;
    return switch (value) {
        .integer => |i| if (i > 0) @intCast(@min(i, 100)) else default,
        else => default,
    };
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0...8, 11...12, 14...0x1f => try writer.print("\\u{x:0>4}", .{c}),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

fn writeJsonValue(writer: anytype, value: std.json.Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .number_string, .string => |s| try writeJsonString(writer, s),
        else => try writer.writeAll("null"),
    }
}
