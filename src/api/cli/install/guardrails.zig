//! Project-level AI agent guardrails installed by `zindeks install`.

const std = @import("std");
const adapters = @import("adapters.zig");
const json_edit = @import("json_edit.zig");
const tmpl = @import("templates.zig");

pub const cursor_hook_command = "node .cursor/hooks/enforce-zindeks-search.js --host cursor";

pub const kiro_hook_command = "node .kiro/hooks/enforce-zindeks-search.js --host kiro";

const cursor_hook_matcher =
    "rg|grep|git\\s+grep|findstr|Select-String|Get-ChildItem|\\bgci\\b|\\bdir\\s+/s";

/// Install project guardrails for a selected host. All writes are idempotent.
pub fn installForHost(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    id: adapters.AdapterId,
    config_path: ?[]const u8,
) !void {
    try installGenericGuidance(allocator, cwd);

    switch (id) {
        .claude_code => {
            try writeSharedGuardScript(allocator, cwd);
            if (config_path) |path| {
                try injectClaudeHookConfig(allocator, path);
                try injectClaudeUserPromptHookConfig(allocator, path);
            }
        },
        .cursor => {
            try writeSharedGuardScript(allocator, cwd);
            try writeCursorRule(allocator, cwd);
            try installCursorHook(allocator, cwd);
        },
        .vscode => try installCopilotGuidance(allocator, cwd),
        .kiro => try installKiroHook(allocator, cwd),
        // Windsurf and Antigravity have no shell pre-tool hook contract we can
        // wire a blocking guard into; they rely on the generic AGENTS.md
        // guidance written above.
        .windsurf, .antigravity => {},
    }
}

pub fn installGenericGuidance(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, "AGENTS.md" });
    defer allocator.free(path);
    try injectManagedBlock(allocator, path, tmpl.agent_guidance_block);
}

pub fn installCopilotGuidance(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, ".github", "copilot-instructions.md" });
    defer allocator.free(path);
    try injectManagedBlock(allocator, path, tmpl.copilot_guidance_block);
}

pub fn writeCursorRule(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, ".cursor", "rules", "zindeks-first.mdc" });
    defer allocator.free(path);
    try json_edit.atomicWrite(allocator, path, tmpl.cursor_rule_mdc);
}

pub fn writeSharedGuardScript(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, ".cursor", "hooks", "enforce-zindeks-search.js" });
    defer allocator.free(path);
    try json_edit.atomicWrite(allocator, path, tmpl.enforce_zindeks_search_js);
}

pub fn installCursorHook(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ cwd, ".cursor", "hooks.json" });
    defer allocator.free(path);
    try injectCursorHookConfig(allocator, path);
}

/// Install the Kiro guard: stage the shared script under .kiro/hooks/ and inject
/// a preToolUse hook into every workspace agent config (.kiro/agents/*.json).
/// Kiro hooks are per-agent, so there is no single config to register; if no
/// workspace agents exist yet the script is staged for when one is added.
pub fn installKiroHook(allocator: std.mem.Allocator, cwd: []const u8) !void {
    const script = try std.fs.path.join(allocator, &.{ cwd, ".kiro", "hooks", "enforce-zindeks-search.js" });
    defer allocator.free(script);
    try json_edit.atomicWrite(allocator, script, tmpl.enforce_zindeks_search_js);

    const agents_dir = try std.fs.path.join(allocator, &.{ cwd, ".kiro", "agents" });
    defer allocator.free(agents_dir);
    var dir = std.fs.openDirAbsolute(agents_dir, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const agent_path = try std.fs.path.join(allocator, &.{ agents_dir, entry.name });
        defer allocator.free(agent_path);
        injectKiroAgentHook(allocator, agent_path) catch continue;
    }
}

/// Inject (idempotently) a shell-matching preToolUse hook into a Kiro agent config.
pub fn injectKiroAgentHook(allocator: std.mem.Allocator, path: []const u8) !void {
    var root = try readJsonObject(allocator, path);
    defer root.deinit();
    const aa = root.arena.allocator();

    const hooks = try ensureObjectField(aa, &root.value, "hooks");
    const pre = try ensureArrayField(aa, hooks, "preToolUse");
    if (!arrayContainsHookCommand(pre, kiro_hook_command)) {
        var hook = std.json.ObjectMap.init(aa);
        try hook.put("matcher", .{ .string = "shell" });
        try hook.put("command", .{ .string = kiro_hook_command });
        try pre.array.append(.{ .object = hook });
    }
    try writeJsonObject(allocator, aa, path, root.value);
}

/// Inject (or replace) a zindeks managed markdown block without touching other content.
pub fn injectManagedBlock(
    allocator: std.mem.Allocator,
    path: []const u8,
    block: []const u8,
) !void {
    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, ""),
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 8 * 1024 * 1024);
    };
    defer allocator.free(existing);

    var new_content: std.ArrayList(u8) = .{};
    defer new_content.deinit(allocator);

    const begin_pos = std.mem.indexOf(u8, existing, tmpl.begin_marker);
    const end_pos = if (begin_pos != null)
        std.mem.indexOf(u8, existing[begin_pos.?..], tmpl.end_marker)
    else
        null;

    if (begin_pos != null and end_pos != null) {
        const block_start = begin_pos.?;
        const block_end = begin_pos.? + end_pos.? + tmpl.end_marker.len;
        try new_content.appendSlice(allocator, existing[0..block_start]);
        try new_content.appendSlice(allocator, block);
        if (block_end < existing.len) {
            try new_content.appendSlice(allocator, existing[block_end..]);
        }
    } else {
        try new_content.appendSlice(allocator, existing);
        if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
            try new_content.append(allocator, '\n');
        }
        try new_content.append(allocator, '\n');
        try new_content.appendSlice(allocator, block);
    }

    try json_edit.atomicWrite(allocator, path, new_content.items);
}

pub fn injectCursorHookConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    var root = try readJsonObject(allocator, path);
    defer root.deinit();

    const aa = root.arena.allocator();
    if (root.value.object.getPtr("version") == null) {
        try root.value.object.put("version", .{ .integer = 1 });
    }

    const hooks = try ensureObjectField(aa, &root.value, "hooks");
    const before_shell = try ensureArrayField(aa, hooks, "beforeShellExecution");
    if (!arrayContainsHookCommand(before_shell, cursor_hook_command)) {
        var hook = std.json.ObjectMap.init(aa);
        try hook.put("command", .{ .string = cursor_hook_command });
        try hook.put("matcher", .{ .string = cursor_hook_matcher });
        try hook.put("failClosed", .{ .bool = true });
        try before_shell.array.append(.{ .object = hook });
    }

    try writeJsonObject(allocator, aa, path, root.value);
}

pub fn injectClaudeHookConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    var root = try readJsonObject(allocator, path);
    defer root.deinit();

    const aa = root.arena.allocator();

    // Resolve binary path and build the hook command string.
    const bin = try adapters.selfExePath(aa);
    const needs_quotes = std.mem.indexOfScalar(u8, bin, ' ') != null;
    const q: []const u8 = if (needs_quotes) "\"" else "";
    const command = try std.fmt.allocPrint(aa, "{s}{s}{s} hook --host claude", .{ q, bin, q });

    const hooks = try ensureObjectField(aa, &root.value, "hooks");
    const pre_tool_use = try ensureArrayField(aa, hooks, "PreToolUse");

    // MIGRATE/IDEMPOTENT: remove any pre-existing zindeks-managed entries
    // (old Node-based hooks or previous binary hooks) before appending.
    var filtered = std.json.Array.init(aa);
    for (pre_tool_use.array.items) |entry| {
        if (nestedHookCommandContains(entry, "zindeks") or
            nestedHookCommandContains(entry, "enforce-zindeks-search"))
        {
            continue; // drop old zindeks hook entry
        }
        try filtered.append(entry);
    }
    pre_tool_use.array = filtered;

    // Append the new binary-based entry.
    var command_hook = std.json.ObjectMap.init(aa);
    try command_hook.put("type", .{ .string = "command" });
    try command_hook.put("command", .{ .string = command });
    try command_hook.put("timeout", .{ .integer = 5 });

    var inner_hooks = std.json.Array.init(aa);
    try inner_hooks.append(.{ .object = command_hook });

    var pre_hook = std.json.ObjectMap.init(aa);
    try pre_hook.put("matcher", .{ .string = "Grep|Glob|Bash" });
    try pre_hook.put("hooks", .{ .array = inner_hooks });
    try pre_tool_use.array.append(.{ .object = pre_hook });

    try writeJsonObject(allocator, aa, path, root.value);
}

pub fn injectClaudeUserPromptHookConfig(allocator: std.mem.Allocator, path: []const u8) !void {
    var root = try readJsonObject(allocator, path);
    defer root.deinit();

    const aa = root.arena.allocator();

    // Resolve binary path and build the hook command string (same quoting logic
    // as injectClaudeHookConfig).
    const bin = try adapters.selfExePath(aa);
    const needs_quotes = std.mem.indexOfScalar(u8, bin, ' ') != null;
    const q: []const u8 = if (needs_quotes) "\"" else "";
    const command = try std.fmt.allocPrint(aa, "{s}{s}{s} hook --event userpromptsubmit --host claude", .{ q, bin, q });

    const hooks = try ensureObjectField(aa, &root.value, "hooks");
    const user_prompt_submit = try ensureArrayField(aa, hooks, "UserPromptSubmit");

    // IDEMPOTENT: remove stale zindeks-managed entries before appending.
    var filtered = std.json.Array.init(aa);
    for (user_prompt_submit.array.items) |entry| {
        if (nestedHookCommandContains(entry, "zindeks")) {
            continue; // drop old zindeks entry
        }
        try filtered.append(entry);
    }
    user_prompt_submit.array = filtered;

    // Check idempotency: don't double-add if already present.
    var already_present = false;
    for (user_prompt_submit.array.items) |entry| {
        if (nestedHookCommandContains(entry, command)) {
            already_present = true;
            break;
        }
    }
    if (already_present) {
        try writeJsonObject(allocator, aa, path, root.value);
        return;
    }

    // Append the new entry. UserPromptSubmit entries have NO matcher field.
    var command_hook = std.json.ObjectMap.init(aa);
    try command_hook.put("type", .{ .string = "command" });
    try command_hook.put("command", .{ .string = command });
    try command_hook.put("timeout", .{ .integer = 10 });

    var inner_hooks = std.json.Array.init(aa);
    try inner_hooks.append(.{ .object = command_hook });

    var ups_hook = std.json.ObjectMap.init(aa);
    try ups_hook.put("hooks", .{ .array = inner_hooks });
    try user_prompt_submit.array.append(.{ .object = ups_hook });

    try writeJsonObject(allocator, aa, path, root.value);
}

/// Returns true if the nested hooks[].command of `entry` contains `needle`.
fn nestedHookCommandContains(entry: std.json.Value, needle: []const u8) bool {
    if (entry != .object) return false;
    const hooks_val = entry.object.get("hooks") orelse return false;
    if (hooks_val != .array) return false;
    for (hooks_val.array.items) |hook| {
        if (hook != .object) continue;
        const cmd_val = hook.object.get("command") orelse continue;
        if (cmd_val != .string) continue;
        if (std.mem.indexOf(u8, cmd_val.string, needle) != null) return true;
    }
    return false;
}

/// ArenaAllocator is heap-allocated so its address is stable when JsonRoot
/// is returned by value.  The ObjectMaps inside `value` store the arena's
/// `Allocator` (which has a pointer to the arena struct), so the arena must
/// not move after those ObjectMaps are created.
const JsonRoot = struct {
    /// Heap-allocated so the address is stable; caller must call arena.deinit()
    /// then free this pointer via the original allocator.
    arena: *std.heap.ArenaAllocator,
    _alloc: std.mem.Allocator, // original allocator used to create `arena`
    value: std.json.Value,

    pub fn deinit(self: *JsonRoot) void {
        self.arena.deinit();
        self._alloc.destroy(self.arena);
    }
};

fn readJsonObject(allocator: std.mem.Allocator, path: []const u8) !JsonRoot {
    // Heap-allocate the arena so its address is stable when JsonRoot is
    // returned by value.  ObjectMaps store an Allocator whose ptr points to
    // this arena; if the arena were on the stack it would become dangling
    // after the return.
    const arena = try allocator.create(std.heap.ArenaAllocator);
    errdefer allocator.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const existing: []u8 = blk: {
        const f = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try aa.dupe(u8, "{}"),
            else => return err,
        };
        defer f.close();
        break :blk try f.readToEndAlloc(aa, 4 * 1024 * 1024);
    };

    if (json_edit.hasComments(existing)) return error.JsoncNotSupported;

    var value: std.json.Value = std.json.parseFromSliceLeaky(
        std.json.Value,
        aa,
        existing,
        .{ .allocate = .alloc_always },
    ) catch .{ .object = std.json.ObjectMap.init(aa) };

    if (value != .object) {
        value = .{ .object = std.json.ObjectMap.init(aa) };
    }

    return .{ .arena = arena, ._alloc = allocator, .value = value };
}

fn writeJsonObject(
    allocator: std.mem.Allocator,
    arena_allocator: std.mem.Allocator,
    path: []const u8,
    value: std.json.Value,
) !void {
    var buf: std.ArrayList(u8) = .{};
    try buf.writer(arena_allocator).print("{f}", .{std.json.fmt(value, .{ .whitespace = .indent_2 })});
    try buf.append(arena_allocator, '\n');
    try json_edit.atomicWrite(allocator, path, buf.items);
}

fn ensureObjectField(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    key: []const u8,
) !*std.json.Value {
    if (value.object.getPtr(key) == null) {
        try value.object.put(key, .{ .object = std.json.ObjectMap.init(allocator) });
    }
    const child = value.object.getPtr(key).?;
    if (child.* != .object) {
        child.* = .{ .object = std.json.ObjectMap.init(allocator) };
    }
    return child;
}

fn ensureArrayField(
    allocator: std.mem.Allocator,
    value: *std.json.Value,
    key: []const u8,
) !*std.json.Value {
    if (value.object.getPtr(key) == null) {
        try value.object.put(key, .{ .array = std.json.Array.init(allocator) });
    }
    const child = value.object.getPtr(key).?;
    if (child.* != .array) {
        child.* = .{ .array = std.json.Array.init(allocator) };
    }
    return child;
}

fn arrayContainsHookCommand(array_value: *const std.json.Value, command: []const u8) bool {
    if (array_value.* != .array) return false;
    for (array_value.array.items) |item| {
        if (item != .object) continue;
        const command_value = item.object.get("command") orelse continue;
        if (command_value == .string and std.mem.eql(u8, command_value.string, command)) return true;
    }
    return false;
}
