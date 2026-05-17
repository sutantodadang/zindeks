//! Tests for config module integration.
//! Note: unit tests for loading/saving/roundtripping live in src/core/config.zig.
//! These tests exercise the module through the public zindeks API.

const std = @import("std");
const zindeks = @import("zindeks");

test "config getDefaultPath returns non-empty string" {
    const allocator = std.testing.allocator;
    const path = try zindeks.config.getDefaultPath(allocator);
    defer allocator.free(path);

    try std.testing.expect(path.len > 0);
    try std.testing.expect(std.mem.endsWith(u8, path, "config.json"));
}

test "config default struct has correct values" {
    const cfg = zindeks.config.Config{};
    try std.testing.expect(cfg.store_root == null);
    try std.testing.expect(cfg.index_dir == null);
    try std.testing.expectEqualStrings("sutantodadang/zindeks", cfg.default_repo);
    try std.testing.expect(cfg.colors_enabled);
    try std.testing.expectEqual(@as(u32, 10), cfg.max_results);
    try std.testing.expectEqualStrings("fasttext", cfg.embedding_model);
}

test "config load/save roundtrip in temp dir" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const config_path = try std.fs.path.join(allocator, &.{ path, "config.json" });
    defer allocator.free(config_path);

    // Create a config with custom values
    var cfg = zindeks.config.Config{};
    cfg.store_root = try allocator.dupe(u8, "/tmp/store");
    cfg.index_dir = try allocator.dupe(u8, "/tmp/index");
    cfg.default_repo = try allocator.dupe(u8, "test/repo");
    cfg.colors_enabled = false;
    cfg.max_results = 50;
    cfg.embedding_model = try allocator.dupe(u8, "test-model");

    try cfg.save(config_path);

    // Load it back
    var loaded = try zindeks.config.Config.load(allocator, config_path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("/tmp/store", loaded.store_root.?);
    try std.testing.expectEqualStrings("/tmp/index", loaded.index_dir.?);
    try std.testing.expectEqualStrings("test/repo", loaded.default_repo);
    try std.testing.expect(!loaded.colors_enabled);
    try std.testing.expectEqual(@as(u32, 50), loaded.max_results);
    try std.testing.expectEqualStrings("test-model", loaded.embedding_model);

    cfg.deinit(allocator);
}

test "config load non-existent file returns defaults" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(path);

    const config_path = try std.fs.path.join(allocator, &.{ path, "nonexistent.json" });
    defer allocator.free(config_path);

    var loaded = try zindeks.config.Config.load(allocator, config_path);
    defer loaded.deinit(allocator);

    try std.testing.expect(loaded.store_root == null);
    try std.testing.expectEqualStrings("sutantodadang/zindeks", loaded.default_repo);
}
