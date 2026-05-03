const std = @import("std");
const storage = @import("../core/storage/index.zig");

pub const ParsedSymbol = struct {
    name: []const u8,
    kind: storage.SymbolKind,
    line: u32,
    byte_off: u32,
};

pub fn parseSymbols(allocator: std.mem.Allocator, content: []const u8) ![]ParsedSymbol {
    var out: std.ArrayList(ParsedSymbol) = .{};
    errdefer out.deinit(allocator);

    var line_no: u32 = 0;
    var byte_off: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| : ({
        byte_off += line.len + 1;
        line_no += 1;
    }) {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (try parseAfterKeyword(allocator, trimmed, "fn ", .function, line_no, byte_off)) |sym| {
            try out.append(allocator, sym);
            continue;
        }
        if (try parseAfterKeyword(allocator, trimmed, "const ", .const_value, line_no, byte_off)) |sym| {
            const eq = std.mem.indexOf(u8, trimmed, "=") orelse 0;
            if (std.mem.indexOf(u8, trimmed[eq..], "struct")) |_| {
                try out.append(allocator, .{ .name = sym.name, .kind = .struct_type, .line = sym.line, .byte_off = sym.byte_off });
            } else {
                try out.append(allocator, sym);
            }
            continue;
        }
        if (try parseAfterKeyword(allocator, trimmed, "var ", .variable, line_no, byte_off)) |sym| {
            try out.append(allocator, sym);
            continue;
        }
        if (try parseImport(allocator, trimmed, line_no, byte_off)) |sym| {
            try out.append(allocator, sym);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn parseAfterKeyword(
    allocator: std.mem.Allocator,
    line: []const u8,
    keyword: []const u8,
    kind: storage.SymbolKind,
    line_no: u32,
    line_off: usize,
) !?ParsedSymbol {
    const idx = std.mem.indexOf(u8, line, keyword) orelse return null;
    var start = idx + keyword.len;
    while (start < line.len and (line[start] == '*' or line[start] == ' ')) start += 1;
    const name_start = start;
    while (start < line.len and (std.ascii.isAlphanumeric(line[start]) or line[start] == '_')) start += 1;
    if (start == name_start) return null;
    return .{
        .name = try allocator.dupe(u8, line[name_start..start]),
        .kind = kind,
        .line = line_no,
        .byte_off = @intCast(line_off + name_start),
    };
}

fn parseImport(allocator: std.mem.Allocator, line: []const u8, line_no: u32, line_off: usize) !?ParsedSymbol {
    const marker = "@import(\"";
    const idx = std.mem.indexOf(u8, line, marker) orelse return null;
    const start = idx + marker.len;
    const rest = line[start..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return .{
        .name = try allocator.dupe(u8, rest[0..end]),
        .kind = .module,
        .line = line_no,
        .byte_off = @intCast(line_off + start),
    };
}
