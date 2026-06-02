//! `zindeks install` subcommand.
//!
//! Wires zindeks into one or more AI host MCP configs.
//!
//! Usage:
//!   zindeks install [--host <id,...>] [--scope user|project|both]
//!                   [--yes] [--dry-run] [--list-hosts] [--http <port>]
//!
//! Default (no --host): auto-detect installed hosts, prompt interactively.
//! Non-interactive (no TTY, no --host): print instructions; do nothing.
//! --http <port>: register HTTP transport (http://127.0.0.1:<port>/mcp)
//!               instead of the default stdio command transport.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal.zig");
const adapters = @import("adapters.zig");
const guardrails = @import("guardrails.zig");
const json_edit = @import("json_edit.zig");
const tmpl = @import("templates.zig");
const service = @import("service.zig");

/// Run the install command.  `args` are the subcommand-level args
/// (after "install" has been stripped).
pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    sw: anytype,
    colors_enabled: bool,
) !void {
    _ = colors_enabled;

    // ── Parse args ────────────────────────────────────────────────────
    var list_hosts = false;
    var dry_run = false;
    var yes = false;
    var scope: adapters.Scope = .user;
    var selected_hosts_buf: [8]adapters.AdapterId = undefined;
    var selected_count: usize = 0;
    var http_port: ?u16 = null;
    var want_service = false;
    var want_uninstall_service = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--list-hosts")) {
            list_hosts = true;
        } else if (std.mem.eql(u8, a, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, a, "--yes") or std.mem.eql(u8, a, "-y")) {
            yes = true;
        } else if (std.mem.eql(u8, a, "--host")) {
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
        } else if (std.mem.eql(u8, a, "--http")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            http_port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidArguments;
        } else if (std.mem.eql(u8, a, "--service")) {
            want_service = true;
        } else if (std.mem.eql(u8, a, "--uninstall-service")) {
            want_uninstall_service = true;
        }
        // skip unknown flags (globals already consumed)
    }

    // ── --uninstall-service (standalone) ──────────────────────────────
    if (want_uninstall_service) {
        try service.uninstall(allocator, sw, dry_run);
        return;
    }

    // --service implies the HTTP transport so hosts connect to the daemon.
    if (want_service and http_port == null) http_port = service.DEFAULT_PORT;

    // ── --list-hosts ──────────────────────────────────────────────────
    if (list_hosts) {
        try sw.print("{s}Supported hosts:{s}\n\n", .{ sw.bold(), sw.reset() });
        for (adapters.all_adapters) |id| {
            const detected = adapters.isDetected(allocator, id);
            const marker: []const u8 = if (detected) "+" else "-";
            try sw.print("  [{s}] {s:<12}  {s}\n", .{ marker, id.toStr(), id.displayName() });
        }
        try sw.print("\n  [+] = detected on this machine\n", .{});
        return;
    }

    // ── Get binary path ────────────────────────────────────────────────
    const bin_path = adapters.selfExePath(allocator) catch {
        try sw.print("{s}error{s}: could not determine zindeks binary path.\n", .{ sw.red(), sw.reset() });
        return error.IoError;
    };
    defer allocator.free(bin_path);

    // ── Build MCP transport ───────────────────────────────────────────
    var http_url_buf: ?[]u8 = null;
    defer if (http_url_buf) |u| allocator.free(u);
    const transport: json_edit.McpTransport = if (http_port) |port| blk: {
        http_url_buf = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/mcp", .{port});
        break :blk .{ .http = http_url_buf.? };
    } else .{ .stdio = bin_path };

    // ── Get cwd ───────────────────────────────────────────────────────
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &cwd_buf);

    // ── Determine hosts to install ────────────────────────────────────
    var final_hosts_buf: [8]adapters.AdapterId = undefined;
    var final_count: usize = 0;

    if (selected_count > 0) {
        @memcpy(final_hosts_buf[0..selected_count], selected_hosts_buf[0..selected_count]);
        final_count = selected_count;
    } else {
        // Auto-detect installed hosts.
        for (adapters.all_adapters) |id| {
            if (adapters.isDetected(allocator, id)) {
                if (final_count < final_hosts_buf.len) {
                    final_hosts_buf[final_count] = id;
                    final_count += 1;
                }
            }
        }

        if (final_count == 0) {
            try sw.print("No AI hosts detected. Install one of: claude-code, cursor, vscode, windsurf, antigravity.\n", .{});
            try sw.print("Then run:  {s}zindeks install --host <id>{s}\n", .{ sw.bold(), sw.reset() });
            return;
        }

        // Interactive picker when not --yes and stdin is a TTY.
        if (!yes and isStdinTty()) {
            final_count = try interactivePicker(sw, final_hosts_buf[0..final_count], &final_hosts_buf);
        } else if (!yes) {
            // Non-interactive, no --host: print instructions only.
            try sw.print("Non-interactive mode. Specify hosts with --host or use --yes to accept all.\n", .{});
            try sw.print("Detected: ", .{});
            for (final_hosts_buf[0..final_count], 0..) |id, idx| {
                if (idx > 0) try sw.print(", ", .{});
                try sw.print("{s}", .{id.toStr()});
            }
            try sw.print("\n", .{});
            return;
        }
    }

    if (final_count == 0) {
        try sw.print("No hosts selected.\n", .{});
        return;
    }

    // ── Install each host ─────────────────────────────────────────────
    var ok_count: usize = 0;
    var err_count: usize = 0;

    for (final_hosts_buf[0..final_count]) |id| {
        installHost(allocator, sw, id, scope, cwd, transport, dry_run) catch |err| {
            err_count += 1;
            sw.print("  {s}error{s}: {s} install failed: {s}\n", .{
                sw.red(), sw.reset(), id.toStr(), @errorName(err),
            }) catch {};
            continue;
        };
        ok_count += 1;
    }

    try sw.print("\n", .{});
    if (err_count == 0) {
        try sw.print("{s}Done.{s} {d} host(s) configured.\n", .{ sw.green(), sw.reset(), ok_count });
    } else {
        try sw.print("{s}Done{s} with errors: {d} ok, {d} failed.\n", .{
            sw.yellow(), sw.reset(), ok_count, err_count,
        });
    }

    if (want_service) {
        service.install(allocator, sw, bin_path, http_port.?, dry_run) catch |err| {
            try sw.print("  {s}warn{s}: service install failed: {s}\n", .{ sw.yellow(), sw.reset(), @errorName(err) });
        };
    } else if (http_port) |port| {
        try sw.print("  NOTE: HTTP transport — start the daemon: zindeks serve --http {d}\n", .{port});
    }

    if (dry_run) {
        try sw.print("\n{s}[dry-run]{s} No files were written.\n", .{ sw.yellow(), sw.reset() });
    }
}

fn installHost(
    allocator: std.mem.Allocator,
    sw: anytype,
    id: adapters.AdapterId,
    scope: adapters.Scope,
    cwd: []const u8,
    transport: json_edit.McpTransport,
    dry_run: bool,
) !void {
    try sw.print("\n{s}{s}{s} ({s}):\n", .{ sw.bold(), id.displayName(), sw.reset(), id.toStr() });

    // Determine which scopes to write.
    const do_user = (scope == .user or scope == .both);
    const do_project = (scope == .project or scope == .both) and adapters.supportsProjectScope(id);

    if (do_user) {
        var paths = try adapters.getPaths(allocator, id, .user, cwd);
        defer paths.deinit(allocator);

        if (paths.config) |cfg_path| {
            try sw.print("  user config: {s}\n", .{cfg_path});
            if (!dry_run) {
                json_edit.injectMcpEntry(allocator, cfg_path, transport) catch |err| {
                    if (err == error.JsoncNotSupported) {
                        try sw.print("  {s}skip{s}: JSONC detected. Merge manually or use --dry-run.\n", .{ sw.yellow(), sw.reset() });
                    } else {
                        return err;
                    }
                };
                if (id == .claude_code) {
                    guardrails.injectClaudeHookConfig(allocator, cfg_path) catch |err| {
                        if (err == error.JsoncNotSupported) {
                            try sw.print("  {s}skip{s}: hook JSONC config detected. Merge manually.\n", .{ sw.yellow(), sw.reset() });
                        } else return err;
                    };
                    try sw.print("  enforcement hook: Grep/Glob -> zindeks (deny), shell grep -> advisory (non-blocking)\n", .{});
                }
            }
        }
    }

    if (do_project) {
        var paths = try adapters.getPaths(allocator, id, .project, cwd);
        defer paths.deinit(allocator);

        if (paths.config) |cfg_path| {
            try sw.print("  project config: {s}\n", .{cfg_path});
            if (!dry_run) {
                json_edit.injectMcpEntry(allocator, cfg_path, transport) catch |err| {
                    if (err == error.JsoncNotSupported) {
                        try sw.print("  {s}skip{s}: JSONC detected. Merge manually.\n", .{ sw.yellow(), sw.reset() });
                    } else {
                        return err;
                    }
                };
                guardrails.installForHost(allocator, cwd, id, cfg_path) catch |err| {
                    if (err == error.JsoncNotSupported) {
                        try sw.print("  {s}skip{s}: guardrail JSONC config detected. Merge manually.\n", .{ sw.yellow(), sw.reset() });
                    } else {
                        return err;
                    }
                };
            }
        }

        // CLAUDE.md block (claude-code only).
        if (paths.claude_md) |md_path| {
            try sw.print("  CLAUDE.md block: {s}\n", .{md_path});
            if (!dry_run) {
                try injectClaudeMdBlock(allocator, md_path);
            }
        }
    }
}

/// Inject (or replace) the managed block in CLAUDE.md.
fn injectClaudeMdBlock(allocator: std.mem.Allocator, md_path: []const u8) !void {
    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(md_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, ""),
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 8 * 1024 * 1024);
    };
    defer allocator.free(existing);

    var new_content: std.ArrayList(u8) = .{};
    defer new_content.deinit(allocator);

    const begin = tmpl.begin_marker;
    const end = tmpl.end_marker;

    const begin_pos = std.mem.indexOf(u8, existing, begin);
    const end_pos = if (begin_pos != null) std.mem.indexOf(u8, existing[begin_pos.?..], end) else null;

    if (begin_pos != null and end_pos != null) {
        // Replace existing block between markers.
        const block_start = begin_pos.?;
        const block_end = begin_pos.? + end_pos.? + end.len;
        try new_content.appendSlice(allocator, existing[0..block_start]);
        try new_content.appendSlice(allocator, tmpl.claude_md_block);
        if (block_end < existing.len) {
            try new_content.appendSlice(allocator, existing[block_end..]);
        }
    } else {
        // Append block at end.
        try new_content.appendSlice(allocator, existing);
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.append(allocator, '\n');
        try new_content.appendSlice(allocator, tmpl.claude_md_block);
    }

    try json_edit.atomicWrite(allocator, md_path, new_content.items);
}

/// Simple interactive host picker: lists hosts, reads "1,2,3" style input.
/// Returns the count of selected hosts written back into `buf`.
fn interactivePicker(
    sw: anytype,
    detected: []const adapters.AdapterId,
    buf: *[8]adapters.AdapterId,
) !usize {
    try sw.print("\n{s}Detected AI hosts:{s}\n", .{ sw.bold(), sw.reset() });
    for (detected, 1..) |id, num| {
        try sw.print("  {d}) {s} ({s})\n", .{ num, id.displayName(), id.toStr() });
    }
    try sw.print("\nSelect hosts (e.g. 1,2 or press Enter for all): ", .{});

    var line_buf: [256]u8 = undefined;
    const stdin = std.fs.File.stdin();
    const n = stdin.read(&line_buf) catch return detected.len;
    const line = std.mem.trim(u8, line_buf[0..n], " \t\r\n");

    if (line.len == 0) {
        // All selected.
        @memcpy(buf[0..detected.len], detected);
        return detected.len;
    }

    var count: usize = 0;
    var it = std.mem.splitScalar(u8, line, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        const num = std.fmt.parseInt(usize, trimmed, 10) catch continue;
        if (num < 1 or num > detected.len) continue;
        if (count < 8) {
            buf[count] = detected[num - 1];
            count += 1;
        }
    }

    return count;
}

/// Detect whether stdin is a TTY (interactive session).
fn isStdinTty() bool {
    if (builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const stdin_handle = windows.GetStdHandle(windows.STD_INPUT_HANDLE) catch return false;
        var mode: windows.DWORD = 0;
        return windows.kernel32.GetConsoleMode(stdin_handle, &mode) != 0;
    }
    return std.posix.isatty(std.posix.STDIN_FILENO);
}

pub fn usage(sw: anytype) !void {
    try sw.print(
        \\{s}zindeks install{s} — Wire zindeks into AI host MCP configs
        \\
        \\{s}Usage:{s}
        \\  zindeks install [--host <id,...>] [--scope user|project|both]
        \\                  [--yes] [--dry-run] [--http <port>] [--service]
        \\  zindeks install --list-hosts
        \\  zindeks install --uninstall-service
        \\
        \\{s}Options:{s}
        \\  --host <id,...>   Comma-separated host IDs (see --list-hosts)
        \\  --scope <scope>   user (default), project, or both
        \\  --yes             Skip interactive prompts (CI-safe)
        \\  --dry-run         Print changes without writing
        \\  --list-hosts      Show supported hosts and detection status
        \\  --http <port>     Register HTTP transport (http://127.0.0.1:<port>/mcp) instead of stdio
        \\  --service         Install an always-on OS supervisor running `serve --http`
        \\                    (launchd / systemd-user / Windows Scheduled Task; port 7717
        \\                    default; implies --http). Auto-starts at login, restarts on crash.
        \\  --uninstall-service  Stop and remove the supervisor installed by --service
        \\
        \\{s}Examples:{s}
        \\  zindeks install                                    # interactive
        \\  zindeks install --host claude-code --scope both --yes
        \\  zindeks install --host claude-code,cursor --yes
        \\  zindeks install --host claude-code --http 7337 --yes   # HTTP daemon transport
        \\  zindeks install --host claude-code --service --yes     # always-on (port 7717)
        \\
    , .{
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
    });
}
