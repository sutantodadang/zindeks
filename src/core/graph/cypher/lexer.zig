//! Cypher query lexer — tokenizes the minimal Cypher subset.
//!
//! Supported: MATCH, RETURN, WHERE, AS, AND, OR, NOT, ORDER BY, LIMIT,
//! node patterns `(var:Label)`, relationship patterns `-[:TYPE]->`,
//! comparisons (=, <>, <, >, <=, >=), string/int literals.
//!
//! ~150 LOC — designed for direct port from goraphdb's Go lexer.

const std = @import("std");

pub const TokenKind = enum {
    keyword_match,
    keyword_return,
    keyword_where,
    keyword_as,
    keyword_and,
    keyword_or,
    keyword_not,
    keyword_order,
    keyword_by,
    keyword_limit,
    keyword_asc,
    keyword_desc,
    identifier,
    label, // :LabelName (after colon)
    edge_type, // :TYPE in []
    string_literal,
    integer_literal,
    lparen,
    rparen,
    lbracket,
    rbracket,
    lbrace,
    rbrace,
    colon,
    comma,
    dot,
    eq,
    neq, // <>
    lt,
    gt,
    lte,
    gte,
    arrow_right,
    arrow_left,
    eof,
};

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

const KEYWORDS = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "MATCH", .keyword_match },
    .{ "RETURN", .keyword_return },
    .{ "WHERE", .keyword_where },
    .{ "AS", .keyword_as },
    .{ "AND", .keyword_and },
    .{ "OR", .keyword_or },
    .{ "NOT", .keyword_not },
    .{ "ORDER", .keyword_order },
    .{ "BY", .keyword_by },
    .{ "LIMIT", .keyword_limit },
    .{ "ASC", .keyword_asc },
    .{ "DESC", .keyword_desc },
});

pub const Lexer = struct {
    input: []const u8,
    pos: usize,

    pub fn init(input: []const u8) Lexer {
        return .{ .input = input, .pos = 0 };
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespace();
        if (self.pos >= self.input.len) return .{ .kind = .eof, .text = "" };

        const ch = self.input[self.pos];

        // Arrows
        if (ch == '-' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
            return self.eat(2, .arrow_right);
        }
        if (ch == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '-') {
            return self.eat(2, .arrow_left);
        }

        // Two-char operators (<>)
        if (ch == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '>') {
            return self.eat(2, .neq);
        }
        if (ch == '<' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
            return self.eat(2, .lte);
        }
        if (ch == '>' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '=') {
            return self.eat(2, .gte);
        }

        // Single-char punctuation
        const single_map = [_]struct { ch: u8, kind: TokenKind }{
            .{ .ch = '(', .kind = .lparen },
            .{ .ch = ')', .kind = .rparen },
            .{ .ch = '[', .kind = .lbracket },
            .{ .ch = ']', .kind = .rbracket },
            .{ .ch = '{', .kind = .lbrace },
            .{ .ch = '}', .kind = .rbrace },
            .{ .ch = ',', .kind = .comma },
            .{ .ch = '.', .kind = .dot },
            .{ .ch = '=', .kind = .eq },
            .{ .ch = '<', .kind = .lt },
            .{ .ch = '>', .kind = .gt },
        };
        for (single_map) |entry| {
            if (ch == entry.ch) return self.eat(1, entry.kind);
        }

        // Colon + label
        if (ch == ':') {
            self.pos += 1; // skip colon
            if (self.pos < self.input.len) {
                const c = self.input[self.pos];
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    return self.readIdent(.label);
                }
            }
            return .{ .kind = .colon, .text = self.input[self.pos - 1 .. self.pos] };
        }

        // String
        if (ch == '\'') return self.readString();

        // Number
        if (std.ascii.isDigit(ch)) return self.readNumber();

        // Identifier / keyword
        if (std.ascii.isAlphabetic(ch) or ch == '_') return self.readWord();

        // Unknown
        self.pos += 1;
        return .{ .kind = .eof, .text = self.input[self.pos - 1 .. self.pos] };
    }

    fn skipWhitespace(self: *Lexer) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\r', '\n' => self.pos += 1,
                else => break,
            }
        }
    }

    fn eat(self: *Lexer, n: usize, kind: TokenKind) Token {
        const text = self.input[self.pos .. self.pos + n];
        self.pos += n;
        return .{ .kind = kind, .text = text };
    }

    fn readString(self: *Lexer) Token {
        self.pos += 1; // opening quote
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != '\'') {
            self.pos += 1;
        }
        const text = self.input[start..self.pos];
        if (self.pos < self.input.len) self.pos += 1; // closing quote
        return .{ .kind = .string_literal, .text = text };
    }

    fn readNumber(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) {
            self.pos += 1;
        }
        return .{ .kind = .integer_literal, .text = self.input[start..self.pos] };
    }

    fn readIdent(self: *Lexer, kind: TokenKind) Token {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        return .{ .kind = kind, .text = self.input[start..self.pos] };
    }

    fn readWord(self: *Lexer) Token {
        const start = self.pos;
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_') {
                self.pos += 1;
            } else {
                break;
            }
        }
        const text = self.input[start..self.pos];
        const keyword = KEYWORDS.get(text);
        if (keyword) |kw| return .{ .kind = kw, .text = text };
        return .{ .kind = .identifier, .text = text };
    }
};
