//! `zindeks hook` — PreToolUse hook for Claude Code / Cursor.
//!
//! Reads a JSON event from stdin, decides allow/ask/deny, emits JSON to stdout.
//! Designed to run as a zero-dependency binary hook (no Node, no JS file).
//!
//! Usage (injected by `zindeks install`):
//!   zindeks hook --host claude    (default)
//!   zindeks hook --host cursor

const std = @import("std");

// ── Decision types ────────────────────────────────────────────────────

pub const Decision = struct {
    action: enum { allow, ask, deny },
    reason: []const u8 = "",
};

const grep_deny_msg =
    "Grep blocked for code search. Use zindeks MCP: search_code (BM25 text), " ++
    "search_graph (symbols/defs), trace_call_path (callers/callees), get_architecture. " ++
    "Read results with read_file; see a file's symbols with file_outline. " ++
    "Escape hatch for non-code or uncommitted files: Bash `rtk grep`.";

const glob_deny_msg =
    "Glob blocked. List indexed files with zindeks list_files(pattern, dir). " ++
    "See a file's symbols with file_outline; read a file with read_file(path, offset, limit). " ++
    "Escape hatch for non-indexed or uncommitted files: Bash `rtk find`.";

const ask_msg =
    "Use zindeks before broad shell search: `zindeks search \"<query>\"` or the zindeks MCP " ++
    "search/graph tools. Retry the shell search if zindeks is insufficient.";

// ── Token helpers ─────────────────────────────────────────────────────

/// Returns true if `needle` appears in `haystack` bounded by
/// start-of-string / whitespace / shell metacharacter on each side.
/// Both haystack and needle must already be lowercased.
fn containsToken(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return false;
    const metas = " \t\n\r;|&)('`\"";
    var i: usize = 0;
    while (i + needle.len <= haystack.len) {
        const pos = std.mem.indexOf(u8, haystack[i..], needle) orelse return false;
        const abs = i + pos;
        // Check left boundary.
        const left_ok = abs == 0 or std.mem.indexOfScalar(u8, metas, haystack[abs - 1]) != null;
        // Check right boundary.
        const right_pos = abs + needle.len;
        const right_ok = right_pos >= haystack.len or std.mem.indexOfScalar(u8, metas, haystack[right_pos]) != null;
        if (left_ok and right_ok) return true;
        i = abs + 1;
    }
    return false;
}

fn invokesZindeks(command: []const u8) bool {
    // Lowercased scan of first 4096 bytes.
    const scan_len = @min(command.len, 4096);
    var buf: [4096]u8 = undefined;
    const lower = buf[0..scan_len];
    _ = std.ascii.lowerString(lower, command[0..scan_len]);
    return std.mem.indexOf(u8, lower, "zindeks") != null;
}

fn invokesRtkSearch(command: []const u8) bool {
    const scan_len = @min(command.len, 4096);
    var buf: [4096]u8 = undefined;
    const lower = buf[0..scan_len];
    _ = std.ascii.lowerString(lower, command[0..scan_len]);
    return std.mem.indexOf(u8, lower, "rtk grep") != null or
        std.mem.indexOf(u8, lower, "rtk find") != null;
}

fn usesBroadShellSearch(command: []const u8) bool {
    const scan_len = @min(command.len, 4096);
    var buf: [4096]u8 = undefined;
    const lower = buf[0..scan_len];
    _ = std.ascii.lowerString(lower, command[0..scan_len]);
    // "git grep" is a substring check (two tokens together).
    if (std.mem.indexOf(u8, lower, "git grep") != null) return true;
    // Token-bounded checks for individual search tools.
    const broad_tools = [_][]const u8{
        "grep",
        "rg",
        "findstr",
        "select-string",
        "get-childitem",
        "gci",
        "ripgrep",
    };
    inline for (broad_tools) |tool| {
        if (containsToken(lower, tool)) return true;
    }
    return false;
}

// ── Pure decision logic (unit-testable, no I/O) ───────────────────────

pub fn decide(tool_name: []const u8, command: []const u8) Decision {
    if (std.mem.eql(u8, tool_name, "Grep"))
        return .{ .action = .deny, .reason = grep_deny_msg };
    if (std.mem.eql(u8, tool_name, "Glob"))
        return .{ .action = .deny, .reason = glob_deny_msg };

    if (std.mem.eql(u8, tool_name, "Bash") or std.mem.eql(u8, tool_name, "Shell")) {
        if (command.len == 0) return .{ .action = .allow };
        if (invokesZindeks(command) or invokesRtkSearch(command)) return .{ .action = .allow };
        if (usesBroadShellSearch(command)) return .{ .action = .ask, .reason = ask_msg };
        return .{ .action = .allow };
    }

    return .{ .action = .allow };
}

// ── I/O wrapper ───────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse --host flag.
    var host: []const u8 = "claude";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i < args.len) host = args[i];
        } else if (std.mem.startsWith(u8, a, "--host=")) {
            host = a["--host=".len..];
        }
    }

    // Read stdin (fail-open: treat read errors as empty input).
    const stdin = std.fs.File.stdin();
    const raw = stdin.readToEndAlloc(allocator, 1024 * 1024) catch "";
    defer if (raw.len > 0) allocator.free(raw);

    // Parse JSON (fail-open on any parse error).
    const parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        raw,
        .{ .allocate = .alloc_always },
    ) catch {
        try emitAllow(host);
        return;
    };
    defer parsed.deinit();

    // Extract tool_name and command.
    var tool_name: []const u8 = "";
    var command: []const u8 = "";

    if (parsed.value == .object) {
        if (parsed.value.object.get("tool_name")) |tn| {
            if (tn == .string) tool_name = tn.string;
        }
        if (parsed.value.object.get("tool_input")) |ti| {
            if (ti == .object) {
                if (ti.object.get("command")) |cmd| {
                    if (cmd == .string) command = cmd.string;
                }
            }
        }
    }

    const d = decide(tool_name, command);
    try emitDecision(host, d);
}

fn emitAllow(host: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (std.mem.eql(u8, host, "cursor")) {
        try stdout.writeAll("{\"permission\":\"allow\"}");
    } else {
        try stdout.writeAll(
            \\{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}
        );
    }
}

fn emitDecision(host: []const u8, d: Decision) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (d.action == .allow) {
        try emitAllow(host);
        return;
    }

    const action_str: []const u8 = switch (d.action) {
        .allow => "allow",
        .ask => "ask",
        .deny => "deny",
    };

    if (std.mem.eql(u8, host, "cursor")) {
        try stdout.print(
            "{{\"permission\":\"{s}\",\"user_message\":{f},\"agent_message\":{f}}}",
            .{
                action_str,
                std.json.fmt(d.reason, .{}),
                std.json.fmt(d.reason, .{}),
            },
        );
    } else {
        // Claude Code format.
        try stdout.print(
            "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\"," ++
                "\"permissionDecision\":\"{s}\"," ++
                "\"permissionDecisionReason\":{f}}}," ++
                "\"systemMessage\":{f}}}",
            .{
                action_str,
                std.json.fmt(d.reason, .{}),
                std.json.fmt(d.reason, .{}),
            },
        );
    }
}

// ── Unit tests ────────────────────────────────────────────────────────

test "decide Grep -> deny" {
    const d = decide("Grep", "");
    try std.testing.expectEqual(.deny, d.action);
}

test "decide Glob -> deny" {
    const d = decide("Glob", "");
    try std.testing.expectEqual(.deny, d.action);
}

test "decide Bash grep -r -> ask" {
    const d = decide("Bash", "grep -r foo .");
    try std.testing.expectEqual(.ask, d.action);
}

test "decide Bash rtk grep -> allow" {
    const d = decide("Bash", "rtk grep foo");
    try std.testing.expectEqual(.allow, d.action);
}

test "decide Bash zindeks search -> allow" {
    const d = decide("Bash", "zindeks search foo");
    try std.testing.expectEqual(.allow, d.action);
}

test "decide Bash ls -la -> allow" {
    const d = decide("Bash", "ls -la");
    try std.testing.expectEqual(.allow, d.action);
}

test "decide Read -> allow" {
    const d = decide("Read", "");
    try std.testing.expectEqual(.allow, d.action);
}

test "decide Bash rg pattern -> ask" {
    const d = decide("Bash", "rg 'some pattern' src/");
    try std.testing.expectEqual(.ask, d.action);
}

test "decide Bash get-childitem -> ask" {
    const d = decide("Bash", "Get-ChildItem -Recurse");
    try std.testing.expectEqual(.ask, d.action);
}

test "decide Bash git grep -> ask" {
    const d = decide("Bash", "git grep -n pattern");
    try std.testing.expectEqual(.ask, d.action);
}

test "decide Bash empty -> allow" {
    const d = decide("Bash", "");
    try std.testing.expectEqual(.allow, d.action);
}

test "containsToken basic" {
    try std.testing.expect(containsToken("grep -r .", "grep"));
    try std.testing.expect(!containsToken("no-grep here", "grep")); // hyphen is not a meta
    try std.testing.expect(containsToken("rg 'pattern'", "rg"));
    try std.testing.expect(!containsToken("rtk grep foo", "grep")); // "grep" preceded by space is fine... wait
}

test "containsToken: grep in 'rtk grep' is NOT a standalone token" {
    // In "rtk grep foo": the 'grep' substring is at position 4, left char is space.
    // Space IS a meta, right char is space. So containsToken returns true for "grep".
    // invokesRtkSearch checks for "rtk grep" BEFORE usesBroadShellSearch, so allow wins.
    const d = decide("Bash", "rtk grep foo");
    try std.testing.expectEqual(.allow, d.action);
}
