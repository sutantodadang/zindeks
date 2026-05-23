//! CLI subcommand: `zindeks bench <scenario> [args...]`
//!
//! Scenarios:
//!   cold-index <path>                 – time full indexing of a directory (default iters=3)
//!   detect-changes-synthetic <count>  – time detectChanges over N synthetic files (default 5000)
//!   cypher-cache <iters>              – time a fixed MATCH query N times (validates B7 cache)
//!   snippet-cache <iters>             – time repeated search_code for same query (validates B8 LRU)

const std = @import("std");
const builtin = @import("builtin");
const bench_mod = @import("../../core/bench.zig");
const indexer_mod = @import("../../core/indexer/indexer.zig");
const incremental = @import("../../core/indexer/incremental.zig");
const storage = @import("../../core/storage/index.zig");
const search_mod = @import("../../core/search/engine.zig");
const graph_db = @import("../../core/storage/graph_db.zig");
const cypher_parser = @import("../../core/graph/cypher/parser.zig");
const cypher_executor = @import("../../core/graph/cypher/executor.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();

    if (args.len == 0) {
        try printUsage(stdout);
        return;
    }

    const scenario = args[0];

    if (std.mem.eql(u8, scenario, "cold-index")) {
        const path = if (args.len > 1) args[1] else ".";
        const iters: usize = if (args.len > 2) std.fmt.parseInt(usize, args[2], 10) catch 3 else 3;
        try runColdIndex(allocator, path, iters, stdout);
    } else if (std.mem.eql(u8, scenario, "detect-changes-synthetic")) {
        const count: usize = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 5000 else 5000;
        try runDetectChangesSynthetic(allocator, count, stdout);
    } else if (std.mem.eql(u8, scenario, "cypher-cache")) {
        const iters: usize = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 1000 else 1000;
        try runCypherCache(allocator, iters, stdout);
    } else if (std.mem.eql(u8, scenario, "snippet-cache")) {
        const iters: usize = if (args.len > 1) std.fmt.parseInt(usize, args[1], 10) catch 1000 else 1000;
        try runSnippetCache(allocator, iters, stdout);
    } else {
        try stdout.print("Unknown bench scenario: {s}\n", .{scenario});
        try printUsage(stdout);
        return error.InvalidArguments;
    }
}

fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: zindeks bench <scenario> [args]
        \\
        \\Scenarios:
        \\  cold-index <path> [iters=3]
        \\      Full index of <path> each iter. Reports wall-clock + peak RSS.
        \\
        \\  detect-changes-synthetic <count=5000>
        \\      Generate N empty files, index them, time detectChanges.
        \\
        \\  cypher-cache <iters=1000>
        \\      Run a fixed MATCH query N times against CWD index. Validates B7 cache.
        \\
        \\  snippet-cache <iters=1000>
        \\      Run search_code("ParserPool") N times. Validates B8 LRU.
        \\
    );
}

// ── cold-index ────────────────────────────────────────────────────────────

fn runColdIndex(allocator: std.mem.Allocator, path: []const u8, iters: usize, writer: anytype) !void {
    try writer.print("bench cold-index path={s} iters={d}\n", .{ path, iters });

    // We time each iter individually (not via runScenario) because we need the
    // temp dir created/destroyed per iter, which doesn't compose with the
    // generic harness neatly.
    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    var ca = bench_mod.CountingAllocator.init(allocator);
    const counted = ca.allocator();

    for (0..iters) |i| {
        // Create a fresh temp dir for this iteration
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp_buf, "zindeks_bench_tmp_{d}_{d}", .{ std.time.milliTimestamp(), i });

        try std.fs.cwd().makePath(tmp_path);

        const t0 = std.time.Instant.now() catch unreachable;
        indexer_mod.indexPath(counted, path, tmp_path) catch |err| {
            // Clean up even on error
            std.fs.cwd().deleteTree(tmp_path) catch {};
            return err;
        };
        const t1 = std.time.Instant.now() catch unreachable;
        samples[i] = t1.since(t0);

        std.fs.cwd().deleteTree(tmp_path) catch {};

        try writer.print("  iter {d}/{d}: {d}ms\n", .{ i + 1, iters, samples[i] / 1_000_000 });
    }

    try ca.report("cold-index", writer);

    std.sort.block(u64, samples, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / iters;

    // Get RSS after final iteration
    const rss_kb = peakRssKb();

    const stats = bench_mod.Stats{
        .name = "cold-index",
        .iters = iters,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .mean_ns = mean,
        .p50_ns = samples[iters / 2],
        .p99_ns = samples[@min(iters - 1, iters * 99 / 100)],
        .peak_rss_bytes = rss_kb * 1024,
    };
    try bench_mod.printStats(stats, writer);
}

// ── detect-changes-synthetic ──────────────────────────────────────────────

fn runDetectChangesSynthetic(allocator: std.mem.Allocator, count: usize, writer: anytype) !void {
    try writer.print("bench detect-changes-synthetic count={d}\n", .{count});

    // Create temp dir with N empty files
    const tmp_path = "zindeks_bench_synthetic";
    std.fs.cwd().deleteTree(tmp_path) catch {};
    try std.fs.cwd().makePath(tmp_path);
    defer std.fs.cwd().deleteTree(tmp_path) catch {};

    var name_buf: [64]u8 = undefined;
    for (0..count) |i| {
        const name = try std.fmt.bufPrint(&name_buf, "{s}/file_{d}.txt", .{ tmp_path, i });
        const f = try std.fs.cwd().createFile(name, .{});
        f.close();
    }

    // Index the synthetic dir
    const idx_path = "zindeks_bench_synthetic_idx";
    std.fs.cwd().deleteTree(idx_path) catch {};
    try std.fs.cwd().makePath(idx_path);
    defer std.fs.cwd().deleteTree(idx_path) catch {};

    try indexer_mod.indexPath(allocator, tmp_path, idx_path);

    // Open graph DB for detectChanges
    const graph_path = try std.fs.path.join(allocator, &.{ idx_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);

    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();
    // migrate() is not fully idempotent (ALTER TABLE may fail if column exists);
    // the DB was already migrated by indexPath above, so ignore errors here.
    gdb.migrate() catch {};

    // Time detectChanges (single run — it's an O(N) scan)
    var ca = bench_mod.CountingAllocator.init(allocator);
    const counted = ca.allocator();
    const t0 = std.time.Instant.now() catch unreachable;
    var diff = try incremental.detectChanges(counted, &gdb, tmp_path);
    const t1 = std.time.Instant.now() catch unreachable;
    diff.deinit();
    try ca.report("detect-changes", writer);

    const elapsed_ns = t1.since(t0);
    const elapsed_ms = elapsed_ns / 1_000_000;
    const rss_kb = peakRssKb();

    try writer.print(
        "[detect-changes-synthetic] files={d} elapsed={d}ms ({d}ns) peak_rss={d}KB\n",
        .{ count, elapsed_ms, elapsed_ns, rss_kb },
    );
}

// ── cypher-cache ──────────────────────────────────────────────────────────

// Cypher query used for the cypher-cache benchmark.
// Uses simple column references that map cleanly to the symbols table.
// The parser expects bracket-only edge syntax: (src)[rel]->(dst)
const CYPHER_QUERY = "MATCH (a)[r]->(b) RETURN name, kind LIMIT 20";

fn runCypherCache(allocator: std.mem.Allocator, iters: usize, writer: anytype) !void {
    try writer.print("bench cypher-cache iters={d}\n", .{iters});

    // Index a small synthetic directory (avoids the pre-existing large-repo indexer panic).
    const src_path = "zindeks_bench_cypher_src";
    const idx_path = "zindeks_bench_cypher_idx";
    std.fs.cwd().deleteTree(src_path) catch {};
    std.fs.cwd().deleteTree(idx_path) catch {};
    try std.fs.cwd().makePath(src_path);
    try std.fs.cwd().makePath(idx_path);
    defer std.fs.cwd().deleteTree(src_path) catch {};
    defer std.fs.cwd().deleteTree(idx_path) catch {};

    // Write a few tiny text files (plain text avoids the pre-existing hashmap
    // panic in indexPath triggered by large Zig source files on Windows debug builds).
    var nbuf: [64]u8 = undefined;
    for (0..5) |i| {
        const name = try std.fmt.bufPrint(&nbuf, "{s}/module{d}.txt", .{ src_path, i });
        const ff = try std.fs.cwd().createFile(name, .{});
        defer ff.close();
        try ff.writeAll("function calls module interface implementation definition\n");
    }

    try writer.print("  indexing {s}...\n", .{src_path});
    try indexer_mod.indexPath(allocator, src_path, idx_path);

    const graph_path = try std.fs.path.join(allocator, &.{ idx_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);

    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();
    gdb.migrate() catch {};

    // Parse the query once; the parser's arena holds the AST nodes.
    var cypher_parser_inst = try cypher_parser.Parser.init(allocator, CYPHER_QUERY);
    defer cypher_parser_inst.deinit();
    const parsed = try cypher_parser_inst.parseQuery();

    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    var ca = bench_mod.CountingAllocator.init(allocator);
    const counted = ca.allocator();
    for (0..iters) |i| {
        var result_buf: std.ArrayList(u8) = .{};
        defer result_buf.deinit(counted);

        const t0 = std.time.Instant.now() catch unreachable;
        try cypher_executor.execute(counted, &gdb, &parsed, result_buf.writer(counted));
        const t1 = std.time.Instant.now() catch unreachable;
        samples[i] = t1.since(t0);
    }

    std.sort.block(u64, samples, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / iters;

    const stats = bench_mod.Stats{
        .name = "cypher-cache",
        .iters = iters,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .mean_ns = mean,
        .p50_ns = samples[iters / 2],
        .p99_ns = samples[@min(iters - 1, iters * 99 / 100)],
        .peak_rss_bytes = peakRssKb() * 1024,
    };
    try bench_mod.printStats(stats, writer);
    try ca.report("cypher-cache", writer);
}

// ── snippet-cache ─────────────────────────────────────────────────────────

fn runSnippetCache(allocator: std.mem.Allocator, iters: usize, writer: anytype) !void {
    try writer.print("bench snippet-cache iters={d}\n", .{iters});

    // Index a small synthetic directory (avoids the pre-existing large-repo indexer panic).
    const src_path = "zindeks_bench_snippet_src";
    const idx_path = "zindeks_bench_snippet_idx";
    std.fs.cwd().deleteTree(src_path) catch {};
    std.fs.cwd().deleteTree(idx_path) catch {};
    try std.fs.cwd().makePath(src_path);
    try std.fs.cwd().makePath(idx_path);
    defer std.fs.cwd().deleteTree(src_path) catch {};
    defer std.fs.cwd().deleteTree(idx_path) catch {};

    // Write a small text file containing the search term (plain text avoids
    // the pre-existing hashmap panic in indexer for large Zig source files).
    const f = try std.fs.cwd().createFile(src_path ++ "/notes.txt", .{});
    defer f.close();
    try f.writeAll(
        \\ParserPool manages a pool of tree sitter parsers
        \\It provides get and release methods for parser instances
        \\ParserPool is initialized with a fixed capacity
        \\Use ParserPool to avoid allocating parsers per request
        \\
    );

    try writer.print("  indexing {s}...\n", .{src_path});
    try indexer_mod.indexPath(allocator, src_path, idx_path);

    var idx = storage.Index.open(allocator, std.fs.cwd(), idx_path) catch |err| {
        try writer.print("  cannot open index ({s}), aborting snippet-cache\n", .{@errorName(err)});
        return;
    };
    defer idx.close();

    var engine = search_mod.Engine.init(&idx);
    const query = "ParserPool";
    const limit: usize = 10;

    var samples = try allocator.alloc(u64, iters);
    defer allocator.free(samples);

    var ca = bench_mod.CountingAllocator.init(allocator);
    const counted = ca.allocator();
    for (0..iters) |i| {
        const t0 = std.time.Instant.now() catch unreachable;
        var results = try engine.search(counted, query, limit);
        const t1 = std.time.Instant.now() catch unreachable;
        results.deinit(counted);
        samples[i] = t1.since(t0);
    }

    std.sort.block(u64, samples, {}, std.sort.asc(u64));
    var sum: u64 = 0;
    for (samples) |s| sum += s;
    const mean = sum / iters;

    const stats = bench_mod.Stats{
        .name = "snippet-cache",
        .iters = iters,
        .min_ns = samples[0],
        .max_ns = samples[samples.len - 1],
        .mean_ns = mean,
        .p50_ns = samples[iters / 2],
        .p99_ns = samples[@min(iters - 1, iters * 99 / 100)],
        .peak_rss_bytes = peakRssKb() * 1024,
    };
    try bench_mod.printStats(stats, writer);
    try ca.report("snippet-cache", writer);
}

// ── helpers ───────────────────────────────────────────────────────────────

fn peakRssKb() u64 {
    if (comptime builtin.os.tag == .windows) {
        const windows = std.os.windows;
        const vmc = windows.GetProcessMemoryInfo(windows.GetCurrentProcess()) catch return 0;
        return @as(u64, @intCast(vmc.PeakWorkingSetSize)) / 1024;
    } else {
        const usage = std.posix.getrusage(std.posix.rusage.SELF);
        const raw: i64 = usage.maxrss;
        if (raw <= 0) return 0;
        // Linux: KB; macOS: bytes
        if (comptime builtin.os.tag == .linux) return @intCast(raw);
        return @as(u64, @intCast(raw)) / 1024;
    }
}
