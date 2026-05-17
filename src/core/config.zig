//! Configuration file support for zindeks.
//!
//! Loads/saves JSON config from XDG config path (or %APPDATA% on Windows).
//! CLI args override config values at runtime.

const std = @import("std");
const builtin = @import("builtin");

/// Persistent configuration loaded from ~/.config/zindeks/config.json
/// (or %APPDATA%\zindeks\config.json on Windows).
pub const Config = struct {
    /// Custom index store root (overrides OS cache default).
    store_root: ?[]const u8 = null,

    /// Explicit index directory for a specific repo.
    index_dir: ?[]const u8 = null,

    /// Default GitHub repo for update/self-upgrade.
    default_repo: []const u8 = "sutantodadang/zindeks",

    /// Enable ANSI color output.
    colors_enabled: bool = true,

    /// Default max search results.
    max_results: u32 = 10,

    /// Embedding model name for semantic search.
    embedding_model: []const u8 = "fasttext",

    /// Read config from a JSON file. Returns default Config if file doesn't exist.
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return Config{},
            else => return err,
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        defer allocator.free(content);

        var parsed = try std.json.parseFromSlice(Config, allocator, content, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        // Clone all string fields so they're owned by caller.
        var config = parsed.value;
        if (config.store_root) |v| {
            config.store_root = try allocator.dupe(u8, v);
        }
        if (config.index_dir) |v| {
            config.index_dir = try allocator.dupe(u8, v);
        }
        config.default_repo = try allocator.dupe(u8, config.default_repo);
        config.embedding_model = try allocator.dupe(u8, config.embedding_model);

        return config;
    }

    /// Write config to a JSON file. Creates parent directories if needed.
    pub fn save(config: Config, path: []const u8) !void {
        // Ensure parent directory exists
        if (std.fs.path.dirname(path)) |parent| {
            std.fs.cwd().makePath(parent) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var writer = file.deprecatedWriter();

        try writer.writeAll("{\n");

        if (config.store_root) |v| {
            try writer.print("  \"store_root\": {f},\n", .{std.json.fmt(v, .{})});
        } else {
            try writer.writeAll("  \"store_root\": null,\n");
        }

        if (config.index_dir) |v| {
            try writer.print("  \"index_dir\": {f},\n", .{std.json.fmt(v, .{})});
        } else {
            try writer.writeAll("  \"index_dir\": null,\n");
        }

        try writer.print("  \"default_repo\": {f},\n", .{std.json.fmt(config.default_repo, .{})});
        try writer.print("  \"colors_enabled\": {},\n", .{config.colors_enabled});
        try writer.print("  \"max_results\": {},\n", .{config.max_results});
        try writer.print("  \"embedding_model\": {f}\n", .{std.json.fmt(config.embedding_model, .{})});

        try writer.writeAll("}\n");
    }

    /// Deinitialize - free all owned strings.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.store_root) |v| allocator.free(v);
        if (self.index_dir) |v| allocator.free(v);
        // Only free if not pointing to default string literals (which are in read-only data)
        const default_repo_literal: []const u8 = "sutantodadang/zindeks";
        const default_model_literal: []const u8 = "fasttext";
        if (self.default_repo.ptr != default_repo_literal.ptr) allocator.free(self.default_repo);
        if (self.embedding_model.ptr != default_model_literal.ptr) allocator.free(self.embedding_model);
        self.* = undefined;
    }
};

/// Returns the platform-specific default config file path.
/// Unix: ~/.config/zindeks/config.json
/// Windows: %APPDATA%\zindeks\config.json
pub fn getDefaultPath(allocator: std.mem.Allocator) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const appdata = try std.process.getEnvVarOwned(allocator, "APPDATA");
        defer allocator.free(appdata);
        return std.fs.path.join(allocator, &.{ appdata, "zindeks", "config.json" });
    }

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "zindeks", "config.json" });
}

/// Minimal JSON string escaping - handles the characters we expect in paths and names.
fn escapeJson(s: []const u8) EscapeJson {
    return .{ .s = s };
}

const EscapeJson = struct {
    s: []const u8,

    pub fn format(self: EscapeJson, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        for (self.s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0x00...0x1F => try writer.print("\\u{d:0>4}", .{c}),
                else => try writer.writeByte(c),
            }
        }
    }
};

test "default config values" {
    const cfg = Config{};
    try std.testing.expect(cfg.store_root == null);
    try std.testing.expect(cfg.index_dir == null);
    try std.testing.expectEqualStrings("sutantodadang/zindeks", cfg.default_repo);
    try std.testing.expect(cfg.colors_enabled);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_results);
    try std.testing.expectEqualStrings("fasttext", cfg.embedding_model);
}

test "load/save roundtrip" {
    const allocator = std.testing.allocator;

    // Create temp dir
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const config_path = try std.fs.path.join(allocator, &.{ path, "config.json" });
    defer allocator.free(config_path);

    // Create and save config
    var cfg = Config{
        .store_root = try allocator.dupe(u8, "/tmp/test-store"),
        .index_dir = try allocator.dupe(u8, "/tmp/test-index"),
        .default_repo = try allocator.dupe(u8, "my/repo"),
        .colors_enabled = false,
        .max_results = 20,
        .embedding_model = try allocator.dupe(u8, "bert"),
    };

    try cfg.save(config_path);

    // Load back
    var loaded = try Config.load(allocator, config_path);
    defer loaded.deinit(allocator);

    try std.testing.expect(loaded.store_root != null);
    try std.testing.expectEqualStrings("/tmp/test-store", loaded.store_root.?);
    try std.testing.expect(loaded.index_dir != null);
    try std.testing.expectEqualStrings("/tmp/test-index", loaded.index_dir.?);
    try std.testing.expectEqualStrings("my/repo", loaded.default_repo);
    try std.testing.expect(!loaded.colors_enabled);
    try std.testing.expectEqual(@as(u32, 20), loaded.max_results);
    try std.testing.expectEqualStrings("bert", loaded.embedding_model);

    // Cleanup original
    cfg.deinit(allocator);
}

test "getDefaultPath returns non-empty string" {
    const allocator = std.testing.allocator;
    const path = try getDefaultPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, "config.json"));
}
