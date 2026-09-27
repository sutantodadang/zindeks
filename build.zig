const std = @import("std");

// ─────────────────────────────────────────────────────────────────────────────
// Vendored tree-sitter grammar specs.
//
// `name` is the library name (the generated C entry point is
// `tree_sitter_<name>`), `parser`/`scanner` are paths relative to
// `vendor/grammars/`, and `include` is its include dir.
// ─────────────────────────────────────────────────────────────────────────────
const GrammarSpec = struct {
    name: []const u8,
    parser: []const u8,
    scanner: ?[]const u8 = null,
    include: []const u8,
};

const grammar_specs = [_]GrammarSpec{
    .{ .name = "tree-sitter-c", .parser = "tree-sitter-c/src/parser.c", .include = "tree-sitter-c/src" },
    .{ .name = "tree-sitter-c-sharp", .parser = "tree-sitter-c-sharp/src/parser.c", .scanner = "tree-sitter-c-sharp/src/scanner.c", .include = "tree-sitter-c-sharp/src" },
    .{ .name = "tree-sitter-cpp", .parser = "tree-sitter-cpp/src/parser.c", .scanner = "tree-sitter-cpp/src/scanner.c", .include = "tree-sitter-cpp/src" },
    .{ .name = "tree-sitter-css", .parser = "tree-sitter-css/src/parser.c", .scanner = "tree-sitter-css/src/scanner.c", .include = "tree-sitter-css/src" },
    .{ .name = "tree-sitter-dart", .parser = "tree-sitter-dart/src/parser.c", .scanner = "tree-sitter-dart/src/scanner.c", .include = "tree-sitter-dart/src" },
    .{ .name = "tree-sitter-elixir", .parser = "tree-sitter-elixir/src/parser.c", .scanner = "tree-sitter-elixir/src/scanner.c", .include = "tree-sitter-elixir/src" },
    .{ .name = "tree-sitter-go", .parser = "tree-sitter-go/src/parser.c", .include = "tree-sitter-go/src" },
    .{ .name = "tree-sitter-haskell", .parser = "tree-sitter-haskell/src/parser.c", .scanner = "tree-sitter-haskell/src/scanner.c", .include = "tree-sitter-haskell/src" },
    .{ .name = "tree-sitter-java", .parser = "tree-sitter-java/src/parser.c", .include = "tree-sitter-java/src" },
    .{ .name = "tree-sitter-javascript", .parser = "tree-sitter-javascript/src/parser.c", .scanner = "tree-sitter-javascript/src/scanner.c", .include = "tree-sitter-javascript/src" },
    .{ .name = "tree-sitter-json", .parser = "tree-sitter-json/src/parser.c", .include = "tree-sitter-json/src" },
    .{ .name = "tree-sitter-lua", .parser = "tree-sitter-lua/src/parser.c", .scanner = "tree-sitter-lua/src/scanner.c", .include = "tree-sitter-lua/src" },
    .{ .name = "tree-sitter-python", .parser = "tree-sitter-python/src/parser.c", .scanner = "tree-sitter-python/src/scanner.c", .include = "tree-sitter-python/src" },
    .{ .name = "tree-sitter-rust", .parser = "tree-sitter-rust/src/parser.c", .scanner = "tree-sitter-rust/src/scanner.c", .include = "tree-sitter-rust/src" },
    .{ .name = "tree-sitter-scala", .parser = "tree-sitter-scala/src/parser.c", .scanner = "tree-sitter-scala/src/scanner.c", .include = "tree-sitter-scala/src" },
    .{ .name = "tree-sitter-swift", .parser = "tree-sitter-swift/src/parser.c", .include = "tree-sitter-swift/src" },
    .{ .name = "tree-sitter-toml", .parser = "tree-sitter-toml/src/parser.c", .scanner = "tree-sitter-toml/src/scanner.c", .include = "tree-sitter-toml/src" },
    .{ .name = "tree-sitter-tsx", .parser = "tree-sitter-typescript/tsx/src/parser.c", .scanner = "tree-sitter-typescript/tsx/src/scanner.c", .include = "tree-sitter-typescript/tsx/src" },
    .{ .name = "tree-sitter-typescript", .parser = "tree-sitter-typescript/typescript/src/parser.c", .scanner = "tree-sitter-typescript/typescript/src/scanner.c", .include = "tree-sitter-typescript/typescript/src" },
    .{ .name = "tree-sitter-yaml", .parser = "tree-sitter-yaml/src/parser.c", .scanner = "tree-sitter-yaml/src/scanner.c", .include = "tree-sitter-yaml/src" },
    .{ .name = "tree-sitter-zig", .parser = "tree-sitter-zig/src/parser.c", .include = "tree-sitter-zig/src" },
};

/// Link every vendored grammar into `compile` (each exposes
/// `tree_sitter_<name>()`).
fn linkGrammars(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    compile: *std.Build.Step.Compile,
    ts_lib: *std.Build.Step.Compile,
) void {
    inline for (grammar_specs) |g| {
        // These static archives also feed the shared library, including musl builds.
        const g_mod = b.createModule(.{ .target = target, .optimize = optimize, .pic = true });
        const parser_path = b.pathJoin(&.{ "vendor/grammars", g.parser });
        const c_files: []const []const u8 = if (g.scanner) |s|
            &.{ parser_path, b.pathJoin(&.{ "vendor/grammars", s }) }
        else
            &.{parser_path};
        g_mod.addCSourceFiles(.{
            .files = c_files,
            // Keep `tree_sitter_<lang>` internal so the embedded shared
            // library exports only the zindeks ABI (the ELF version script
            // enforces the same allowlist on Linux).  TREE_SITTER_HIDE_SYMBOLS
            // makes the generated parser's TS_PUBLIC expand to nothing.
            .flags = &.{"-fvisibility=hidden"},
        });
        g_mod.addCMacro("TREE_SITTER_HIDE_SYMBOLS", "1");
        g_mod.addIncludePath(b.path(b.pathJoin(&.{ "vendor/grammars", g.include })));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
        g_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
        const g_lib = b.addLibrary(.{
            .linkage = .static,
            .name = g.name,
            .root_module = g_mod,
        });
        g_lib.linkLibC();
        g_lib.linkLibrary(ts_lib);
        compile.linkLibrary(g_lib);
    }
}

/// The only symbols the embedded shared library exposes (ABI 1).
const exported_symbols = [_][]const u8{
    "zindeks_abi_version",
    "zindeks_open",
    "zindeks_request",
    "zindeks_buffer_free",
    "zindeks_close",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Generate version.zig from build.zig.zon ──────────────────────────────
    const zon_file = std.fs.cwd().openFile("build.zig.zon", .{}) catch {
        std.debug.print("Failed to open build.zig.zon\n", .{});
        std.process.exit(1);
    };
    defer zon_file.close();
    const zon_contents = zon_file.readToEndAlloc(b.allocator, 4096) catch {
        std.debug.print("Failed to read build.zig.zon\n", .{});
        std.process.exit(1);
    };
    defer b.allocator.free(zon_contents);

    const version_key = ".version = \"";
    const version_start = std.mem.indexOf(u8, zon_contents, version_key) orelse {
        std.debug.print("No .version field in build.zig.zon\n", .{});
        std.process.exit(1);
    };
    const rest = zon_contents[version_start + version_key.len ..];
    const version_end = std.mem.indexOfScalar(u8, rest, '"') orelse {
        std.debug.print("Malformed .version field in build.zig.zon\n", .{});
        std.process.exit(1);
    };
    const version_str = rest[0..version_end];

    const version_zig_contents = std.fmt.allocPrint(
        b.allocator,
        "// Auto-generated from build.zig.zon \u{2014} do not edit manually\n" ++
            "pub const version = \"{s}\";\n",
        .{version_str},
    ) catch @panic("OOM");
    defer b.allocator.free(version_zig_contents);

    const version_file = std.fs.cwd().createFile("src/version.zig", .{ .truncate = true }) catch {
        std.debug.print("Failed to create src/version.zig\n", .{});
        std.process.exit(1);
    };
    defer version_file.close();
    version_file.writeAll(version_zig_contents) catch {
        std.debug.print("Failed to write src/version.zig\n", .{});
        std.process.exit(1);
    };

    // ── Vendored C: SQLite 3 ─────────────────────────────────────────────────
    const sqlite_mod = b.createModule(.{ .target = target, .optimize = optimize, .pic = true });
    sqlite_mod.addCSourceFiles(.{ .files = &.{"vendor/sqlite3/sqlite3.c"} });
    sqlite_mod.addIncludePath(b.path("vendor/sqlite3"));
    // Multi-thread mode: safe to use across threads as long as no single
    // connection is touched by two threads at once. The MCP server's read-only
    // worker pool gives each worker its own pooled connection, so mode 2 is the
    // correct (and faster-than-serialized) choice. Mode 0 would leave SQLite's
    // global state (allocator, PRNG, page cache) unprotected and corrupt under
    // concurrent read dispatch.
    sqlite_mod.addCMacro("SQLITE_THREADSAFE", "2");
    sqlite_mod.addCMacro("SQLITE_OMIT_LOAD_EXTENSION", "1");
    sqlite_mod.addCMacro("SQLITE_ENABLE_FTS5", "1");
    // Hide SQLite's symbols so the embedded shared library cannot interpose
    // (or be interposed by) a host-provided SQLite (e.g. rusqlite's bundled
    // copy).  This is the ELF/Mach-O visibility control; the version script
    // below is the belt-and-braces ELF localization.
    sqlite_mod.addCMacro("SQLITE_API", "__attribute__((visibility(\"hidden\")))");
    sqlite_mod.addCMacro("SQLITE_APICALL", "");
    sqlite_mod.addCMacro("SQLITE_CALLBACK", "");
    sqlite_mod.addCMacro("SQLITE_CDECL", "");
    sqlite_mod.addCMacro("SQLITE_STDCALL", "");
    const sqlite = b.addLibrary(.{
        .linkage = .static,
        .name = "sqlite3",
        .root_module = sqlite_mod,
    });
    sqlite.linkLibC();

    // ── Vendored C: tree-sitter core ─────────────────────────────────────────
    const ts_mod = b.createModule(.{ .target = target, .optimize = optimize, .pic = true });
    ts_mod.addCSourceFiles(.{
        .files = &.{"vendor/tree-sitter/src/lib.c"},
        .flags = &.{"-fvisibility=hidden"},
    });
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/src"));
    ts_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    ts_mod.addCMacro("TREE_SITTER_HIDE_SYMBOLS", "1");
    // alloc.h uses a different macro for the allocator function pointers.
    ts_mod.addCMacro("TREE_SITTER_HIDDEN_SYMBOLS", "1");
    const ts = b.addLibrary(.{
        .linkage = .static,
        .name = "tree-sitter",
        .root_module = ts_mod,
    });
    ts.linkLibC();

    // ── Zindeks module ───────────────────────────────────────────────────────
    const zindeks_mod = b.addModule("zindeks", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // C-header search paths so @cImport works inside Zig source
    zindeks_mod.addIncludePath(b.path("vendor/sqlite3"));
    zindeks_mod.addIncludePath(b.path("vendor/tree-sitter/include"));

    // ── Executable (standalone CLI / MCP) ────────────────────────────────────
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
    linkGrammars(b, target, optimize, exe, ts);
    if (optimize != .Debug) {
        exe.root_module.strip = true;
    }

    b.installArtifact(exe);

    const run_step = b.step("run", "Run zindeks");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // ── Embedded shared library (ABI 1) ──────────────────────────────────────
    // Kode loads this in-process; the standalone CLI/MCP binary above remains
    // fully supported.  Only the five `zindeks_*` symbols may be exported.
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(b.path("vendor/sqlite3"));
    lib_mod.addIncludePath(b.path("vendor/tree-sitter/include"));
    lib_mod.export_symbol_names = &exported_symbols;

    const lib = b.addLibrary(.{
        .linkage = .dynamic,
        .name = "zindeks",
        .root_module = lib_mod,
    });
    lib.linkLibrary(sqlite);
    lib.linkLibrary(ts);
    linkGrammars(b, target, optimize, lib, ts);
    lib.linkLibC();
    // ELF: localize everything except the ABI allowlist.  Mach-O export lists
    // and COFF `.def` files are platform-specific; the allowlist above plus
    // SQLITE_API/TREE_SITTER_HIDE_SYMBOLS cover those targets.
    if (target.result.ofmt == .elf) {
        // Zig 0.15's native ELF linker does not apply version scripts.
        lib.use_llvm = true;
        lib.use_lld = true;
        lib.version_script = b.path("build/lib/zindeks.map");
    }
    if (optimize != .Debug) {
        lib.root_module.strip = true;
    }

    const lib_step = b.step("library", "Build the embedded zindeks shared library");
    lib_step.dependOn(&b.addInstallArtifact(lib, .{}).step);

    // ── FFI smoke test: compile and run the C consumer ───────────────────────
    const consumer_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    consumer_mod.addCSourceFile(.{
        .file = b.path("tests/ffi_consumer.c"),
        .flags = &.{"-std=c11"},
    });
    consumer_mod.addIncludePath(b.path("include"));
    const consumer = b.addExecutable(.{
        .name = "ffi_consumer",
        .root_module = consumer_mod,
    });
    consumer.linkLibrary(lib);
    const run_consumer = b.addRunArtifact(consumer);

    // ── FFI export allowlist check ───────────────────────────────────────────
    const exports_check_mod = b.createModule(.{
        .root_source_file = b.path("tests/ffi_exports_check.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exports_check = b.addExecutable(.{
        .name = "ffi_exports_check",
        .root_module = exports_check_mod,
    });
    const run_exports_check = b.addRunArtifact(exports_check);
    run_exports_check.addArtifactArg(lib);

    const exports_step = b.step("ffi-exports", "Verify only the ABI-1 symbols are exported");
    exports_step.dependOn(&run_exports_check.step);

    const ffi_test_step = b.step("ffi-test", "Build and run the C ABI smoke test");
    ffi_test_step.dependOn(&run_consumer.step);
    ffi_test_step.dependOn(&run_exports_check.step);

    // ── Tests ────────────────────────────────────────────────────────────────
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
    linkGrammars(b, target, optimize, all_tests, ts);
    const run_all_tests = b.addRunArtifact(all_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_all_tests.step);

    // Legacy alias for graph tests (now same as 'test').
    const graph_test_step = b.step("test-graph", "Run all tests (same as 'test')");
    graph_test_step.dependOn(&run_all_tests.step);
}
