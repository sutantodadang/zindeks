//! Tree-sitter C bindings and Zig-friendly wrapper.
//!
//! Provides safe Zig types over the raw tree-sitter C API.  Usage:
//!   const ts = @import("tree_sitter.zig");
//!   var parser = ts.Parser.init();
//!   defer parser.deinit();
//!   parser.setLanguage(ts.languages.zig);
//!   const tree = parser.parseString(source);
//!   defer tree.deinit();
//!   // walk tree.root()...
const std = @import("std");

// ██████████████████████████████████████████████████████████████████████████
// C bindings via @cImport
// ██████████████████████████████████████████████████████████████████████████

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

// ██████████████████████████████████████████████████████████████████████████
// Opaque C type aliases
// ██████████████████████████████████████████████████████████████████████████

pub const Language = *const c.TSLanguage;
pub const InputEncoding = c.TSInputEncoding;
pub const SymbolType = c.TSSymbolType;
pub const Point = c.TSPoint;
pub const Range = c.TSRange;
pub const Input = c.TSInput;

// ██████████████████████████████████████████████████████████████████████████
// Node — zero-cost wrapper over the value-type TSNode
// ██████████████████████████████████████████████████████████████████████████

pub const Node = struct {
    inner: c.TSNode,

    pub const Id = struct { context: [*]const u8 = undefined, id: ?*const anyopaque = null };

    pub fn id(self: Node) Id {
        return .{
            .context = self.inner.context[0..].ptr,
            .id = self.inner.id,
        };
    }

    pub fn isNull(self: Node) bool {
        return c.ts_node_is_null(self.inner);
    }

    pub fn kind(self: Node) []const u8 {
        const ptr = c.ts_node_type(self.inner);
        if (@intFromPtr(ptr) == 0) return "(null)";
        const len = std.mem.len(ptr);
        return ptr[0..len];
    }

    pub fn childCount(self: Node) u32 {
        return c.ts_node_child_count(self.inner);
    }

    pub fn child(self: Node, idx: u32) Node {
        return .{ .inner = c.ts_node_child(self.inner, idx) };
    }

    pub fn namedChildCount(self: Node) u32 {
        return c.ts_node_named_child_count(self.inner);
    }

    pub fn namedChild(self: Node, idx: u32) Node {
        return .{ .inner = c.ts_node_named_child(self.inner, idx) };
    }

    pub fn fieldChild(self: Node, field_name: []const u8) ?Node {
        const n = c.ts_node_child_by_field_name(self.inner, field_name.ptr, @intCast(field_name.len));
        if (c.ts_node_is_null(n)) return null;
        return .{ .inner = n };
    }

    pub fn parent(self: Node) Node {
        return .{ .inner = c.ts_node_parent(self.inner) };
    }

    pub fn nextSibling(self: Node) Node {
        return .{ .inner = c.ts_node_next_sibling(self.inner) };
    }

    pub fn prevSibling(self: Node) Node {
        return .{ .inner = c.ts_node_prev_sibling(self.inner) };
    }

    pub fn nextNamedSibling(self: Node) Node {
        return .{ .inner = c.ts_node_next_named_sibling(self.inner) };
    }

    pub fn startByte(self: Node) u32 {
        return c.ts_node_start_byte(self.inner);
    }

    pub fn endByte(self: Node) u32 {
        return c.ts_node_end_byte(self.inner);
    }

    pub fn startPoint(self: Node) Point {
        return c.ts_node_start_point(self.inner);
    }

    pub fn endPoint(self: Node) Point {
        return c.ts_node_end_point(self.inner);
    }

    pub fn text(self: Node, source: []const u8) []const u8 {
        const start = self.startByte();
        const end = self.endByte();
        if (start >= source.len or end > source.len or end < start) return "";
        return source[start..end];
    }

    /// Return the S-expression representation (caller must free with allocator).
    pub fn toString(self: Node, allocator: std.mem.Allocator) ![]const u8 {
        const cstr = c.ts_node_string(self.inner);
        if (cstr == null) return error.NullNode;
        const len = std.mem.len(cstr.?);
        const result = try allocator.dupe(u8, cstr.?[0..len]);
        // ts_node_string returns malloc'd memory — free it
        c.ts_free(cstr);
        return result;
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Tree — owns the parsed syntax tree
// ██████████████████████████████████████████████████████████████████████████

pub const Tree = struct {
    inner: ?*c.TSTree,

    pub fn deinit(self: *Tree) void {
        if (self.inner) |t| {
            c.ts_tree_delete(t);
            self.inner = null;
        }
    }

    pub fn root(self: *const Tree) Node {
        return .{ .inner = c.ts_tree_root_node(self.inner.?) };
    }

    pub fn edit(self: *Tree, input_edit: c.TSInputEdit) void {
        c.ts_tree_edit(self.inner, &input_edit);
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Parser — reusable, language-specific parser
// ██████████████████████████████████████████████████████████████████████████

pub const Parser = struct {
    inner: ?*c.TSParser,

    pub fn init() !Parser {
        const p = c.ts_parser_new() orelse return error.OutOfMemory;
        return .{ .inner = p };
    }

    pub fn deinit(self: *Parser) void {
        if (self.inner) |p| {
            c.ts_parser_delete(p);
            self.inner = null;
        }
    }

    pub fn setLanguage(self: *Parser, lang: Language) !void {
        if (!c.ts_parser_set_language(self.inner.?, lang)) {
            return error.IncompatibleLanguageVersion;
        }
    }

    pub fn parseString(self: *Parser, source: []const u8) !Tree {
        const tree = c.ts_parser_parse_string(self.inner.?, null, source.ptr, @intCast(source.len));
        if (tree == null) return error.ParseFailed;
        return .{ .inner = tree };
    }

    /// Parse from a file or other input using a callback.
    pub fn parseWithInput(self: *Parser, input: c.TSInput) !Tree {
        const tree = c.ts_parser_parse(self.inner.?, null, input);
        if (tree == null) return error.ParseFailed;
        return .{ .inner = tree };
    }
};

// ██████████████████████████████████████████████████████████████████████████
// Query — pattern-matching on syntax trees
// ██████████████████████████████████████████████████████████████████████████

pub const Query = struct {
    inner: ?*c.TSQuery,

    pub fn compile(lang: Language, source: []const u8) !Query {
        var error_offset: u32 = 0;
        var error_type: c.TSQueryError = 0;
        const q = c.ts_query_new(
            lang,
            source.ptr,
            @intCast(source.len),
            &error_offset,
            &error_type,
        );
        if (q == null) return error.QueryCompileFailed;
        return .{ .inner = q };
    }

    pub fn deinit(self: *Query) void {
        if (self.inner) |q| {
            c.ts_query_delete(q);
            self.inner = null;
        }
    }

    pub fn patternCount(self: *const Query) u32 {
        return c.ts_query_pattern_count(self.inner.?);
    }

    pub fn captureCount(self: *const Query) u32 {
        return c.ts_query_capture_count(self.inner.?);
    }
};

pub const QueryCursor = struct {
    inner: ?*c.TSQueryCursor,

    pub fn init() !QueryCursor {
        const cursor = c.ts_query_cursor_new() orelse return error.OutOfMemory;
        return .{ .inner = cursor };
    }

    pub fn deinit(self: *QueryCursor) void {
        if (self.inner) |cur| {
            c.ts_query_cursor_delete(cur);
            self.inner = null;
        }
    }

    pub fn exec(self: *QueryCursor, query: *const Query, node: Node) void {
        c.ts_query_cursor_exec(self.inner.?, query.inner.?, node.inner);
    }

    pub fn nextMatch(self: *QueryCursor) ?Match {
        var match: c.TSQueryMatch = undefined;
        if (c.ts_query_cursor_next_match(self.inner.?, &match)) {
            return .{ .inner = match };
        }
        return null;
    }

    pub const Match = struct {
        inner: c.TSQueryMatch,
    };
};

// ██████████████████████████████████████████████████████████████████████████
// Language registry — loads grammar functions at comptime or runtime
// ██████████████████████████████████████████████████████████████████████████

/// Language identifiers — maps file extensions to tree-sitter grammars.
pub const LanguageId = enum {
    c,
    c_sharp,
    cpp,
    css,
    dart,
    elixir,
    go,
    haskell,
    java,
    javascript,
    json,
    lua,
    python,
    rust,
    scala,
    swift,
    toml,
    tsx,
    typescript,
    yaml,
    zig,

    pub fn fromExtension(ext: []const u8) ?LanguageId {
        if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h")) return .c;
        if (std.mem.eql(u8, ext, ".cpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx") or
            std.mem.eql(u8, ext, ".hpp") or std.mem.eql(u8, ext, ".hxx")) return .cpp;
        if (std.mem.eql(u8, ext, ".cs")) return .c_sharp;
        if (std.mem.eql(u8, ext, ".css")) return .css;
        if (std.mem.eql(u8, ext, ".dart")) return .dart;
        if (std.mem.eql(u8, ext, ".ex") or std.mem.eql(u8, ext, ".exs")) return .elixir;
        if (std.mem.eql(u8, ext, ".go")) return .go;
        if (std.mem.eql(u8, ext, ".hs")) return .haskell;
        if (std.mem.eql(u8, ext, ".java")) return .java;
        if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or std.mem.eql(u8, ext, ".mjs")) return .javascript;
        if (std.mem.eql(u8, ext, ".json")) return .json;
        if (std.mem.eql(u8, ext, ".lua")) return .lua;
        if (std.mem.eql(u8, ext, ".py") or std.mem.eql(u8, ext, ".pyi")) return .python;
        if (std.mem.eql(u8, ext, ".rs")) return .rust;
        if (std.mem.eql(u8, ext, ".scala") or std.mem.eql(u8, ext, ".sc")) return .scala;
        if (std.mem.eql(u8, ext, ".swift")) return .swift;
        if (std.mem.eql(u8, ext, ".toml")) return .toml;
        if (std.mem.eql(u8, ext, ".ts")) return .typescript;
        if (std.mem.eql(u8, ext, ".tsx")) return .tsx;
        if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
        if (std.mem.eql(u8, ext, ".zig")) return .zig;
        return null;
    }

    pub fn displayName(self: LanguageId) []const u8 {
        return switch (self) {
            .c => "C",
            .c_sharp => "C#",
            .cpp => "C++",
            .css => "CSS",
            .dart => "Dart",
            .elixir => "Elixir",
            .go => "Go",
            .haskell => "Haskell",
            .java => "Java",
            .javascript => "JavaScript",
            .json => "JSON",
            .lua => "Lua",
            .python => "Python",
            .rust => "Rust",
            .scala => "Scala",
            .swift => "Swift",
            .toml => "TOML",
            .tsx => "TSX",
            .typescript => "TypeScript",
            .yaml => "YAML",
            .zig => "Zig",
        };
    }
};

// Grammars are loaded lazily via extern functions linked at build time.
// Each grammar C file exports `tree_sitter_<lang>()` → *const TSLanguage.

extern fn tree_sitter_c() Language;
extern fn tree_sitter_c_sharp() Language;
extern fn tree_sitter_cpp() Language;
extern fn tree_sitter_css() Language;
extern fn tree_sitter_dart() Language;
extern fn tree_sitter_elixir() Language;
extern fn tree_sitter_go() Language;
extern fn tree_sitter_haskell() Language;
extern fn tree_sitter_java() Language;
extern fn tree_sitter_javascript() Language;
extern fn tree_sitter_json() Language;
extern fn tree_sitter_lua() Language;
extern fn tree_sitter_python() Language;
extern fn tree_sitter_rust() Language;
extern fn tree_sitter_scala() Language;
extern fn tree_sitter_swift() Language;
extern fn tree_sitter_toml() Language;
extern fn tree_sitter_tsx() Language;
extern fn tree_sitter_typescript() Language;
extern fn tree_sitter_yaml() Language;
extern fn tree_sitter_zig() Language;

/// Get the tree-sitter language for a given LanguageId.
/// Returns null if no grammar is linked for that language.
pub fn languageForId(id: LanguageId) ?Language {
    return switch (id) {
        .c => tree_sitter_c(),
        .c_sharp => tree_sitter_c_sharp(),
        .cpp => tree_sitter_cpp(),
        .css => tree_sitter_css(),
        .dart => tree_sitter_dart(),
        .elixir => tree_sitter_elixir(),
        .go => tree_sitter_go(),
        .haskell => tree_sitter_haskell(),
        .java => tree_sitter_java(),
        .javascript => tree_sitter_javascript(),
        .json => tree_sitter_json(),
        .lua => tree_sitter_lua(),
        .python => tree_sitter_python(),
        .rust => tree_sitter_rust(),
        .scala => tree_sitter_scala(),
        .swift => tree_sitter_swift(),
        .toml => tree_sitter_toml(),
        .tsx => tree_sitter_tsx(),
        .typescript => tree_sitter_typescript(),
        .yaml => tree_sitter_yaml(),
        .zig => tree_sitter_zig(),
    };
}