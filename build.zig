const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Vendored C: SQLite 3 ────────────────────────────────────────
    const sqlite_mod = b.createModule(.{ .target = target, .optimize = optimize });
    sqlite_mod.addCSourceFiles(.{ .files = &.{"vendor/sqlite3/sqlite3.c"} });
    sqlite_mod.addIncludePath(b.path("vendor/sqlite3"));
    sqlite_mod.addCMacro("SQLITE_THREADSAFE", "0");
    sqlite_mod.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    sqlite_mod.addCMacro("SQLITE_ENABLE_FTS5", "1");
    const sqlite = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });
    sqlite.linkLibC();

    // ── Vendored C: tree-sitter core ────────────────────────────────
    const ts_mod = b.createModule(.{ .target = target, .optimize = optimize });
    ts_mod.addCSourceFiles(.{ .files = &.{"vendor/tree-sitter/src/lib.c"} });
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts_mod.addCMacro("TREE_SITTER_HIDE_SYMBOLS", "1");
    const ts = b.addLibrary(.{
        .linkage = .static,
        .name = "tree-sitter",
        .root_module = ts_mod,
    });
    ts.linkLibC();

    // ── Vendored C: Tree-sitter grammars ──────────────────────────────
    // Explicit paths for flexibility (some grammars live in monorepos).
    const GrammarSpec = struct {
        name: []const u8,       // library name (C fn: tree_sitter_<name>)
        parser: []const u8,     // path relative to vendor/grammars/
        scanner: ?[]const u8 = null,
        include: []const u8,    // include dir relative to vendor/grammars/
    };
    const grammar_specs = [_]GrammarSpec{
        .{ .name = "tree-sitter-c",           .parser = "tree-sitter-c/src/parser.c",           .include = "tree-sitter-c/src" },
        .{ .name = "tree-sitter-c-sharp",     .parser = "tree-sitter-c-sharp/src/parser.c",     .scanner = "tree-sitter-c-sharp/src/scanner.c", .include = "tree-sitter-c-sharp/src" },
        .{ .name = "tree-sitter-cpp",         .parser = "tree-sitter-cpp/src/parser.c",         .scanner = "tree-sitter-cpp/src/scanner.c",     .include = "tree-sitter-cpp/src" },
        .{ .name = "tree-sitter-css",         .parser = "tree-sitter-css/src/parser.c",         .scanner = "tree-sitter-css/src/scanner.c",     .include = "tree-sitter-css/src" },
        .{ .name = "tree-sitter-dart",        .parser = "tree-sitter-dart/src/parser.c",        .scanner = "tree-sitter-dart/src/scanner.c",    .include = "tree-sitter-dart/src" },
        .{ .name = "tree-sitter-elixir",      .parser = "tree-sitter-elixir/src/parser.c",      .scanner = "tree-sitter-elixir/src/scanner.c",  .include = "tree-sitter-elixir/src" },
        .{ .name = "tree-sitter-go",          .parser = "tree-sitter-go/src/parser.c",          .include = "tree-sitter-go/src" },
        .{ .name = "tree-sitter-haskell",     .parser = "tree-sitter-haskell/src/parser.c",     .scanner = "tree-sitter-haskell/src/scanner.c", .include = "tree-sitter-haskell/src" },
        .{ .name = "tree-sitter-java",        .parser = "tree-sitter-java/src/parser.c",        .include = "tree-sitter-java/src" },
        .{ .name = "tree-sitter-javascript",  .parser = "tree-sitter-javascript/src/parser.c",  .scanner = "tree-sitter-javascript/src/scanner.c", .include = "tree-sitter-javascript/src" },
        .{ .name = "tree-sitter-json",        .parser = "tree-sitter-json/src/parser.c",        .include = "tree-sitter-json/src" },
        .{ .name = "tree-sitter-lua",         .parser = "tree-sitter-lua/src/parser.c",         .scanner = "tree-sitter-lua/src/scanner.c",     .include = "tree-sitter-lua/src" },
        .{ .name = "tree-sitter-python",      .parser = "tree-sitter-python/src/parser.c",      .scanner = "tree-sitter-python/src/scanner.c",  .include = "tree-sitter-python/src" },
        .{ .name = "tree-sitter-rust",        .parser = "tree-sitter-rust/src/parser.c",        .scanner = "tree-sitter-rust/src/scanner.c",    .include = "tree-sitter-rust/src" },
        .{ .name = "tree-sitter-scala",       .parser = "tree-sitter-scala/src/parser.c",       .scanner = "tree-sitter-scala/src/scanner.c",   .include = "tree-sitter-scala/src" },
        .{ .name = "tree-sitter-swift",       .parser = "tree-sitter-swift/src/parser.c",       .include = "tree-sitter-swift/src" },
        .{ .name = "tree-sitter-toml",        .parser = "tree-sitter-toml/src/parser.c",        .scanner = "tree-sitter-toml/src/scanner.c",    .include = "tree-sitter-toml/src" },
        .{ .name = "tree-sitter-tsx",         .parser = "tree-sitter-typescript/tsx/src/parser.c", .scanner = "tree-sitter-typescript/tsx/src/scanner.c", .include = "tree-sitter-typescript/tsx/src" },
        .{ .name = "tree-sitter-typescript",  .parser = "tree-sitter-typescript/typescript/src/parser.c", .scanner = "tree-sitter-typescript/typescript/src/scanner.c", .include = "tree-sitter-typescript/typescript/src" },
        .{ .name = "tree-sitter-yaml",        .parser = "tree-sitter-yaml/src/parser.c",        .scanner = "tree-sitter-yaml/src/scanner.c",    .include = "tree-sitter-yaml/src" },
        .{ .name = "tree-sitter-zig",         .parser = "tree-sitter-zig/src/parser.c",         .include = "tree-sitter-zig/src" },
    };

    // ── Zindeks module ──────────────────────────────────────────────
    const zindeks_mod = b.addModule("zindeks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C-header search paths so @cImport works inside Zig source
    zindeks_mod.addIncludePath(b.path("vendor/sqlite3"));
    zindeks_mod.addIncludePath(b.path("vendor/tree-sitter/include"));

    // ── Executable ──────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "zindeks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zindeks", .module = zindeks_mod },
            },
        }),
    });
    exe.linkLibrary(sqlite);
    exe.linkLibrary(ts);

    // Link tree-sitter grammar libraries (each exposes tree_sitter_<lang>()).
    inline for (grammar_specs) |g| {
        const parser_path = b.pathJoin(&.{ "vendor/grammars", g.parser });
        const c_files: []const []const u8 = if (g.scanner) |s|
            &.{ parser_path, b.pathJoin(&.{ "vendor/grammars", s }) }
        else
            &.{parser_path};

        const g_mod = b.createModule(.{ .target = target, .optimize = optimize });
        g_mod.addCSourceFiles(.{ .files = c_files });
        g_mod.addIncludePath(b.path(b.pathJoin(&.{ "vendor/grammars", g.include })));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/src"));

        const g_lib = b.addLibrary(.{
            .linkage = .static,
            .name = g.name,
            .root_module = g_mod,
        });
        g_lib.linkLibC();
        g_lib.linkLibrary(ts);

        exe.linkLibrary(g_lib);
    }
    b.installArtifact(exe);

    const run_step = b.step("run", "Run zindeks");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── Tests ───────────────────────────────────────────────────────
    // All tests need SQLite + tree-sitter + grammars (C libraries).
    const all_tests_mod = b.createModule(.{
        .root_source_file = b.path("tests/all_tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zindeks", .module = zindeks_mod },
        },
    });
    all_tests_mod.addIncludePath(b.path("vendor/sqlite3"));
    all_tests_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    const all_tests = b.addTest(.{ .root_module = all_tests_mod });
    all_tests.linkLibrary(sqlite);
    all_tests.linkLibrary(ts);
    inline for (grammar_specs) |g| {
        const g_mod = b.createModule(.{ .target = target, .optimize = optimize });
        const parser_path = b.pathJoin(&.{ "vendor/grammars", g.parser });
        const c_files: []const []const u8 = if (g.scanner) |s|
            &.{ parser_path, b.pathJoin(&.{ "vendor/grammars", s }) }
        else
            &.{parser_path};
        g_mod.addCSourceFiles(.{ .files = c_files });
        g_mod.addIncludePath(b.path(b.pathJoin(&.{ "vendor/grammars", g.include })));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
        const g_lib = b.addLibrary(.{
            .linkage = .static,
            .name = g.name,
            .root_module = g_mod,
        });
        g_lib.linkLibC();
        g_lib.linkLibrary(ts);
        all_tests.linkLibrary(g_lib);
    }
    const run_all_tests = b.addRunArtifact(all_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_all_tests.step);

    // Legacy alias for graph tests (now same as 'test').
    const graph_test_step = b.step("test-graph", "Run all tests (same as 'test')");
    graph_test_step.dependOn(&run_all_tests.step);
}
