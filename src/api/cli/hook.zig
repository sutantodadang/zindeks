//! `zindeks hook` — PreToolUse and UserPromptSubmit hook for Claude Code / Cursor.
//!
//! Reads a JSON event from stdin, decides allow/ask/deny (PreToolUse) or injects
//! an attention map (UserPromptSubmit), emits JSON to stdout.
//! Designed to run as a zero-dependency binary hook (no Node, no JS file).
//!
//! Usage (injected by `zindeks install`):
//!   zindeks hook --host claude              (default, PreToolUse)
//!   zindeks hook --event userpromptsubmit   (UserPromptSubmit attention map)
//!   zindeks hook --host cursor

const std = @import("std");
const project_store = @import("../../core/project_store.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
const attention = @import("../../core/ai/attention.zig");

// ── Decision types ────────────────────────────────────────────────────

pub const Decision = struct {
    action: enum { allow, ask, deny },
    reason: []const u8 = "",
};

const grep_deny_msg =
    "Grep blocked for code search. Use zindeks MCP: search (BM25/hybrid/semantic), " ++
    "search_graph (symbols/defs), trace_call_path (callers/callees), get_architecture. " ++
    "Read results with read_file; see a file's symbols with file_outline. " ++
    "Escape hatch for non-code or uncommitted files: Bash `rtk grep`.";

const glob_deny_msg =
    "Glob blocked. List indexed files with zindeks list_files(pattern, dir). " ++
    "See a file's symbols with file_outline; read a file with read_file(path, offset, limit). " ++
    "Escape hatch for non-indexed or uncommitted files: Bash `rtk find`.";

// Advisory nudge for broad Bash search. Emitted as a NON-blocking `allow`
// (with additionalContext), not `ask` — `ask` would override Claude Code's
// auto-accept mode and force a confirmation prompt on every broad shell
// search. The Grep/Glob *tools* stay hard-denied; raw shell search is only
// nudged, never blocked.
const advise_msg =
    "Tip: zindeks is faster for code search — `zindeks search \"<query>\"` or the zindeks MCP " ++
    "search/graph tools. This shell search was allowed; prefer zindeks when the project is indexed.";

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
        // Broad shell search is ALLOWED with an advisory nudge — never `ask`,
        // so auto-accept mode is not interrupted by a confirmation prompt.
        if (usesBroadShellSearch(command)) return .{ .action = .allow, .reason = advise_msg };
        return .{ .action = .allow };
    }

    return .{ .action = .allow };
}

// ── I/O wrapper ───────────────────────────────────────────────────────

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse --host and --event flags.
    var host: []const u8 = "claude";
    var explicit_event: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host")) {
            i += 1;
            if (i < args.len) host = args[i];
        } else if (std.mem.startsWith(u8, a, "--host=")) {
            host = a["--host=".len..];
        } else if (std.mem.eql(u8, a, "--event")) {
            i += 1;
            if (i < args.len) explicit_event = args[i];
        } else if (std.mem.startsWith(u8, a, "--event=")) {
            explicit_event = a["--event=".len..];
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

    // Determine effective event: explicit --event > hook_event_name JSON field > "pretooluse".
    var effective_event_buf: [64]u8 = undefined;
    const effective_event: []const u8 = blk: {
        if (explicit_event) |e| {
            const lower = std.ascii.lowerString(effective_event_buf[0..@min(e.len, 64)], e[0..@min(e.len, 64)]);
            break :blk lower;
        }
        if (parsed.value == .object) {
            if (parsed.value.object.get("hook_event_name")) |hen| {
                if (hen == .string and hen.string.len <= 64) {
                    const lower = std.ascii.lowerString(effective_event_buf[0..hen.string.len], hen.string);
                    break :blk lower;
                }
            }
        }
        break :blk "pretooluse";
    };

    // Route to UserPromptSubmit handler if applicable.
    if (std.mem.eql(u8, effective_event, "userpromptsubmit")) {
        runUserPromptSubmit(allocator, host, parsed.value) catch {
            // Last-resort fail-open: if our handler itself errors, emit empty context.
            const stdout = std.fs.File.stdout().deprecatedWriter();
            stdout.writeAll(
                \\{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":""}}
            ) catch {};
        };
        return;
    }

    // ── PreToolUse path (unchanged) ───────────────────────────────────
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

fn runUserPromptSubmit(allocator: std.mem.Allocator, host: []const u8, root_json: std.json.Value) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    // Fail-open emitter for early returns.
    const emitEmpty = struct {
        fn call(w: @TypeOf(stdout)) void {
            w.writeAll(
                \\{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":""}}
            ) catch {};
        }
    }.call;

    // Cursor has no UserPromptSubmit equivalent — no-op.
    if (std.mem.eql(u8, host, "cursor")) {
        try stdout.writeAll("{}");
        return;
    }

    // 1. Extract cwd from JSON; fall back to process cwd.
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd: []const u8 = blk: {
        if (root_json == .object) {
            if (root_json.object.get("cwd")) |cv| {
                if (cv == .string and cv.string.len > 0) break :blk cv.string;
            }
        }
        break :blk std.fs.cwd().realpath(".", &cwd_buf) catch ".";
    };

    // 2. Derive working set from git.
    const working_set = attention.gitWorkingSet(allocator, cwd) catch {
        emitEmpty(stdout);
        return;
    };
    defer {
        for (working_set) |p| allocator.free(p);
        allocator.free(working_set);
    }

    if (working_set.len == 0) {
        emitEmpty(stdout);
        return;
    }

    // 3. Load engine for cwd (fail-open if repo not indexed).
    var location = project_store.resolveRead(allocator, cwd, .{}) catch {
        emitEmpty(stdout);
        return;
    };
    defer location.deinit();

    var idx = storage.Index.open(allocator, std.fs.cwd(), location.index_dir) catch {
        emitEmpty(stdout);
        return;
    };
    defer idx.close();

    var engine = search.Engine.init(&idx);

    // 4. Score — fail-open to empty slice.
    var scored_owned: ?[]attention.Scored = null;
    defer if (scored_owned) |s| attention.freeScored(allocator, s);
    const scored: []attention.Scored = if (attention.score(allocator, &engine, working_set, "", 12)) |s| blk: {
        scored_owned = s;
        break :blk s;
    } else |_| &.{};

    // 5. Build additionalContext text.
    var ctx_buf = std.ArrayList(u8){};
    defer ctx_buf.deinit(allocator);

    if (scored.len > 0) {
        try ctx_buf.appendSlice(allocator,
            "Zindeks attention \u{2014} indexed files most relevant to current uncommitted changes " ++
                "(relevance 0..1). Prefer these when you need code context:\n",
        );
        for (scored) |s| {
            try ctx_buf.writer(allocator).print("  {s}  {d:.2}\n", .{ s.path, s.score });
        }
    }

    // 6. Emit UserPromptSubmit JSON.
    try stdout.print(
        "{{\"hookSpecificOutput\":{{\"hookEventName\":\"UserPromptSubmit\",\"additionalContext\":{f}}}}}",
        .{std.json.fmt(ctx_buf.items, .{})},
    );
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

/// Emit an `allow` decision that also carries a non-blocking advisory message.
/// On Claude Code the nudge goes in `additionalContext` (shown to the model,
/// no prompt); on Cursor it rides along as `agent_message` with `allow`.
fn emitAllowAdvisory(host: []const u8, reason: []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    if (std.mem.eql(u8, host, "cursor")) {
        try stdout.print(
            "{{\"permission\":\"allow\",\"agent_message\":{f}}}",
            .{std.json.fmt(reason, .{})},
        );
    } else {
        try stdout.print(
            "{{\"hookSpecificOutput\":{{\"hookEventName\":\"PreToolUse\"," ++
                "\"permissionDecision\":\"allow\"," ++
                "\"additionalContext\":{f}}}}}",
            .{std.json.fmt(reason, .{})},
        );
    }
}

fn emitDecision(host: []const u8, d: Decision) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (d.action == .allow) {
        // Plain allow when there's nothing to say; advisory allow (carries a
        // non-blocking nudge) when a reason is attached.  Either way the tool
        // runs without a confirmation prompt.
        if (d.reason.len == 0) {
            try emitAllow(host);
        } else {
            try emitAllowAdvisory(host, d.reason);
        }
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

test "decide Bash grep -r -> allow with advisory" {
    const d = decide("Bash", "grep -r foo .");
    try std.testing.expectEqual(.allow, d.action);
    try std.testing.expect(d.reason.len > 0); // advisory nudge attached, non-blocking
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

test "decide Bash rg pattern -> allow with advisory" {
    const d = decide("Bash", "rg 'some pattern' src/");
    try std.testing.expectEqual(.allow, d.action);
    try std.testing.expect(d.reason.len > 0);
}

test "decide Bash get-childitem -> allow with advisory" {
    const d = decide("Bash", "Get-ChildItem -Recurse");
    try std.testing.expectEqual(.allow, d.action);
    try std.testing.expect(d.reason.len > 0);
}

test "decide Bash git grep -> allow with advisory" {
    const d = decide("Bash", "git grep -n pattern");
    try std.testing.expectEqual(.allow, d.action);
    try std.testing.expect(d.reason.len > 0);
}

test "decide never returns ask (auto-accept must not be interrupted)" {
    // Broad search is advisory-allow, tools are deny — nothing returns ask.
    try std.testing.expect(decide("Bash", "grep -r x .").action != .ask);
    try std.testing.expect(decide("Bash", "rg x").action != .ask);
    try std.testing.expect(decide("Grep", "").action != .ask);
    try std.testing.expect(decide("Glob", "").action != .ask);
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
