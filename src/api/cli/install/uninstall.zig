//! `zindeks uninstall` subcommand.
//!
//! Removes only the `zindeks` MCP entry from each host's config.
//! Removes the managed block from CLAUDE.md (claude-code project scope).
//!
//! Usage:
//!   zindeks uninstall [--host <id,...>] [--scope user|project|both]

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal.zig");
const adapters = @import("adapters.zig");
const json_edit = @import("json_edit.zig");
const tmpl = @import("templates.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    sw: anytype,
    colors_enabled: bool,
) !void {
    _ = colors_enabled;

    // ── Parse args ────────────────────────────────────────────────────
    var scope: adapters.Scope = .user;
    var selected_hosts_buf: [8]adapters.AdapterId = undefined;
    var selected_count: usize = 0;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |token| {
                const trimmed = std.mem.trim(u8, token, " \t");
                const id = adapters.AdapterId.fromStr(trimmed) orelse {
                    try sw.print("Unknown host '{s}'. Use --list-hosts to see options.\n", .{trimmed});
                    return error.InvalidArguments;
                };
                if (selected_count >= selected_hosts_buf.len) return error.InvalidArguments;
                selected_hosts_buf[selected_count] = id;
                selected_count += 1;
            }
        } else if (std.mem.eql(u8, a, "--scope")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, args[i], "user")) {
                scope = .user;
            } else if (std.mem.eql(u8, args[i], "project")) {
                scope = .project;
            } else if (std.mem.eql(u8, args[i], "both")) {
                scope = .both;
            } else {
                return error.InvalidArguments;
            }
        }
    }

    // ── Get cwd ───────────────────────────────────────────────────────
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    // ── Determine hosts ───────────────────────────────────────────────
    var final_hosts_buf: [8]adapters.AdapterId = undefined;
    var final_count: usize = 0;

    if (selected_count > 0) {
        @memcpy(final_hosts_buf[0..selected_count], selected_hosts_buf[0..selected_count]);
        final_count = selected_count;
    } else {
        // Default: all adapters
        for (adapters.all_adapters) |id| {
            if (final_count < final_hosts_buf.len) {
                final_hosts_buf[final_count] = id;
                final_count += 1;
            }
        }
    }

    // ── Uninstall each host ───────────────────────────────────────────
    var ok_count: usize = 0;
    var err_count: usize = 0;

    for (final_hosts_buf[0..final_count]) |id| {
        const result = uninstallHost(allocator, sw, id, scope, cwd);
        if (result) {
            ok_count += 1;
        } else |err| {
            err_count += 1;
            try sw.print("  {s}error{s}: {s} uninstall failed: {s}\n", .{
                sw.red(), sw.reset(), id.toStr(), @errorName(err),
            });
        }
    }

    try sw.print("\n", .{});
    if (err_count == 0) {
        try sw.print("{s}Done.{s} {d} host(s) cleaned.\n", .{ sw.green(), sw.reset(), ok_count });
    } else {
        try sw.print("{s}Done{s} with errors: {d} ok, {d} failed.\n", .{
            sw.yellow(), sw.reset(), ok_count, err_count,
        });
    }
}

fn uninstallHost(
    allocator: std.mem.Allocator,
    sw: anytype,
    id: adapters.AdapterId,
    scope: adapters.Scope,
    cwd: []const u8,
) !void {
    try sw.print("\n{s}{s}{s} ({s}):\n", .{ sw.bold(), id.displayName(), sw.reset(), id.toStr() });

    const do_user = (scope == .user or scope == .both);
    const do_project = (scope == .project or scope == .both) and adapters.supportsProjectScope(id);

    if (do_user) {
        var paths = try adapters.getPaths(allocator, id, .user, cwd);
        defer paths.deinit(allocator);

        if (paths.config) |cfg_path| {
            try sw.print("  removing from: {s}\n", .{cfg_path});
            json_edit.removeMcpEntry(allocator, cfg_path) catch |err| {
                if (err == error.JsoncNotSupported) {
                    try sw.print("  {s}skip{s}: file has JSON comments. Remove 'zindeks' key manually.\n", .{ sw.yellow(), sw.reset() });
                } else {
                    return err;
                }
            };
        }
    }

    if (do_project) {
        var paths = try adapters.getPaths(allocator, id, .project, cwd);
        defer paths.deinit(allocator);

        if (paths.config) |cfg_path| {
            try sw.print("  removing from: {s}\n", .{cfg_path});
            json_edit.removeMcpEntry(allocator, cfg_path) catch |err| {
                if (err == error.JsoncNotSupported) {
                    try sw.print("  {s}skip{s}: JSONC detected. Remove 'zindeks' key manually.\n", .{ sw.yellow(), sw.reset() });
                } else {
                    return err;
                }
            };
        }

        if (paths.claude_md) |md_path| {
            try sw.print("  removing CLAUDE.md block from: {s}\n", .{md_path});
            try removeClaudeMdBlock(allocator, md_path);
        }
    }
}

/// Remove the managed block (between markers) from CLAUDE.md.
/// If the file or block don't exist, this is a no-op.
fn removeClaudeMdBlock(allocator: std.mem.Allocator, md_path: []const u8) !void {
    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(md_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 8 * 1024 * 1024);
    };
    defer allocator.free(existing);

    const begin = tmpl.begin_marker;
    const end_marker = tmpl.end_marker;

    const begin_pos = std.mem.indexOf(u8, existing, begin) orelse return;
    const rest = existing[begin_pos..];
    const end_offset = std.mem.indexOf(u8, rest, end_marker) orelse return;
    const block_end = begin_pos + end_offset + end_marker.len;

    var new_content: std.ArrayList(u8) = .{};
    defer new_content.deinit(allocator);

    // Content before block (trim trailing blank line if present).
    var prefix = existing[0..begin_pos];
    // Strip one trailing blank line before the block.
    if (std.mem.endsWith(u8, prefix, "\n\n")) {
        prefix = prefix[0 .. prefix.len - 1];
    }
    try new_content.appendSlice(allocator, prefix);

    // Content after block.
    if (block_end < existing.len) {
        try new_content.appendSlice(allocator, existing[block_end..]);
    }

    try json_edit.atomicWrite(allocator, md_path, new_content.items);
}

pub fn usage(sw: anytype) !void {
    try sw.print(
        \\{s}zindeks uninstall{s} — Remove zindeks from AI host MCP configs
        \\
        \\{s}Usage:{s}
        \\  zindeks uninstall [--host <id,...>] [--scope user|project|both]
        \\
        \\{s}Options:{s}
        \\  --host <id,...>   Comma-separated host IDs (default: all)
        \\  --scope <scope>   user (default), project, or both
        \\
        \\{s}Examples:{s}
        \\  zindeks uninstall --host claude-code --scope both
        \\  zindeks uninstall --scope user
        \\
    , .{
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
    });
}
