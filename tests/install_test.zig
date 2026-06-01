//! Tests for the install subcommand: json_edit, adapters, and CLAUDE.md injection.

const std = @import("std");
const zindeks = @import("zindeks");
const je = zindeks.api.cli.install.json_edit;
const tmpl = zindeks.api.cli.install.templates;
const guardrails = zindeks.api.cli.install.guardrails;

// ── JSON-preserving edit tests ────────────────────────────────────────

test "inject preserves unrelated mcpServers entry" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(cfg_path);

    // Write initial JSON with a pre-existing entry.
    const initial =
        \\{
        \\  "mcpServers": {
        \\    "other": {
        \\      "command": "other-tool",
        \\      "args": ["run"]
        \\    }
        \\  }
        \\}
    ;
    try je.atomicWrite(allocator, cfg_path, initial);

    // Inject zindeks entry.
    try je.injectMcpEntry(allocator, cfg_path, .{ .stdio = "/usr/local/bin/zindeks" });

    // Read back and verify.
    const content = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    // Both entries must be present.
    const mcp = parsed.value.object.get("mcpServers") orelse return error.MissingMcpServers;
    try std.testing.expect(mcp.object.get("other") != null);
    try std.testing.expect(mcp.object.get("zindeks") != null);

    // zindeks entry must have correct command.
    const zindeks_entry = mcp.object.get("zindeks").?;
    const cmd = zindeks_entry.object.get("command").?;
    try std.testing.expectEqualStrings("/usr/local/bin/zindeks", cmd.string);
}

test "inject is idempotent — second run produces same result" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "mcp.json" });
    defer allocator.free(cfg_path);

    // First install.
    try je.injectMcpEntry(allocator, cfg_path, .{ .stdio = "/usr/bin/zindeks" });

    const first_run = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(first_run);

    // Second install — must produce identical zindeks entry.
    try je.injectMcpEntry(allocator, cfg_path, .{ .stdio = "/usr/bin/zindeks" });

    const second_run = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(second_run);

    // Parse both and compare the zindeks entry.
    var parsed1 = try std.json.parseFromSlice(std.json.Value, allocator, first_run, .{ .allocate = .alloc_always });
    defer parsed1.deinit();
    var parsed2 = try std.json.parseFromSlice(std.json.Value, allocator, second_run, .{ .allocate = .alloc_always });
    defer parsed2.deinit();

    const mcp1 = parsed1.value.object.get("mcpServers").?.object.get("zindeks").?;
    const mcp2 = parsed2.value.object.get("mcpServers").?.object.get("zindeks").?;
    try std.testing.expectEqualStrings(
        mcp1.object.get("command").?.string,
        mcp2.object.get("command").?.string,
    );
}

test "uninstall removes zindeks key and leaves siblings" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "mcp.json" });
    defer allocator.free(cfg_path);

    // Set up a file with two entries.
    const initial =
        \\{
        \\  "mcpServers": {
        \\    "sibling": {"command": "sibling-tool", "args": []},
        \\    "zindeks": {"command": "/usr/bin/zindeks", "args": ["serve"]}
        \\  }
        \\}
    ;
    try je.atomicWrite(allocator, cfg_path, initial);

    // Remove zindeks entry.
    try je.removeMcpEntry(allocator, cfg_path);

    const content = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const mcp = parsed.value.object.get("mcpServers") orelse return error.MissingMcpServers;
    // sibling must survive.
    try std.testing.expect(mcp.object.get("sibling") != null);
    // zindeks must be gone.
    try std.testing.expect(mcp.object.get("zindeks") == null);
}

test "CLAUDE.md block injection: adds then replaces on second run" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const md_path = try std.fs.path.join(allocator, &.{ dir_path, "CLAUDE.md" });
    defer allocator.free(md_path);

    // Start with some existing content.
    const initial_content = "# My Project\n\nSome existing docs.\n";
    try je.atomicWrite(allocator, md_path, initial_content);

    // Inject block helper.
    const injectBlock = struct {
        fn call(alloc: std.mem.Allocator, path: []const u8) !void {
            const existing = blk: {
                const f = try std.fs.openFileAbsolute(path, .{});
                defer f.close();
                break :blk try f.readToEndAlloc(alloc, 8 * 1024 * 1024);
            };
            defer alloc.free(existing);

            var new_content: std.ArrayList(u8) = .{};
            defer new_content.deinit(alloc);

            const begin = tmpl.begin_marker;
            const end_marker_str = tmpl.end_marker;

            const begin_pos = std.mem.indexOf(u8, existing, begin);
            const end_pos = if (begin_pos != null)
                std.mem.indexOf(u8, existing[begin_pos.?..], end_marker_str)
            else
                null;

            if (begin_pos != null and end_pos != null) {
                const block_start = begin_pos.?;
                const block_end = begin_pos.? + end_pos.? + end_marker_str.len;
                try new_content.appendSlice(alloc, existing[0..block_start]);
                try new_content.appendSlice(alloc, tmpl.claude_md_block);
                if (block_end < existing.len) {
                    try new_content.appendSlice(alloc, existing[block_end..]);
                }
            } else {
                try new_content.appendSlice(alloc, existing);
                if (new_content.items.len > 0 and new_content.items[new_content.items.len - 1] != '\n') {
                    try new_content.append(alloc, '\n');
                }
                try new_content.append(alloc, '\n');
                try new_content.appendSlice(alloc, tmpl.claude_md_block);
            }

            try je.atomicWrite(alloc, path, new_content.items);
        }
    }.call;

    // First injection.
    try injectBlock(allocator, md_path);

    const after_first = blk: {
        const f = try std.fs.openFileAbsolute(md_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(after_first);

    // Must contain the begin marker exactly once.
    const count1 = std.mem.count(u8, after_first, tmpl.begin_marker);
    try std.testing.expectEqual(@as(usize, 1), count1);

    // Original content must be preserved.
    try std.testing.expect(std.mem.indexOf(u8, after_first, "Some existing docs.") != null);

    // Second injection — must replace, not append.
    try injectBlock(allocator, md_path);

    const after_second = blk: {
        const f = try std.fs.openFileAbsolute(md_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(after_second);

    // Still exactly one begin marker.
    const count2 = std.mem.count(u8, after_second, tmpl.begin_marker);
    try std.testing.expectEqual(@as(usize, 1), count2);
}

test "hasComments correctly identifies JSONC" {
    try std.testing.expect(je.hasComments("{ // line comment\n}"));
    try std.testing.expect(je.hasComments("{ /* block */ }"));
    try std.testing.expect(!je.hasComments("{\"url\": \"https://x.com\"}"));
    try std.testing.expect(!je.hasComments("{}"));
}

test "managed guidance block appends then replaces without duplicating" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const md_path = try std.fs.path.join(allocator, &.{ dir_path, "AGENTS.md" });
    defer allocator.free(md_path);

    try je.atomicWrite(allocator, md_path, "# Existing\n\nKeep this.\n");

    try guardrails.injectManagedBlock(allocator, md_path, tmpl.agent_guidance_block);
    try guardrails.injectManagedBlock(allocator, md_path, tmpl.agent_guidance_block);

    const content = blk: {
        const f = try std.fs.openFileAbsolute(md_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Keep this.") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, tmpl.begin_marker));
    try std.testing.expect(std.mem.indexOf(u8, content, "Use zindeks first") != null);
}

test "cursor hook config preserves existing hook and is idempotent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const hooks_path = try std.fs.path.join(allocator, &.{ dir_path, "hooks.json" });
    defer allocator.free(hooks_path);

    const initial =
        \\{
        \\  "version": 1,
        \\  "hooks": {
        \\    "beforeShellExecution": [
        \\      {"command": ".cursor/hooks/existing.js"}
        \\    ]
        \\  }
        \\}
    ;
    try je.atomicWrite(allocator, hooks_path, initial);

    try guardrails.injectCursorHookConfig(allocator, hooks_path);
    try guardrails.injectCursorHookConfig(allocator, hooks_path);

    const content = blk: {
        const f = try std.fs.openFileAbsolute(hooks_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, ".cursor/hooks/existing.js") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, guardrails.cursor_hook_command));
}

test "claude hook config preserves permissions and is idempotent" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const settings_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(settings_path);

    const initial =
        \\{
        \\  "permissions": {
        \\    "allow": ["Bash(zig build *)"]
        \\  }
        \\}
    ;
    try je.atomicWrite(allocator, settings_path, initial);

    try guardrails.injectClaudeHookConfig(allocator, settings_path);
    try guardrails.injectClaudeHookConfig(allocator, settings_path);

    const content = blk: {
        const f = try std.fs.openFileAbsolute(settings_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "Bash(zig build *)") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "\"hooks\"") != null);
    // Must contain "hook --host claude" exactly once (idempotent).
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "hook --host claude"));
}

test "claude hook config: empty settings gets exactly 1 PreToolUse entry with correct matcher" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(cfg_path);

    // Start with empty object.
    try je.atomicWrite(allocator, cfg_path, "{}");

    // First call.
    try guardrails.injectClaudeHookConfig(allocator, cfg_path);

    const content1 = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content1);

    var parsed1 = try std.json.parseFromSlice(std.json.Value, allocator, content1, .{ .allocate = .alloc_always });
    defer parsed1.deinit();

    const hooks1 = parsed1.value.object.get("hooks") orelse return error.MissingHooks;
    const ptu1 = hooks1.object.get("PreToolUse") orelse return error.MissingPreToolUse;
    try std.testing.expectEqual(@as(usize, 1), ptu1.array.items.len);

    // Check matcher contains "Grep|Glob".
    const entry1 = ptu1.array.items[0];
    const matcher1 = entry1.object.get("matcher") orelse return error.MissingMatcher;
    try std.testing.expect(std.mem.indexOf(u8, matcher1.string, "Grep|Glob") != null);

    // Check nested hooks[0].command contains "hook --host claude".
    const inner_hooks1 = entry1.object.get("hooks") orelse return error.MissingInnerHooks;
    try std.testing.expectEqual(@as(usize, 1), inner_hooks1.array.items.len);
    const cmd1 = inner_hooks1.array.items[0].object.get("command") orelse return error.MissingCommand;
    try std.testing.expect(std.mem.indexOf(u8, cmd1.string, "hook --host claude") != null);

    // Second call — must remain idempotent (still exactly 1 entry).
    try guardrails.injectClaudeHookConfig(allocator, cfg_path);

    const content2 = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content2);

    var parsed2 = try std.json.parseFromSlice(std.json.Value, allocator, content2, .{ .allocate = .alloc_always });
    defer parsed2.deinit();

    const hooks2 = parsed2.value.object.get("hooks") orelse return error.MissingHooks;
    const ptu2 = hooks2.object.get("PreToolUse") orelse return error.MissingPreToolUse;
    try std.testing.expectEqual(@as(usize, 1), ptu2.array.items.len);
}

test "inject http transport writes type+url and omits command/args" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "mcp_http.json" });
    defer allocator.free(cfg_path);

    // Inject using HTTP transport.
    try je.injectMcpEntry(allocator, cfg_path, .{ .http = "http://127.0.0.1:7337/mcp" });

    const content = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const mcp = parsed.value.object.get("mcpServers") orelse return error.MissingMcpServers;
    const zindeks_entry = mcp.object.get("zindeks") orelse return error.MissingZindeksEntry;

    // Must have type="http".
    const type_val = zindeks_entry.object.get("type") orelse return error.MissingType;
    try std.testing.expectEqualStrings("http", type_val.string);

    // Must have correct url.
    const url_val = zindeks_entry.object.get("url") orelse return error.MissingUrl;
    try std.testing.expectEqualStrings("http://127.0.0.1:7337/mcp", url_val.string);

    // Must NOT have command or args.
    try std.testing.expect(zindeks_entry.object.get("command") == null);
    try std.testing.expect(zindeks_entry.object.get("args") == null);
}

test "claude hook config: migrates old Node-based enforce-zindeks-search entry" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir_path);

    const cfg_path = try std.fs.path.join(allocator, &.{ dir_path, "settings.json" });
    defer allocator.free(cfg_path);

    // Pre-seed with old Node-based hook entry.
    const initial =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {
        \\        "matcher": "Bash|Shell",
        \\        "hooks": [
        \\          {
        \\            "type": "command",
        \\            "command": "node .cursor/hooks/enforce-zindeks-search.js --host claude",
        \\            "timeout": 5
        \\          }
        \\        ]
        \\      }
        \\    ]
        \\  }
        \\}
    ;
    try je.atomicWrite(allocator, cfg_path, initial);

    // Run inject — should migrate: remove old, add new.
    try guardrails.injectClaudeHookConfig(allocator, cfg_path);

    const content = blk: {
        const f = try std.fs.openFileAbsolute(cfg_path, .{});
        defer f.close();
        break :blk try f.readToEndAlloc(allocator, 65536);
    };
    defer allocator.free(content);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const hooks = parsed.value.object.get("hooks") orelse return error.MissingHooks;
    const ptu = hooks.object.get("PreToolUse") orelse return error.MissingPreToolUse;

    // Old entry gone, exactly 1 new entry.
    try std.testing.expectEqual(@as(usize, 1), ptu.array.items.len);
    // Old Node command must be absent.
    try std.testing.expect(std.mem.indexOf(u8, content, "enforce-zindeks-search.js") == null);
    // New binary command must be present.
    try std.testing.expect(std.mem.indexOf(u8, content, "hook --host claude") != null);
}
