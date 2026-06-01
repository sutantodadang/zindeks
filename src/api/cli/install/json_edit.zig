//! JSON-preserving edit helpers for MCP config files.
//!
//! Strategy:
//!   1. Read existing file (or start with `{}`).
//!   2. Detect JSONC (comments) — bail with clear error if found.
//!   3. Parse with std.json into a Value tree (arena-backed).
//!   4. Walk/create the `mcpServers` object.
//!   5. Set (or overwrite) the `zindeks` key.
//!   6. Stringify with 2-space indent.
//!   7. Write atomically (tmpfile + rename).
//!
//! All JSON mutation uses an ArenaAllocator so no individual frees are needed.

const std = @import("std");
const builtin = @import("builtin");

/// How the MCP client should connect to zindeks.
///
/// - `.stdio`: client auto-spawns the binary over stdin/stdout (default).
///   Payload: absolute path to the zindeks binary.
/// - `.http`: client connects to a running HTTP daemon.
///   Payload: full URL, e.g. `http://127.0.0.1:7337/mcp`.
pub const McpTransport = union(enum) {
    stdio: []const u8, // absolute path to the zindeks binary
    http: []const u8, // full URL, e.g. http://127.0.0.1:7337/mcp
};

/// Inject (or overwrite) the `zindeks` key inside `mcpServers` in a JSON
/// config file.  Creates the file and any parent directories if absent.
/// The write is atomic: a temp file is written first, then renamed over
/// the target.
///
/// `transport` controls the MCP entry shape:
///   - `.stdio |cmd|`: `{"command":<cmd>,"args":["serve"]}`
///   - `.http  |url|`: `{"type":"http","url":<url>}`
pub fn injectMcpEntry(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    transport: McpTransport,
) !void {
    // Use an arena for all JSON parsing + mutation; freed at end.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // ── Read existing content (or empty object) ───────────────────────
    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try aa.dupe(u8, "{}"),
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(aa, 4 * 1024 * 1024);
    };

    // ── JSONC guard ───────────────────────────────────────────────────
    if (hasComments(existing)) return error.JsoncNotSupported;

    // ── Parse into mutable Value tree ─────────────────────────────────
    var root: std.json.Value = blk: {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            aa,
            existing,
            .{ .allocate = .alloc_always },
        ) catch {
            break :blk .{ .object = std.json.ObjectMap.init(aa) };
        };
        // Don't call parsed.deinit() — arena will free everything.
        break :blk parsed.value;
    };

    // Ensure root is an object.
    if (root != .object) {
        root = .{ .object = std.json.ObjectMap.init(aa) };
    }

    // ── Get or create `mcpServers` ────────────────────────────────────
    const mcp_key = "mcpServers";
    if (root.object.getPtr(mcp_key) == null) {
        try root.object.put(mcp_key, .{ .object = std.json.ObjectMap.init(aa) });
    }
    const mcp_servers = root.object.getPtr(mcp_key).?;
    if (mcp_servers.* != .object) {
        mcp_servers.* = .{ .object = std.json.ObjectMap.init(aa) };
    }

    // ── Build the zindeks entry ───────────────────────────────────────
    var entry_obj = std.json.ObjectMap.init(aa);
    switch (transport) {
        .stdio => |cmd| {
            try entry_obj.put("command", .{ .string = cmd });
            var args_array = std.json.Array.init(aa);
            try args_array.append(.{ .string = "serve" });
            try entry_obj.put("args", .{ .array = args_array });
        },
        .http => |url| {
            try entry_obj.put("type", .{ .string = "http" });
            try entry_obj.put("url", .{ .string = url });
        },
    }

    try mcp_servers.object.put("zindeks", .{ .object = entry_obj });

    // ── Serialize to JSON with 2-space indent ─────────────────────────
    var buf: std.ArrayList(u8) = .{};
    try buf.writer(aa).print("{f}", .{std.json.fmt(root, .{ .whitespace = .indent_2 })});
    try buf.append(aa, '\n');

    // ── Atomic write (uses caller's allocator for tmp path) ───────────
    try atomicWrite(allocator, file_path, buf.items);
}

/// Remove the `zindeks` key from `mcpServers` in a JSON config file.
/// If `mcpServers` doesn't exist or has no `zindeks` key, this is a no-op.
pub fn removeMcpEntry(
    allocator: std.mem.Allocator,
    file_path: []const u8,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(file_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return, // nothing to remove
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(aa, 4 * 1024 * 1024);
    };

    if (hasComments(existing)) return error.JsoncNotSupported;

    var root = blk: {
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            aa,
            existing,
            .{ .allocate = .alloc_always },
        ) catch return; // malformed — leave untouched
        break :blk parsed.value;
    };

    if (root != .object) return;

    const mcp_servers_ptr = root.object.getPtr("mcpServers") orelse return;
    if (mcp_servers_ptr.* != .object) return;
    _ = mcp_servers_ptr.object.orderedRemove("zindeks");

    var buf2: std.ArrayList(u8) = .{};
    try buf2.writer(aa).print("{f}", .{std.json.fmt(root, .{ .whitespace = .indent_2 })});
    try buf2.append(aa, '\n');

    try atomicWrite(allocator, file_path, buf2.items);
}

/// Check if a JSON string contains comment markers (// or /*) outside
/// of string literals — a rough but safe heuristic.
pub fn hasComments(content: []const u8) bool {
    var in_string = false;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (in_string) {
            if (c == '\\') {
                i += 1; // skip escaped char
            } else if (c == '"') {
                in_string = false;
            }
        } else {
            if (c == '"') {
                in_string = true;
            } else if (c == '/' and i + 1 < content.len) {
                const next = content[i + 1];
                if (next == '/' or next == '*') return true;
            }
        }
    }
    return false;
}

/// Write `content` atomically to `dest_path`.
/// Uses a sibling temp file + rename.  On Windows, the destination is
/// deleted first since Windows rename-over-existing can fail.
pub fn atomicWrite(
    allocator: std.mem.Allocator,
    dest_path: []const u8,
    content: []const u8,
) !void {
    // Ensure parent directory exists.
    if (std.fs.path.dirname(dest_path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Build temp path alongside the target.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.zindeks_tmp", .{dest_path});
    defer allocator.free(tmp_path);

    {
        const tmp_file = try std.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer tmp_file.close();
        try tmp_file.writeAll(content);
    }

    // On Windows, rename-over-existing may fail; remove the destination first.
    if (builtin.os.tag == .windows) {
        std.fs.deleteFileAbsolute(dest_path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => {
                std.fs.deleteFileAbsolute(tmp_path) catch {};
                return err;
            },
        };
    }

    std.fs.renameAbsolute(tmp_path, dest_path) catch |err| {
        std.fs.deleteFileAbsolute(tmp_path) catch {};
        return err;
    };
}

// ── Tests ─────────────────────────────────────────────────────────────

test "hasComments detects line comment" {
    try std.testing.expect(hasComments("{ // comment\n}"));
}

test "hasComments detects block comment" {
    try std.testing.expect(hasComments("{ /* comment */ }"));
}

test "hasComments ignores slashes inside strings" {
    try std.testing.expect(!hasComments("{\"url\": \"https://example.com\"}"));
}

test "hasComments returns false for plain JSON" {
    try std.testing.expect(!hasComments("{\"mcpServers\": {}}"));
}
