//! Zig language extractor — uses tree-sitter AST queries to find symbols and edges.
//!
//! Extracts: functions, methods, struct/enum/union/opaque types, constants,
//! variables, type aliases, test declarations, and @import edges.
//!
//! Note: tree-sitter-zig uses `variable_declaration` for BOTH `const` and `var`.
//! There is no `constant_declaration` node type. The first child of a
//! `variable_declaration` contains the `_variable_declaration_header` which
//! starts with `const` or `var` and contains the identifier.
const std = @import("std");
const ts = @import("tree_sitter.zig");
const extractor_mod = @import("extractor.zig");

const ExtractedSymbol = extractor_mod.ExtractedSymbol;
const ExtractedEdge = extractor_mod.ExtractedEdge;
const ExtractionResult = extractor_mod.ExtractionResult;
const SymbolKind = extractor_mod.SymbolKind;
const EdgeKind = extractor_mod.EdgeKind;

// ██████████████████████████████████████████████████████████████████████████
// Extraction logic
// ██████████████████████████████████████████████████████████████████████████

/// Extract all symbols and edges from Zig source code.
pub fn extract(allocator: std.mem.Allocator, source: []const u8, lang: ts.LanguageId) anyerror!ExtractionResult {
    std.debug.assert(lang == .zig);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var symbols = std.ArrayList(ExtractedSymbol).initCapacity(allocator, 64) catch @panic("OOM");
    var edges = std.ArrayList(ExtractedEdge).initCapacity(allocator, 32) catch @panic("OOM");

    // Parse with tree-sitter
    const language = ts.languageForId(.zig) orelse return error.NoGrammarLinked;
    var parser = ts.Parser.init() catch return error.ParserInitFailed;
    defer parser.deinit();
    parser.setLanguage(language) catch return error.IncompatibleLanguageVersion;

    var tree = parser.parseString(source) catch return error.ParseFailed;
    defer tree.deinit();

    const root = tree.root();
    var error_count: u32 = 0;

    // Walk the tree manually, depth-first
    var node_stack = std.ArrayList(ts.Node).initCapacity(arena_alloc, 32) catch @panic("OOM");
    try node_stack.append(arena_alloc, root);

    // Track the enclosing struct/enum/union name for method/field attribution
    var enclosing_type_name: ?[]const u8 = null;

    while (node_stack.items.len > 0) {
        const node = node_stack.pop() orelse continue;
        if (node.isNull()) continue;

        const kind_str = node.kind();

        // Pre-order: push children in reverse so leftmost is processed first
        const child_count = node.childCount();
        var i: u32 = child_count;
        while (i > 0) {
            i -= 1;
            const child = node.child(i);
            if (!child.isNull()) {
                try node_stack.append(arena_alloc, child);
            }
        }

        // Skip the root node
        if (std.mem.eql(u8, kind_str, "source_file") or
            std.mem.eql(u8, kind_str, "ERROR"))
        {
            if (std.mem.eql(u8, kind_str, "ERROR")) error_count += 1;
            continue;
        }

        // ── Extract based on node kind ────────────────────────────────

        if (std.mem.eql(u8, kind_str, "function_declaration")) {
            // function_declaration has a "name" field for the identifier
            const name_node = node.fieldChild("name") orelse {
                // Try first named child as fallback
                const first_named = node.namedChild(0);
                if (first_named.isNull()) continue;
                if (!std.mem.eql(u8, first_named.kind(), "identifier")) continue;
                const name = first_named.text(source);
                if (name.len == 0) continue;
                const sym_kind: SymbolKind = if (enclosing_type_name != null) .method else .function;
                try symbols.append(allocator, .{
                    .name = try allocator.dupe(u8, name),
                    .kind = sym_kind,
                    .line_start = node.startPoint().row + 1,
                    .line_end = node.endPoint().row + 1,
                    .col_start = node.startPoint().column,
                    .col_end = node.endPoint().column,
                    .parent_name = if (enclosing_type_name) |pn| try allocator.dupe(u8, pn) else null,
                });
                continue;
            };
            const name = name_node.text(source);
            if (name.len == 0) continue;

            const sym_kind: SymbolKind = if (enclosing_type_name != null) .method else .function;
            try symbols.append(allocator, .{
                .name = try allocator.dupe(u8, name),
                .kind = sym_kind,
                .line_start = node.startPoint().row + 1,
                .line_end = node.endPoint().row + 1,
                .col_start = node.startPoint().column,
                .col_end = node.endPoint().column,
                .parent_name = if (enclosing_type_name) |pn| try allocator.dupe(u8, pn) else null,
            });

            // If this function is inside a struct/enum, create a "contains" edge
            if (enclosing_type_name) |pn| {
                try edges.append(allocator, .{
                    .source_name = try allocator.dupe(u8, pn),
                    .source_kind = .struct_type,
                    .target_name = try allocator.dupe(u8, name),
                    .target_kind = sym_kind,
                    .edge_type = .contains,
                    .confidence = 1.0,
                });
            }
        } else if (std.mem.eql(u8, kind_str, "struct_declaration") or
                    std.mem.eql(u8, kind_str, "enum_declaration") or
                    std.mem.eql(u8, kind_str, "union_declaration") or
                    std.mem.eql(u8, kind_str, "opaque_declaration"))
        {
            // struct/enum/union/opaque type declarations appear as value of a
            // variable_declaration (e.g., const MyStruct = struct { ... }).
            // They don't have a "name" field — the name comes from the parent.
            // Set enclosing_type_name so child methods get attributed correctly.
            // The variable_declaration handler will record the actual symbol name.
            enclosing_type_name = kind_str;
        } else if (std.mem.eql(u8, kind_str, "variable_declaration")) {
            // variable_declaration handles BOTH `const` and `var` declarations.
            // Structure: [pub?] [export/extern?] [threadlocal?] _variable_declaration_header [= expression] ;
            // The _variable_declaration_header contains: const/var identifier [:type]
            // We need to find the identifier name and check if the value is a type declaration.

            // Find the identifier (first named child of the header, or look for it directly)
            // tree-sitter-zig: the variable_declaration has named children including
            // the identifier and possibly the value expression.
            const name_node = node.fieldChild("name") orelse blk: {
                // Fallback: scan named children for an identifier
                var ni: u32 = 0;
                while (ni < node.namedChildCount()) : (ni += 1) {
                    const nc = node.namedChild(ni);
                    if (std.mem.eql(u8, nc.kind(), "identifier")) {
                        break :blk nc;
                    }
                }
                break :blk null;
            };
            if (name_node == null) continue;
            const name = name_node.?.text(source);
            if (name.len == 0) continue;

            // Check if the value is a type declaration (struct/enum/union/opaque)
            // In tree-sitter-zig, the value expression appears as a named child
            // after the identifier. Its kind tells us what it is.
            var sym_kind: SymbolKind = .const_value;

            // Look for the value expression among named children
            var ci: u32 = 0;
            while (ci < node.namedChildCount()) : (ci += 1) {
                const child_node = node.namedChild(ci);
                const child_kind = child_node.kind();
                if (std.mem.eql(u8, child_kind, "struct_declaration")) {
                    sym_kind = .struct_type;
                    enclosing_type_name = name;
                    break;
                } else if (std.mem.eql(u8, child_kind, "enum_declaration")) {
                    sym_kind = .enum_type;
                    enclosing_type_name = name;
                    break;
                } else if (std.mem.eql(u8, child_kind, "union_declaration")) {
                    sym_kind = .union_type;
                    enclosing_type_name = name;
                    break;
                } else if (std.mem.eql(u8, child_kind, "opaque_declaration")) {
                    sym_kind = .struct_type; // opaque types treated as struct-like
                    enclosing_type_name = name;
                    break;
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

            } else if (std.mem.eql(u8, kind_str, "builtin_expr")) {
            // Check for @import("module")
            const call_child = node.namedChild(0);
            if (call_child.isNull()) continue;
            if (std.mem.eql(u8, call_child.kind(), "call_expr")) {
                // Navigate to function name
                const func_node = call_child.fieldChild("function") orelse continue;
                if (std.mem.eql(u8, func_node.text(source), "@import")) {
                    const args = call_child.fieldChild("arguments") orelse continue;
                    const path_node = args.namedChild(0);
                    if (path_node.isNull()) continue;
                    const path_text = path_node.text(source);
                    // Strip quotes
                    const import_path = if (path_text.len >= 2) path_text[1 .. path_text.len - 1] else path_text;

                    try edges.append(allocator, .{
                        .source_name = try allocator.dupe(u8, "(file)"),
                        .source_kind = .module,
                        .target_name = try allocator.dupe(u8, import_path),
                        .target_kind = .module,
                        .edge_type = .imports,
                        .confidence = 1.0,
                    });
                }
            }
        }
    }

    // ── Second pass: extract CALLS edges ────────────────────────────
    // Walk all call_expression nodes, find enclosing function via
    // ts_node_parent(), and create CALLS edges.
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

        if (!std.mem.eql(u8, node.kind(), "call_expression")) continue;

        // Get called function name from the "function" field
        const func_node = node.fieldChild("function") orelse continue;
        const called_name = func_node.text(source);
        if (called_name.len == 0) continue;
        // Skip builtin calls like @import, @intCast etc.
        if (called_name[0] == '@') continue;

        // Walk up to find enclosing function_declaration
        var parent_node = node.parent();
        var enclosing_fn: ?[]const u8 = null;
        while (!parent_node.isNull()) {
            if (std.mem.eql(u8, parent_node.kind(), "function_declaration")) {
                const fn_name_node = parent_node.fieldChild("name") orelse blk2: {
                    const nc = parent_node.namedChild(0);
                    if (!nc.isNull() and std.mem.eql(u8, nc.kind(), "identifier")) {
                        break :blk2 nc;
                    }
                    break :blk2 null;
                };
                if (fn_name_node) |nn| {
                    const n = nn.text(source);
                    if (n.len > 0) enclosing_fn = n;
                }
                break;
            }
            parent_node = parent_node.parent();
        }

        if (enclosing_fn) |fn_name| {
            try edges.append(allocator, .{
                .source_name = try allocator.dupe(u8, fn_name),
                .source_kind = .function,
                .target_name = try allocator.dupe(u8, called_name),
                .target_kind = .function,
                .edge_type = .calls,
                .confidence = 1.0,
            });
        }
    }

    return .{
        .symbols = try symbols.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
        .language = .zig,
        .errors = error_count,
    };
}

// ██████████████████████████████████████████████████████████████████████████
// Extractor singleton — registered in the Registry
// ██████████████████████████████████████████████████████████████████████████

pub const extractor: extractor_mod.Extractor = .{
    .language = .zig,
    .extract = extract,
};