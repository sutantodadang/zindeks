//! Lightweight rule-based code summarisation — no ML, pure pattern
//! matching for Zig, Python, JavaScript/TypeScript, Rust, Go, C, C++, Java.
//!
//! Extracts: signature, purpose (from doc comments), key operations,
//! symbol dependencies, and a rough complexity score.

const std = @import("std");

/// Summary of a single code symbol (function, struct, class, etc.).
pub const SymbolSummary = struct {
    name: []const u8,
    kind: []const u8, // "function", "struct", "class", etc.
    signature: []const u8,
    purpose: []const u8, // one-line description extracted from comments
    key_operations: []const []const u8, // list of important operations
    dependencies: []const []const u8, // symbols this depends on
    complexity_score: f32, // rough metric: lines + branch count

    pub fn deinit(self: *const SymbolSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        // self.kind is a string literal, not allocated
        allocator.free(self.signature);
        if (self.purpose.len > 0) allocator.free(self.purpose);
        for (self.key_operations) |op| allocator.free(op);
        allocator.free(self.key_operations);
        for (self.dependencies) |dep| allocator.free(dep);
        allocator.free(self.dependencies);
    }
};

/// Summarise a code snippet for a given language.
pub fn summarizeSymbol(
    allocator: std.mem.Allocator,
    code: []const u8,
    language: []const u8,
) !SymbolSummary {
    const name = try extractName(allocator, code, language);
    const kind = extractKind(code, language);
    const sig = try extractSignature(allocator, code, language);
    const purpose = (try extractPurpose(allocator, code)) orelse "";
    const ops = try extractKeyOperations(allocator, code);
    const deps = try extractDependencies(allocator, code, language);
    const score = computeComplexity(code);

    return .{
        .name = name,
        .kind = kind,
        .signature = sig,
        .purpose = purpose,
        .key_operations = ops,
        .dependencies = deps,
        .complexity_score = score,
    };
}

// ── Name extraction ────────────────────────────────────────────────

fn extractName(allocator: std.mem.Allocator, code: []const u8, language: []const u8) ![]const u8 {
    const trimmed = skipCommentsAndWS(code, language);

    var it = std.mem.tokenizeAny(u8, trimmed, " \t\n\r(");
    while (it.next()) |tok| {
        if (isDeclarationKeyword(tok)) continue;
        if (std.mem.eql(u8, tok, "class") or std.mem.eql(u8, tok, "struct") or
            std.mem.eql(u8, tok, "enum") or std.mem.eql(u8, tok, "interface") or
            std.mem.eql(u8, tok, "trait"))
        {
            continue;
        }
        return allocator.dupe(u8, tok);
    }
    return allocator.dupe(u8, "(unknown)");
}

fn isDeclarationKeyword(tok: []const u8) bool {
    const kws = [_][]const u8{
        "fn",          "func",     "def",     "function",
        "pub",         "export",   "static",  "virtual",
        "inline",      "noinline", "const",   "volatile",
        "extern",      "override", "final",   "abstract",
        "async",       "await",    "unsafe",  "mut",
        "public",      "private",  "protected",
        "void",        "int",      "float",   "double",
        "bool",        "char",     "long",    "short",
        "unsigned",    "signed",   "auto",    "let",
        "var",         "val",      "type",    "typedef",
        "comptime",    "threadlocal",
    };
    for (kws) |kw| {
        if (std.mem.eql(u8, tok, kw)) return true;
    }
    return false;
}

// ── Kind extraction ────────────────────────────────────────────────

fn extractKind(code: []const u8, language: []const u8) []const u8 {
    const trimmed = skipCommentsAndWS(code, language);
    var it = std.mem.tokenizeAny(u8, trimmed, " \t\n\r");

    var cur: ?[]const u8 = null;
    var prev: ?[]const u8 = null;
    while (it.next()) |tok| {
        prev = cur;
        cur = tok;
        if (prev) |p| {
            if (std.mem.eql(u8, p, "class")) return "class";
            if (std.mem.eql(u8, p, "struct")) return "struct";
            if (std.mem.eql(u8, p, "enum")) return "enum";
            if (std.mem.eql(u8, p, "interface")) return "interface";
            if (std.mem.eql(u8, p, "trait")) return "trait";
            if (std.mem.eql(u8, p, "module")) return "module";
        }
    }
    return "function";
}

// ── Signature extraction ───────────────────────────────────────────

fn extractSignature(
    allocator: std.mem.Allocator,
    code: []const u8,
    language: []const u8,
) ![]const u8 {
    var lines = std.mem.splitAny(u8, code, "\n\r");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (isSignatureStart(trimmed, language)) {
            return allocator.dupe(u8, trimmed);
        }
    }
    return allocator.dupe(u8, "");
}

fn isSignatureStart(line: []const u8, language: []const u8) bool {
    _ = language;
    const patterns = [_][]const u8{
        "pub fn ", "fn ", "func ", "def ", "function ",
        "class ", "struct ", "enum ", "trait ", "interface ",
        "pub fn(", "fn(", "func(", "def(", "function(",
    };
    for (patterns) |p| {
        if (std.mem.startsWith(u8, line, p)) return true;
    }
    if (!std.mem.startsWith(u8, line, "//") and
        !std.mem.startsWith(u8, line, "#") and
        !std.mem.startsWith(u8, line, "/*") and
        !std.mem.startsWith(u8, line, "*") and
        !std.mem.startsWith(u8, line, "import") and
        !std.mem.startsWith(u8, line, "package") and
        !std.mem.startsWith(u8, line, "use ") and
        !std.mem.startsWith(u8, line, "mod ") and
        !std.mem.startsWith(u8, line, "from ") and
        !std.mem.startsWith(u8, line, "const ") and
        line.len > 0)
    {
        if (std.mem.indexOfScalar(u8, line, '(') != null) {
            return true;
        }
    }
    return false;
}

// ── Purpose extraction ─────────────────────────────────────────────

/// Extract a doc comment / purpose description from code.
/// Looks for `//`, `///`, `/**`, `/*!`, `#`, `"""` before the declaration.
pub fn extractPurpose(
    allocator: std.mem.Allocator,
    code: []const u8,
) !?[]const u8 {
    var lines = std.mem.splitAny(u8, code, "\n");
    var purpose_buf = std.ArrayList(u8){};
    errdefer purpose_buf.deinit(allocator);

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#!") or
            std.mem.startsWith(u8, trimmed, "#!/"))
            continue;

        // Doc comment patterns
        if (std.mem.startsWith(u8, trimmed, "///") or
            std.mem.startsWith(u8, trimmed, "//!") or
            std.mem.startsWith(u8, trimmed, "//"))
        {
            const after = std.mem.trimLeft(u8, trimmed["//".len..], " \t/!");
            if (after.len == 0) continue;
            if (purpose_buf.items.len > 0) try purpose_buf.append(allocator, ' ');
            try purpose_buf.appendSlice(allocator, after);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "# ") or
            std.mem.startsWith(u8, trimmed, "## "))
        {
            const after = std.mem.trimLeft(u8, trimmed[2..], " \t#");
            if (after.len == 0) continue;
            if (purpose_buf.items.len > 0) try purpose_buf.append(allocator, ' ');
            try purpose_buf.appendSlice(allocator, after);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "/*") or
            std.mem.startsWith(u8, trimmed, "/**"))
        {
            var comment = trimmed;
            if (std.mem.startsWith(u8, comment, "/**")) {
                comment = comment[3..];
            } else {
                comment = comment[2..];
            }
            if (std.mem.endsWith(u8, comment, "*/")) {
                comment = comment[0 .. comment.len - 2];
            }
            comment = std.mem.trim(u8, comment, " \t*");
            if (comment.len == 0) continue;
            if (purpose_buf.items.len > 0) try purpose_buf.append(allocator, ' ');
            try purpose_buf.appendSlice(allocator, comment);
            continue;
        }

        // Python docstrings: """...""" or '''...'''
        if (std.mem.startsWith(u8, trimmed, "\"\"\"") or
            std.mem.startsWith(u8, trimmed, "'''"))
        {
            const quote: u8 = trimmed[0];
            var doc = std.ArrayList(u8){};
            defer doc.deinit(allocator);

            var inner = trimmed[3..];
            if (std.mem.indexOfScalar(u8, inner, quote)) |end| {
                inner = inner[0..end];
            }
            const cleaned = std.mem.trim(u8, inner, " \t\r\n");
            if (cleaned.len > 0) {
                try doc.appendSlice(allocator, cleaned);
            }
            while (lines.next()) |next_line| {
                const nl = std.mem.trim(u8, next_line, " \t\r\n");
                if (std.mem.indexOfScalar(u8, nl, quote) != null) break;
                if (nl.len > 0) {
                    if (doc.items.len > 0) try doc.append(allocator, ' ');
                    try doc.appendSlice(allocator, nl);
                }
            }
            if (doc.items.len > 0) {
                const slice = try doc.toOwnedSlice(allocator);
                return @as(?[]const u8, slice);
            }
            continue;
        }

        // Non-comment line — stop
        if (!std.mem.startsWith(u8, trimmed, "//") and
            !std.mem.startsWith(u8, trimmed, "/*") and
            !std.mem.startsWith(u8, trimmed, "*") and
            !std.mem.startsWith(u8, trimmed, "#") and
            !std.mem.startsWith(u8, trimmed, "///") and
            !std.mem.startsWith(u8, trimmed, "\"\"\"") and
            !std.mem.startsWith(u8, trimmed, "'''"))
        {
            break;
        }
    }

    if (purpose_buf.items.len == 0) return null;
    const slice = try purpose_buf.toOwnedSlice(allocator);
    return @as(?[]const u8, slice);
}

// ── Key operations ─────────────────────────────────────────────────

fn extractKeyOperations(
    allocator: std.mem.Allocator,
    code: []const u8,
) ![]const []const u8 {
    var ops = std.ArrayList([]const u8){};
    errdefer {
        for (ops.items) |op| allocator.free(op);
        ops.deinit(allocator);
    }

    var lines = std.mem.splitAny(u8, code, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        if (std.mem.indexOf(u8, trimmed, "(") != null and
            !std.mem.startsWith(u8, trimmed, "for (") and
            !std.mem.startsWith(u8, trimmed, "if (") and
            !std.mem.startsWith(u8, trimmed, "while (") and
            !std.mem.startsWith(u8, trimmed, "switch (") and
            !std.mem.startsWith(u8, trimmed, "catch (") and
            !std.mem.startsWith(u8, trimmed, "return "))
        {
            if (std.mem.indexOfScalar(u8, trimmed, '(')) |paren| {
                const before = std.mem.trim(u8, trimmed[0..paren], " \t");
                const last_space = std.mem.lastIndexOfAny(u8, before, " \t.");
                const ident = if (last_space) |sp|
                    before[sp + 1 ..]
                else
                    before;

                if (ident.len > 0 and
                    !std.mem.eql(u8, ident, "if") and
                    !std.mem.eql(u8, ident, "for") and
                    !std.mem.eql(u8, ident, "while") and
                    !std.mem.eql(u8, ident, "switch") and
                    !std.mem.eql(u8, ident, "return") and
                    !std.mem.eql(u8, ident, "catch") and
                    !std.mem.eql(u8, ident, "try") and
                    !std.mem.eql(u8, ident, "defer") and
                    !std.mem.eql(u8, ident, "errdefer"))
                {
                    const duped = try allocator.dupe(u8, ident);
                    try ops.append(allocator, duped);
                }
            }
        }
    }

    // Deduplicate
    var deduped = std.ArrayList([]const u8){};
    for (ops.items) |op| {
        var found = false;
        for (deduped.items) |d| {
            if (std.mem.eql(u8, d, op)) {
                found = true;
                break;
            }
        }
        if (!found) {
            try deduped.append(allocator, op);
        } else {
            allocator.free(op);
        }
    }
    ops.deinit(allocator);

    return deduped.toOwnedSlice(allocator);
}

fn containsUpper(s: []const u8) bool {
    for (s) |c| {
        if (std.ascii.isUpper(c)) return true;
    }
    return false;
}

// ── Dependencies ───────────────────────────────────────────────────

fn extractDependencies(
    allocator: std.mem.Allocator,
    code: []const u8,
    language: []const u8,
) ![]const []const u8 {
    var deps = std.ArrayList([]const u8){};
    errdefer {
        for (deps.items) |d| allocator.free(d);
        deps.deinit(allocator);
    }

    var lines = std.mem.splitAny(u8, code, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Zig: const x = @import("...")
        if (std.mem.eql(u8, language, "zig") or std.mem.indexOf(u8, trimmed, "@import") != null) {
            if (std.mem.indexOf(u8, trimmed, "@import(")) |start| {
                const after = trimmed[start + "@import(".len ..];
                if (std.mem.indexOfScalar(u8, after, '"')) |qstart| {
                    const from_quote = after[qstart + 1 ..];
                    if (std.mem.indexOfScalar(u8, from_quote, '"')) |qend| {
                        try deps.append(allocator, try allocator.dupe(u8, from_quote[0..qend]));
                        continue;
                    }
                }
            }
        }

        // Python: import X or from X import Y
        if (std.mem.startsWith(u8, trimmed, "import ") or
            std.mem.startsWith(u8, trimmed, "from "))
        {
            var tokens = std.mem.splitAny(u8, trimmed, " \t,");
            _ = tokens.next();
            if (tokens.next()) |mod| {
                if (!std.mem.eql(u8, mod, "import")) {
                    try deps.append(allocator, try allocator.dupe(u8, mod));
                    continue;
                }
            }
        }

        // JS/TS: import ... from '...' or require('...')
        if (std.mem.indexOf(u8, trimmed, "require(")) |start| {
            const after = trimmed[start + "require(".len ..];
            if (std.mem.indexOfScalar(u8, after, '\'')) |qstart| {
                const from_quote = after[qstart + 1 ..];
                if (std.mem.indexOfScalar(u8, from_quote, '\'')) |qend| {
                    try deps.append(allocator, try allocator.dupe(u8, from_quote[0..qend]));
                    continue;
                }
            }
            if (std.mem.indexOfScalar(u8, after, '"')) |qstart| {
                const from_quote = after[qstart + 1 ..];
                if (std.mem.indexOfScalar(u8, from_quote, '"')) |qend| {
                    try deps.append(allocator, try allocator.dupe(u8, from_quote[0..qend]));
                    continue;
                }
            }
        }
        if (std.mem.startsWith(u8, trimmed, "import ")) {
            if (std.mem.indexOf(u8, trimmed, " from ")) |_| {
                if (std.mem.indexOfScalar(u8, trimmed, '\'')) |qstart| {
                    const after = trimmed[qstart + 1 ..];
                    if (std.mem.indexOfScalar(u8, after, '\'')) |qend| {
                        try deps.append(allocator, try allocator.dupe(u8, after[0..qend]));
                        continue;
                    }
                }
                if (std.mem.indexOfScalar(u8, trimmed, '"')) |qstart| {
                    const after = trimmed[qstart + 1 ..];
                    if (std.mem.indexOfScalar(u8, after, '"')) |qend| {
                        try deps.append(allocator, try allocator.dupe(u8, after[0..qend]));
                        continue;
                    }
                }
            }
        }

        // C/C++: #include "..." or #include <...>
        if (std.mem.startsWith(u8, trimmed, "#include")) {
            if (std.mem.indexOfScalar(u8, trimmed, '"')) |qstart| {
                const after = trimmed[qstart + 1 ..];
                if (std.mem.indexOfScalar(u8, after, '"')) |qend| {
                    try deps.append(allocator, try allocator.dupe(u8, after[0..qend]));
                    continue;
                }
            }
            if (std.mem.indexOfScalar(u8, trimmed, '<')) |qstart| {
                const after = trimmed[qstart + 1 ..];
                if (std.mem.indexOfScalar(u8, after, '>')) |qend| {
                    try deps.append(allocator, try allocator.dupe(u8, after[0..qend]));
                    continue;
                }
            }
        }

        // Rust: use crate::... or use std::...
        if (std.mem.startsWith(u8, trimmed, "use ")) {
            const path = std.mem.trim(u8, trimmed["use ".len..], " \t;");
            if (path.len > 0) {
                try deps.append(allocator, try allocator.dupe(u8, path));
                continue;
            }
        }

        // Go: import "..."
        if (std.mem.startsWith(u8, trimmed, "import \"")) {
            const after = trimmed["import \"".len..];
            if (std.mem.indexOfScalar(u8, after, '"')) |qend| {
                try deps.append(allocator, try allocator.dupe(u8, after[0..qend]));
                continue;
            }
        }
    }

    return deps.toOwnedSlice(allocator);
}

// ── Complexity ─────────────────────────────────────────────────────

/// Compute a rough complexity score.
/// Score = line_count * 0.1 + branch_count * 0.5 + nesting_depth * 0.3
pub fn computeComplexity(code: []const u8) f32 {
    var line_count: f32 = 0;
    var branch_count: f32 = 0;
    var max_nesting: f32 = 0;
    var current_nesting: f32 = 0;

    var lines = std.mem.splitAny(u8, code, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (trimmed.len == 0) continue;

        line_count += 1;

        if (std.mem.startsWith(u8, trimmed, "if ") or
            std.mem.startsWith(u8, trimmed, "if(") or
            std.mem.startsWith(u8, trimmed, "else if") or
            std.mem.startsWith(u8, trimmed, "for ") or
            std.mem.startsWith(u8, trimmed, "for(") or
            std.mem.startsWith(u8, trimmed, "while ") or
            std.mem.startsWith(u8, trimmed, "while(") or
            std.mem.startsWith(u8, trimmed, "switch ") or
            std.mem.startsWith(u8, trimmed, "switch(") or
            std.mem.startsWith(u8, trimmed, "match ") or
            std.mem.startsWith(u8, trimmed, "catch ") or
            std.mem.eql(u8, trimmed, "else"))
        {
            branch_count += 1;
        }

        for (trimmed) |c| {
            if (c == '{') {
                current_nesting += 1;
            } else if (c == '}') {
                current_nesting -= 1;
                if (current_nesting < 0) current_nesting = 0;
            }
        }
        if (current_nesting > max_nesting) {
            max_nesting = current_nesting;
        }
    }

    return line_count * 0.1 + branch_count * 0.5 + max_nesting * 0.3;
}

// ── Helpers ────────────────────────────────────────────────────────

fn skipCommentsAndWS(code: []const u8, language: []const u8) []const u8 {
    _ = language;
    var lines = std.mem.splitAny(u8, code, "\n");
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "//") or
            std.mem.startsWith(u8, trimmed, "///") or
            std.mem.startsWith(u8, trimmed, "//!") or
            std.mem.startsWith(u8, trimmed, "/*") or
            std.mem.startsWith(u8, trimmed, "*") or
            std.mem.startsWith(u8, trimmed, "#") or
            std.mem.startsWith(u8, trimmed, "\"\"\"") or
            std.mem.startsWith(u8, trimmed, "'''"))
        {
            continue;
        }
        return trimmed;
    }
    return "";
}

// ── Tests ──────────────────────────────────────────────────────────

test "summarizeSymbol zig function" {
    const code =
        \\/// Authenticate a user session.
        \\pub fn authenticate(token: []const u8) !bool {
        \\    const session = try validateSession(token);
        \\    return session.valid;
        \\}
    ;
    const summary = try summarizeSymbol(std.testing.allocator, code, "zig");
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("authenticate", summary.name);
    try std.testing.expectEqualStrings("function", summary.kind);
    try std.testing.expectStringStartsWith(summary.signature, "pub fn authenticate");
    try std.testing.expectStringContains(summary.purpose, "Authenticate a user session");
    try std.testing.expect(summary.complexity_score > 0);
}

test "summarizeSymbol python function" {
    const code =
        \\def calculate_total(items: list[Item]) -> float:
        \\    """Sum up prices of all items."""
        \\    total = 0.0
        \\    for item in items:
        \\        total += item.price
        \\    return total
    ;
    const summary = try summarizeSymbol(std.testing.allocator, code, "python");
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("calculate_total", summary.name);
    try std.testing.expectStringContains(summary.purpose, "Sum up prices");
}

test "summarizeSymbol struct" {
    const code =
        \\/// Configuration for the search engine.
        \\pub const Config = struct {
        \\    max_results: u32,
        \\    timeout_ms: u64,
        \\};
    ;
    const summary = try summarizeSymbol(std.testing.allocator, code, "zig");
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("struct", summary.kind);
    try std.testing.expectStringContains(summary.purpose, "Configuration for the search engine");
}

test "extractPurpose from doc comment" {
    const code =
        \\/// Validate an authentication token.
        \\/// Returns the user ID if valid, null otherwise.
        \\pub fn validateToken(tok: []const u8) ?u32 {
    ;
    const purpose = try extractPurpose(std.testing.allocator, code);
    defer if (purpose) |p| std.testing.allocator.free(p);

    try std.testing.expect(purpose != null);
    try std.testing.expectStringContains(purpose.?, "Validate an authentication token");
}

test "extractPurpose returns null for no comment" {
    const code = "pub fn foo() void {}";
    const purpose = try extractPurpose(std.testing.allocator, code);
    try std.testing.expect(purpose == null);
}

test "computeComplexity simple" {
    const code = "pub fn hello() void {\n    return;\n}";
    const score = computeComplexity(code);
    try std.testing.expect(score >= 0);
    try std.testing.expect(score < 5.0);
}

test "computeComplexity nested" {
    const code =
        \\pub fn complex(x: i32) i32 {
        \\    if (x > 0) {
        \\        if (x > 10) {
        \\            for (0..x) |i| {
        \\                if (i % 2 == 0) {
        \\                    return i;
        \\                }
        \\            }
        \\        }
        \\    }
        \\    return 0;
        \\}
    ;
    const score = computeComplexity(code);
    try std.testing.expect(score > 3.0);
}

test "summarizeSymbol rust function" {
    const code =
        \\/// Calculate the factorial of n.
        \\pub fn factorial(n: u64) -> u64 {
        \\    if n <= 1 { 1 } else { n * factorial(n - 1) }
        \\}
    ;
    const summary = try summarizeSymbol(std.testing.allocator, code, "rust");
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("factorial", summary.name);
    try std.testing.expectStringContains(summary.purpose, "Calculate the factorial");
}

test "summarizeSymbol javascript function" {
    const code =
        \\// Fetch user data from the API.
        \\async function fetchUser(id) {
        \\    const response = await fetch('/api/users/' + id);
        \\    return response.json();
        \\}
    ;
    const summary = try summarizeSymbol(std.testing.allocator, code, "javascript");
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("fetchUser", summary.name);
    try std.testing.expectStringContains(summary.purpose, "Fetch user data from the API");
}

test "extractDependencies zig" {
    const code =
        \\const std = @import("std");
        \\const http = @import("http");
        \\pub fn serve() void {}
    ;
    const deps = try extractDependencies(std.testing.allocator, code, "zig");
    defer {
        for (deps) |d| std.testing.allocator.free(d);
        std.testing.allocator.free(deps);
    }
    try std.testing.expect(deps.len >= 2);
}

test "extractDependencies python" {
    const code =
        \\import os
        \\import sys
        \\from collections import defaultdict
        \\def main(): pass
    ;
    const deps = try extractDependencies(std.testing.allocator, code, "python");
    defer {
        for (deps) |d| std.testing.allocator.free(d);
        std.testing.allocator.free(deps);
    }
    try std.testing.expect(deps.len >= 2);
}
