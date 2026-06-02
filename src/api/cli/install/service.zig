//! Cross-platform "always-on" supervisor for `zindeks serve --http <port>`.
//!
//! `zindeks install --service` installs an OS-native supervisor that starts the
//! MCP HTTP server at login and restarts it on crash:
//!   * macOS   → launchd user agent (~/Library/LaunchAgents/com.zindeks.mcp.plist)
//!   * Linux   → systemd user unit  (~/.config/systemd/user/zindeks.service)
//!   * Windows → Scheduled Task at logon (schtasks, no admin)
//!
//! Honest limitation: nothing runs while the machine is asleep — OS sleep
//! suspends the process; the supervisor brings it back on wake / login / crash.

const std = @import("std");
const builtin = @import("builtin");

pub const DEFAULT_PORT: u16 = 7717;
const LABEL = "com.zindeks.mcp";
const TASK_NAME = "zindeks-mcp";
const UNIT_NAME = "zindeks.service";

/// Install + start the supervisor. `exe` = absolute zindeks binary path.
pub fn install(allocator: std.mem.Allocator, sw: anytype, exe: []const u8, port: u16, dry_run: bool) !void {
    try sw.print("\n{s}Service:{s} installing always-on MCP server (port {d})\n", .{ sw.bold(), sw.reset(), port });

    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});

    switch (builtin.os.tag) {
        .macos => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
                try sw.print("  {s}error{s}: HOME not set; cannot locate LaunchAgents.\n", .{ sw.red(), sw.reset() });
                return;
            };
            defer allocator.free(home);

            const dir = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents", .{home});
            defer allocator.free(dir);
            const plist_path = try std.fmt.allocPrint(allocator, "{s}/{s}.plist", .{ dir, LABEL });
            defer allocator.free(plist_path);
            const log_path = try std.fmt.allocPrint(allocator, "{s}/Library/Logs/zindeks.log", .{home});
            defer allocator.free(log_path);

            const plist = try std.fmt.allocPrint(allocator,
                \\<?xml version="1.0" encoding="UTF-8"?>
                \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                \\<plist version="1.0"><dict>
                \\  <key>Label</key><string>{s}</string>
                \\  <key>ProgramArguments</key><array><string>{s}</string><string>serve</string><string>--http</string><string>{s}</string></array>
                \\  <key>RunAtLoad</key><true/>
                \\  <key>KeepAlive</key><true/>
                \\  <key>StandardOutPath</key><string>{s}</string>
                \\  <key>StandardErrorPath</key><string>{s}</string>
                \\</dict></plist>
                \\
            , .{ LABEL, exe, port_str, log_path, log_path });
            defer allocator.free(plist);

            if (dry_run) {
                try sw.print("  [dry-run] would write {s}:\n{s}\n", .{ plist_path, plist });
            } else {
                writeFileAbs(dir, plist_path, plist) catch |err| {
                    try sw.print("  {s}error{s}: writing plist: {s}\n", .{ sw.red(), sw.reset(), @errorName(err) });
                    return;
                };
                try sw.print("  wrote {s}\n", .{plist_path});
            }
            runCmd(allocator, sw, &.{ "launchctl", "unload", plist_path }, dry_run); // ignore failure
            runCmd(allocator, sw, &.{ "launchctl", "load", "-w", plist_path }, dry_run);
        },
        .linux => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch {
                try sw.print("  {s}error{s}: HOME not set; cannot locate systemd user dir.\n", .{ sw.red(), sw.reset() });
                return;
            };
            defer allocator.free(home);

            const dir = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user", .{home});
            defer allocator.free(dir);
            const unit_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, UNIT_NAME });
            defer allocator.free(unit_path);

            const unit = try std.fmt.allocPrint(allocator,
                \\[Unit]
                \\Description=zindeks MCP server
                \\After=network.target
                \\
                \\[Service]
                \\ExecStart={s} serve --http {s}
                \\Restart=always
                \\RestartSec=2
                \\
                \\[Install]
                \\WantedBy=default.target
                \\
            , .{ exe, port_str });
            defer allocator.free(unit);

            if (dry_run) {
                try sw.print("  [dry-run] would write {s}:\n{s}\n", .{ unit_path, unit });
            } else {
                writeFileAbs(dir, unit_path, unit) catch |err| {
                    try sw.print("  {s}error{s}: writing unit: {s}\n", .{ sw.red(), sw.reset(), @errorName(err) });
                    return;
                };
                try sw.print("  wrote {s}\n", .{unit_path});
            }
            runCmd(allocator, sw, &.{ "systemctl", "--user", "daemon-reload" }, dry_run);
            runCmd(allocator, sw, &.{ "systemctl", "--user", "enable", "--now", UNIT_NAME }, dry_run);
            try sw.print("  tip: run `loginctl enable-linger $USER` to keep it running without an active login.\n", .{});
        },
        .windows => {
            // schtasks /TR must be a single string; quote the exe to survive spaces.
            const tr = try std.fmt.allocPrint(allocator, "\"{s}\" serve --http {s}", .{ exe, port_str });
            defer allocator.free(tr);
            runCmd(allocator, sw, &.{ "schtasks", "/Create", "/TN", TASK_NAME, "/TR", tr, "/SC", "ONLOGON", "/RL", "LIMITED", "/F" }, dry_run);
            runCmd(allocator, sw, &.{ "schtasks", "/Run", "/TN", TASK_NAME }, dry_run);
        },
        else => {
            try sw.print("  {s}error{s}: --service is not supported on this OS.\n", .{ sw.red(), sw.reset() });
            return;
        },
    }

    try sw.print(
        "  {s}done.{s} server → http://127.0.0.1:{d}/mcp\n" ++
            "  note: runs whenever the machine is awake; OS sleep suspends it (auto-resumes on wake).\n",
        .{ sw.green(), sw.reset(), port },
    );
}

/// Stop + remove the supervisor.
pub fn uninstall(allocator: std.mem.Allocator, sw: anytype, dry_run: bool) !void {
    try sw.print("\n{s}Service:{s} removing always-on MCP server\n", .{ sw.bold(), sw.reset() });
    switch (builtin.os.tag) {
        .macos => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
            defer allocator.free(home);
            const plist_path = try std.fmt.allocPrint(allocator, "{s}/Library/LaunchAgents/{s}.plist", .{ home, LABEL });
            defer allocator.free(plist_path);
            runCmd(allocator, sw, &.{ "launchctl", "unload", plist_path }, dry_run);
            if (!dry_run) std.fs.cwd().deleteFile(plist_path) catch {};
            try sw.print("  removed {s}\n", .{plist_path});
        },
        .linux => {
            const home = std.process.getEnvVarOwned(allocator, "HOME") catch return;
            defer allocator.free(home);
            const unit_path = try std.fmt.allocPrint(allocator, "{s}/.config/systemd/user/{s}", .{ home, UNIT_NAME });
            defer allocator.free(unit_path);
            runCmd(allocator, sw, &.{ "systemctl", "--user", "disable", "--now", UNIT_NAME }, dry_run);
            if (!dry_run) std.fs.cwd().deleteFile(unit_path) catch {};
            runCmd(allocator, sw, &.{ "systemctl", "--user", "daemon-reload" }, dry_run);
            try sw.print("  removed {s}\n", .{unit_path});
        },
        .windows => {
            runCmd(allocator, sw, &.{ "schtasks", "/Delete", "/TN", TASK_NAME, "/F" }, dry_run);
        },
        else => try sw.print("  {s}error{s}: --service is not supported on this OS.\n", .{ sw.red(), sw.reset() }),
    }
    try sw.print("  {s}done.{s}\n", .{ sw.green(), sw.reset() });
}

/// Create parent dir (recursive) + write `content` to an absolute file path.
fn writeFileAbs(dir: []const u8, path: []const u8, content: []const u8) !void {
    std.fs.cwd().makePath(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    var f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
}

/// Run an external command, non-fatally. On `dry_run`, only print it.
fn runCmd(allocator: std.mem.Allocator, sw: anytype, argv: []const []const u8, dry_run: bool) void {
    if (dry_run) {
        sw.print("  [dry-run] would run:", .{}) catch {};
        for (argv) |a| sw.print(" {s}", .{a}) catch {};
        sw.print("\n", .{}) catch {};
        return;
    }
    const res = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch |err| {
        sw.print("  {s}warn{s}: `{s}` failed to launch: {s}\n", .{ sw.yellow(), sw.reset(), argv[0], @errorName(err) }) catch {};
        return;
    };
    allocator.free(res.stdout);
    allocator.free(res.stderr);
}
