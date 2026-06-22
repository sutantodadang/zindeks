//! Incremental indexing — detect changed files and update the graph DB.
//!
//! Strategy (per PLAN §6: "Use SQLite transactions. Delete all nodes/edges
//! for a file, then re-insert. Simple but correct."):
//!
//! 1. Scan filesystem metadata (path, size, mtime) — cheap, no content reads.
//! 2. Compare against documents table (path, mtime).
//! 3. Classify files: added, modified, deleted.
//! 4. In a SQLite transaction: delete old symbols+edges for changed files,
//!    re-extract and re-insert for added/modified files.
const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const graph_db = @import("../storage/graph_db.zig");
const overlay_mod = @import("../storage/overlay.zig");
const ts = @import("../parser/tree_sitter.zig");
const extractor_mod = @import("../parser/extractor.zig");
const edge_resolver = @import("../parser/edge_resolver.zig");
pub const parser_pool = @import("../parser/parser_pool.zig");
pub const ParserPool = parser_pool.ParserPool;

const Registry = extractor_mod.Registry;
const GraphDb = graph_db.GraphDb;
const PendingEdge = edge_resolver.PendingEdge;

// ██████████████████████████████████████████████████████████████████████████
// Diff result types
// ██████████████████████████████████████████████████████████████████████████

pub const FileChange = struct {
    path: []const u8,
    kind: enum { added, modified, deleted },
};

pub const DiffResult = struct {
    allocator: std.mem.Allocator,
    added: []FileChange,
    modified: []FileChange,
    deleted: []FileChange,
    total_files: u32,

    pub fn deinit(self: *DiffResult) void {
        for (self.added) |c| self.allocator.free(c.path);
        for (self.modified) |c| self.allocator.free(c.path);
        for (self.deleted) |c| self.allocator.free(c.path);
        self.allocator.free(self.added);
        self.allocator.free(self.modified);
        self.allocator.free(self.deleted);
        self.* = undefined;
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Update stats
// ██████████████████████████████████████████████████████████████████████████

pub const UpdateStats = struct {
    added: u32 = 0,
    modified: u32 = 0,
    deleted: u32 = 0,
    symbols_added: u32 = 0,
    edges_added: u32 = 0,
    errors: u32 = 0,
    // Per-reason error breakdown (sum == errors)
    err_unknown_lang: u32 = 0,
    err_no_extractor: u32 = 0,
    err_read_failed: u32 = 0,
    err_stat_failed: u32 = 0,
    err_extract_failed: u32 = 0,
    duration_ms: u64 = 0,
    /// Stats from the optional BM25 overlay rebuild that runs after the
    /// graph-DB transaction commits.  Zeroed when `applyChangesWithOverlay`
    /// is not used.
    overlay_docs: u32 = 0,
    overlay_tombstoned: u32 = 0,
};

// ██████████████████████████████████████████████████████████████████████████
// Diff detection
// ██████████████████████████████████████████████████████████████████████████

/// Compare filesystem metadata against the SQLite documents table using a
/// sorted merge-join.  Avoids materialising two full hash maps — only paths
/// that actually land in a diff list are allocated.
///
/// Algorithm:
///   1. Scan the filesystem for metadata (path, mtime).
///   2. Sort the result by path ASC.
///   3. Walk the SQLite cursor (also ORDER BY path ASC) in lock-step.
///   4. A standard merge-join emits added/modified/deleted without any
///      per-stored-path duplicate allocation.
pub fn detectChanges(
    allocator: std.mem.Allocator,
    gdb: *GraphDb,
    project_path: []const u8,
) !DiffResult {
    // ── 1. Scan current filesystem state (metadata only — fast) ──────
    const current = try scanner.scanPathMetadata(allocator, project_path);
    defer scanner.freeMetadata(allocator, current);

    // ── 2. Sort filesystem entries by path ASC ────────────────────────
    std.mem.sort(scanner.FileMetadata, current, {}, struct {
        fn lessThan(_: void, a: scanner.FileMetadata, b: scanner.FileMetadata) bool {
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lessThan);

    // ── 3. Open SQLite cursor sorted by path ASC ──────────────────────
    var stmt = try gdb.prepare("SELECT path, mtime FROM documents ORDER BY path ASC");
    defer stmt.finalize();

    // ── 4. Diff lists — only changed-path allocations ─────────────────
    var added = std.ArrayList(FileChange).initCapacity(allocator, 16) catch @panic("OOM");
    var modified = std.ArrayList(FileChange).initCapacity(allocator, 16) catch @panic("OOM");
    var deleted = std.ArrayList(FileChange).initCapacity(allocator, 16) catch @panic("OOM");

    errdefer {
        for (added.items) |c| allocator.free(c.path);
        for (modified.items) |c| allocator.free(c.path);
        for (deleted.items) |c| allocator.free(c.path);
        added.deinit(allocator);
        modified.deinit(allocator);
        deleted.deinit(allocator);
    }

    // Merge-join state
    var ci: usize = 0; // index into sorted `current`
    var db_has_row: bool = try stmt.step(); // advance to first stored row

    while (ci < current.len and db_has_row) {
        const cur = current[ci];
        const stored_path = try stmt.columnText(0);
        const stored_mtime: i64 = try stmt.columnInt(1);

        const cmp = std.mem.order(u8, cur.path, stored_path);
        if (cmp == .lt) {
            // cur.path < stored_path → file only in filesystem → added
            try added.append(allocator, .{
                .path = try allocator.dupe(u8, cur.path),
                .kind = .added,
            });
            ci += 1;
        } else if (cmp == .gt) {
            // cur.path > stored_path → file only in DB → deleted
            try deleted.append(allocator, .{
                .path = try allocator.dupe(u8, stored_path),
                .kind = .deleted,
            });
            db_has_row = try stmt.step();
        } else {
            // paths equal → file exists in both; check mtime
            if (cur.mtime != stored_mtime) {
                try modified.append(allocator, .{
                    .path = try allocator.dupe(u8, cur.path),
                    .kind = .modified,
                });
            }
            ci += 1;
            db_has_row = try stmt.step();
        }
    }

    // Drain remaining filesystem entries (all added)
    while (ci < current.len) : (ci += 1) {
        try added.append(allocator, .{
            .path = try allocator.dupe(u8, current[ci].path),
            .kind = .added,
        });
    }

    // Drain remaining DB entries (all deleted)
    while (db_has_row) {
        const stored_path = try stmt.columnText(0);
        try deleted.append(allocator, .{
            .path = try allocator.dupe(u8, stored_path),
            .kind = .deleted,
        });
        db_has_row = try stmt.step();
    }

    return DiffResult{
        .allocator = allocator,
        .added = try added.toOwnedSlice(allocator),
        .modified = try modified.toOwnedSlice(allocator),
        .deleted = try deleted.toOwnedSlice(allocator),
        .total_files = @intCast(current.len),
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Apply incremental changes to graph DB
// ██████████████████████████████████████████████████████████████████████████

/// Apply a diff to the graph database: delete old data for changed files,
/// then re-extract and re-insert symbols/edges for added and modified files.
/// Everything runs inside a single SQLite transaction for atomicity.
/// `pool` is optional: when non-null parsers are reused across files (faster);
/// when null a fresh parser is created per file (safe for one-shot CLI calls).
///
/// Two-phase edge resolution:
///   Phase A — insert all documents + symbols for the delta, buffering edges.
///   Phase B — resolve + insert edges after all delta symbols exist.
///             Uses same-file-first + globally-unique cross-file logic so
///             unambiguous cross-file calls produce a CALLS edge even when
///             the target file was not part of this delta (it is already in
///             the global symbols table from a previous index run).
pub fn applyChanges(
    allocator: std.mem.Allocator,
    gdb: *GraphDb,
    project_path: []const u8,
    diff: *const DiffResult,
    pool: ?*ParserPool,
) !UpdateStats {
    const start = std.time.milliTimestamp();

    var stats = UpdateStats{};

    const total_changes = diff.added.len + diff.modified.len + diff.deleted.len;
    if (total_changes == 0) {
        stats.duration_ms = @intCast(std.time.milliTimestamp() - start);
        return stats;
    }

    // Set up extractor registry
    var reg = Registry.init();
    reg.register(.zig, @import("../parser/zig_extractor.zig").extractor) catch {};
    // Generic config-driven extractors for all other supported languages
    const generic = @import("../parser/generic_extractor.zig");
    inline for ([_]ts.LanguageId{ .python, .javascript, .typescript, .tsx, .go, .rust, .java, .c, .cpp }) |gid| {
        reg.register(gid, generic.extractorFor(gid)) catch {};
    }

    // ── Begin transaction ──────────────────────────────────────────────
    try gdb.exec("BEGIN TRANSACTION");

    // ── Remove old data for changed/deleted files ──────────────────────
    for (diff.modified) |change| {
        try removeFileFromGraph(gdb, change.path);
        stats.modified += 1;
    }
    for (diff.deleted) |change| {
        try removeFileFromGraph(gdb, change.path);
        stats.deleted += 1;
    }

    // ── Build list of files to (re-)extract ───────────────────────────
    var re_extract_files = std.ArrayList([]const u8).initCapacity(allocator, diff.added.len + diff.modified.len) catch @panic("OOM");
    defer re_extract_files.deinit(allocator);

    for (diff.added) |change| {
        try re_extract_files.append(allocator, change.path);
    }
    for (diff.modified) |change| {
        try re_extract_files.append(allocator, change.path);
    }

    // ── Arena for pending-edge string copies (freed after phase B) ─────
    var edge_arena = std.heap.ArenaAllocator.init(allocator);
    defer edge_arena.deinit();
    const edge_alloc = edge_arena.allocator();

    var pending_edges = std.ArrayList(PendingEdge).initCapacity(allocator, 64) catch @panic("OOM");
    defer pending_edges.deinit(allocator);

    // ── Prepare reusable statements ────────────────────────────────────
    var doc_insert = try gdb.prepare(
        \\INSERT OR REPLACE INTO documents (path, content_hash, language, mtime)
        \\VALUES (?, ?, ?, ?)
    );
    defer doc_insert.finalize();

    var sym_insert = try gdb.prepare(
        \\INSERT INTO symbols (document_id, name, kind, line_start, line_end, col_start, col_end)
        \\VALUES (?, ?, ?, ?, ?, ?, ?)
    );
    defer sym_insert.finalize();

    // ── Phase A: Insert documents + symbols, buffer edges ─────────────
    for (re_extract_files.items) |rel_path| {
        const full_path = try std.fs.path.join(allocator, &.{ project_path, rel_path });
        defer allocator.free(full_path);

        const ext = std.fs.path.extension(rel_path);
        const lang_id = ts.LanguageId.fromExtension(ext) orelse {
            stats.errors += 1;
            stats.err_unknown_lang += 1;
            continue;
        };

        const extractor = reg.get(lang_id) orelse {
            stats.errors += 1;
            stats.err_no_extractor += 1;
            continue;
        };

        // Read file content
        const content = std.fs.cwd().readFileAlloc(allocator, full_path, 16 * 1024 * 1024) catch {
            stats.errors += 1;
            stats.err_read_failed += 1;
            continue;
        };
        defer allocator.free(content);

        // Hash content
        const hash = std.hash.Wyhash.hash(0, content);
        const stat = std.fs.cwd().statFile(full_path) catch {
            stats.errors += 1;
            stats.err_stat_failed += 1;
            continue;
        };

        // Extract symbols and edges — reuse pool parser when available.
        const zig_extractor = @import("../parser/zig_extractor.zig");
        const extraction = if (pool != null and lang_id == .zig)
            zig_extractor.extractWithPool(allocator, content, lang_id, pool) catch {
                stats.errors += 1;
                stats.err_extract_failed += 1;
                continue;
            }
        else
            extractor.extract(allocator, content, lang_id) catch {
                stats.errors += 1;
                stats.err_extract_failed += 1;
                continue;
            };

        // Insert document
        var hash_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &hash_bytes, hash, .little);

        try doc_insert.bindText(1, rel_path);
        try doc_insert.bindBlob(2, &hash_bytes);
        try doc_insert.bindText(3, @tagName(lang_id));
        try doc_insert.bindInt(4, @intCast(stat.mtime));
        _ = try doc_insert.step();
        try doc_insert.reset();

        const doc_id = gdb.lastInsertRowid();

        // Insert symbols
        for (extraction.symbols) |sym| {
            try sym_insert.bindInt(1, doc_id);
            try sym_insert.bindText(2, sym.name);
            try sym_insert.bindText(3, @tagName(sym.kind));
            try sym_insert.bindInt(4, @intCast(sym.line_start));
            try sym_insert.bindInt(5, @intCast(sym.line_end));
            try sym_insert.bindInt(6, @intCast(sym.col_start));
            try sym_insert.bindInt(7, @intCast(sym.col_end));
            _ = try sym_insert.step();
            try sym_insert.reset();
        }
        stats.symbols_added += @intCast(extraction.symbols.len);

        // Buffer edges for phase B
        for (extraction.edges) |edge| {
            try edge_resolver.bufferEdge(
                allocator,
                edge_alloc,
                &pending_edges,
                doc_id,
                edge.source_name,
                edge.target_name,
                edge.edge_type,
                edge.confidence,
            );
        }
        stats.edges_added += @intCast(extraction.edges.len);

        var mut_extraction = extraction;
        mut_extraction.deinit(allocator);
    }

    stats.added = @intCast(diff.added.len);

    // ── Phase B: Resolve + insert edges (all delta symbols now present) ─
    _ = try edge_resolver.resolveEdges(gdb, pending_edges.items);

    // ── Commit transaction ────────────────────────────────────────────
    try gdb.exec("COMMIT");

    stats.duration_ms = @intCast(std.time.milliTimestamp() - start);
    return stats;
}

/// Apply changes (as `applyChanges`) and additionally rebuild the BM25
/// delta overlay at `<index_path>/overlay/` so search reflects the new
/// state without a full re-index.  `index_path` must already contain a
/// base binary index built by `indexer.indexPath`.
pub fn applyChangesWithOverlay(
    allocator: std.mem.Allocator,
    gdb: *GraphDb,
    project_path: []const u8,
    index_path: []const u8,
    diff: *const DiffResult,
) !UpdateStats {
    return applyChangesWithOverlayPooled(allocator, gdb, project_path, index_path, diff, null);
}

/// Like `applyChangesWithOverlay` but accepts an optional parser pool for
/// reusing TSParser instances across files.
pub fn applyChangesWithOverlayPooled(
    allocator: std.mem.Allocator,
    gdb: *GraphDb,
    project_path: []const u8,
    index_path: []const u8,
    diff: *const DiffResult,
    pool: ?*ParserPool,
) !UpdateStats {
    var stats = try applyChanges(allocator, gdb, project_path, diff, pool);
    const ov_stats = overlay_mod.rebuild(allocator, std.fs.cwd(), index_path, project_path, gdb) catch overlay_mod.RebuildStats{};
    stats.overlay_docs = ov_stats.overlay_docs;
    stats.overlay_tombstoned = ov_stats.tombstoned;
    return stats;
}

// ██████████████████████████████████████████████████████████████████████████
// Helpers
// ██████████████████████████████████████████████████████████████████████████

/// Remove a file and all its symbols/edges from the graph DB.
///
/// `gdb.exec()` does not bind parameters, so the previous version using
/// `exec("... WHERE path = ?")` left the `?` unbound and deleted every
/// row in each table.  Use `prepare`+`bindText` so the predicate is
/// honored.  ON DELETE CASCADE on symbols/edges' FKs handles the
/// dependent rows, but we still delete edges first to avoid relying on
/// foreign_keys=ON being enabled.
fn removeFileFromGraph(gdb: *GraphDb, path: []const u8) !void {
    {
        var stmt = try gdb.prepare(
            \\DELETE FROM edges WHERE source_symbol_id IN (
            \\    SELECT id FROM symbols WHERE document_id IN (
            \\        SELECT id FROM documents WHERE path = ?
            \\    )
            \\)
        );
        defer stmt.finalize();
        try stmt.bindText(1, path);
        _ = try stmt.step();
    }
    {
        var stmt = try gdb.prepare(
            \\DELETE FROM symbols WHERE document_id IN (
            \\    SELECT id FROM documents WHERE path = ?
            \\)
        );
        defer stmt.finalize();
        try stmt.bindText(1, path);
        _ = try stmt.step();
    }
    {
        var stmt = try gdb.prepare("DELETE FROM documents WHERE path = ?");
        defer stmt.finalize();
        try stmt.bindText(1, path);
        _ = try stmt.step();
    }
}
