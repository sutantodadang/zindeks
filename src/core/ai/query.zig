//! Natural-language query understanding — maps user intent to structured
//! search requests without requiring an NLP library.
//!
//! Uses keyword matching to detect intent, identifier scanning to extract
//! target symbols, and constraint extraction for language/module filters.

const std = @import("std");

pub const QueryIntent = enum {
    find_definition, // "where is X defined"
    find_usage, // "who uses X"
    explain, // "explain how X works"
    refactor, // "how to refactor X"
    debug, // "why is X failing"
    explore, // "show me the architecture"
    search, // generic search
};

pub const StructuredQuery = struct {
    intent: QueryIntent,
    target_symbols: []const []const u8, // extracted symbol names
    constraints: []const Constraint, // file type, module, etc.
    original: []const u8,

    pub fn deinit(self: *const StructuredQuery, allocator: std.mem.Allocator) void {
        for (self.target_symbols) |s| allocator.free(s);
        allocator.free(self.target_symbols);
        for (self.constraints) |c| c.deinit(allocator);
        allocator.free(self.constraints);
        allocator.free(self.original);
    }
};

pub const Constraint = struct {
    kind: ConstraintKind,
    value: []const u8,

    pub fn deinit(self: *const Constraint, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }
};

pub const ConstraintKind = enum {
    language,
    module,
    file_pattern,
    max_results,
};

/// Parse a natural language query into a structured representation.
pub fn parseQuery(
    allocator: std.mem.Allocator,
    query: []const u8,
) !StructuredQuery {
    const lowered = try allocator.dupe(u8, query);
    defer allocator.free(lowered);
    for (lowered) |*c| c.* = std.ascii.toLower(c.*);

    const intent = detectIntent(lowered);
    const symbols = try extractSymbols(allocator, query);
    const constraints = try extractConstraints(allocator, lowered);

    return .{
        .intent = intent,
        .target_symbols = symbols,
        .constraints = constraints,
        .original = try allocator.dupe(u8, query),
    };
}

// ── Intent detection ───────────────────────────────────────────────

fn detectIntent(lowered: []const u8) QueryIntent {
    // Ordered by specificity: more specific patterns first.

    // "where is X defined" / "find definition of X" / "define X"
    if (matchAny(lowered, &.{
        "where is", "where's", "where are",
        "defined", "definition of", "define ",
        "declaration of", "declare ",
        "location of",
    }) and !containsWord(lowered, "how") and !containsWord(lowered, "explain")) {
        return .find_definition;
    }

    // "who uses X" / "who calls X" / "called by" / "usage of" / "references to"
    if (matchAny(lowered, &.{
        "who uses", "who calls", "what uses", "what calls",
        "called by", "called from", "callers of", "caller of",
        "usage of", "usages of", "references to", "referenced by",
        "used by", "used in", "invokes", "invoked by",
        "dependents of", "dependencies of",
    })) {
        return .find_usage;
    }

    // "explain how X works" / "how does X" / "what does X do"
    if (matchAny(lowered, &.{
        "explain how", "explain what", "explain the",
        "how does", "how do", "how is", "how are",
        "what does", "what do", "what is", "what are",
        "describe", "tell me about", "tell me how",
        "walk through", "walkthrough",
    }) or
        (containsWord(lowered, "explain") and !containsWord(lowered, "refactor")))
    {
        return .explain;
    }

    // "refactor X" / "how to refactor X" / "improve X"
    if (matchAny(lowered, &.{
        "refactor", "restructure", "reorganize",
        "improve", "optimize", "clean up",
        "simplify", "extract method", "extract function",
        "rename", "split", "merge",
    })) {
        return .refactor;
    }

    // "why is X failing" / "error in X" / "bug in X" / "X is broken"
    if (matchAny(lowered, &.{
        "why is", "why does", "failing", "failed",
        "error in", "error:", "exception",
        "bug in", "bug:", "broken", "crash",
        "stack trace", "stacktrace", "traceback",
        "not working", "doesn't work", "don't work",
        "debug", "fix this", "fix the",
    })) {
        return .debug;
    }

    // "architecture" / "overview" / "structure" / "show me the project"
    if (matchAny(lowered, &.{
        "architecture", "structure", "overview",
        "show me the", "show me how",
        "what modules", "module structure",
        "high level", "high-level", "bird's eye",
        "entry points", "project layout",
        "codebase", "repository",
    }) and !containsWord(lowered, "explain")) {
        return .explore;
    }

    return .search;
}

fn matchAny(lowered: []const u8, patterns: []const []const u8) bool {
    for (patterns) |p| {
        if (std.mem.indexOf(u8, lowered, p) != null) return true;
    }
    return false;
}

fn containsWord(lowered: []const u8, word: []const u8) bool {
    return std.mem.indexOf(u8, lowered, word) != null;
}

// ── Symbol extraction ──────────────────────────────────────────────

/// Extract identifiers that look like code symbols from a query.
/// Matches camelCase, PascalCase, snake_case, and dot-separated names.
fn extractSymbols(
    allocator: std.mem.Allocator,
    query: []const u8,
) ![]const []const u8 {
    var symbols = std.ArrayList([]const u8){};

    var i: usize = 0;
    while (i < query.len) {
        // Skip non-identifier chars
        while (i < query.len and !isIdentStart(query[i])) i += 1;
        if (i >= query.len) break;

        const start = i;
        while (i < query.len and isIdentChar(query[i])) i += 1;
        const word = query[start..i];

        // Filter out common English words that aren't code symbols.
        if (!isCommonEnglish(word) and isLikelySymbol(word)) {
            try symbols.append(allocator, try allocator.dupe(u8, word));
        }
    }

    return symbols.toOwnedSlice(allocator);
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

/// Check if a word looks like a code symbol (has capital letters,
/// underscores, or is not a common word).
fn isLikelySymbol(word: []const u8) bool {
    if (word.len < 2) return false;

    // Has uppercase letters (camelCase/PascalCase)
    for (word) |c| {
        if (std.ascii.isUpper(c)) return true;
    }

    // Has underscores (snake_case)
    if (std.mem.indexOfScalar(u8, word, '_') != null) return true;

    // Single-word lowercase symbols might be too ambiguous.
    // Only include if reasonably long or has dot.
    if (word.len <= 4 and std.mem.indexOfScalar(u8, word, '.') == null) return false;

    return false;
}

/// Check if a word is a common English word (not a code symbol).
fn isCommonEnglish(word: []const u8) bool {
    const common = [_][]const u8{
        "the",     "and",    "for",    "with",   "from",
        "this",    "that",   "what",   "when",   "where",
        "which",   "who",    "how",    "why",    "does",
        "have",    "been",   "will",   "would",  "could",
        "should",  "about",  "into",   "over",   "after",
        "before",  "under",  "above",  "below",  "between",
        "find",    "show",   "list",   "get",    "set",
        "make",    "call",   "calls",  "called", "define",
        "defined", "explain","describe","search", "look",
        "there",   "their",  "they",   "here",   "just",
        "like",    "some",   "more",   "only",   "also",
        "very",    "each",   "every",  "all",    "any",
    };

    // Quick lowercase comparison
    for (common) |cw| {
        if (word.len != cw.len) continue;
        // Case-insensitive match
        var matches = true;
        for (word, 0..) |c, j| {
            if (std.ascii.toLower(c) != cw[j]) {
                matches = false;
                break;
            }
        }
        if (matches) return true;
    }
    return false;
}

// ── Constraint extraction ──────────────────────────────────────────

fn extractConstraints(
    allocator: std.mem.Allocator,
    lowered: []const u8,
) ![]const Constraint {
    var constraints = std.ArrayList(Constraint){};

    // Language constraint: "in zig", "in python", "in rust", etc.
    const language_patterns = [_][]const u8{
        "in zig", "in ziglang", "in python", "in javascript", "in js",
        "in typescript", "in ts", "in rust", "in go", "in golang",
        "in c ", "in c++", "in cpp", "in java", "in csharp", "in c#",
        "in scala", "in kotlin", "in swift", "in lua", "in haskell",
        "in elixir", "in clojure", "in ruby", "in php", "in dart",
    };
    for (language_patterns) |pat| {
        if (std.mem.indexOf(u8, lowered, pat) != null) {
            const lang = std.mem.trim(u8, pat["in ".len..], " ");
            try constraints.append(allocator, .{
                .kind = .language,
                .value = try allocator.dupe(u8, lang),
            });
            break;
        }
    }

    // "in module X" / "in directory Y" / "in file Z"
    const module_patterns = [_][]const u8{ "in module ", "in directory ", "in dir ", "in file " };
    for (module_patterns) |pat| {
        if (std.mem.indexOf(u8, lowered, pat)) |idx| {
            const start = idx + pat.len;
            var end = start;
            while (end < lowered.len and lowered[end] != ' ' and lowered[end] != ',' and lowered[end] != '.') end += 1;
            if (end > start) {
                try constraints.append(allocator, .{
                    .kind = .module,
                    .value = try allocator.dupe(u8, lowered[start..end]),
                });
            }
            break;
        }
    }

    // "*.zig", "*.rs" file pattern
    if (std.mem.indexOf(u8, lowered, "*.")) |idx| {
        var end = idx + 1;
        while (end < lowered.len and (std.ascii.isAlphanumeric(lowered[end]) or lowered[end] == '*')) end += 1;
        if (end > idx) {
            try constraints.append(allocator, .{
                .kind = .file_pattern,
                .value = try allocator.dupe(u8, lowered[idx..end]),
            });
        }
    }

    // "top N" / "first N" → max_results
    const top_patterns = [_][]const u8{ "top ", "first " };
    for (top_patterns) |pat| {
        if (std.mem.indexOf(u8, lowered, pat)) |idx| {
            const num_start = idx + pat.len;
            var num_end = num_start;
            while (num_end < lowered.len and std.ascii.isDigit(lowered[num_end])) num_end += 1;
            if (num_end > num_start) {
                try constraints.append(allocator, .{
                    .kind = .max_results,
                    .value = try allocator.dupe(u8, lowered[num_start..num_end]),
                });
            }
            break;
        }
    }

    return constraints.toOwnedSlice(allocator);
}

// ── Suggested tools ────────────────────────────────────────────────

/// Return suggested MCP tools for a given intent.
pub fn suggestedTools(allocator: std.mem.Allocator, intent: QueryIntent) ![]const []const u8 {
    const tools: []const []const u8 = switch (intent) {
        .find_definition => &.{ "search_code", "search_graph", "get_code_snippet" },
        .find_usage => &.{ "trace_call_path", "search_graph" },
        .explain => &.{ "search_code", "get_code_snippet", "search_graph", "get_architecture" },
        .refactor => &.{ "trace_call_path", "get_architecture", "search_graph" },
        .debug => &.{ "search_code", "trace_call_path", "get_code_snippet" },
        .explore => &.{ "get_architecture", "detect_communities", "search_graph" },
        .search => &.{ "search_code", "hybrid_search", "semantic_search" },
    };

    var result = std.ArrayList([]const u8){};
    for (tools) |t| {
        try result.append(allocator, try allocator.dupe(u8, t));
    }
    return result.toOwnedSlice(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────

test "parseQuery find_definition" {
    const q = try parseQuery(std.testing.allocator, "where is the auth middleware defined?");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.find_definition, q.intent);
    try std.testing.expect(q.target_symbols.len > 0);
}

test "parseQuery find_usage" {
    const q = try parseQuery(std.testing.allocator, "who calls parseToken?");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.find_usage, q.intent);
}

test "parseQuery explain" {
    const q = try parseQuery(std.testing.allocator, "explain how the authentication flow works");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.explain, q.intent);
}

test "parseQuery refactor" {
    const q = try parseQuery(std.testing.allocator, "how can I refactor the userManager class?");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.refactor, q.intent);
}

test "parseQuery debug" {
    const q = try parseQuery(std.testing.allocator, "why is the login function failing?");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.debug, q.intent);
}

test "parseQuery explore" {
    const q = try parseQuery(std.testing.allocator, "show me the project architecture");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.explore, q.intent);
}

test "parseQuery search (default)" {
    const q = try parseQuery(std.testing.allocator, "user authentication with JWT tokens");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.search, q.intent);
}

test "parseQuery extracts symbols" {
    const q = try parseQuery(std.testing.allocator, "where is loginMiddleware defined?");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.find_definition, q.intent);
    // loginMiddleware should be extracted as a camelCase symbol
    var found = false;
    for (q.target_symbols) |s| {
        if (std.mem.eql(u8, s, "loginMiddleware")) found = true;
    }
    try std.testing.expect(found);
}

test "parseQuery language constraint" {
    const q = try parseQuery(std.testing.allocator, "how does auth work in zig?");
    defer q.deinit(std.testing.allocator);

    var found = false;
    for (q.constraints) |c| {
        if (c.kind == .language and std.mem.eql(u8, c.value, "zig")) found = true;
    }
    try std.testing.expect(found);
}

test "suggestedTools for intents" {
    var tools = try suggestedTools(std.testing.allocator, .find_definition);
    defer {
        for (tools) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tools);
    }
    try std.testing.expect(tools.len > 0);

    tools = try suggestedTools(std.testing.allocator, .explain);
    defer {
        for (tools) |t| std.testing.allocator.free(t);
        std.testing.allocator.free(tools);
    }
    try std.testing.expect(tools.len > 0);
}

test "parseQuery empty query" {
    const q = try parseQuery(std.testing.allocator, "");
    defer q.deinit(std.testing.allocator);

    try std.testing.expectEqual(QueryIntent.search, q.intent);
    try std.testing.expectEqual(@as(usize, 0), q.target_symbols.len);
}

test "extractSymbols camelCase and snake_case" {
    const symbols = try extractSymbols(std.testing.allocator, "refactor userAuthManager and http_client module");
    defer {
        for (symbols) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(symbols);
    }
    // Should extract userAuthManager and http_client, not "and", "refactor", "module"
    var has_camel = false;
    var has_snake = false;
    for (symbols) |s| {
        if (std.mem.eql(u8, s, "userAuthManager")) has_camel = true;
        if (std.mem.eql(u8, s, "http_client")) has_snake = true;
    }
    try std.testing.expect(has_camel);
    try std.testing.expect(has_snake);
}
