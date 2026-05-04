const std = @import("std");
const builtin = @import("builtin");

pub const Options = struct {
    index_dir: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
};

pub const ReadLocation = struct {
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    project_root: ?[]const u8 = null,
    project_id: ?[]const u8 = null,

    pub fn deinit(self: *ReadLocation) void {
        self.allocator.free(self.index_dir);
        if (self.project_root) |value| self.allocator.free(value);
        if (self.project_id) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

pub const WriteLocation = struct {
    allocator: std.mem.Allocator,
    index_dir: []const u8,
    project_root: ?[]const u8 = null,
    project_id: ?[]const u8 = null,
    project_dir: ?[]const u8 = null,
    segment_id: ?[]const u8 = null,
    lock: ?Lock = null,
    committed: bool = false,

    pub fn commit(self: *WriteLocation) !void {
        const project_dir = self.project_dir orelse {
            self.committed = true;
            return;
        };
        const segment_id = self.segment_id.?;
        const project_root = self.project_root.?;
        const project_id = self.project_id.?;

        var dir = try std.fs.openDirAbsolute(project_dir, .{});
        defer dir.close();

        var metadata: std.ArrayList(u8) = .{};
        defer metadata.deinit(self.allocator);
        var writer = metadata.writer(self.allocator);
        try writer.writeAll("{\n  \"root\": ");
        try writeJsonString(&writer, project_root);
        try writer.writeAll(",\n  \"project_id\": ");
        try writeJsonString(&writer, project_id);
        try writer.writeAll(",\n  \"current_segment\": ");
        try writeJsonString(&writer, segment_id);
        try writer.print(",\n  \"updated_at\": {d},\n  \"zindeks_version\": 1\n", .{std.time.timestamp()});
        try writer.writeAll("}\n");

        try writeAtomic(&dir, "project.json", metadata.items);

        var current: std.ArrayList(u8) = .{};
        defer current.deinit(self.allocator);
        try current.appendSlice(self.allocator, segment_id);
        try current.append(self.allocator, '\n');
        try writeAtomic(&dir, "current", current.items);
        self.committed = true;
    }

    pub fn deinit(self: *WriteLocation) void {
        if (!self.committed and self.project_dir != null) {
            std.fs.deleteTreeAbsolute(self.index_dir) catch {};
        }
        if (self.lock) |*lock| {
            lock.release();
            self.allocator.free(lock.path);
        }
        self.allocator.free(self.index_dir);
        if (self.project_root) |value| self.allocator.free(value);
        if (self.project_id) |value| self.allocator.free(value);
        if (self.project_dir) |value| self.allocator.free(value);
        if (self.segment_id) |value| self.allocator.free(value);
        self.* = undefined;
    }
};

const Lock = struct {
    path: []const u8,
    file: std.fs.File,

    fn release(self: *Lock) void {
        self.file.close();
        std.fs.deleteFileAbsolute(self.path) catch {};
    }
};

pub fn prepareWrite(allocator: std.mem.Allocator, repo_path: []const u8, options: Options) !WriteLocation {
    if (options.index_dir) |index_dir| {
        try std.fs.cwd().makePath(index_dir);
        return .{
            .allocator = allocator,
            .index_dir = try allocator.dupe(u8, index_dir),
            .committed = false,
        };
    }

    const project_root = try canonicalProjectRoot(allocator, repo_path);
    errdefer allocator.free(project_root);

    const store_root = try defaultStoreRoot(allocator, options.store_root);
    defer allocator.free(store_root);

    const project_id = try makeProjectId(allocator, project_root);
    errdefer allocator.free(project_id);

    const project_dir = try std.fs.path.join(allocator, &.{ store_root, "projects", project_id });
    errdefer allocator.free(project_dir);
    try std.fs.cwd().makePath(project_dir);

    const lock_path = try std.fs.path.join(allocator, &.{ project_dir, "lock" });
    const lock_file = std.fs.createFileAbsolute(lock_path, .{ .exclusive = true }) catch |err| {
        allocator.free(lock_path);
        switch (err) {
            error.PathAlreadyExists => return error.ProjectIndexLocked,
            else => |e| return e,
        }
    };
    var lock = Lock{ .path = lock_path, .file = lock_file };
    errdefer {
        lock.release();
        allocator.free(lock_path);
    }

    const segments_dir = try std.fs.path.join(allocator, &.{ project_dir, "segments" });
    defer allocator.free(segments_dir);
    try std.fs.cwd().makePath(segments_dir);

    const segment_id = try makeSegmentId(allocator);
    errdefer allocator.free(segment_id);
    const index_dir = try std.fs.path.join(allocator, &.{ segments_dir, segment_id });
    errdefer allocator.free(index_dir);
    try std.fs.cwd().makePath(index_dir);

    return .{
        .allocator = allocator,
        .index_dir = index_dir,
        .project_root = project_root,
        .project_id = project_id,
        .project_dir = project_dir,
        .segment_id = segment_id,
        .lock = lock,
    };
}

pub fn resolveRead(allocator: std.mem.Allocator, repo_path: []const u8, options: Options) !ReadLocation {
    if (options.index_dir) |index_dir| {
        return .{ .allocator = allocator, .index_dir = try allocator.dupe(u8, index_dir) };
    }

    const project_root = try canonicalProjectRoot(allocator, repo_path);
    errdefer allocator.free(project_root);

    const store_root = try defaultStoreRoot(allocator, options.store_root);
    defer allocator.free(store_root);

    const project_id = try makeProjectId(allocator, project_root);
    errdefer allocator.free(project_id);

    const project_dir = try std.fs.path.join(allocator, &.{ store_root, "projects", project_id });
    defer allocator.free(project_dir);

    const current_path = try std.fs.path.join(allocator, &.{ project_dir, "current" });
    defer allocator.free(current_path);
    const current_raw = std.fs.cwd().readFileAlloc(allocator, current_path, 4096) catch |err| switch (err) {
        error.FileNotFound => return error.ProjectNotIndexed,
        else => |e| return e,
    };
    defer allocator.free(current_raw);
    const current = std.mem.trim(u8, current_raw, " \t\r\n");
    if (current.len == 0) return error.BadProjectIndex;

    return .{
        .allocator = allocator,
        .index_dir = try std.fs.path.join(allocator, &.{ project_dir, "segments", current }),
        .project_root = project_root,
        .project_id = project_id,
    };
}

pub fn defaultStoreRoot(allocator: std.mem.Allocator, override_root: ?[]const u8) ![]u8 {
    if (override_root) |root| return allocator.dupe(u8, root);

    switch (builtin.os.tag) {
        .windows => {
            if (envOwned(allocator, "LOCALAPPDATA")) |local| {
                defer allocator.free(local);
                return std.fs.path.join(allocator, &.{ local, "zindeks" });
            }
            if (envOwned(allocator, "USERPROFILE")) |profile| {
                defer allocator.free(profile);
                return std.fs.path.join(allocator, &.{ profile, "AppData", "Local", "zindeks" });
            }
        },
        .macos => {
            if (envOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &.{ home, "Library", "Caches", "zindeks" });
            }
        },
        else => {
            if (envOwned(allocator, "XDG_CACHE_HOME")) |xdg| {
                defer allocator.free(xdg);
                return std.fs.path.join(allocator, &.{ xdg, "zindeks" });
            }
            if (envOwned(allocator, "HOME")) |home| {
                defer allocator.free(home);
                return std.fs.path.join(allocator, &.{ home, ".cache", "zindeks" });
            }
        },
    }
    return error.HomeNotFound;
}

fn canonicalProjectRoot(allocator: std.mem.Allocator, repo_path: []const u8) ![]u8 {
    return std.fs.realpathAlloc(allocator, repo_path);
}

fn makeProjectId(allocator: std.mem.Allocator, project_root: []const u8) ![]u8 {
    const base = std.fs.path.basename(project_root);
    var safe = try allocator.alloc(u8, @max(base.len, 1));
    defer allocator.free(safe);

    if (base.len == 0) {
        safe[0] = 'p';
    } else {
        for (base, 0..) |char, i| {
            safe[i] = if (std.ascii.isAlphanumeric(char) or char == '-' or char == '_' or char == '.') char else '-';
        }
    }

    const safe_name = if (base.len == 0) safe[0..1] else safe[0..base.len];
    const hash = std.hash.Wyhash.hash(0x7a696e64656b73, project_root);
    return std.fmt.allocPrint(allocator, "{s}-{x:0>16}", .{ safe_name, hash });
}

fn makeSegmentId(allocator: std.mem.Allocator) ![]u8 {
    const nanos = std.time.nanoTimestamp();
    const random = std.crypto.random.int(u32);
    return std.fmt.allocPrint(allocator, "{d}-{x:0>8}", .{ nanos, random });
}

fn envOwned(allocator: std.mem.Allocator, key: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

fn writeAtomic(dir: *std.fs.Dir, name: []const u8, bytes: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var file = try dir.atomicFile(name, .{ .write_buffer = &buffer });
    defer file.deinit();
    try file.file_writer.file.writeAll(bytes);
    try file.finish();
}

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |char| switch (char) {
        '\\' => try writer.writeAll("\\\\"),
        '"' => try writer.writeAll("\\\""),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        else => if (char < 0x20) {
            try writer.print("\\u{x:0>4}", .{char});
        } else {
            try writer.writeByte(char);
        },
    };
    try writer.writeByte('"');
}
