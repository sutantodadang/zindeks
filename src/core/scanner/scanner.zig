const std = @import("std");

pub const FileEntry = struct {
    path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
};

pub fn scanPath(allocator: std.mem.Allocator, root_path: []const u8) ![]FileEntry {
    var root = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer root.close();
    var files: std.ArrayList(FileEntry) = .{};
    errdefer {
        for (files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.content);
        }
        files.deinit(allocator);
    }
    try scanDir(allocator, root, "", &files);
    return files.toOwnedSlice(allocator);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []FileEntry) void {
    for (entries) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.content);
    }
    allocator.free(entries);
}

fn scanDir(allocator: std.mem.Allocator, dir: std.fs.Dir, prefix: []const u8, files: *std.ArrayList(FileEntry)) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (shouldSkip(entry.name)) continue;
        const rel = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fs.path.join(allocator, &.{ prefix, entry.name });
        errdefer allocator.free(rel);

        switch (entry.kind) {
            .directory => {
                var child = try dir.openDir(entry.name, .{ .iterate = true });
                defer child.close();
                try scanDir(allocator, child, rel, files);
                allocator.free(rel);
            },
            .file => {
                if (!looksLikeSource(rel)) {
                    allocator.free(rel);
                    continue;
                }
                const content = try dir.readFileAlloc(allocator, entry.name, 16 * 1024 * 1024);
                errdefer allocator.free(content);
                const stat = try dir.statFile(entry.name);
                try files.append(allocator, .{
                    .path = rel,
                    .content = content,
                    .hash = std.hash.Wyhash.hash(0, content),
                    .mtime = @intCast(stat.mtime),
                });
            },
            else => allocator.free(rel),
        }
    }
}

fn shouldSkip(name: []const u8) bool {
    const skips = [_][]const u8{ ".git", ".zig-cache", "zig-out", ".zindeks", "node_modules", "target" };
    for (skips) |skip| if (std.mem.eql(u8, name, skip)) return true;
    return false;
}

fn looksLikeSource(path: []const u8) bool {
    const exts = [_][]const u8{
        ".zig", ".zon", ".c",    ".h",  ".cpp", ".hpp", ".rs",  ".go", ".py",   ".js",   ".ts",
        ".tsx", ".jsx", ".java", ".kt", ".cs",  ".rb",  ".php", ".md", ".json", ".toml", ".yaml",
        ".yml",
    };
    for (exts) |ext| if (std.mem.endsWith(u8, path, ext)) return true;
    return false;
}
