//! Extractor framework — language-agnostic interface for AST symbol extraction.
//!
//! Each language provides an Extractor that walks its tree-sitter AST and
//! produces ExtractedSymbol and ExtractedEdge records.  The pipeline collects
//! these from all files, resolves cross-references, then stores them in the
//! graph database.
const std = @import("std");
const ts = @import("tree_sitter.zig");

// ██████████████████████████████████████████████████████████████████████████
// Extracted types — unified across all languages
// ██████████████████████████████████████████████████████████████████████████

/// Symbol kinds — universal across languages.
/// Stored as TEXT in SQLite (the @tagName value).
pub const SymbolKind = enum {
    function,
    method,
    struct_type,
    enum_type,
    union_type,
    interface,
    const_value,
    variable,
    field,
    parameter,
    type_alias,
    module,
    macro,
    namespace,
};

/// Edge kinds — directed relationships between symbols.
/// Stored as TEXT in SQLite (the @tagName value).
pub const EdgeKind = enum {
    calls, // A calls B
    imports, // A imports B
    defines, // parent scope defines child symbol
    implements, // A implements B (interface)
    inherits, // A inherits from B
    contains, // A contains B (namespace/module)
    references, // A references B (usage)
    http_calls, // HTTP endpoint route
};

/// A single extracted symbol, before graph insertion.
pub const ExtractedSymbol = struct {
    name: []const u8,
    kind: SymbolKind,
    line_start: u32,
    line_end: u32,
    col_start: u32 = 0,
    col_end: u32 = 0,
    parent_name: ?[]const u8 = null, // e.g. struct name containing a method
    doc_comment: ?[]const u8 = null, // first doc comment, if any

    pub fn format(
        self: ExtractedSymbol,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s}:{s}@{d}:{d}",
            .{ @tagName(self.kind), self.name, self.line_start, self.col_start });
    }
};

/// A directed edge between two symbols (by name, resolved later).
pub const ExtractedEdge = struct {
    source_name: []const u8,
    source_kind: SymbolKind,
    target_name: []const u8,
    target_kind: SymbolKind = .module, // default, overridden by import edges
    edge_type: EdgeKind,
    confidence: f32 = 1.0, // 1.0 = certain, lower = heuristic guess
    /// Segment before the callee in a scoped call (`session` in
    /// `session::append_turn()`, `Foo` in `Foo::new()`); used to pick
    /// among same-named cross-file targets.
    target_qualifier: ?[]const u8 = null,
    /// Start line of the source/target symbol when known (0 = unknown);
    /// picks between same-named symbols in one file (two `impl` blocks
    /// each with a `new`).
    source_line: u32 = 0,
    target_line: u32 = 0,

    pub fn format(
        self: ExtractedEdge,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("{s} --[{s}]--> {s} ({d:.0}%)",
            .{ self.source_name, @tagName(self.edge_type), self.target_name, @as(u32, @intFromFloat(self.confidence * 100)) });
    }
};

/// Result of extracting symbols from a single source file.
pub const ExtractionResult = struct {
    symbols: []ExtractedSymbol,
    edges: []ExtractedEdge,
    language: ts.LanguageId,
    errors: u32 = 0, // number of parse errors encountered

    pub fn deinit(self: *ExtractionResult, allocator: std.mem.Allocator) void {
        for (self.symbols) |sym| {
            allocator.free(sym.name);
            if (sym.parent_name) |pn| allocator.free(pn);
            if (sym.doc_comment) |dc| allocator.free(dc);
        }
        for (self.edges) |edge| {
            allocator.free(edge.source_name);
            allocator.free(edge.target_name);
            if (edge.target_qualifier) |q| allocator.free(q);
        }
        allocator.free(self.symbols);
        allocator.free(self.edges);
    }
};

/// Segment immediately before the callee name in a scoped/dotted call
/// expression: `crate::session::append_turn` → `session`, `Foo::new` → `Foo`,
/// `pay.charge` → `pay`, `obj->run` → `obj`, `Foo::<T>::new` → `Foo`.
/// Null for an unqualified call or a non-identifier qualifier (`a.b().c`).
pub fn qualifierSegment(raw: []const u8) ?[]const u8 {
    const t = std.mem.trimRight(u8, std.mem.trim(u8, raw, " \t\r\n"), "( ");
    var i = skipGenerics(t, t.len); // turbofish on the callee: `parse::<T>`
    if (i != t.len) while (i > 0 and t[i - 1] == ':') : (i -= 1) {};
    while (i > 0 and isIdentChar(t[i - 1])) i -= 1; // callee name
    // Separators (`.`, `::`, `->`), whitespace and generic args `<...>`.
    var saw_sep = false;
    while (i > 0) {
        const c = t[i - 1];
        if (c == '>' and !(i >= 2 and t[i - 2] == '-')) {
            const j = skipGenerics(t, i);
            if (j == i) break; // unbalanced `>`
            i = j;
        } else if (std.mem.indexOfScalar(u8, ".:->", c) != null or std.ascii.isWhitespace(c)) {
            if (c != ' ' and c != '\t' and c != '\r' and c != '\n') saw_sep = true;
            i -= 1;
        } else break;
    }
    if (!saw_sep) return null;
    const end = i;
    while (i > 0 and isIdentChar(t[i - 1])) i -= 1;
    return if (end == i) null else t[i..end];
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

/// If `t[0..end]` ends with a balanced `<...>` group, return its start index.
fn skipGenerics(t: []const u8, end: usize) usize {
    if (end == 0 or t[end - 1] != '>') return end;
    var depth: usize = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        switch (t[i]) {
            '>' => depth += 1,
            '<' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return end; // unbalanced: leave as-is
}

// ██████████████████████████████████████████████████████████████████████████
// Extractor interface — vtable pattern for language-specific extractors
// ██████████████████████████████████████████████████████████████████████████

/// Function pointer type for the extract method.
pub const ExtractFn = *const fn (std.mem.Allocator, []const u8, ts.LanguageId) anyerror!ExtractionResult;

/// An extractor for a specific language.
/// Each language module exports a singleton `extractor` constant.
pub const Extractor = struct {
    /// The language this extractor handles.
    language: ts.LanguageId,
    /// The extraction function.
    extract: ExtractFn,
};

// ██████████████████████████████████████████████████████████████████████████
// Registry — maps LanguageId → Extractor
// ██████████████████████████████████████████████████████████████████████████

/// Registry of all available extractors, keyed by LanguageId.
/// Uses function pointers to avoid circular imports — each language module
/// registers its extractor here at runtime via `register()`.
pub const Registry = struct {
    const MAX_LANGUAGES = 32;

    entries: [MAX_LANGUAGES]Entry = undefined,
    count: u32 = 0,

    const Entry = struct {
        id: ts.LanguageId,
        extractor: Extractor,
    };

    /// Create an empty registry.
    pub fn init() Registry {
        return .{ .count = 0 };
    }

    /// Register an extractor for a language.
    pub fn register(self: *Registry, id: ts.LanguageId, ext: Extractor) !void {
        if (self.count >= MAX_LANGUAGES) return error.RegistryFull;
        self.entries[self.count] = .{ .id = id, .extractor = ext };
        self.count += 1;
    }

    /// Look up the extractor for a given language, or null if not available.
    pub fn get(self: *const Registry, id: ts.LanguageId) ?Extractor {
        for (self.entries[0..self.count]) |entry| {
            if (entry.id == id) return entry.extractor;
        }
        return null;
    }

    /// Return all registered languages.
    pub fn languages(self: *const Registry) []const ts.LanguageId {
        var result: [MAX_LANGUAGES]ts.LanguageId = undefined;
        for (self.entries[0..self.count], 0..) |entry, i| {
            result[i] = entry.id;
        }
        return result[0..self.count];
    }
};