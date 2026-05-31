//! Two-phase cross-file edge resolver.
//!
//! Resolves buffered (source_doc_id, source_name, target_name, edge_type,
//! confidence) tuples into concrete symbol-id pairs after ALL symbols for
//! the current index run have been inserted.
//!
//! Algorithm (per edge):
//!
//!   Source side:
//!     Resolve to symbols WHERE name = source_name AND document_id = source_doc_id.
//!     (Scope source to its own file — prevents source-side over-linking.)
//!     If none, skip.
//!
//!   Target side — CALLS edges only:
//!     1. Same-file first: WHERE name = target_name AND document_id = source_doc_id.
//!        If ≥1 found → create edges, confidence = 1.0.  (Intra-file — current good behavior.)
//!     2. Else globally unique: WHERE name = target_name across the whole DB.
//!        If exactly 1 found → create that edge, confidence = 0.9.  (Cross-file fix.)
//!     3. Else (0 = external/unknown, >1 = ambiguous like `init`/`print`) → SKIP.
//!        Ambiguous cross-file names stay unresolved to preserve precision.
//!        Import-scope disambiguation is future work (track `const pay = @import(...)`).
//!
//!   Non-CALLS edges (imports, defines, contains, references, inherits, implements,
//!   http_calls): preserved with the old exact global name match so their behavior
//!   is unchanged.  They run in phase 2 (after symbols exist) so they now correctly
//!   resolve cross-file symbols too.
const std = @import("std");
const graph_db = @import("../storage/graph_db.zig");
const extractor_mod = @import("extractor.zig");

const GraphDb = graph_db.GraphDb;
const EdgeKind = extractor_mod.EdgeKind;

// ██████████████████████████████████████████████████████████████████████████
// Buffered edge record
// ██████████████████████████████████████████████████████████████████████████

/// A pending edge that carries the source document id so the resolver can
/// scope the source-symbol lookup to the correct file.
pub const PendingEdge = struct {
    source_doc_id: i64,
    source_name: []const u8, // owned by the arena passed to bufferEdge
    target_name: []const u8, // owned by the arena
    edge_type: EdgeKind,
    confidence: f32,
};

// ██████████████████████████████████████████████████████████████████████████
// Edge buffer
// ██████████████████████████████████████████████████████████████████████████

/// Append a pending edge to `buf`.
///
/// `buf_alloc`   — allocator that owns the ArrayList backing store.
/// `string_arena` — arena for duping source_name / target_name strings
///                  (freed as a unit after phase 2, so no per-string free).
pub fn bufferEdge(
    buf_alloc: std.mem.Allocator,
    string_arena: std.mem.Allocator,
    buf: *std.ArrayList(PendingEdge),
    source_doc_id: i64,
    source_name: []const u8,
    target_name: []const u8,
    edge_type: EdgeKind,
    confidence: f32,
) !void {
    try buf.append(buf_alloc, .{
        .source_doc_id = source_doc_id,
        .source_name = try string_arena.dupe(u8, source_name),
        .target_name = try string_arena.dupe(u8, target_name),
        .edge_type = edge_type,
        .confidence = confidence,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Resolver
// ██████████████████████████████████████████████████████████████████████████

/// Resolve and insert all buffered edges into the graph DB.
/// Call this AFTER all symbols for the current run have been inserted.
///
/// Prepares statements once and reuses them across all edges.
/// Returns the total number of edge rows inserted.
pub fn resolveEdges(
    gdb: *GraphDb,
    edges: []const PendingEdge,
) !u32 {
    var inserted: u32 = 0;

    // ── Prepared statements (prepared once, reused) ──────────────────

    // Resolve source symbol scoped to its document.
    var src_stmt = try gdb.prepare(
        "SELECT id FROM symbols WHERE name = ? AND document_id = ? LIMIT 1",
    );
    defer src_stmt.finalize();

    // Candidate count for a target name across ALL files.
    var tgt_count_stmt = try gdb.prepare(
        "SELECT COUNT(*) FROM symbols WHERE name = ?",
    );
    defer tgt_count_stmt.finalize();

    // Resolve target same-file: ordered by id for determinism.
    var tgt_same_stmt = try gdb.prepare(
        "SELECT id FROM symbols WHERE name = ? AND document_id = ? ORDER BY id ASC",
    );
    defer tgt_same_stmt.finalize();

    // Resolve target globally unique.
    var tgt_global_stmt = try gdb.prepare(
        "SELECT id FROM symbols WHERE name = ? LIMIT 2",
    );
    defer tgt_global_stmt.finalize();

    // Old-style global pair match for non-CALLS edges.
    var pair_stmt = try gdb.prepare(
        \\SELECT s1.id, s2.id
        \\FROM symbols s1, symbols s2
        \\WHERE s1.name = ? AND s2.name = ?
        \\LIMIT 1
    );
    defer pair_stmt.finalize();

    // Insert edge — no duplicates: INSERT OR IGNORE if unique constraint exists,
    // otherwise plain INSERT.  The schema has no unique constraint on edges so
    // we use a guard SELECT; prefer simplicity over a second compound query.
    var edge_ins = try gdb.prepare(
        \\INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence)
        \\VALUES (?, ?, ?, ?)
    );
    defer edge_ins.finalize();

    for (edges) |e| {
        const edge_type_str = @tagName(e.edge_type);

        if (e.edge_type == .calls) {
            // ── Source: scoped to its own file ───────────────────────────
            try src_stmt.bindText(1, e.source_name);
            try src_stmt.bindInt(2, e.source_doc_id);
            const src_has_row = try src_stmt.step();
            if (!src_has_row) {
                try src_stmt.reset();
                continue;
            }
            const src_id = try src_stmt.columnInt(0);
            try src_stmt.reset();

            // ── Target: same-file first ──────────────────────────────────
            try tgt_same_stmt.bindText(1, e.target_name);
            try tgt_same_stmt.bindInt(2, e.source_doc_id);

            var same_file_count: u32 = 0;
            while (try tgt_same_stmt.step()) {
                const tgt_id = try tgt_same_stmt.columnInt(0);
                // Insert edge (same-file, confidence = 1.0)
                try edge_ins.bindInt(1, src_id);
                try edge_ins.bindInt(2, tgt_id);
                try edge_ins.bindText(3, edge_type_str);
                try edge_ins.bindFloat(4, 1.0);
                _ = try edge_ins.step();
                try edge_ins.reset();
                inserted += 1;
                same_file_count += 1;
            }
            try tgt_same_stmt.reset();

            if (same_file_count > 0) continue; // intra-file resolved, done

            // ── Target: globally unique cross-file ───────────────────────
            // Count candidates repo-wide to enforce the ambiguity guard.
            try tgt_count_stmt.bindText(1, e.target_name);
            _ = try tgt_count_stmt.step();
            const candidate_count = try tgt_count_stmt.columnInt(0);
            try tgt_count_stmt.reset();

            if (candidate_count != 1) {
                // 0 = external/stdlib, >1 = ambiguous → skip to preserve precision.
                continue;
            }

            // Exactly one definition repo-wide — safe to link cross-file.
            try tgt_global_stmt.bindText(1, e.target_name);
            if (try tgt_global_stmt.step()) {
                const tgt_id = try tgt_global_stmt.columnInt(0);
                try tgt_global_stmt.reset();

                try edge_ins.bindInt(1, src_id);
                try edge_ins.bindInt(2, tgt_id);
                try edge_ins.bindText(3, edge_type_str);
                try edge_ins.bindFloat(4, @as(f64, e.confidence) * 0.9);
                _ = try edge_ins.step();
                try edge_ins.reset();
                inserted += 1;
            } else {
                try tgt_global_stmt.reset();
            }
        } else {
            // ── Non-CALLS edges: old exact global pair match ─────────────
            // Behavior unchanged from before the two-phase refactor; they now
            // simply run after all symbols exist (phase 2), which itself fixes
            // the ordering issue for cross-file non-call edges.
            try pair_stmt.bindText(1, e.source_name);
            try pair_stmt.bindText(2, e.target_name);
            if (try pair_stmt.step()) {
                const src_id = try pair_stmt.columnInt(0);
                const tgt_id = try pair_stmt.columnInt(1);
                try pair_stmt.reset();

                try edge_ins.bindInt(1, src_id);
                try edge_ins.bindInt(2, tgt_id);
                try edge_ins.bindText(3, edge_type_str);
                try edge_ins.bindFloat(4, e.confidence);
                _ = try edge_ins.step();
                try edge_ins.reset();
                inserted += 1;
            } else {
                try pair_stmt.reset();
            }
        }
    }

    return inserted;
}
