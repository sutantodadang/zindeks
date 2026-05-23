const std = @import("std");
const builtin = @import("builtin");
const zindeks = @import("zindeks");

pub fn main() u8 {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = builtin.mode == .Debug }) = .{};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
    return mainErr(allocator) catch |err| {
        // CliError: the handler already printed a clean message; don't dump
        // a stack trace on top of it.  Other errors bubble through.
        if (err == error.CliError) return 1;
        std.debug.print("error: {s}\n", .{@errorName(err)});
        if (builtin.mode == .Debug) {
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        }
        return 1;
    };
}

fn mainErr(allocator: std.mem.Allocator) !u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    // Fast path: no subcommand provided
    if (args.len <= 1) {
        const stdout = std.fs.File.stdout().deprecatedWriter();
        try stdout.writeAll(
            \\zindeks — Local code knowledge graph engine
            \\
            \\Usage:
            \\  zindeks <command> [options]
            \\
            \\Commands:
            \\  index       Index a repository
            \\  search      Search indexed code (BM25)
            \\  serve       Start MCP JSON-RPC server
            \\  update      Update zindeks to latest version
            \\  completions Generate shell completions
            \\  help        Show full help
            \\
            \\Run 'zindeks help' for detailed usage.
            \\
        );
        return 0;
    }

    try zindeks.api.cli.cli.run(allocator, args);
    return 0;
}
