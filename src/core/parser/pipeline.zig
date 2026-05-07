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

const ExtractedSymbol = extractor_mod.ExtractedSymbol;
const ExtractedEdge = extractor_mod.ExtractedEdge;
const ExtractionResult = extractor_mod.ExtractionResult;
const SymbolKind = extractor_mod.SymbolKind;
const EdgeKind = extractor_mod.EdgeKind;
const Registry = extractor_mod.Registry;

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
        // Future: register C, Go, JS, Python, Rust extractors here
        return .{
            .allocator = allocator,
            .gdb = gdb,
            .project_path = project_path,
            .registry = reg,
        };
    }

    /// Run the full pipeline: scan → extract → store.
    pub fn run(self: *Pipeline) !PipelineResult {
        const start = std.time.milliTimestamp();

        var result = PipelineResult{
            .files_scanned = 0,
            .symbols_extracted = 0,
            .edges_extracted = 0,
            .files_with_errors = 0,
            .files_skipped = 0,
            .duration_ms = 0,
        };

        // ── Phase 1: Scan files ──────────────────────────────────────
        const files = try scanner.scanPath(self.allocator, self.project_path);
        defer {
            for (files) |f| self.allocator.free(f.content);
            self.allocator.free(files);
        }
        result.files_scanned = @intCast(files.len);

        // ── Phase 2 & 3: Extract and store ───────────────────────────
        for (files) |entry| {
            const ext = std.fs.path.extension(entry.path);
            const lang_id = ts.LanguageId.fromExtension(ext) orelse {
                result.files_skipped += 1;
                continue;
            };

            // Check if we have an extractor for this language
            const ext_ptr = self.registry.get(lang_id) orelse {
                result.files_skipped += 1;
                continue;
            };

            // Extract symbols and edges
            const extraction = ext_ptr.extract(self.allocator, entry.content, lang_id) catch {
                result.files_with_errors += 1;
                continue;
            };

            // ── Phase 3: Store in graph DB ────────────────────────────
            // Insert document with content hash for incremental change detection
            var doc_insert = try self.gdb.prepare(
                \\INSERT OR REPLACE INTO documents (path, content_hash, language, mtime)
                \\VALUES (?, ?, ?, ?)
            );
            defer doc_insert.finalize();

            // Convert u64 hash to 8-byte blob
            var hash_bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &hash_bytes, entry.hash, .little);

            try doc_insert.bindText(1, entry.path);
            try doc_insert.bindBlob(2, &hash_bytes);
            try doc_insert.bindText(3, @tagName(lang_id));
            try doc_insert.bindInt(4, @intCast(entry.mtime));
            _ = try doc_insert.step();
            // Reset for next use
            try doc_insert.reset();

            const doc_id = self.gdb.lastInsertRowid();

            // Insert symbols
            var sym_insert = try self.gdb.prepare(
                \\INSERT INTO symbols (document_id, name, kind, line_start, line_end, col_start, col_end)
                \\VALUES (?, ?, ?, ?, ?, ?, ?)
            );
            defer sym_insert.finalize();

            for (extraction.symbols) |sym| {
                try sym_insert.bindInt(1, doc_id);
                try sym_insert.bindText(2, sym.name);
                try sym_insert.bindText(3, @tagName(sym.kind));
                try sym_insert.bindInt(4, @intCast(sym.line_start));
                try sym_insert.bindInt(5, @intCast(sym.line_end));
                try sym_insert.bindInt(6, @intCast(sym.col_start));
                try sym_insert.bindInt(7, @intCast(sym.col_end));
                const stepped = try sym_insert.step();
                _ = stepped;
                try sym_insert.reset();
            }
            result.symbols_extracted += @intCast(extraction.symbols.len);

            // Insert edges
            var edge_insert = try self.gdb.prepare(
                \\INSERT INTO edges (source_symbol_id, target_symbol_id, edge_type, confidence)
                \\SELECT s1.id, s2.id, ?, ?
                \\FROM symbols s1, symbols s2
                \\WHERE s1.name = ? AND s2.name = ?
            );
            defer edge_insert.finalize();

            for (extraction.edges) |edge| {
                try edge_insert.bindText(1, @tagName(edge.edge_type));
                try edge_insert.bindFloat(2, edge.confidence);
                try edge_insert.bindText(3, edge.source_name);
                try edge_insert.bindText(4, edge.target_name);
                _ = try edge_insert.step();
                try edge_insert.reset();
            }
            result.edges_extracted += @intCast(extraction.edges.len);

            // Clean up extraction result
            var mut_extraction = extraction;
            mut_extraction.deinit(self.allocator);
        }

        const end = std.time.milliTimestamp();
        result.duration_ms = @intCast(end - start);
        return result;
    }
};