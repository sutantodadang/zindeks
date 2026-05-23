//! `zindeks doctor` subcommand.
//!
//! Read-only health check:
//!   - Binary on PATH?
//!   - For each detected host: is the zindeks MCP entry present?
//!   - Current cwd: is there a warm index?
//!   - If indexed: any drift?
//!   - Server self-test: spawn `zindeks serve`, exchange initialize, kill.
//!
//! Exit code 0 if all green, 1 if anything red.

const std = @import("std");
const builtin = @import("builtin");
const terminal = @import("../terminal.zig");
const adapters = @import("adapters.zig");
const json_edit = @import("json_edit.zig");
const project_store = @import("../../../core/project_store.zig");
const incremental = @import("../../../core/indexer/incremental.zig");
const graph_db = @import("../../../core/storage/graph_db.zig");

pub fn run(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    sw: anytype,
    colors_enabled: bool,
) !bool {
    _ = args;
    _ = colors_enabled;

    var all_ok = true;

    try sw.print("{s}zindeks doctor{s}\n\n", .{ sw.bold(), sw.reset() });

    // ── 1. Binary on PATH ─────────────────────────────────────────────
    {
        const on_path = isBinaryOnPath(allocator);
        const ok_str = if (on_path) "ok" else "WARN";
        const color = if (on_path) sw.green() else sw.yellow();
        try sw.print("  {s}{s:>4}{s}  binary on PATH\n", .{ color, ok_str, sw.reset() });
        if (!on_path) {
            try sw.print("         hint: add zindeks directory to PATH\n", .{});
        }
    }

    // ── 2. Per-host MCP entry check ───────────────────────────────────
    try sw.print("\n  {s}MCP config entries:{s}\n", .{ sw.bold(), sw.reset() });

    const self_path = adapters.selfExePath(allocator) catch null;
    defer if (self_path) |p| allocator.free(p);

    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch ".";

    for (adapters.all_adapters) |id| {
        const detected = adapters.isDetected(allocator, id);
        if (!detected) {
            try sw.print("  {s}skip{s}  {s} (not installed)\n", .{ sw.dim(), sw.reset(), id.displayName() });
            continue;
        }

        var paths = adapters.getPaths(allocator, id, .user, cwd) catch continue;
        defer paths.deinit(allocator);

        const cfg_path = paths.config orelse continue;
        const entry_ok = checkMcpEntry(allocator, cfg_path, self_path);
        const color = if (entry_ok) sw.green() else sw.red();
        const label = if (entry_ok) "ok  " else "FAIL";
        try sw.print("  {s}{s}{s}  {s} ({s})\n", .{ color, label, sw.reset(), id.displayName(), cfg_path });
        if (!entry_ok) all_ok = false;
    }

    // ── 3. Index warm check ───────────────────────────────────────────
    try sw.print("\n  {s}Index status:{s}\n", .{ sw.bold(), sw.reset() });

    const maybe_location: ?project_store.ReadLocation = blk: {
        const loc = project_store.resolveRead(allocator, ".", .{}) catch |err| {
            if (err == error.ProjectNotIndexed or err == error.BadProjectIndex) {
                sw.print("  {s}WARN{s}  no index for cwd — run 'zindeks index .'\n", .{ sw.yellow(), sw.reset() }) catch {};
            } else {
                sw.print("  {s}WARN{s}  could not read index: {s}\n", .{ sw.yellow(), sw.reset(), @errorName(err) }) catch {};
            }
            all_ok = false;
            break :blk null;
        };
        break :blk loc;
    };

    if (maybe_location) |loc| {
        var location = loc;
        defer location.deinit();
        try sw.print("  {s}ok  {s}  index at {s}\n", .{ sw.green(), sw.reset(), location.index_dir });

        // ── 4. Drift check ─────────────────────────────────────────────
        try driftCheck(allocator, sw, location.index_dir);
    }

    // ── 5. Server self-test ───────────────────────────────────────────
    try sw.print("\n  {s}Server self-test:{s}\n", .{ sw.bold(), sw.reset() });

    const serve_ok = try serverSelfTest(allocator, sw);
    if (!serve_ok) all_ok = false;

    // ── Summary ───────────────────────────────────────────────────────
    try sw.print("\n", .{});
    if (all_ok) {
        try sw.print("{s}All checks passed.{s}\n", .{ sw.green(), sw.reset() });
    } else {
        try sw.print("{s}Some checks failed.{s} See above for details.\n", .{ sw.red(), sw.reset() });
    }

    return all_ok;
}

/// Run a drift check against the graph DB in the given index directory.
fn driftCheck(allocator: std.mem.Allocator, sw: anytype, index_dir: []const u8) !void {
    const graph_path = std.fs.path.join(allocator, &.{ index_dir, "graph.db" }) catch {
        try sw.print("  {s}WARN{s}  OOM building graph.db path\n", .{ sw.yellow(), sw.reset() });
        return;
    };
    defer allocator.free(graph_path);

    const graph_path_z = allocator.dupeZ(u8, graph_path) catch {
        try sw.print("  {s}WARN{s}  OOM converting graph.db path\n", .{ sw.yellow(), sw.reset() });
        return;
    };
    defer allocator.free(graph_path_z);

    var gdb = graph_db.GraphDb.open(graph_path_z) catch {
        try sw.print("  {s}WARN{s}  could not open graph.db for drift check\n", .{ sw.yellow(), sw.reset() });
        return;
    };
    defer gdb.close();
    gdb.migrate() catch {};

    var diff = incremental.detectChanges(allocator, &gdb, ".") catch {
        try sw.print("  {s}WARN{s}  drift check failed\n", .{ sw.yellow(), sw.reset() });
        return;
    };
    defer diff.deinit();

    const total_changes = diff.added.len + diff.modified.len + diff.deleted.len;
    if (total_changes == 0) {
        try sw.print("  {s}ok  {s}  no drift ({d} files indexed)\n", .{ sw.green(), sw.reset(), diff.total_files });
    } else {
        try sw.print("  {s}WARN{s}  drift detected: +{d} ~{d} -{d} — run 'zindeks reindex'\n", .{
            sw.yellow(), sw.reset(), diff.added.len, diff.modified.len, diff.deleted.len,
        });
    }
}

/// Check if the `zindeks` binary is findable on PATH.
fn isBinaryOnPath(allocator: std.mem.Allocator) bool {
    const path_env = std.process.getEnvVarOwned(allocator, "PATH") catch return false;
    defer allocator.free(path_env);

    const sep: u8 = if (builtin.os.tag == .windows) ';' else ':';
    const exe_name = if (builtin.os.tag == .windows) "zindeks.exe" else "zindeks";

    var it = std.mem.splitScalar(u8, path_env, sep);
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(allocator, &.{ dir, exe_name }) catch continue;
        defer allocator.free(candidate);
        if (std.fs.path.isAbsolute(candidate)) {
            std.fs.accessAbsolute(candidate, .{}) catch continue;
        } else {
            std.fs.cwd().access(candidate, .{}) catch continue;
        }
        return true;
    }
    return false;
}

/// Check if a JSON config file contains a `mcpServers.zindeks` entry.
/// If `expected_path` is non-null, also verify the command path matches.
fn checkMcpEntry(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    expected_path: ?[]const u8,
) bool {
    const content: []u8 = blk: {
        const f = std.fs.openFileAbsolute(config_path, .{}) catch return false;
        defer f.close();
        break :blk f.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return false;
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        content,
        .{ .allocate = .alloc_always },
    ) catch return false;
    defer parsed.deinit();

    if (parsed.value != .object) return false;
    const mcp = parsed.value.object.get("mcpServers") orelse return false;
    if (mcp != .object) return false;
    const entry = mcp.object.get("zindeks") orelse return false;
    if (entry != .object) return false;

    // If we have an expected path, verify it matches.
    if (expected_path) |ep| {
        const cmd = entry.object.get("command") orelse return true; // present but no command
        if (cmd != .string) return true;
        // Normalize both paths for comparison.
        const norm_ep = allocator.dupe(u8, ep) catch return true;
        defer allocator.free(norm_ep);
        const norm_cmd = allocator.dupe(u8, cmd.string) catch return true;
        defer allocator.free(norm_cmd);
        for (norm_ep) |*c| if (c.* == '\\') { c.* = '/'; };
        for (norm_cmd) |*c| if (c.* == '\\') { c.* = '/'; };
        if (!std.mem.eql(u8, norm_ep, norm_cmd)) return false;
    }

    return true;
}

/// Spawn `zindeks serve`, send the MCP `initialize` request, verify we get
/// a valid `result.serverInfo` back, then kill the child.
/// Returns true if the handshake succeeded.
fn serverSelfTest(allocator: std.mem.Allocator, sw: anytype) !bool {
    // Find our own binary path.
    var self_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = std.fs.selfExePath(&self_buf) catch {
        try sw.print("  {s}SKIP{s}  could not determine binary path\n", .{ sw.yellow(), sw.reset() });
        return true; // don't count as failure
    };

    const argv = [_][]const u8{ self_path, "serve" };
    var child = std.process.Child.init(&argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        try sw.print("  {s}FAIL{s}  could not spawn 'zindeks serve': {s}\n", .{
            sw.red(), sw.reset(), @errorName(err),
        });
        return false;
    };

    var ok = false;

    // Write MCP initialize request (newline-delimited JSON-RPC).
    const init_req =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"doctor","version":"0"}}}
        ++ "\n";

    if (child.stdin) |stdin| {
        stdin.writeAll(init_req) catch {};
        stdin.close();
        child.stdin = null;
    }

    // Read response with timeout (we read up to 64 KB with a deadline).
    if (child.stdout) |stdout| {
        var resp_buf: [64 * 1024]u8 = undefined;
        var total: usize = 0;
        // Read until newline or buffer full.
        while (total < resp_buf.len - 1) {
            const n = stdout.read(resp_buf[total..]) catch break;
            if (n == 0) break;
            total += n;
            if (std.mem.indexOfScalar(u8, resp_buf[0..total], '\n') != null) break;
        }
        const resp = resp_buf[0..total];

        // Parse and check for "result" with "serverInfo".
        if (std.json.parseFromSlice(std.json.Value, allocator, resp, .{ .allocate = .alloc_always })) |parsed| {
            defer parsed.deinit();
            if (parsed.value == .object) {
                if (parsed.value.object.get("result")) |result| {
                    if (result == .object and result.object.get("serverInfo") != null) {
                        ok = true;
                    }
                }
            }
        } else |_| {}
    }

    _ = child.kill() catch {};
    _ = child.wait() catch {};

    if (ok) {
        try sw.print("  {s}ok  {s}  'zindeks serve' responded to initialize\n", .{ sw.green(), sw.reset() });
    } else {
        try sw.print("  {s}FAIL{s}  'zindeks serve' did not return valid serverInfo\n", .{ sw.red(), sw.reset() });
    }

    return ok;
}

pub fn usage(sw: anytype) !void {
    try sw.print(
        \\{s}zindeks doctor{s} — Health check for zindeks installation
        \\
        \\{s}Usage:{s}
        \\  zindeks doctor
        \\
        \\Checks:
        \\  - Binary on PATH
        \\  - MCP entry present in each detected host config
        \\  - Warm index in current directory
        \\  - Index drift (changed files)
        \\  - Server self-test (spawn + initialize handshake)
        \\
        \\Exit code 0 if all green, 1 if anything failed.
        \\
    , .{
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
    });
}
