const std = @import("std");
const indexer = @import("../../core/indexer/indexer.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
const mcp = @import("../mcp/server.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) return invalidUsage();
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        try usage(std.fs.File.stdout().deprecatedWriter());
        return;
    }
    if (std.mem.eql(u8, cmd, "index")) {
        const repo = if (args.len >= 3) args[2] else ".";
        const out = if (args.len >= 4) args[3] else ".zindeks";
        try indexer.indexPath(allocator, repo, out);
    } else if (std.mem.eql(u8, cmd, "search")) {
        if (args.len < 3) return invalidUsage();
        const index_path = if (args.len >= 4) args[3] else ".zindeks";
        var idx = try storage.Index.open(allocator, std.fs.cwd(), index_path);
        defer idx.close();
        var engine = search.Engine.init(&idx);
        var results = try engine.search(allocator, args[2], 10);
        defer results.deinit(allocator);
        const stdout = std.fs.File.stdout().deprecatedWriter();
        for (results.items) |item| {
            try stdout.print("{d:.3}\t{s}\t{s}\n", .{ item.score, item.path, item.snippet });
        }
    } else if (std.mem.eql(u8, cmd, "serve")) {
        const index_path = if (args.len >= 3) args[2] else ".zindeks";
        var idx = try storage.Index.open(allocator, std.fs.cwd(), index_path);
        defer idx.close();
        var engine = search.Engine.init(&idx);
        try mcp.serve(allocator, &engine);
    } else {
        return invalidUsage();
    }
}

fn invalidUsage() !void {
    try usage(std.fs.File.stderr().deprecatedWriter());
    return error.InvalidArguments;
}

fn usage(writer: anytype) !void {
    try writer.writeAll(
        \\usage:
        \\  zindeks index <repo> [index-dir]
        \\  zindeks search <query> [index-dir]
        \\  zindeks serve [index-dir]
        \\
    );
}
