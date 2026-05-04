const std = @import("std");
const indexer = @import("../../core/indexer/indexer.zig");
const project_store = @import("../../core/project_store.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
const mcp = @import("../mcp/server.zig");
const update = @import("update.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return invalidUsage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try usage(std.fs.File.stdout().deprecatedWriter());
        return;
    }
    if (std.mem.eql(u8, cmd, "index")) {
        const parsed = try parseIndexArgs(args[2..]);
        var location = try project_store.prepareWrite(allocator, parsed.repo, .{ .index_dir = parsed.index_dir, .store_root = parsed.store_root });
        defer location.deinit();
        try indexer.indexPath(allocator, parsed.repo, location.index_dir);
        try location.commit();
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (args.len < 3) return invalidUsage();
        const parsed = try parseReadArgs(allocator, args[3..]);
        var location = try project_store.resolveRead(allocator, parsed.repo, .{ .index_dir = parsed.index_dir, .store_root = parsed.store_root });
        defer location.deinit();
        var idx = try storage.Index.open(allocator, std.fs.cwd(), location.index_dir);
        defer idx.close();
        var engine = search.Engine.init(&idx);
        var results = try engine.search(allocator, args[2], 10);
        defer results.deinit(allocator);
        const stdout = std.fs.File.stdout().deprecatedWriter();
        for (results.items) |item| {
            try stdout.print("{d:.3}\t{s}\t{s}\n", .{ item.score, item.path, item.snippet });
        }
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const parsed = try parseReadArgs(allocator, args[2..]);
        var location = try project_store.resolveRead(allocator, parsed.repo, .{ .index_dir = parsed.index_dir, .store_root = parsed.store_root });
        defer location.deinit();
        var idx = try storage.Index.open(allocator, std.fs.cwd(), location.index_dir);
        defer idx.close();
        var engine = search.Engine.init(&idx);
        try mcp.serve(allocator, &engine);
    } else if (std.mem.eql(u8, cmd, "update")) {
        update.run(allocator, args[2..], std.fs.File.stdout().deprecatedWriter()) catch |err| switch (err) {
            error.HelpRequested => return update.usage(std.fs.File.stdout().deprecatedWriter()),
            else => return err,
        };
    } else {
        return invalidUsage();
    }
}

const IndexArgs = struct {
    repo: []const u8 = ".",
    index_dir: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
};

const ReadArgs = struct {
    repo: []const u8 = ".",
    index_dir: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
};

fn parseIndexArgs(args: []const []const u8) !IndexArgs {
    var parsed = IndexArgs{};
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--index-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.index_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--store-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.store_root = args[i];
        } else {
            if (positional_len >= positional.len) return error.InvalidArguments;
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len >= 1) parsed.repo = positional[0];
    if (positional_len >= 2) parsed.index_dir = positional[1];
    return parsed;
}

fn parseReadArgs(allocator: std.mem.Allocator, args: []const []const u8) !ReadArgs {
    var parsed = ReadArgs{};
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--index-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.index_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--store-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.store_root = args[i];
        } else {
            if (positional_len >= positional.len) return error.InvalidArguments;
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len == 1) {
        if (try looksLikeIndexDir(allocator, positional[0])) {
            parsed.index_dir = positional[0];
        } else {
            parsed.repo = positional[0];
        }
    } else if (positional_len == 2) {
        parsed.repo = positional[0];
        parsed.index_dir = positional[1];
    }
    return parsed;
}

fn looksLikeIndexDir(allocator: std.mem.Allocator, path: []const u8) !bool {
    const meta_path = try std.fs.path.join(allocator, &.{ path, "meta.idx" });
    defer allocator.free(meta_path);
    if (std.fs.path.isAbsolute(meta_path)) {
        std.fs.accessAbsolute(meta_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
    } else {
        std.fs.cwd().access(meta_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
    }
    return true;
}

fn invalidUsage() !void {
    try usage(std.fs.File.stderr().deprecatedWriter());
    return error.InvalidArguments;
}

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage:
        \\  zindeks index [repo] [--store-root dir] [--index-dir dir]
        \\  zindeks search <query> [repo] [--store-root dir] [--index-dir dir]
        \\  zindeks serve [repo] [--store-root dir] [--index-dir dir]
        \\  zindeks update [--version tag|latest] [--repo owner/repo] [--dir install-dir] [--no-path-update] [--dry-run]
        \\
        \\default index store:
        \\  OS cache dir / zindeks / projects / <project-id> / segments / <segment-id>
        \\
    );
}
