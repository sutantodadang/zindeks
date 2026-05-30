//! Generic tree-sitter extractor — config-driven symbol/edge extraction
//! for non-Zig languages.
//!
//! Extracts: functions, methods, type declarations (struct/enum/union/interface/
//! type_alias), and CALLS/CONTAINS/IMPORTS edges via a per-language LangSpec.
//!
//! Supported languages: python, javascript, typescript, tsx, go, rust, java, c, cpp.
//! Each language has a corresponding LangSpec that describes which tree-sitter
//! node kinds map to which symbol kinds.
const std = @import("std");
const ts = @import("tree_sitter.zig");
const extractor_mod = @import("extractor.zig");

const ExtractedSymbol = extractor_mod.ExtractedSymbol;
const ExtractedEdge = extractor_mod.ExtractedEdge;
const ExtractionResult = extractor_mod.ExtractionResult;
const SymbolKind = extractor_mod.SymbolKind;
const EdgeKind = extractor_mod.EdgeKind;

// ██████████████████████████████████████████████████████████████████████████
// LangSpec — per-language configuration
// ██████████████████████████████████████████████████████████████████████████

/// Maps a tree-sitter node kind to a SymbolKind.
const KindMap = struct { node: []const u8, kind: SymbolKind };

/// Config for one language.  All slice fields default to empty.
const LangSpec = struct {
    func_kinds: []const []const u8 = &.{},
    method_kinds: []const []const u8 = &.{},
    type_kinds: []const KindMap = &.{},
    scope_open_kinds: []const []const u8 = &.{},
    scope_name_field: []const u8 = "name",
    call_kind: []const u8 = "",
    call_callee_field: []const u8 = "function",
    import_kinds: []const []const u8 = &.{},
    c_style_decl: bool = false, // C/C++ declarator nesting
    go_type_spec: bool = false, // Go `type Foo struct { … }` pattern
};

// ── Spec instances (comptime constants) ────────────────────────────────────

const spec_python = LangSpec{
    .func_kinds = &.{"function_definition"},
    .type_kinds = &.{.{ .node = "class_definition", .kind = .struct_type }},
    .scope_open_kinds = &.{"class_definition"},
    .call_kind = "call",
    .call_callee_field = "function",
    .import_kinds = &.{ "import_statement", "import_from_statement" },
};

const spec_javascript = LangSpec{
    .func_kinds = &.{ "function_declaration", "generator_function_declaration" },
    .method_kinds = &.{"method_definition"},
    .type_kinds = &.{.{ .node = "class_declaration", .kind = .struct_type }},
    .scope_open_kinds = &.{ "class_declaration", "class" },
    .call_kind = "call_expression",
    .import_kinds = &.{"import_statement"},
};

const spec_typescript = LangSpec{
    .func_kinds = &.{ "function_declaration", "generator_function_declaration" },
    .method_kinds = &.{ "method_definition", "method_signature", "abstract_method_signature" },
    .type_kinds = &.{
        .{ .node = "class_declaration", .kind = .struct_type },
        .{ .node = "abstract_class_declaration", .kind = .struct_type },
        .{ .node = "interface_declaration", .kind = .interface },
        .{ .node = "enum_declaration", .kind = .enum_type },
        .{ .node = "type_alias_declaration", .kind = .type_alias },
    },
    .scope_open_kinds = &.{
        "class_declaration",
        "abstract_class_declaration",
        "interface_declaration",
    },
    .call_kind = "call_expression",
    .import_kinds = &.{"import_statement"},
};

const spec_go = LangSpec{
    .func_kinds = &.{"function_declaration"},
    .method_kinds = &.{"method_declaration"},
    .go_type_spec = true,
    .call_kind = "call_expression",
    .import_kinds = &.{"import_declaration"},
};

const spec_rust = LangSpec{
    .func_kinds = &.{"function_item"},
    .type_kinds = &.{
        .{ .node = "struct_item", .kind = .struct_type },
        .{ .node = "enum_item", .kind = .enum_type },
        .{ .node = "trait_item", .kind = .interface },
        .{ .node = "union_item", .kind = .union_type },
    },
    .scope_open_kinds = &.{"impl_item"},
    .scope_name_field = "type",
    .call_kind = "call_expression",
    .import_kinds = &.{"use_declaration"},
};

const spec_java = LangSpec{
    .method_kinds = &.{ "method_declaration", "constructor_declaration" },
    .type_kinds = &.{
        .{ .node = "class_declaration", .kind = .struct_type },
        .{ .node = "interface_declaration", .kind = .interface },
        .{ .node = "enum_declaration", .kind = .enum_type },
        .{ .node = "record_declaration", .kind = .struct_type },
    },
    .scope_open_kinds = &.{
        "class_declaration",
        "interface_declaration",
        "enum_declaration",
        "record_declaration",
    },
    .call_kind = "method_invocation",
    .call_callee_field = "name",
    .import_kinds = &.{"import_declaration"},
};

const spec_c = LangSpec{
    .func_kinds = &.{"function_definition"},
    .type_kinds = &.{
        .{ .node = "struct_specifier", .kind = .struct_type },
        .{ .node = "enum_specifier", .kind = .enum_type },
        .{ .node = "union_specifier", .kind = .union_type },
    },
    .call_kind = "call_expression",
    .import_kinds = &.{"preproc_include"},
    .c_style_decl = true,
};

const spec_cpp = LangSpec{
    .func_kinds = &.{"function_definition"},
    .type_kinds = &.{
        .{ .node = "struct_specifier", .kind = .struct_type },
        .{ .node = "class_specifier", .kind = .struct_type },
        .{ .node = "enum_specifier", .kind = .enum_type },
        .{ .node = "union_specifier", .kind = .union_type },
    },
    .scope_open_kinds = &.{ "class_specifier", "struct_specifier" },
    .call_kind = "call_expression",
    .import_kinds = &.{"preproc_include"},
    .c_style_decl = true,
};

/// Return the spec for a language, or null if unsupported.
fn specFor(lang: ts.LanguageId) ?LangSpec {
    return switch (lang) {
        .python => spec_python,
        .javascript => spec_javascript,
        .typescript, .tsx => spec_typescript,
        .go => spec_go,
        .rust => spec_rust,
        .java => spec_java,
        .c => spec_c,
        .cpp => spec_cpp,
        else => null,
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Small helpers
// ██████████████████████████████████████████████████████████████████████████

/// True if `kind` appears in `list`.
fn inList(kind: []const u8, list: []const []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, kind, item)) return true;
    }
    return false;
}

/// Return the SymbolKind for `kind` from a KindMap slice, or null.
fn typeKindFor(kind: []const u8, list: []const KindMap) ?SymbolKind {
    for (list) |m| {
        if (std.mem.eql(u8, kind, m.node)) return m.kind;
    }
    return null;
}

/// True if `c` can start a bare identifier.
fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

/// Strip dotted/scoped prefixes and trailing `(` from a callee text.
/// `"foo.bar.baz("` → `"baz"`, `"a::b"` → `"b"`.
fn lastSegment(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r");
    // Strip trailing `(`
    var end = trimmed.len;
    while (end > 0 and (trimmed[end - 1] == '(' or trimmed[end - 1] == ' ')) {
        end -= 1;
    }
    const work = trimmed[0..end];
    // Find last `.` `:` `>`
    var last: usize = 0;
    var found = false;
    for (work, 0..) |ch, i| {
        if (ch == '.' or ch == ':' or ch == '>') {
            last = i;
            found = true;
        }
    }
    if (found and last + 1 < work.len) return work[last + 1 ..];
    return work;
}

/// Navigate C/C++ declarator nesting to find the leaf identifier.
/// Handles `pointer_declarator`, `function_declarator`, `qualified_identifier`,
/// etc.
fn findCName(node: ts.Node, source: []const u8) ?[]const u8 {
    var cur_opt: ?ts.Node = node.fieldChild("declarator");
    var iterations: u32 = 0;
    while (cur_opt) |cur| : (iterations += 1) {
        if (iterations >= 16) break;
        const k = cur.kind();
        if (std.mem.eql(u8, k, "identifier") or
            std.mem.eql(u8, k, "field_identifier") or
            std.mem.eql(u8, k, "type_identifier") or
            std.mem.eql(u8, k, "destructor_name") or
            std.mem.eql(u8, k, "operator_name"))
        {
            return cur.text(source);
        }
        if (std.mem.eql(u8, k, "qualified_identifier")) {
            cur_opt = cur.fieldChild("name");
            continue;
        }
        cur_opt = cur.fieldChild("declarator");
    }
    return null;
}

/// Walk up from `node`'s parent to find an enclosing type scope.
/// Returns `.found=true` with the scope name when one is found.
fn walkUpScope(node: ts.Node, spec: LangSpec, source: []const u8) struct { found: bool, name: ?[]const u8 } {
    var pn = node.parent();
    while (!pn.isNull()) {
        const k = pn.kind();
        if (typeKindFor(k, spec.type_kinds) != null) {
            const name_node = pn.fieldChild("name");
            const n = if (name_node) |nn| nn.text(source) else "";
            return .{ .found = true, .name = if (n.len > 0) n else null };
        }
        if (inList(k, spec.scope_open_kinds)) {
            const name_node = pn.fieldChild(spec.scope_name_field);
            const n = if (name_node) |nn| nn.text(source) else "";
            return .{ .found = true, .name = if (n.len > 0) n else null };
        }
        pn = pn.parent();
    }
    return .{ .found = false, .name = null };
}

/// DFS descendants to find the best import target string.
/// Returns empty string if nothing found.
fn extractImportTarget(node: ts.Node, source: []const u8) []const u8 {
    // Iterative DFS — small fixed stack (imports are never deep)
    var stack: [64]ts.Node = undefined;
    var top: usize = 0;
    stack[top] = node;
    top += 1;

    while (top > 0) {
        top -= 1;
        const cur = stack[top];
        if (cur.isNull()) continue;

        const k = cur.kind();
        // Prefer string literals (Python import from, JS import "...", C #include)
        if (std.mem.containsAtLeast(u8, k, 1, "string")) {
            const raw = cur.text(source);
            if (raw.len >= 2) {
                const inner = raw[1 .. raw.len - 1];
                const capped = if (inner.len > 256) inner[0..256] else inner;
                return capped;
            }
            return raw;
        }
        // Module path identifiers
        if (std.mem.eql(u8, k, "dotted_name") or
            std.mem.eql(u8, k, "scoped_identifier") or
            std.mem.eql(u8, k, "identifier") or
            std.mem.eql(u8, k, "import_spec"))
        {
            const t = cur.text(source);
            if (t.len > 0) {
                const capped = if (t.len > 256) t[0..256] else t;
                return capped;
            }
        }

        // Push children in reverse order
        const cc = cur.childCount();
        var i: u32 = cc;
        while (i > 0) {
            i -= 1;
            const child = cur.child(i);
            if (!child.isNull() and top < stack.len - 1) {
                stack[top] = child;
                top += 1;
            }
        }
    }
    return "";
}

// ██████████████████████████████████████████████████████████████████████████
// Main extraction entry point
// ██████████████████████████████████████████████████████████████████████████

/// Extract symbols and edges from `source` using the generic config-driven
/// walker.  `allocator` owns all returned strings; arena is used only for
/// DFS scratch stacks.
pub fn extract(
    allocator: std.mem.Allocator,
    source: []const u8,
    lang: ts.LanguageId,
) anyerror!ExtractionResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var symbols = std.ArrayList(ExtractedSymbol).initCapacity(allocator, 64) catch @panic("OOM");
    var edges = std.ArrayList(ExtractedEdge).initCapacity(allocator, 32) catch @panic("OOM");

    // If we have no spec for this language, return empty result cleanly.
    const spec = specFor(lang) orelse {
        return .{
            .symbols = try symbols.toOwnedSlice(allocator),
            .edges = try edges.toOwnedSlice(allocator),
            .language = lang,
            .errors = 0,
        };
    };

    // Create a fresh parser for this call.
    const language = ts.languageForId(lang) orelse return error.NoGrammarLinked;
    var p = ts.Parser.init() catch return error.ParserInitFailed;
    defer p.deinit();
    p.setLanguage(language) catch return error.IncompatibleLanguageVersion;
    var tree = p.parseString(source) catch return error.ParseFailed;
    defer tree.deinit();

    const root = tree.root();
    var error_count: u32 = 0;

    // ── Pass 1: symbols + CONTAINS + IMPORTS ─────────────────────────────

    var node_stack = std.ArrayList(ts.Node).initCapacity(arena_alloc, 64) catch @panic("OOM");
    try node_stack.append(arena_alloc, root);

    while (node_stack.items.len > 0) {
        const node = node_stack.pop() orelse continue;
        if (node.isNull()) continue;

        const kind_str = node.kind();

        // Push children in reverse so leftmost is processed first (pre-order).
        const child_count = node.childCount();
        var ci: u32 = child_count;
        while (ci > 0) {
            ci -= 1;
            const child = node.child(ci);
            if (!child.isNull()) try node_stack.append(arena_alloc, child);
        }

        // Count ERROR nodes; skip root containers.
        if (std.mem.eql(u8, kind_str, "ERROR")) {
            error_count += 1;
            continue;
        }
        if (std.mem.eql(u8, kind_str, "source_file") or
            std.mem.eql(u8, kind_str, "program") or
            std.mem.eql(u8, kind_str, "translation_unit") or
            std.mem.eql(u8, kind_str, "compilation_unit"))
        {
            continue;
        }

        // ── (a) Go type_spec ──────────────────────────────────────────────
        if (spec.go_type_spec and std.mem.eql(u8, kind_str, "type_spec")) {
            const name_node = node.fieldChild("name") orelse continue;
            const name = name_node.text(source);
            if (name.len == 0) continue;

            // Determine sub-kind from the "type" field child.
            var sym_kind: SymbolKind = .type_alias;
            if (node.fieldChild("type")) |type_node| {
                const tk = type_node.kind();
                if (std.mem.eql(u8, tk, "struct_type")) {
                    sym_kind = .struct_type;
                } else if (std.mem.eql(u8, tk, "interface_type")) {
                    sym_kind = .interface;
                }
            }

            try symbols.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .kind = sym_kind,
                .line_start = node.startPoint().row + 1,
                .line_end = node.endPoint().row + 1,
                .col_start = node.startPoint().column,
                .col_end = node.endPoint().column,
            });
            continue;
        }

        // ── (a) Generic type declarations ─────────────────────────────────
        if (typeKindFor(kind_str, spec.type_kinds)) |sym_kind| {
            const name_node = node.fieldChild("name") orelse continue;
            const name = name_node.text(source);
            if (name.len == 0) continue;

            try symbols.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .kind = sym_kind,
                .line_start = node.startPoint().row + 1,
                .line_end = node.endPoint().row + 1,
                .col_start = node.startPoint().column,
                .col_end = node.endPoint().column,
            });
            continue;
        }

        // ── (b) Method declarations ───────────────────────────────────────
        if (inList(kind_str, spec.method_kinds)) {
            const name: []const u8 = blk: {
                if (spec.c_style_decl) {
                    break :blk findCName(node, source) orelse continue;
                }
                const nn = node.fieldChild("name") orelse continue;
                const n = nn.text(source);
                if (n.len == 0) continue;
                break :blk n;
            };

            // Walk up to find the enclosing type scope.
            const scope = walkUpScope(node, spec, source);
            const parent_name: ?[]const u8 = if (scope.found) scope.name else null;

            try symbols.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .kind = .method,
                .line_start = node.startPoint().row + 1,
                .line_end = node.endPoint().row + 1,
                .col_start = node.startPoint().column,
                .col_end = node.endPoint().column,
                .parent_name = if (parent_name) |pn| try allocator.dupe(u8, pn) else null,
            });

            if (parent_name) |pn| {
                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, pn),
                    .source_kind = .struct_type,
                    .target_name = try allocator.dupe(u8, name),
                    .target_kind = .method,
                    .edge_type = .contains,
                    .confidence = 1.0,
                });
            }
            continue;
        }

        // ── (b) Function declarations ─────────────────────────────────────
        if (inList(kind_str, spec.func_kinds)) {
            const name: []const u8 = blk: {
                if (spec.c_style_decl) {
                    break :blk findCName(node, source) orelse continue;
                }
                const nn = node.fieldChild("name") orelse continue;
                const n = nn.text(source);
                if (n.len == 0) continue;
                break :blk n;
            };

            // Determine if this function sits inside a type scope (→ method).
            const scope = walkUpScope(node, spec, source);
            const sym_kind: SymbolKind = if (scope.found) .method else .function;
            const parent_name: ?[]const u8 = if (scope.found) scope.name else null;

            try symbols.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .kind = sym_kind,
                .line_start = node.startPoint().row + 1,
                .line_end = node.endPoint().row + 1,
                .col_start = node.startPoint().column,
                .col_end = node.endPoint().column,
                .parent_name = if (parent_name) |pn| try allocator.dupe(u8, pn) else null,
            });

            if (sym_kind == .method) {
                if (parent_name) |pn| {
                    try edges.append(allocator, .{
                        .source_name = try allocator.dupe(u8, pn),
                        .source_kind = .struct_type,
                        .target_name = try allocator.dupe(u8, name),
                        .target_kind = .method,
                        .edge_type = .contains,
                        .confidence = 1.0,
                    });
                }
            }
            continue;
        }

        // ── (c) Import statements ─────────────────────────────────────────
        if (inList(kind_str, spec.import_kinds)) {
            const target = extractImportTarget(node, source);
            if (target.len > 0) {
                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, "(file)"),
                    .source_kind = .module,
                    .target_name = try allocator.dupe(u8, target),
                    .target_kind = .module,
                    .edge_type = .imports,
                    .confidence = 1.0,
                });
            }
            continue;
        }
    }

    // ── Pass 2: CALLS edges ───────────────────────────────────────────────

    if (spec.call_kind.len > 0) {
        var call_stack = std.ArrayList(ts.Node).initCapacity(arena_alloc, 64) catch @panic("OOM");
        try call_stack.append(arena_alloc, root);

        while (call_stack.items.len > 0) {
            const node = call_stack.pop() orelse continue;
            if (node.isNull()) continue;

            const cc = node.childCount();
            var ci: u32 = cc;
            while (ci > 0) {
                ci -= 1;
                const child = node.child(ci);
                if (!child.isNull()) try call_stack.append(arena_alloc, child);
            }

            if (!std.mem.eql(u8, node.kind(), spec.call_kind)) continue;

            // Get called function name.
            const callee_node = node.fieldChild(spec.call_callee_field) orelse continue;
            const raw = callee_node.text(source);
            const called = lastSegment(raw);
            if (called.len == 0) continue;
            if (!isIdentStart(called[0])) continue;

            // Walk up to find the nearest enclosing func/method.
            var parent_node = node.parent();
            var enclosing_fn: ?[]const u8 = null;
            while (!parent_node.isNull()) {
                const pk = parent_node.kind();
                if (inList(pk, spec.func_kinds) or inList(pk, spec.method_kinds)) {
                    const fn_name: []const u8 = blk: {
                        if (spec.c_style_decl) {
                            break :blk findCName(parent_node, source) orelse "";
                        }
                        const nn = parent_node.fieldChild("name") orelse break :blk "";
                        break :blk nn.text(source);
                    };
                    if (fn_name.len > 0) enclosing_fn = fn_name;
                    break;
                }
                parent_node = parent_node.parent();
            }

            if (enclosing_fn) |fn_name| {
                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, fn_name),
                    .source_kind = .function,
                    .target_name = try allocator.dupe(u8, called),
                    .target_kind = .function,
                    .edge_type = .calls,
                    .confidence = 1.0,
                });
            }
        }
    }

    return .{
        .symbols = try symbols.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
        .language = lang,
        .errors = error_count,
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Extractor factory — creates an Extractor for any supported language
// ██████████████████████████████████████████████████████████████████████████

/// Return an Extractor vtable entry for `lang`.
pub fn extractorFor(lang: ts.LanguageId) extractor_mod.Extractor {
    return .{ .language = lang, .extract = extract };
}
