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
    // Grammar source files (each has src/parser.c; some also have src/scanner.c).
    const GrammarSpec = struct { name: []const u8, scanner: bool };
    const grammar_specs = [_]GrammarSpec{
        .{ .name = "tree-sitter-zig", .scanner = false },
        .{ .name = "tree-sitter-c", .scanner = false },
        .{ .name = "tree-sitter-go", .scanner = false },
        .{ .name = "tree-sitter-javascript", .scanner = true },
        .{ .name = "tree-sitter-python", .scanner = true },
        .{ .name = "tree-sitter-rust", .scanner = true },
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
        const parser_c = b.pathJoin(&.{ "vendor/grammars", g.name, "src/parser.c" });
        const c_files: []const []const u8 = if (g.scanner)
            &.{ parser_c, b.pathJoin(&.{ "vendor/grammars", g.name, "src/scanner.c" }) }
        else
            &.{parser_c};

        const g_mod = b.createModule(.{ .target = target, .optimize = optimize });
        g_mod.addCSourceFiles(.{ .files = c_files });
        g_mod.addIncludePath(b.path(b.pathJoin(&.{ "vendor/grammars", g.name, "src" })));
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
    // We use a single test step to avoid recompiling C libraries per artifact.
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
        const parser_c = b.pathJoin(&.{ "vendor/grammars", g.name, "src/parser.c" });
        const c_files: []const []const u8 = if (g.scanner)
            &.{ parser_c, b.pathJoin(&.{ "vendor/grammars", g.name, "src/scanner.c" }) }
        else
            &.{parser_c};
        g_mod.addCSourceFiles(.{ .files = c_files });
        g_mod.addIncludePath(b.path(b.pathJoin(&.{ "vendor/grammars", g.name, "src" })));
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
