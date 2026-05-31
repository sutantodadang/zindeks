//! CLI subcommand: `zindeks bench <scenario> [args...]`
//!
//! Scenarios:
//!   cold-index <path>                 – time full indexing of a directory (default iters=3)
//!   detect-changes-synthetic <count>  – time detectChanges over N synthetic files (default 5000)
//!   cypher-cache <iters>              – time a fixed MATCH query N times (validates B7 cache)
//!   snippet-cache <iters>             – time repeated BM25 search for same query (validates B8 LRU)
//!   answer-quality [corpus_path]      – retrieval precision/recall/F1 vs grep baseline

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
const call_graph = @import("../../core/graph/call_graph.zig");
const pipeline_mod = @import("../../core/parser/pipeline.zig");

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
    } else if (std.mem.eql(u8, scenario, "answer-quality")) {
        const corpus_path = if (args.len > 1) args[1] else "bench/corpus";
        try runAnswerQuality(allocator, corpus_path, stdout);
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
        \\      Run BM25 search("ParserPool") N times. Validates B8 LRU.
        \\
        \\  answer-quality [corpus_path=bench/corpus]
        \\      Measure retrieval precision/recall/F1 of zindeks graph vs grep baseline
        \\      over a multi-language fixture corpus with a hand-authored answer key.
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

// ── answer-quality ────────────────────────────────────────────────────────

/// Question types for the answer-quality benchmark.
const QType = enum { definition, callers, callees };

/// A single benchmark question with semantic ground truth.
const Question = struct {
    id: []const u8,
    qtype: QType,
    target: []const u8,
    /// Expected file basenames (semantic ground truth — what a perfect tool returns).
    expected_files: []const []const u8,
};

/// Precision/recall/F1 triple.
const PRF = struct {
    precision: f64,
    recall: f64,
    f1: f64,
};

/// Per-question result for both arms.
const QuestionResult = struct {
    q: *const Question,
    zindeks_prf: PRF,
    grep_prf: PRF,
    zindeks_hits: usize,
    grep_hits: usize,
    grep_bytes: usize,
};

/// Compute PRF given returned set size, intersection size, and ground-truth size.
fn computePRF(returned: usize, intersection: usize, gt_size: usize) PRF {
    // Empty-GT convention: if GT is empty, precision = (arm returned nothing ? 1.0 : 0.0), recall = 1.0.
    if (gt_size == 0) {
        const p: f64 = if (returned == 0) 1.0 else 0.0;
        const f1: f64 = p; // recall=1.0, so F1 = 2*p*1/(p+1); simplified: if p=1 → 1, if p=0 → 0
        return .{ .precision = p, .recall = 1.0, .f1 = f1 };
    }
    const p: f64 = if (returned == 0) 1.0 else @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(returned));
    const r: f64 = @as(f64, @floatFromInt(intersection)) / @as(f64, @floatFromInt(gt_size));
    const f1: f64 = if (p + r == 0.0) 0.0 else 2.0 * p * r / (p + r);
    return .{ .precision = p, .recall = r, .f1 = f1 };
}

/// Return true if `c` is a word-boundary character (not identifier char).
inline fn isWordChar(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_';
}

/// Grep arm: scan a file's bytes for whole-word occurrences of `target`.
/// Returns: (matched: bool, bytes_of_matched_lines: usize).
fn grepFile(content: []const u8, target: []const u8) struct { matched: bool, line_bytes: usize } {
    if (target.len == 0) return .{ .matched = false, .line_bytes = 0 };
    var matched = false;
    var line_bytes: usize = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        // Find end of line.
        const ch = content[i];
        if (ch == '\n' or i == content.len - 1) {
            const line_end = if (ch == '\n') i else i + 1;
            const line = content[line_start..line_end];
            // Search for target as whole word in this line.
            var j: usize = 0;
            while (j + target.len <= line.len) : (j += 1) {
                if (std.mem.eql(u8, line[j .. j + target.len], target)) {
                    const before_ok = j == 0 or !isWordChar(line[j - 1]);
                    const after_ok = j + target.len == line.len or !isWordChar(line[j + target.len]);
                    if (before_ok and after_ok) {
                        matched = true;
                        line_bytes += line.len;
                        break; // count line only once even if multiple hits
                    }
                }
            }
            line_start = i + 1;
        }
    }
    return .{ .matched = matched, .line_bytes = line_bytes };
}

/// Query the graph DB for file paths of symbols with the given name.
/// Returns a list of basenames (caller owns memory).
fn zindeksDefinition(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    name: []const u8,
) !std.ArrayList([]u8) {
    var results = std.ArrayList([]u8).initCapacity(allocator, 8) catch @panic("OOM");
    var stmt = try gdb.prepare(
        \\SELECT DISTINCT d.path
        \\FROM symbols s
        \\JOIN documents d ON d.id = s.document_id
        \\WHERE s.name = ?
    );
    defer stmt.finalize();
    try stmt.bindText(1, name);
    while (try stmt.step()) {
        const path = try stmt.columnText(0);
        const base = std.fs.path.basename(path);
        try results.append(allocator, try allocator.dupe(u8, base));
    }
    return results;
}

/// Use call_graph.trace to get depth-1 neighbor file basenames.
/// direction: .inbound for callers, .outbound for callees.
fn zindeksTrace(
    allocator: std.mem.Allocator,
    gdb: *graph_db.GraphDb,
    name: []const u8,
    direction: call_graph.Direction,
) !std.ArrayList([]u8) {
    var results = std.ArrayList([]u8).initCapacity(allocator, 8) catch @panic("OOM");

    var tr = try call_graph.trace(allocator, gdb, name, direction, 1);
    defer tr.deinit(allocator);

    // Collect file paths of depth-1 nodes (exclude depth-0 which is the target itself).
    // Use edges to identify the depth-1 neighbors more reliably.
    var seen = std.StringHashMap(void).init(allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        seen.deinit();
    }

    for (tr.nodes) |node| {
        if (node.depth == 0) continue; // skip target itself
        const base = std.fs.path.basename(node.file_path);
        const gop = try seen.getOrPut(base);
        if (!gop.found_existing) {
            gop.key_ptr.* = try allocator.dupe(u8, base);
            gop.value_ptr.* = {};
            try results.append(allocator, try allocator.dupe(u8, base));
        }
    }
    return results;
}

/// Check whether `haystack` contains `needle` (case-sensitive string equality).
fn sliceContainsStr(haystack: []const []u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn sliceContainsOwnedStr(haystack: std.ArrayList([]u8), needle: []const u8) bool {
    for (haystack.items) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

fn runAnswerQuality(allocator: std.mem.Allocator, corpus_path: []const u8, writer: anytype) !void {
    try writer.print("bench answer-quality corpus={s}\n\n", .{corpus_path});

    // ── ground-truth answer key ────────────────────────────────────────────
    // File basenames only; semantic truth — what a perfect tool should return.

    const gt_q1_files = [_][]const u8{"orders.zig"};
    const gt_q2_files = [_][]const u8{ "orders.zig", "payments.zig" };
    const gt_q3_files = [_][]const u8{"orders.zig"};
    const gt_q4_files = [_][]const u8{"payments.zig"};
    const gt_q5_files = [_][]const u8{"inventory.py"};
    const gt_q6_files = [_][]const u8{"inventory.py"};
    const gt_q7_files = [_][]const u8{}; // entry point — nothing calls it
    const gt_q8_files = [_][]const u8{"cart.ts"};
    const gt_q9_files = [_][]const u8{"orders.zig"};
    const gt_q10_files = [_][]const u8{"inventory.py"};

    const questions = [_]Question{
        .{ .id = "Q01", .qtype = .callers, .target = "validateOrder", .expected_files = &gt_q1_files },
        .{ .id = "Q02", .qtype = .callees, .target = "processOrder", .expected_files = &gt_q2_files },
        .{ .id = "Q03", .qtype = .callers, .target = "chargeCard", .expected_files = &gt_q3_files },
        .{ .id = "Q04", .qtype = .callees, .target = "chargeCard", .expected_files = &gt_q4_files },
        .{ .id = "Q05", .qtype = .callers, .target = "check_stock", .expected_files = &gt_q5_files },
        .{ .id = "Q06", .qtype = .callees, .target = "reserve_stock", .expected_files = &gt_q6_files },
        .{ .id = "Q07", .qtype = .callers, .target = "processOrder", .expected_files = &gt_q7_files },
        .{ .id = "Q08", .qtype = .callees, .target = "addItem", .expected_files = &gt_q8_files },
        .{ .id = "Q09", .qtype = .definition, .target = "validateOrder", .expected_files = &gt_q9_files },
        .{ .id = "Q10", .qtype = .definition, .target = "check_stock", .expected_files = &gt_q10_files },
    };

    // ── index the corpus ───────────────────────────────────────────────────
    const idx_path = "zindeks_bench_aq_idx";
    std.fs.cwd().deleteTree(idx_path) catch {};
    try std.fs.cwd().makePath(idx_path);
    defer std.fs.cwd().deleteTree(idx_path) catch {};

    try writer.print("  indexing {s}...\n", .{corpus_path});
    try indexer_mod.indexPath(allocator, corpus_path, idx_path);

    // ── run tree-sitter graph pipeline (populates symbols + edges) ─────────
    // indexPath only builds the BM25 index. Symbols and edges require the
    // tree-sitter pipeline, exactly as the CLI `index` command does.
    {
        const graph_path_pipe = try std.fs.path.join(allocator, &.{ idx_path, "graph.db" });
        defer allocator.free(graph_path_pipe);
        const graph_path_pipe_z = try allocator.dupeZ(u8, graph_path_pipe);
        defer allocator.free(graph_path_pipe_z);

        var gdb_pipe = try graph_db.GraphDb.open(graph_path_pipe_z);
        try gdb_pipe.migrate();
        defer gdb_pipe.close();

        // Resolve absolute path for the corpus (pipeline requires it).
        var abs_corpus_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_corpus = try std.fs.cwd().realpath(corpus_path, &abs_corpus_buf);

        var pipe = pipeline_mod.Pipeline.init(allocator, gdb_pipe, abs_corpus);
        _ = try pipe.run();
    }

    // ── open graph DB for queries ──────────────────────────────────────────
    const graph_path = try std.fs.path.join(allocator, &.{ idx_path, "graph.db" });
    defer allocator.free(graph_path);
    const graph_path_z = try allocator.dupeZ(u8, graph_path);
    defer allocator.free(graph_path_z);

    var gdb = try graph_db.GraphDb.open(graph_path_z);
    defer gdb.close();
    gdb.migrate() catch {};

    // ── load corpus files for grep arm ─────────────────────────────────────
    // Read each corpus file into memory.
    const corpus_files = [_][]const u8{ "orders.zig", "payments.zig", "inventory.py", "cart.ts" };

    var corpus_contents: [corpus_files.len][]u8 = undefined;
    for (corpus_files, 0..) |fname, fi| {
        const fpath = try std.fs.path.join(allocator, &.{ corpus_path, fname });
        defer allocator.free(fpath);
        const f = try std.fs.cwd().openFile(fpath, .{});
        defer f.close();
        corpus_contents[fi] = try f.readToEndAlloc(allocator, 1 << 20);
    }
    defer for (corpus_contents) |c| allocator.free(c);

    // ── run each question ──────────────────────────────────────────────────
    var q_results = try allocator.alloc(QuestionResult, questions.len);
    defer allocator.free(q_results);

    var total_zindeks_grep_bytes: usize = 0; // for cost proxy denominator
    var total_grep_bytes: usize = 0;
    var total_zindeks_answer_bytes: usize = 0; // approx: sum of returned basename lengths

    for (&questions, 0..) |*q, qi| {
        // ── zindeks arm ───────────────────────────────────────────────────
        var zindeks_files: std.ArrayList([]u8) = switch (q.qtype) {
            .definition => try zindeksDefinition(allocator, &gdb, q.target),
            .callers => try zindeksTrace(allocator, &gdb, q.target, .inbound),
            .callees => try zindeksTrace(allocator, &gdb, q.target, .outbound),
        };
        defer {
            for (zindeks_files.items) |s| allocator.free(s);
            zindeks_files.deinit(allocator);
        }

        var zindeks_intersection: usize = 0;
        for (q.expected_files) |ef| {
            if (sliceContainsOwnedStr(zindeks_files, ef)) zindeks_intersection += 1;
        }
        const zindeks_prf = computePRF(zindeks_files.items.len, zindeks_intersection, q.expected_files.len);

        // Approximate answer bytes: sum basename lengths (comma-separated).
        var ans_bytes: usize = 0;
        for (zindeks_files.items) |s| ans_bytes += s.len + 1;
        if (ans_bytes == 0) ans_bytes = 1; // at least 1 byte for empty answer "[]"
        total_zindeks_answer_bytes += ans_bytes;

        // ── grep arm ──────────────────────────────────────────────────────
        var grep_files = std.ArrayList([]u8).initCapacity(allocator, 8) catch @panic("OOM");
        defer {
            for (grep_files.items) |s| allocator.free(s);
            grep_files.deinit(allocator);
        }
        var q_grep_bytes: usize = 0;

        for (corpus_files, 0..) |fname, fi| {
            const gr = grepFile(corpus_contents[fi], q.target);
            if (gr.matched) {
                try grep_files.append(allocator, try allocator.dupe(u8, fname));
                q_grep_bytes += gr.line_bytes;
            }
        }
        total_grep_bytes += q_grep_bytes;

        var grep_intersection: usize = 0;
        for (q.expected_files) |ef| {
            if (sliceContainsOwnedStr(grep_files, ef)) grep_intersection += 1;
        }
        const grep_prf = computePRF(grep_files.items.len, grep_intersection, q.expected_files.len);

        q_results[qi] = .{
            .q = q,
            .zindeks_prf = zindeks_prf,
            .grep_prf = grep_prf,
            .zindeks_hits = zindeks_files.items.len,
            .grep_hits = grep_files.items.len,
            .grep_bytes = q_grep_bytes,
        };
    }

    total_zindeks_grep_bytes = total_zindeks_answer_bytes; // rename for clarity below

    // ── print scorecard ────────────────────────────────────────────────────
    try writer.writeAll("\n");
    try writer.print(
        "  {s:<4} {s:<12} {s:<15}  {s:<24}  {s:<24}  {s}\n",
        .{ "ID", "type", "target", "zindeks P/R/F1", "grep P/R/F1", "grep_bytes" },
    );
    try writer.writeAll("  " ++ "-" ** 100 ++ "\n");

    var sum_z_p: f64 = 0;
    var sum_z_r: f64 = 0;
    var sum_z_f1: f64 = 0;
    var sum_g_p: f64 = 0;
    var sum_g_r: f64 = 0;
    var sum_g_f1: f64 = 0;

    for (q_results) |qr| {
        const qt_str = switch (qr.q.qtype) {
            .definition => "definition",
            .callers => "callers",
            .callees => "callees",
        };
        try writer.print(
            "  {s:<4} {s:<12} {s:<15}  {d:.2}/{d:.2}/{d:.2}               {d:.2}/{d:.2}/{d:.2}               {d}\n",
            .{
                qr.q.id,
                qt_str,
                qr.q.target,
                qr.zindeks_prf.precision,
                qr.zindeks_prf.recall,
                qr.zindeks_prf.f1,
                qr.grep_prf.precision,
                qr.grep_prf.recall,
                qr.grep_prf.f1,
                qr.grep_bytes,
            },
        );
        sum_z_p += qr.zindeks_prf.precision;
        sum_z_r += qr.zindeks_prf.recall;
        sum_z_f1 += qr.zindeks_prf.f1;
        sum_g_p += qr.grep_prf.precision;
        sum_g_r += qr.grep_prf.recall;
        sum_g_f1 += qr.grep_prf.f1;
    }

    const n: f64 = @floatFromInt(questions.len);
    try writer.writeAll("  " ++ "-" ** 100 ++ "\n");
    try writer.print(
        "  {s:<4} {s:<12} {s:<15}  {d:.2}/{d:.2}/{d:.2}               {d:.2}/{d:.2}/{d:.2}               {d}\n",
        .{
            "AVG",
            "",
            "",
            sum_z_p / n,
            sum_z_r / n,
            sum_z_f1 / n,
            sum_g_p / n,
            sum_g_r / n,
            sum_g_f1 / n,
            total_grep_bytes,
        },
    );

    try writer.writeAll("\n");
    try writer.print(
        "  cost proxy: zindeks={d} tool_calls  grep={d} bytes read  ratio={d:.1}x bytes/tool_call\n",
        .{
            questions.len,
            total_grep_bytes,
            if (total_zindeks_answer_bytes == 0) 0.0 else @as(f64, @floatFromInt(total_grep_bytes)) / @as(f64, @floatFromInt(total_zindeks_answer_bytes)),
        },
    );
    try writer.writeAll("\n");
    try writer.print("  per-qtype breakdown:\n", .{});
    // Compute per-qtype aggregates.
    var def_z_f1: f64 = 0;
    var def_g_f1: f64 = 0;
    var def_n: f64 = 0;
    var cal_z_f1: f64 = 0;
    var cal_g_f1: f64 = 0;
    var cal_n: f64 = 0;
    var cle_z_f1: f64 = 0;
    var cle_g_f1: f64 = 0;
    var cle_n: f64 = 0;
    for (q_results) |qr| {
        switch (qr.q.qtype) {
            .definition => { def_z_f1 += qr.zindeks_prf.f1; def_g_f1 += qr.grep_prf.f1; def_n += 1; },
            .callers => { cal_z_f1 += qr.zindeks_prf.f1; cal_g_f1 += qr.grep_prf.f1; cal_n += 1; },
            .callees => { cle_z_f1 += qr.zindeks_prf.f1; cle_g_f1 += qr.grep_prf.f1; cle_n += 1; },
        }
    }
    try writer.print(
        "    definition: zindeks_F1={d:.2} grep_F1={d:.2}\n",
        .{ if (def_n > 0) def_z_f1 / def_n else 0.0, if (def_n > 0) def_g_f1 / def_n else 0.0 },
    );
    try writer.print(
        "    callers:    zindeks_F1={d:.2} grep_F1={d:.2}\n",
        .{ if (cal_n > 0) cal_z_f1 / cal_n else 0.0, if (cal_n > 0) cal_g_f1 / cal_n else 0.0 },
    );
    try writer.print(
        "    callees:    zindeks_F1={d:.2} grep_F1={d:.2}\n",
        .{ if (cle_n > 0) cle_z_f1 / cle_n else 0.0, if (cle_n > 0) cle_g_f1 / cle_n else 0.0 },
    );
    try writer.writeAll("\n");
    try writer.print("bench answer-quality done.\n", .{});
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
