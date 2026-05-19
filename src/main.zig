const std = @import("std");
const builtin = @import("builtin");
const zindeks = @import("zindeks");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{ .safety = builtin.mode == .Debug }) = .{};
    defer _ = gpa.deinit();
    const allocator = if (builtin.mode == .Debug) gpa.allocator() else std.heap.c_allocator;
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
        return;
    }

    try zindeks.api.cli.cli.run(allocator, args);
}
