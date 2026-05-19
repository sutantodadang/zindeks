const std = @import("std");

/// Absolute upper bound for files we will index.  Anything larger is skipped
/// with a warning.  64 MB is high enough to cover legitimate-but-large
/// sources (committed generated code, big YAML/JSON manifests) while still
/// preventing a 1 GB lockfile from blowing up the indexer.
pub const max_file_size: usize = 64 * 1024 * 1024;

/// Files >= this size are streamed chunk-by-chunk through the chunked
/// scanner / `Writer.beginStreamFile` path rather than buffered whole.  Below
/// the threshold, the simpler buffered path stays in place for throughput.
pub const stream_threshold: usize = 1 * 1024 * 1024;

/// Chunk size for the streaming scanner.  256 KB keeps the per-file working
/// set small while amortizing syscall overhead.
pub const CHUNK_SIZE: usize = 256 * 1024;

pub const FileEntry = struct {
    path: []const u8,
    content: []const u8,
    hash: u64,
    mtime: i64,
};

/// Whether to print progress to stderr during scanning.
var progress_enabled: bool = false;
var progress_count: usize = 0;

/// Enable or disable progress reporting for scanPath/scanPathStreaming.
pub fn setProgress(enabled: bool) void {
    progress_enabled = enabled;
    if (enabled) progress_count = 0;
}

pub fn scanPath(allocator: std.mem.Allocator, root_path: []const u8) ![]FileEntry {
    const Collector = struct {
        allocator: std.mem.Allocator,
        files: std.ArrayList(FileEntry),

        fn onFile(self: *@This(), entry: FileEntry) !void {
            try self.files.append(self.allocator, .{
                .path = try self.allocator.dupe(u8, entry.path),
                .content = try self.allocator.dupe(u8, entry.content),
                .hash = entry.hash,
                .mtime = entry.mtime,
            });
        }
    };

    var collector = Collector{ .allocator = allocator, .files = .{} };
    errdefer {
        for (collector.files.items) |file| {
            allocator.free(file.path);
            allocator.free(file.content);
        }
        collector.files.deinit(allocator);
    }

    try scanPathStreaming(allocator, root_path, &collector, Collector.onFile);
    return collector.files.toOwnedSlice(allocator);
}

pub fn scanPathStreaming(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    context: anytype,
    comptime on_file: fn (@TypeOf(context), FileEntry) anyerror!void,
) !void {
    var root = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer root.close();
    try scanDirStreaming(@TypeOf(context), allocator, root, "", context, on_file);
    if (progress_enabled) {
        std.debug.print("\r  {d} source files scanned.\n", .{progress_count});
    }
}

/// Event emitted by the chunked scanner.  Files under `stream_threshold`
/// emit a single `file` event with the full content already buffered.  Files
/// at or above the threshold emit `begin` → `chunk`* → `end`, letting the
/// consumer process them without loading the whole content into memory.
pub const ChunkEvent = union(enum) {
    file: FileEntry,
    begin: struct { path: []const u8, mtime: i64 },
    chunk: []const u8,
    end: struct { hash: u64 },
};

/// Chunked walker — emits a single `file` event for small files, and a
/// `begin`/`chunk`*/`end` triple for files above `stream_threshold`.
/// The chunk bytes are only valid for the duration of the `chunk` callback;
/// consumers must copy them out if they need a longer lifetime.
pub fn scanPathChunked(
    allocator: std.mem.Allocator,
    root_path: []const u8,
    context: anytype,
    comptime on_event: fn (@TypeOf(context), ChunkEvent) anyerror!void,
) !void {
    var root = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer root.close();
    try scanDirChunked(@TypeOf(context), allocator, root, "", context, on_event);
    if (progress_enabled) {
        std.debug.print("\r  {d} source files scanned.\n", .{progress_count});
    }
}

fn scanDirChunked(
    comptime Context: type,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    context: Context,
    comptime on_event: fn (Context, ChunkEvent) anyerror!void,
) !void {
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
                try scanDirChunked(Context, allocator, child, rel, context, on_event);
                allocator.free(rel);
            },
            .file => {
                if (!looksLikeSource(rel)) {
                    allocator.free(rel);
                    continue;
                }
                const stat = try dir.statFile(entry.name);
                if (stat.size > max_file_size) {
                    std.debug.print("warning: skipping large file '{s}' ({d} bytes > {d} MB cap)\n", .{ rel, stat.size, max_file_size / (1024 * 1024) });
                    allocator.free(rel);
                    continue;
                }
                if (stat.size <= stream_threshold) {
                    const content = dir.readFileAlloc(allocator, entry.name, max_file_size) catch |err| {
                        if (err == error.FileTooBig) {
                            allocator.free(rel);
                            continue;
                        }
                        return err;
                    };
                    errdefer allocator.free(content);
                    try on_event(context, .{ .file = .{
                        .path = rel,
                        .content = content,
                        .hash = std.hash.Wyhash.hash(0, content),
                        .mtime = @intCast(stat.mtime),
                    } });
                    allocator.free(content);
                    allocator.free(rel);
                } else {
                    var file = try dir.openFile(entry.name, .{});
                    defer file.close();
                    try on_event(context, .{ .begin = .{ .path = rel, .mtime = @intCast(stat.mtime) } });
                    var hasher = std.hash.Wyhash.init(0);
                    var buf: [CHUNK_SIZE]u8 = undefined;
                    while (true) {
                        const n = try file.read(&buf);
                        if (n == 0) break;
                        hasher.update(buf[0..n]);
                        try on_event(context, .{ .chunk = buf[0..n] });
                    }
                    try on_event(context, .{ .end = .{ .hash = hasher.final() } });
                    allocator.free(rel);
                }
                if (progress_enabled) {
                    progress_count += 1;
                    if (progress_count % 100 == 0) {
                        std.debug.print("\r  {d} source files scanned...", .{progress_count});
                    }
                }
            },
            else => allocator.free(rel),
        }
    }
}

/// Metadata-only file entry (no content). Used for fast staleness checks.
pub const FileMetadata = struct {
    path: []const u8,
    size: u64,
    mtime: i64,
};

/// Scan a directory for source files, returning only metadata (path, size, mtime).
/// Much faster than scanPath() since it never reads file contents.
pub fn scanPathMetadata(allocator: std.mem.Allocator, root_path: []const u8) ![]FileMetadata {
    var list = std.ArrayList(FileMetadata).initCapacity(allocator, 64) catch @panic("OOM");
    errdefer {
        for (list.items) |meta| allocator.free(meta.path);
        list.deinit(allocator);
    }

    var root = try std.fs.cwd().openDir(root_path, .{ .iterate = true });
    defer root.close();
    try scanDirMetadata(allocator, root, "", &list);
    return list.toOwnedSlice(allocator);
}

fn scanDirMetadata(
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    list: *std.ArrayList(FileMetadata),
) !void {
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
                try scanDirMetadata(allocator, child, rel, list);
                allocator.free(rel);
            },
            .file => {
                if (!looksLikeSource(rel)) {
                    allocator.free(rel);
                    continue;
                }
                const stat = try dir.statFile(entry.name);
                try list.append(allocator, .{
                    .path = rel,
                    .size = stat.size,
                    .mtime = @intCast(stat.mtime),
                });
                // `rel` is now owned by the list entry — `freeMetadata` will
                // free it.  The pre-existing `allocator.free(rel)` here was
                // a double-free that only stayed hidden because every caller
                // happened to use an arena allocator.
            },
            else => allocator.free(rel),
        }
    }
}

pub fn freeMetadata(allocator: std.mem.Allocator, entries: []FileMetadata) void {
    for (entries) |entry| allocator.free(entry.path);
    allocator.free(entries);
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []FileEntry) void {
    for (entries) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.content);
    }
    allocator.free(entries);
}

fn scanDirStreaming(
    comptime Context: type,
    allocator: std.mem.Allocator,
    dir: std.fs.Dir,
    prefix: []const u8,
    context: Context,
    comptime on_file: fn (Context, FileEntry) anyerror!void,
) !void {
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
                try scanDirStreaming(Context, allocator, child, rel, context, on_file);
                allocator.free(rel);
            },
            .file => {
                if (!looksLikeSource(rel)) {
                    allocator.free(rel);
                    continue;
                }
                // Stat first so we can skip oversize files without ever
                // attempting to allocate a buffer for their content.
                const stat = try dir.statFile(entry.name);
                if (stat.size > max_file_size) {
                    std.debug.print("warning: skipping large file '{s}' ({d} bytes > {d} MB cap)\n", .{ rel, stat.size, max_file_size / (1024 * 1024) });
                    allocator.free(rel);
                    continue;
                }
                const content = dir.readFileAlloc(allocator, entry.name, max_file_size) catch |err| {
                    if (err == error.FileTooBig) {
                        // Raced with a write that grew the file past the cap.
                        allocator.free(rel);
                        continue;
                    }
                    return err;
                };
                errdefer allocator.free(content);
                try on_file(context, .{
                    .path = rel,
                    .content = content,
                    .hash = std.hash.Wyhash.hash(0, content),
                    .mtime = @intCast(stat.mtime),
                });
                allocator.free(content);
                allocator.free(rel);
                if (progress_enabled) {
                    progress_count += 1;
                    if (progress_count % 100 == 0) {
                        std.debug.print("\r  {d} source files scanned...", .{progress_count});
                    }
                }
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
