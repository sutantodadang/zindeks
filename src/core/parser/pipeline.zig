//! Multi-pass indexing pipeline.
//!
//! Phase 1: Structure  — scan files, detect language
//! Phase 2: Extract    — parse AST, extract symbols and edges
//! Phase 3: Store      — insert symbols and edges into graph DB
//!
//! The pipeline replaces the old line-based `symbols.parseSymbols()` with
//! tree-sitter-powered extraction when a grammar is available, falling back
//! to the line parser otherwise.
const std = @import("std");
const scanner = @import("../scanner/scanner.zig");
const ts = @import("tree_sitter.zig");
const extractor_mod = @import("extractor.zig");
const graph_db = @import("../storage/graph_db.zig");
const edge_resolver = @import("edge_resolver.zig");
const diag = @import("../diag.zig");

const ExtractedSymbol = extractor_mod.ExtractedSymbol;
const ExtractedEdge = extractor_mod.ExtractedEdge;
const ExtractionResult = extractor_mod.ExtractionResult;
const SymbolKind = extractor_mod.SymbolKind;
const EdgeKind = extractor_mod.EdgeKind;
const Registry = extractor_mod.Registry;
const PendingEdge = edge_resolver.PendingEdge;

// ██████████████████████████████████████████████████████████████████████████
// Pipeline result
// ██████████████████████████████████████████████████████████████████████████

pub const PipelineResult = struct {
    files_scanned: u32,
    symbols_extracted: u32,
    edges_extracted: u32,
    files_with_errors: u32,
    files_skipped: u32,
    duration_ms: u64,
    err_extract_failed: u32,
};

// ██████████████████████████████████████████████████████████████████████████
// Pipeline — orchestrates the multi-pass indexing
// ██████████████████████████████████████████████████████████████████████████

pub const Pipeline = struct {
    allocator: std.mem.Allocator,
    gdb: graph_db.GraphDb,
    project_path: []const u8,
    registry: Registry,

    pub fn init(allocator: std.mem.Allocator, gdb: graph_db.GraphDb, project_path: []const u8) Pipeline {
        var reg = Registry.init();
        // Register built-in extractors
        reg.register(.zig, @import("zig_extractor.zig").extractor) catch {};
        // Generic config-driven extractors for all other supported languages
        const generic = @import("generic_extractor.zig");
        inline for ([_]ts.LanguageId{ .python, .javascript, .typescript, .tsx, .go, .rust, .java, .c, .cpp }) |gid| {
            reg.register(gid, generic.extractorFor(gid)) catch {};
        }
        return .{
            .allocator = allocator,
            .gdb = gdb,
            .project_path = project_path,
            .registry = reg,
        };
    }

    /// Run the full pipeline: scan → extract → store.
    ///
    /// Two-phase edge resolution:
    ///   Phase 1 — insert all documents + symbols, buffer edges with their
    ///             source document id.
    ///   Phase 2 — resolve + insert edges now that ALL symbols exist.
    ///             Uses same-file-first + globally-unique cross-file logic
    ///             so unambiguous cross-file calls produce a CALLS edge.
    pub fn run(self: *Pipeline) !PipelineResult {
        const start = std.time.milliTimestamp();

        var result = PipelineResult{
            .files_scanned = 0,
            .symbols_extracted = 0,
            .edges_extracted = 0,
            .files_with_errors = 0,
            .files_skipped = 0,
            .duration_ms = 0,
            .err_extract_failed = 0,
        };

        // ── Scan files ───────────────────────────────────────────────
        const files = try scanner.scanPath(self.allocator, self.project_path);
        defer {
            for (files) |f| {
                self.allocator.free(f.path);
                self.allocator.free(f.content);
            }
            self.allocator.free(files);
        }
        result.files_scanned = @intCast(files.len);

        // ── Arena for pending-edge string copies (freed after phase 2) ─
        var edge_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer edge_arena.deinit();
        const edge_alloc = edge_arena.allocator();

        var pending_edges = std.ArrayList(PendingEdge).initCapacity(self.allocator, 64) catch @panic("OOM");
        defer pending_edges.deinit(self.allocator);

        // ── Prepare reusable statements ──────────────────────────────
        var doc_insert = try self.gdb.prepare(
            \\INSERT OR REPLACE INTO documents (path, content_hash, language, mtime)
            \\VALUES (?, ?, ?, ?)
        );
        defer doc_insert.finalize();

        var sym_insert = try self.gdb.prepare(
            \\INSERT INTO symbols (document_id, name, kind, line_start, line_end, col_start, col_end)
            \\VALUES (?, ?, ?, ?, ?, ?, ?)
        );
        defer sym_insert.finalize();

        // ── Phase 1: Extract and store documents + symbols ───────────
        for (files) |entry| {
            // Breadcrumb: if extract() panics (vs. errors, which are caught
            // below), the abort names this file.
            diag.setFile(entry.path);
            const ext = std.fs.path.extension(entry.path);
            const lang_id = ts.LanguageId.fromExtension(ext) orelse {
                result.files_skipped += 1;
                continue;
            };

            const ext_ptr = self.registry.get(lang_id) orelse {
                result.files_skipped += 1;
                continue;
            };

            const extraction = ext_ptr.extract(self.allocator, entry.content, lang_id) catch {
                result.files_with_errors += 1;
                result.err_extract_failed += 1;
                continue;
            };

            // Insert document
            var hash_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &hash_bytes, entry.hash, .little);

            try doc_insert.bindText(1, entry.path);
            try doc_insert.bindBlob(2, &hash_bytes);
            try doc_insert.bindText(3, @tagName(lang_id));
            try doc_insert.bindInt(4, @intCast(entry.mtime));
            _ = try doc_insert.step();
            try doc_insert.reset();

            const doc_id = self.gdb.lastInsertRowid();

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
            result.symbols_extracted += @intCast(extraction.symbols.len);

            // Buffer edges — strings are duped into the edge arena so the
            // extraction result can be freed before phase 2.
            for (extraction.edges) |edge| {
                try edge_resolver.bufferEdge(
                    self.allocator,
                    edge_alloc,
                    &pending_edges,
                    doc_id,
                    edge.source_name,
                    edge.target_name,
                    edge.edge_type,
                    edge.confidence,
                );
            }
            result.edges_extracted += @intCast(extraction.edges.len);

            var mut_extraction = extraction;
            mut_extraction.deinit(self.allocator);
        }

        // ── Phase 2: Resolve + insert edges (all symbols now present) ─
        _ = try edge_resolver.resolveEdges(&self.gdb, pending_edges.items);

        const end = std.time.milliTimestamp();
        result.duration_ms = @intCast(end - start);
        return result;
    }
};