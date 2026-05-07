//! Cypher parser — recursive descent parser for minimal Cypher subset.
//!
//! Produces an AST (QueryNode) from a token stream.
//! ~180 LOC — designed for direct port from goraphdb's Go parser.

const std = @import("std");
const lexer = @import("lexer.zig");

const Token = lexer.Token;
const TokenKind = lexer.TokenKind;

// ██████████████████████████████████████████████████████████████████████████
// AST types
// ██████████████████████████████████████████████████████████████████████████

pub const QueryNode = struct {
    match_clauses: []MatchClause,
    where_clause: ?WhereClause,
    return_clause: ReturnClause,
    order_by: ?OrderBy,
    limit: ?i64,
};

pub const MatchClause = struct {
    node_var: []const u8,
    node_label: []const u8,
    edge_var: []const u8,
    edge_type: []const u8,
    direction: Direction,
    target_var: []const u8,
    target_label: []const u8,
};

pub const Direction = enum { right, left, both };

pub const WhereClause = struct {
    expression: ExprNode,
};

pub const ReturnClause = struct {
    items: []ReturnItem,
};

pub const ReturnItem = struct {
    expression: ExprNode,
    alias: ?[]const u8,
};

pub const OrderBy = struct {
    items: []OrderItem,
};

pub const OrderItem = struct {
    expression: ExprNode,
    descending: bool,
};

pub const ExprNode = struct {
    kind: ExprKind,
    left: ?*ExprNode,
    right: ?*ExprNode,
    value: []const u8,
    value_int: i64,
};

pub const ExprKind = enum {
    identifier,
    string_literal,
    integer_literal,
    property_access,
    eq,
    neq,
    lt,
    gt,
    lte,
    gte,
    @"and",
    @"or",
    @"not",
};

// ██████████████████████████████████████████████████████████████████████████
// Parser
// ██████████████████████████████████████████████████████████████████████████

pub const Parser = struct {
    tokens: std.ArrayList(Token),
    pos: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, input: []const u8) !Parser {
        var lex = lexer.Lexer.init(input);
        var tokens = std.ArrayList(Token).initCapacity(allocator, 32) catch @panic("OOM");
        while (true) {
            const tok = lex.next();
            const is_eof = tok.kind == .eof;
            try tokens.append(allocator, tok);
            if (is_eof) break;
        }
        return .{ .tokens = tokens, .pos = 0, .allocator = allocator };
    }

    pub fn deinit(self: *Parser) void {
        self.tokens.deinit(self.allocator);
    }

    fn cur(self: *const Parser) Token {
        if (self.pos < self.tokens.items.len) return self.tokens.items[self.pos];
        return .{ .kind = .eof, .text = "" };
    }

    fn advance(self: *Parser) void {
        if (self.pos < self.tokens.items.len) self.pos += 1;
    }

    fn expect(self: *Parser, kind: TokenKind) !void {
        if (self.cur().kind != kind) return error.UnexpectedToken;
        self.advance();
    }

    fn matchToken(self: *Parser, kind: TokenKind) bool {
        if (self.cur().kind == kind) {
            self.advance();
            return true;
        }
        return false;
    }

    // ── query ─────────────────────────────────────────────────────────

    pub fn parseQuery(self: *Parser) !QueryNode {
        var match_clauses = std.ArrayList(MatchClause).initCapacity(self.allocator, 4) catch @panic("OOM");

        while (self.cur().kind == .keyword_match) {
            self.advance(); // skip MATCH
            try match_clauses.append(self.allocator, try self.parseMatchClause());
        }

        var where_clause: ?WhereClause = null;
        if (self.cur().kind == .keyword_where) {
            self.advance();
            where_clause = .{ .expression = try self.parseExpression() };
        }

        try self.expect(.keyword_return);
        const ret = try self.parseReturnClause();

        var order_by: ?OrderBy = null;
        if (self.cur().kind == .keyword_order) {
            self.advance();
            try self.expect(.keyword_by);
            order_by = try self.parseOrderBy();
        }

        var limit: ?i64 = null;
        if (self.cur().kind == .keyword_limit) {
            self.advance();
            if (self.cur().kind == .integer_literal) {
                limit = try std.fmt.parseInt(i64, self.cur().text, 10);
                self.advance();
            }
        }

        return .{
            .match_clauses = try match_clauses.toOwnedSlice(self.allocator),
            .where_clause = where_clause,
            .return_clause = ret,
            .order_by = order_by,
            .limit = limit,
        };
    }

    fn parseMatchClause(self: *Parser) !MatchClause {
        // (var:Label)
        try self.expect(.lparen);
        const node_var = if (self.cur().kind == .identifier) self.eatIdent() else "";
        const node_label = if (self.matchToken(.colon) and self.cur().kind == .label) self.eatIdent() else "";
        try self.expect(.rparen);

        // Determine direction
        var direction: Direction = .right;
        if (self.cur().kind == .arrow_left) {
            direction = .left;
            self.advance();
        }

        // -[:TYPE]->
        var edge_var: []const u8 = "";
        var edge_type: []const u8 = "";
        if (self.matchToken(.lbracket)) {
            if (self.cur().kind == .identifier) edge_var = self.eatIdent();
            if (self.matchToken(.colon) and self.cur().kind == .label) edge_type = self.eatIdent();
            try self.expect(.rbracket);
            // The dash
            if (self.cur().kind == .identifier) {
                // dash after bracket could be arrow or ignored
            }
        } else {
            // Simple arrow -[:TYPE]->
            // Already handled by lbracket check above
        }

        // Arrow
        if (direction == .right) {
            if (self.matchToken(.arrow_right)) {} else {
                // Handle case where bracket consumes the dash
                if (self.cur().kind == .identifier and std.mem.eql(u8, self.cur().text, "-")) {
                    self.advance();
                }
                // Now expect arrow
                if (self.cur().kind == .arrow_right) self.advance()
                else if (self.matchToken(.arrow_right)) {}
            }
        }

        // (var:Label)
        try self.expect(.lparen);
        const target_var = if (self.cur().kind == .identifier) self.eatIdent() else "";
        const target_label = if (self.matchToken(.colon) and self.cur().kind == .label) self.eatIdent() else "";
        try self.expect(.rparen);

        return .{
            .node_var = node_var,
            .node_label = node_label,
            .edge_var = edge_var,
            .edge_type = edge_type,
            .direction = direction,
            .target_var = target_var,
            .target_label = target_label,
        };
    }

    fn parseReturnClause(self: *Parser) !ReturnClause {
        var items = std.ArrayList(ReturnItem).initCapacity(self.allocator, 4) catch @panic("OOM");

        while (true) {
            const expr = try self.parseExpression();
            var alias: ?[]const u8 = null;
            if (self.matchToken(.keyword_as)) {
                const ident = self.eatIdent();
                alias = try self.allocator.dupe(u8, ident);
            }
            try items.append(self.allocator, .{ .expression = expr, .alias = alias });
            if (!self.matchToken(.comma)) break;
        }

        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    fn parseOrderBy(self: *Parser) !OrderBy {
        var items = std.ArrayList(OrderItem).initCapacity(self.allocator, 4) catch @panic("OOM");

        while (true) {
            const expr = try self.parseExpression();
            var desc = false;
            if (self.cur().kind == .keyword_asc or self.cur().kind == .keyword_desc) {
                desc = self.cur().kind == .keyword_desc;
                self.advance();
            }
            try items.append(self.allocator, .{ .expression = expr, .descending = desc });
            if (!self.matchToken(.comma)) break;
        }

        return .{ .items = try items.toOwnedSlice(self.allocator) };
    }

    fn parseExpression(self: *Parser) !ExprNode {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) !ExprNode {
        var left = try self.parseAnd();
        while (self.matchToken(.keyword_or)) {
            const right = try self.parseAnd();
            const node = try self.allocator.create(ExprNode);
            node.* = left;
            const right_node = try self.allocator.create(ExprNode);
            right_node.* = right;
            left = .{ .kind = .@"or", .left = node, .right = right_node, .value = "", .value_int = 0 };
        }
        return left;
    }

    fn parseAnd(self: *Parser) !ExprNode {
        var left = try self.parseNot();
        while (self.matchToken(.keyword_and)) {
            const right = try self.parseNot();
            const node = try self.allocator.create(ExprNode);
            node.* = left;
            const right_node = try self.allocator.create(ExprNode);
            right_node.* = right;
            left = .{ .kind = .@"and", .left = node, .right = right_node, .value = "", .value_int = 0 };
        }
        return left;
    }

    fn parseNot(self: *Parser) !ExprNode {
        if (self.matchToken(.keyword_not)) {
            const inner = try self.parseComparison();
            const node = try self.allocator.create(ExprNode);
            node.* = inner;
            return .{ .kind = .@"not", .left = node, .right = null, .value = "", .value_int = 0 };
        }
        return self.parseComparison();
    }

    fn parseComparison(self: *Parser) !ExprNode {
        const left = try self.parsePrimary();
        const cmp_kind: ?ExprKind = switch (self.cur().kind) {
            .eq => .eq,
            .neq => .neq,
            .lt => .lt,
            .gt => .gt,
            .lte => .lte,
            .gte => .gte,
            else => null,
        };
        if (cmp_kind) |kind| {
            self.advance();
            const right = try self.parsePrimary();
            const left_node = try self.allocator.create(ExprNode);
            left_node.* = left;
            const right_node = try self.allocator.create(ExprNode);
            right_node.* = right;
            return .{ .kind = kind, .left = left_node, .right = right_node, .value = "", .value_int = 0 };
        }
        return left;
    }

    fn parsePrimary(self: *Parser) !ExprNode {
        const tok = self.cur();
        switch (tok.kind) {
            .identifier => {
                self.advance();
                // Check for property access (var.prop)
                if (self.matchToken(.dot) and self.cur().kind == .identifier) {
                    const prop = self.eatIdent();
                    const left_node = try self.allocator.create(ExprNode);
                    left_node.* = .{ .kind = .identifier, .left = null, .right = null, .value = tok.text, .value_int = 0 };
                    return .{ .kind = .property_access, .left = left_node, .right = null, .value = prop, .value_int = 0 };
                }
                return .{ .kind = .identifier, .left = null, .right = null, .value = tok.text, .value_int = 0 };
            },
            .string_literal => {
                self.advance();
                return .{ .kind = .string_literal, .left = null, .right = null, .value = tok.text, .value_int = 0 };
            },
            .integer_literal => {
                self.advance();
                return .{ .kind = .integer_literal, .left = null, .right = null, .value = tok.text, .value_int = try std.fmt.parseInt(i64, tok.text, 10) };
            },
            else => return error.UnexpectedToken,
        }
    }

    fn eatIdent(self: *Parser) []const u8 {
        const text = self.cur().text;
        self.advance();
        return text;
    }
};
