const std = @import("std");
const indexer = @import("../../core/indexer/indexer.zig");
const project_store = @import("../../core/project_store.zig");
const storage = @import("../../core/storage/index.zig");
const search = @import("../../core/search/engine.zig");
const mcp = @import("../mcp/server.zig");
const update = @import("update.zig");
const scanner = @import("../../core/scanner/scanner.zig");
const terminal = @import("terminal.zig");
const errors = @import("errors.zig");
const config_mod = @import("../../core/config.zig");
const completions = @import("completions.zig");

/// Runtime state passed through the CLI pipeline.
const CliState = struct {
    allocator: std.mem.Allocator,
    colors_enabled: bool,
    config: ?[]const u8, // path, loaded from arg or default
    /// Owned config values (caller must deinit)
    cfg: config_mod.Config,

    fn deinit(self: *CliState) void {
        self.cfg.deinit(self.allocator);
    }
};

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    // Parse global flags from ALL args, then find subcommand position
    const global = try parseGlobalArgs(args);
    defer allocator.free(global.config_path);

    // Load config
    var cfg = try loadConfig(allocator, global.config_path);
    errdefer cfg.deinit(allocator);

    // Merge CLI flags into config
    if (global.no_color) cfg.colors_enabled = false;
    if (global.store_root) |v| {
        if (cfg.store_root) |old| allocator.free(old);
        cfg.store_root = try allocator.dupe(u8, v);
    }
    if (global.index_dir) |v| {
        if (cfg.index_dir) |old| allocator.free(old);
        cfg.index_dir = try allocator.dupe(u8, v);
    }

    var state = CliState{
        .allocator = allocator,
        .colors_enabled = cfg.colors_enabled,
        .config = global.config_path,
        .cfg = cfg,
    };
    defer state.deinit();

    // Handle --version before subcommand
    if (global.show_version) {
        const stdout_w = std.fs.File.stdout().deprecatedWriter();
        var sw = terminal.StyledWriter(@TypeOf(stdout_w)).init(stdout_w);
        sw.setColors(state.colors_enabled);
        try sw.print("{s}zindeks 0.1.0{s}\n", .{ sw.bold(), sw.reset() });
        return;
    }

    // Fast path: no subcommand
    if (global.cmd_index >= args.len) {
        var sw = terminal.StyledWriter(@TypeOf(std.fs.File.stderr().deprecatedWriter())).init(std.fs.File.stderr().deprecatedWriter());
        sw.setColors(state.colors_enabled);
        try usage(sw);
        return;
    }

    const cmd = args[global.cmd_index];

    // --help / help can appear anywhere
    if (std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "help")) {
        var sw = terminal.StyledWriter(@TypeOf(std.fs.File.stdout().deprecatedWriter())).init(std.fs.File.stdout().deprecatedWriter());
        sw.setColors(state.colors_enabled);
        try usage(sw);
        return;
    }

    // Dispatch to subcommand
    if (std.mem.eql(u8, cmd, "index")) {
        try runIndex(&state, args[global.cmd_index + 1 ..]);
    } else if (std.mem.eql(u8, cmd, "search")) {
        try runSearch(&state, args[global.cmd_index + 1 ..]);
    } else if (std.mem.eql(u8, cmd, "serve")) {
        try runServe(&state);
    } else if (std.mem.eql(u8, cmd, "update")) {
        try runUpdate(&state, args[global.cmd_index + 1 ..]);
    } else if (std.mem.eql(u8, cmd, "completions")) {
        try runCompletions(&state, args[global.cmd_index + 1 ..]);
    } else {
        return fmtError(state.colors_enabled, errors.invalidArgs("Unknown command"), std.fs.File.stderr().deprecatedWriter());
    }
}

// ── Global argument parsing ───────────────────────────────────────────

const GlobalArgs = struct {
    show_version: bool = false,
    no_color: bool = false,
    config_path: []const u8 = "",
    store_root: ?[]const u8 = null,
    index_dir: ?[]const u8 = null,
    cmd_index: usize = 0, // index of subcommand in args array
};

fn parseGlobalArgs(args: []const []const u8) !GlobalArgs {
    var g = GlobalArgs{};
    g.cmd_index = 1; // default: first positional is subcommand

    if (args.len <= 1) {
        g.cmd_index = args.len;
        return g;
    }

    // Scan for global flags before the subcommand
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--version")) {
            g.show_version = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--no-color")) {
            g.no_color = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            g.config_path = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--store-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            g.store_root = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "--index-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            g.index_dir = args[i];
            continue;
        }
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            g.cmd_index = i;
            return g;
        }
        // First non-flag argument is the subcommand
        g.cmd_index = i;
        return g;
    }

    g.cmd_index = i;
    return g;
}

fn loadConfig(allocator: std.mem.Allocator, explicit_path: []const u8) !config_mod.Config {
    if (explicit_path.len > 0) {
        return config_mod.Config.load(allocator, explicit_path) catch |err| {
            // If explicit path doesn't exist, return error
            return err;
        };
    }

    const default_path = config_mod.getDefaultPath(allocator) catch {
        return config_mod.Config{};
    };
    defer allocator.free(default_path);

    return config_mod.Config.load(allocator, default_path) catch |err| switch (err) {
        error.FileNotFound => return config_mod.Config{},
        else => return err,
    };
}

// ── Subcommand: index ─────────────────────────────────────────────────

fn runIndex(state: *CliState, args: []const []const u8) !void {
    const parsed = try parseIndexArgs(state, args);
    var location = try project_store.prepareWrite(state.allocator, parsed.repo, .{
        .index_dir = parsed.index_dir,
        .store_root = parsed.store_root,
    });
    defer location.deinit();

    var sw = terminal.StyledWriter(@TypeOf(std.fs.File.stderr().deprecatedWriter())).init(std.fs.File.stderr().deprecatedWriter());
    sw.setColors(state.colors_enabled);

    try sw.print("{s}Indexing '{s}'...{s}\n", .{ sw.bold(), parsed.repo, sw.reset() });

    // Disable scanner's internal progress printing
    scanner.setProgress(false);

    var spin = terminal.Spinner.init("Scanning and indexing");
    spin.writer.setColors(state.colors_enabled);
    spin.start();

    indexer.indexPath(state.allocator, parsed.repo, location.index_dir) catch |err| {
        spin.done(false);
        return err;
    };

    spin.done(true);

    try location.commit();

    try sw.print("{s}Done.{s}\n", .{ sw.green(), sw.reset() });
}

// ── Subcommand: search ────────────────────────────────────────────────

fn runSearch(state: *CliState, args: []const []const u8) !void {
    if (args.len < 1) {
        return fmtError(state.colors_enabled, errors.invalidArgs("Missing search query"), std.fs.File.stderr().deprecatedWriter());
    }

    const query = args[0];
    const rest = args[1..];

    const parsed = try parseReadArgs(state.allocator, rest);

    var location = try project_store.resolveRead(state.allocator, parsed.repo, .{
        .index_dir = parsed.index_dir,
        .store_root = parsed.store_root,
    });
    defer location.deinit();

    var idx = try storage.Index.open(state.allocator, std.fs.cwd(), location.index_dir);
    defer idx.close();

    var engine = search.Engine.init(&idx);
    const limit = state.cfg.max_results;
    var results = try engine.search(state.allocator, query, limit);
    defer results.deinit(state.allocator);

    var stdout_sw = terminal.StyledWriter(@TypeOf(std.fs.File.stdout().deprecatedWriter())).init(std.fs.File.stdout().deprecatedWriter());
    stdout_sw.setColors(state.colors_enabled);

    // Header
    try stdout_sw.print("{s}Search results for:{s} {s}\n", .{
        stdout_sw.bold(), stdout_sw.reset(), query,
    });
    if (results.items.len == 0) {
        try stdout_sw.print("  {s}No results found.{s}\n", .{ stdout_sw.dim(), stdout_sw.reset() });
        return;
    }

    try stdout_sw.print("\n", .{});

    for (results.items) |item| {
        if (state.colors_enabled) {
            try stdout_sw.writer.print("{s}{d:.3}{s}\t{s}{s}{s}\t{s}\n", .{
                stdout_sw.green(),
                item.score,
                stdout_sw.reset(),
                stdout_sw.cyan(),
                item.path,
                stdout_sw.reset(),
                item.snippet,
            });
        } else {
            try stdout_sw.writer.print("{d:.3}\t{s}\t{s}\n", .{ item.score, item.path, item.snippet });
        }
    }
}

// ── Subcommand: serve ─────────────────────────────────────────────────

fn runServe(state: *CliState) !void {
    var server = mcp.Server.init(state.allocator, .{});
    defer server.deinit();
    try server.serve();
}

// ── Subcommand: update ────────────────────────────────────────────────

fn runUpdate(state: *CliState, args: []const []const u8) !void {
    var sw = terminal.StyledWriter(@TypeOf(std.fs.File.stdout().deprecatedWriter())).init(std.fs.File.stdout().deprecatedWriter());
    sw.setColors(state.colors_enabled);

    update.run(state.allocator, args, sw) catch |err| switch (err) {
        error.HelpRequested => return update.usage(sw),
        else => return err,
    };
}

// ── Subcommand: completions ───────────────────────────────────────────

fn runCompletions(state: *CliState, args: []const []const u8) !void {
    const shell = if (args.len > 0) args[0] else "";
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (std.mem.eql(u8, shell, "bash")) {
        try completions.generateBash(stdout);
    } else if (std.mem.eql(u8, shell, "zsh")) {
        try completions.generateZsh(stdout);
    } else if (std.mem.eql(u8, shell, "fish")) {
        try completions.generateFish(stdout);
    } else {
        var sw = terminal.StyledWriter(@TypeOf(std.fs.File.stderr().deprecatedWriter())).init(std.fs.File.stderr().deprecatedWriter());
        sw.setColors(state.colors_enabled);
        return fmtError(state.colors_enabled, errors.invalidArgs("Specify shell: bash, zsh, or fish"), sw.writer);
    }
}

// ── Argument parsing helpers ──────────────────────────────────────────

const IndexArgs = struct {
    repo: []const u8 = ".",
    index_dir: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
};

fn parseIndexArgs(state: *CliState, args: []const []const u8) !IndexArgs {
    var parsed = IndexArgs{};

    // Start with config defaults
    if (state.cfg.index_dir) |v| parsed.index_dir = v;
    if (state.cfg.store_root) |v| parsed.store_root = v;

    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--index-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.index_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--store-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.store_root = args[i];
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            // Already handled in global, skip
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1; // skip value already consumed
        } else {
            if (positional_len >= 2) return error.InvalidArguments;
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len >= 1) parsed.repo = positional[0];
    if (positional_len >= 2) parsed.index_dir = positional[1];
    return parsed;
}

const ReadArgs = struct {
    repo: []const u8 = ".",
    index_dir: ?[]const u8 = null,
    store_root: ?[]const u8 = null,
};

fn parseReadArgs(allocator: std.mem.Allocator, args: []const []const u8) !ReadArgs {
    var parsed = ReadArgs{};
    var positional: [2][]const u8 = undefined;
    var positional_len: usize = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--index-dir")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.index_dir = args[i];
        } else if (std.mem.eql(u8, arg, "--store-root")) {
            i += 1;
            if (i >= args.len) return error.InvalidArguments;
            parsed.store_root = args[i];
        } else if (std.mem.eql(u8, arg, "--no-color")) {
            // skip global flag
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1; // skip value already consumed
        } else {
            if (positional_len >= 2) return error.InvalidArguments;
            positional[positional_len] = arg;
            positional_len += 1;
        }
    }

    if (positional_len == 1) {
        if (try looksLikeIndexDir(allocator, positional[0])) {
            parsed.index_dir = positional[0];
        } else {
            parsed.repo = positional[0];
        }
    } else if (positional_len == 2) {
        parsed.repo = positional[0];
        parsed.index_dir = positional[1];
    }
    return parsed;
}

fn looksLikeIndexDir(allocator: std.mem.Allocator, path: []const u8) !bool {
    const meta_path = try std.fs.path.join(allocator, &.{ path, "meta.idx" });
    defer allocator.free(meta_path);
    if (std.fs.path.isAbsolute(meta_path)) {
        std.fs.accessAbsolute(meta_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
    } else {
        std.fs.cwd().access(meta_path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return false,
        };
    }
    return true;
}

// ── Output helpers ────────────────────────────────────────────────────

fn fmtError(colors_enabled: bool, err: errors.CliError, writer: anytype) !void {
    var sw = terminal.StyledWriter(@TypeOf(writer)).init(writer);
    sw.setColors(colors_enabled);
    try sw.print(
        "{s}{s}error{s}: {s}{s}\n",
        .{ sw.bold(), sw.red(), sw.reset(), sw.bold(), err.message },
    );
    const suggestion_text = err.suggestion orelse defaultSuggestion(err.category);
    if (suggestion_text.len > 0) {
        try sw.print(
            "  {s}hint{s}: {s}\n",
            .{ sw.dim(), sw.reset(), suggestion_text },
        );
    }
    if (err.context) |ctx| {
        try sw.print(
            "  {s}context{s}: {s}\n",
            .{ sw.dim(), sw.reset(), ctx },
        );
    }
    return error.CliError;
}

fn defaultSuggestion(cat: errors.ErrorCategory) []const u8 {
    return switch (cat) {
        .InvalidArguments => "Use 'zindeks help' to see usage",
        .NotFound => "Run 'zindeks index' first to create an index",
        .PermissionDenied => "Check file permissions or try a different path",
        .NetworkError => "Check your internet connection and try again",
        .IoError => "Verify the path exists and is accessible",
        .ProjectLocked => "Another zindeks process may be indexing. Try again later.",
        .InternalError => "This is a bug. Please report it with the context above.",
    };
}

fn usage(sw: anytype) !void {
    try sw.print(
        \\{s}zindeks 0.1.0{s} — Local code knowledge graph engine
        \\
        \\{s}Commands:{s}
        \\  index [repo]              Index a repository
        \\  search <query> [repo]     Search indexed code (BM25)
        \\  serve [repo]              Start MCP JSON-RPC server
        \\  update                    Update zindeks to latest version
        \\  completions <shell>       Generate shell completions (bash|zsh|fish)
        \\  help                      Show this help
        \\
        \\{s}Global flags:{s}
        \\  -v, --version             Print version
        \\  --no-color                Disable colored output
        \\  --config <path>           Specify config file path
        \\  --store-root <path>       Custom index store root
        \\  --index-dir <path>        Explicit index directory
        \\
        \\{s}Shell completions:{s}
        \\  zindeks completions bash  →  ~/.bash_completion.d/zindeks
        \\  zindeks completions zsh   →  /usr/share/zsh/site-functions/_zindeks
        \\  zindeks completions fish  →  ~/.config/fish/completions/zindeks.fish
        \\
        \\{s}Default store:{s}
        \\  Linux:   ~/.cache/zindeks/
        \\  macOS:   ~/Library/Caches/zindeks/
        \\  Windows: %LOCALAPPDATA%\zindeks\
        \\
    , .{
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
        sw.bold(), sw.reset(),
    });
}
