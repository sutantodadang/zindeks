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
//!   Target side — CALLS edges only.  Candidates = same-named symbols that can
//!   be called (fields, variables, parameters, modules excluded).  Each is
//!   scored by:
//!     - qualifier match (+1000): the call's qualifier (`session` in
//!       `session::append_turn()`, `Foo` in `Foo::new()`, `pay` in
//!       `pay.charge()`) equals the candidate file's stem, the directory of a
//!       module-index/Go file, or a type declared in the candidate's file.
//!       `self`/`Self`/`this`/`cls`/`crate`/`super` count as no qualifier;
//!     - path proximity (+1 per shared leading path component with the
//!       caller's file) — keeps a nested repo copy (git worktree, vendored
//!       tree) from stealing or erasing the real edges.
//!     1. Same-file first: link every local candidate, confidence = 1.0 —
//!        unless the qualifier matches no local candidate but does match a
//!        cross-file one (`Bar::new()` from a file defining its own `new`).
//!     2. Else cross-file, best-scoring candidate(s):
//!          exactly 1 candidate repo-wide        → confidence 0.9
//!          qualifier matched nothing            → skip (external, e.g. `list.append()`)
//!          tie of ≤ MAX_FANOUT candidates       → each, confidence 0.4
//!          unique best, qualifier matched       → confidence 0.8
//!          unique best, proximity only          → confidence 0.6
//!        0 candidates = external/stdlib → skip.
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

/// Max candidates linked when the best score is tied.
// ponytail: a wider tie (e.g. unqualified `init` with 50 defs) is skipped,
// not fanned out; record unresolved call sites if those ever matter.
const MAX_FANOUT = 8;

// ██████████████████████████████████████████████████████████████████████████
// Buffered edge record
// ██████████████████████████████████████████████████████████████████████████

/// A pending edge that carries the source document id so the resolver can
/// scope the source-symbol lookup to the correct file.
pub const PendingEdge = struct {
    source_doc_id: i64,
    source_name: []const u8, // owned by the arena passed to bufferEdge
    target_name: []const u8, // owned by the arena
    target_qualifier: ?[]const u8 = null, // owned by the arena
    edge_type: EdgeKind,
    confidence: f32,
    source_line: u32 = 0, // 0 = unknown
    target_line: u32 = 0, // 0 = unknown
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
    edge: extractor_mod.ExtractedEdge,
) !void {
    try buf.append(buf_alloc, .{
        .source_doc_id = source_doc_id,
        .source_name = try string_arena.dupe(u8, edge.source_name),
        .target_name = try string_arena.dupe(u8, edge.target_name),
        .target_qualifier = if (edge.target_qualifier) |q| try string_arena.dupe(u8, q) else null,
        .edge_type = edge.edge_type,
        .confidence = edge.confidence,
        .source_line = edge.source_line,
        .target_line = edge.target_line,
    });
}

// ██████████████████████████████████████████████████████████████████████████
// Candidate scoring helpers
// ██████████████████████████████████████████████████████████████████████████

/// Number of leading path components shared by `a` and `b` (either separator).
fn sharedPrefixDepth(a: []const u8, b: []const u8) u32 {
    var ia = std.mem.tokenizeAny(u8, a, "/\\");
    var ib = std.mem.tokenizeAny(u8, b, "/\\");
    var depth: u32 = 0;
    while (ia.next()) |ca| {
        const cb = ib.next() orelse break;
        if (!std.mem.eql(u8, ca, cb)) break;
        depth += 1;
    }
    return depth;
}

/// A same-named call-target candidate with the module names its file defines.
const Cand = struct {
    id: i64,
    doc: i64,
    path: []const u8,
    /// File stem (`session` for `session.rs`).
    stem: []const u8,
    /// Directory name for module-index files (`session/mod.rs`,
    /// `pkg/__init__.py`, `lib/index.ts`) and Go files (package = directory).
    index_dir: ?[]const u8,

    fn init(id: i64, doc: i64, path: []const u8) Cand {
        var it = std.mem.splitBackwardsAny(u8, path, "/\\");
        const base = it.next() orelse "";
        const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse base.len;
        const stem = base[0..dot];
        const is_index = std.mem.eql(u8, stem, "mod") or std.mem.eql(u8, stem, "__init__") or
            std.mem.eql(u8, stem, "index") or std.mem.eql(u8, base[dot..], ".go");
        return .{ .id = id, .doc = doc, .path = path, .stem = stem, .index_dir = if (is_index) it.next() else null };
    }

    /// True when qualifier `q` names this candidate's module, or a type
    /// declared in its file (`type_docs`).
    fn matches(c: Cand, q: []const u8, type_docs: []const i64) bool {
        if (std.ascii.eqlIgnoreCase(q, c.stem)) return true;
        if (c.index_dir) |d| if (std.ascii.eqlIgnoreCase(q, d)) return true;
        return std.mem.indexOfScalar(i64, type_docs, c.doc) != null;
    }
};

/// Receiver/module words that carry no target information (`self.run()`,
/// `Self::new()`, `super::helper()`): treated like an unqualified call.
fn isSelfQualifier(q: []const u8) bool {
    const words = [_][]const u8{ "self", "Self", "this", "cls", "crate", "super" };
    for (words) |w| if (std.mem.eql(u8, q, w)) return true;
    return false;
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

    // Resolve a symbol scoped to one document; the one starting on the
    // given line wins (two `new`s in one file), else the first by id.
    var src_stmt = try gdb.prepare(
        "SELECT id FROM symbols WHERE name = ? AND document_id = ? ORDER BY line_start = ? DESC, id LIMIT 1",
    );
    defer src_stmt.finalize();

    // Non-CALLS target with no same-file match: first global match by name.
    var global_stmt = try gdb.prepare("SELECT id FROM symbols WHERE name = ? ORDER BY id LIMIT 1");
    defer global_stmt.finalize();

    // Path of the caller's document (for proximity scoring).
    var doc_path_stmt = try gdb.prepare("SELECT path FROM documents WHERE id = ?");
    defer doc_path_stmt.finalize();

    // Fields, variables, parameters and modules are never call targets.
    const callable = " AND kind NOT IN ('field','variable','parameter','module','namespace')";

    // All candidates for a target name (any file), with their file path.
    // Ordered by id for determinism.
    var tgt_cand_stmt = try gdb.prepare(
        "SELECT s.id, s.document_id, d.path FROM symbols s JOIN documents d ON d.id = s.document_id" ++
            " WHERE s.name = ?" ++ callable ++ " ORDER BY s.id ASC",
    );
    defer tgt_cand_stmt.finalize();

    // Documents declaring a type named like the qualifier (`Foo` in `Foo::new`).
    var type_doc_stmt = try gdb.prepare(
        \\SELECT DISTINCT document_id FROM symbols
        \\WHERE name = ? AND kind IN ('struct_type','enum_type','union_type',
        \\  'interface','type_alias','namespace','module')
        \\LIMIT 16
    );
    defer type_doc_stmt.finalize();

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

    // Per-run memo of candidates and type documents, keyed by name: hot names
    // (`new`, `init`) are called thousands of times.
    // ponytail: memory grows with distinct target names; fine for one run.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cand_cache: std.StringHashMapUnmanaged([]const Cand) = .{};
    var type_cache: std.StringHashMapUnmanaged([]const i64) = .{};

    // Caller path cache — edges arrive grouped by document.
    var src_path_buf: [4096]u8 = undefined;
    var src_path: []const u8 = "";
    var src_path_doc: i64 = -1;

    for (edges) |e| {
        const edge_type_str = @tagName(e.edge_type);

        if (e.edge_type == .calls) {
            // ── Source: scoped to its own file ───────────────────────────
            const src_id = try lookupInDoc(&src_stmt, e.source_name, e.source_doc_id, e.source_line) orelse continue;

            // ── Score every candidate (same-file and cross-file) ─────────
            if (src_path_doc != e.source_doc_id) {
                src_path_doc = e.source_doc_id;
                src_path = "";
                try doc_path_stmt.bindInt(1, e.source_doc_id);
                if (try doc_path_stmt.step()) {
                    const p = try doc_path_stmt.columnText(0);
                    const n = @min(p.len, src_path_buf.len);
                    @memcpy(src_path_buf[0..n], p[0..n]);
                    src_path = src_path_buf[0..n];
                }
                try doc_path_stmt.reset();
            }

            // A qualifier other than `self`/`Self`/... names the target's
            // type or module; with none, only the name is known.
            const foreign_q: ?[]const u8 = if (e.target_qualifier) |q|
                (if (isSelfQualifier(q)) null else q)
            else
                null;

            const type_docs: []const i64 = if (foreign_q) |q| blk: {
                const gop = try type_cache.getOrPut(a, q);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try a.dupe(u8, q);
                    var list: std.ArrayList(i64) = .empty;
                    try type_doc_stmt.bindText(1, q);
                    while (try type_doc_stmt.step()) try list.append(a, try type_doc_stmt.columnInt(0));
                    try type_doc_stmt.reset();
                    gop.value_ptr.* = list.items;
                }
                break :blk gop.value_ptr.*;
            } else &.{};

            const cands: []const Cand = blk: {
                const gop = try cand_cache.getOrPut(a, e.target_name);
                if (!gop.found_existing) {
                    gop.key_ptr.* = try a.dupe(u8, e.target_name);
                    var list: std.ArrayList(Cand) = .empty;
                    try tgt_cand_stmt.bindText(1, e.target_name);
                    while (try tgt_cand_stmt.step()) try list.append(a, Cand.init(
                        try tgt_cand_stmt.columnInt(0),
                        try tgt_cand_stmt.columnInt(1),
                        try a.dupe(u8, try tgt_cand_stmt.columnText(2)),
                    ));
                    try tgt_cand_stmt.reset();
                    gop.value_ptr.* = list.items;
                }
                break :blk gop.value_ptr.*;
            };

            // Pass 1 (cheap): qualifier matches and local/remote counts.
            var total: u32 = 0; // cross-file candidates
            var any_qualified = false; // among cross-file candidates
            var local_count: u32 = 0;
            var local_qualified = false;
            for (cands) |c| {
                const qualified = if (foreign_q) |q| c.matches(q, type_docs) else false;
                if (c.doc == e.source_doc_id) {
                    local_count += 1;
                    local_qualified = local_qualified or qualified;
                } else {
                    total += 1;
                    any_qualified = any_qualified or qualified;
                }
            }

            // ── Same-file first, unless the qualifier points elsewhere ───
            // (`Bar::new()` from a file with its own `new` but no `Bar`).
            const points_elsewhere = foreign_q != null and !local_qualified and any_qualified;
            if (local_count > 0 and !points_elsewhere) {
                for (cands) |c| {
                    if (c.doc != e.source_doc_id) continue;
                    try edge_ins.bindInt(1, src_id);
                    try edge_ins.bindInt(2, c.id);
                    try edge_ins.bindText(3, edge_type_str);
                    try edge_ins.bindFloat(4, 1.0);
                    _ = try edge_ins.step();
                    try edge_ins.reset();
                    inserted += 1;
                }
                continue;
            }

            // ── Cross-file ───────────────────────────────────────────────
            if (total == 0) continue;
            // A qualifier that matches no candidate (`list.append()` on a
            // std container) is an external call: link only a sole
            // definition, as before the ambiguity fix, never a guess.
            if (foreign_q != null and !any_qualified and !(total == 1 and local_count == 0)) continue;

            // Pass 2: path proximity among the contenders (qualified ones
            // when any qualify, else all cross-file candidates).
            var best: [MAX_FANOUT]i64 = undefined;
            var best_n: usize = 0; // may exceed MAX_FANOUT (overflow = skip)
            var best_depth: i64 = -1;
            for (cands) |c| {
                if (c.doc == e.source_doc_id) continue;
                if (any_qualified and !c.matches(foreign_q.?, type_docs)) continue;
                const depth: i64 = sharedPrefixDepth(src_path, c.path);
                if (depth > best_depth) {
                    best_depth = depth;
                    best[0] = c.id;
                    best_n = 1;
                } else if (depth == best_depth) {
                    if (best_n < MAX_FANOUT) best[best_n] = c.id;
                    best_n += 1;
                }
            }
            if (best_n > MAX_FANOUT) continue;

            const factor: f64 = if (total == 1 and local_count == 0)
                0.9
            else if (best_n > 1)
                0.4
            else if (any_qualified)
                0.8
            else
                0.6;

            for (best[0..best_n]) |tgt_id| {
                try edge_ins.bindInt(1, src_id);
                try edge_ins.bindInt(2, tgt_id);
                try edge_ins.bindText(3, edge_type_str);
                try edge_ins.bindFloat(4, @as(f64, e.confidence) * factor);
                _ = try edge_ins.step();
                try edge_ins.reset();
                inserted += 1;
            }
        } else {
            // ── Non-CALLS edges ──────────────────────────────────────────
            // Source in its own file; target in the same file first (by
            // line: `Bar contains new` → Bar's `new`, not Foo's), else the
            // first global match (`extends Base` from another file).
            // Sources that are not symbols (`(file)` for imports) keep the
            // old global pair match.
            var pair: ?[2]i64 = null;
            if (try lookupInDoc(&src_stmt, e.source_name, e.source_doc_id, e.source_line)) |src_id| {
                const tgt_id = try lookupInDoc(&src_stmt, e.target_name, e.source_doc_id, e.target_line) orelse blk: {
                    try global_stmt.bindText(1, e.target_name);
                    defer global_stmt.reset() catch {};
                    break :blk if (try global_stmt.step()) try global_stmt.columnInt(0) else null;
                };
                if (tgt_id) |t| pair = .{ src_id, t };
            } else {
                try pair_stmt.bindText(1, e.source_name);
                try pair_stmt.bindText(2, e.target_name);
                if (try pair_stmt.step()) pair = .{ try pair_stmt.columnInt(0), try pair_stmt.columnInt(1) };
                try pair_stmt.reset();
            }

            if (pair) |p| {
                try edge_ins.bindInt(1, p[0]);
                try edge_ins.bindInt(2, p[1]);
                try edge_ins.bindText(3, edge_type_str);
                try edge_ins.bindFloat(4, e.confidence);
                _ = try edge_ins.step();
                try edge_ins.reset();
                inserted += 1;
            }
        }
    }

    return inserted;
}

/// Run `stmt` (name, document_id, preferred line) and return the first id.
fn lookupInDoc(stmt: *graph_db.Statement, name: []const u8, doc_id: i64, line: u32) !?i64 {
    try stmt.bindText(1, name);
    try stmt.bindInt(2, doc_id);
    try stmt.bindInt(3, line);
    defer stmt.reset() catch {};
    return if (try stmt.step()) try stmt.columnInt(0) else null;
}
