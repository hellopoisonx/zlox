const std = @import("std");
const token = @import("token.zig");
const expr = @import("expr.zig");
const diagnose = @import("diagnose.zig");
const stmt = @import("stmt.zig");

/// Recursive-descent parser for the chapter 8 grammar (§8.1):
///
///   program   → statement* EOF ;
///   statement → exprStmt | printStmt ;
///   exprStmt  → expression ";" ;
///   printStmt → "print" expression ";" ;
///
/// on top of the chapter 6 expression grammar:
///
///   expression → equality ;
///   equality   → comparison ( ( "!=" | "==" ) comparison )* ;
///   comparison → term ( ( ">" | ">=" | "<" | "<=" ) term )* ;
///   term       → factor ( ( "-" | "+" ) factor )* ;
///   factor     → unary ( ( "/" | "*" ) unary )* ;
///   unary      → ( "!" | "-" ) unary | primary ;
///   primary    → NUMBER | STRING | "true" | "false" | "nil"
///               | "(" expression ")" ;
///
/// Syntax errors (book §6.3) are recorded as `Diagnostic`s — the port's
/// stand-in for the book's Lox.error side channel. `error.Parse` unwinds the
/// descent the same way the book's ParseError exception does; `parse()`
/// catches it and stops, so the parser never crashes or hangs on
/// invalid input. Nodes and diagnostics share the caller's allocator, which
/// is expected to be an arena (see `expr.Expr`).
pub const Parser = struct {
    allocator: std.mem.Allocator,
    tokens: []const token.Token,
    cursor: usize = 0,
    diagnostics: std.ArrayList(*diagnose.Diagnostic) = .empty,

    pub const ParseError = error{Parse};
    pub const Error = ParseError || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, tokens: []const token.Token) Parser {
        return .{ .allocator = allocator, .tokens = tokens };
    }

    /// Parses a whole program — statements until EOF, the `program` rule
    /// (book §8.1.2). Panic-mode recovery is deliberately NOT wired yet:
    /// the book defers that to §8.2 (declarations), so the first syntax
    /// error stops the parse; collected diagnostics already keep the
    /// program from running.
    pub fn parse(self: *Parser) Error!std.ArrayList(*stmt.Stmt) {
        var statements: std.ArrayList(*stmt.Stmt) = .empty;

        while (!self.atEnd()) {
            const s = self.statement() catch |err| switch (err) {
                error.Parse => return statements,
                else => return err,
            };
            try statements.append(self.allocator, s);
        }

        return statements;
    }

    /// Book §8.1.2: dispatch on the leading token. `print` is the only
    /// keyword-led statement so far; anything else must be an expression
    /// statement — the standard fallthrough, since an expression's first
    /// token is hard to recognize proactively.
    fn statement(self: *Parser) Error!*stmt.Stmt {
        if (self.match(.{.print})) {
            return self.printStatement();
        }
        return self.expressionStatement();
    }

    /// Book §8.1.2: `printStmt → "print" expression ";"`. The `print`
    /// keyword itself is already consumed.
    fn printStatement(self: *Parser) Error!*stmt.Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after value.");
        return try stmt.Stmt.create(self.allocator, .{ .print = .init(value) });
    }

    /// Book §8.1.2: `exprStmt → expression ";"`.
    fn expressionStatement(self: *Parser) Error!*stmt.Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after expression.");
        return try stmt.Stmt.create(self.allocator, .{ .expression = .init(value) });
    }

    fn expression(self: *Parser) Error!*expr.Expr {
        return try self.equality();
    }

    /// equality → comparison ( ( "!=" | "==" ) comparison )* ;
    fn equality(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.comparison();

        while (self.match(.{ .bang_equal, .equal_equal })) {
            const op = self.previous();
            const right = try self.comparison();
            e = try expr.Expr.create(self.allocator, .{ .binary = .init(e, right, op) });
        }

        return e;
    }

    /// comparison → term ( ( ">" | ">=" | "<" | "<=" ) term )* ;
    fn comparison(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.term();

        while (self.match(.{ .greater, .greater_equal, .less, .less_equal })) {
            const op = self.previous();
            const right = try self.term();
            e = try expr.Expr.create(self.allocator, .{ .binary = .init(e, right, op) });
        }

        return e;
    }

    /// term → factor ( ( "-" | "+" ) factor )* ;
    fn term(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.factor();

        while (self.match(.{ .minus, .plus })) {
            const op = self.previous();
            const right = try self.factor();
            e = try expr.Expr.create(self.allocator, .{ .binary = .init(e, right, op) });
        }

        return e;
    }

    /// factor → unary ( ( "/" | "*" ) unary )* ;
    fn factor(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.unary();

        while (self.match(.{ .slash, .star })) {
            const op = self.previous();
            const right = try self.unary();
            e = try expr.Expr.create(self.allocator, .{ .binary = .init(e, right, op) });
        }

        return e;
    }

    /// unary → ( "!" | "-" ) unary | primary ;
    fn unary(self: *Parser) Error!*expr.Expr {
        if (self.match(.{ .bang, .minus })) {
            const op = self.previous();
            const right = try self.unary();
            return try expr.Expr.create(self.allocator, .{ .unary = .init(op, right) });
        }

        return try self.primary();
    }

    /// primary → NUMBER | STRING | "true" | "false" | "nil"
    ///          | "(" expression ")" ;
    fn primary(self: *Parser) Error!*expr.Expr {
        if (self.match(.{._false})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .literal = .{ .boolean = false } },
            );
        }

        if (self.match(.{._true})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .literal = .{ .boolean = true } },
            );
        }

        if (self.match(.{.nil})) {
            return try expr.Expr.create(self.allocator, .{ .literal = .nil });
        }

        if (self.match(.{.number_literal})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .literal = .{ .number = self.previous().tag.number_literal } },
            );
        }

        if (self.match(.{.string_literal})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .literal = .{ .string = self.previous().tag.string_literal } },
            );
        }

        if (self.match(.{.l_paren})) {
            const grouped = try self.expression();
            _ = try self.consume(.r_paren, "Expect ')' after expression.");
            return try expr.Expr.create(self.allocator, .{ .grouping = .init(grouped) });
        }

        // Sitting on a token that can't start an expression (book §6.4,
        // "Wiring up the Parser").
        try self.reportError(self.peek(), "Expect expression.");
        return error.Parse;
    }

    /// Book §6.3.2: `consume` — accept the expected token or panic.
    fn consume(self: *Parser, tag: Tag, message: []const u8) Error!token.Token {
        if (self.check(tag)) return self.advance();
        try self.reportError(self.peek(), message);
        return error.Parse;
    }

    /// Book §6.3.2: `error(token, message)` — record a Diagnostic with the
    /// token's location and hand back `error.Parse` for the caller to
    /// unwind with.
    fn reportError(self: *Parser, tok: token.Token, message: []const u8) Error!void {
        const located = if (std.meta.activeTag(tok.tag) == .eof)
            std.fmt.allocPrint(self.allocator, "at end: {s}", .{message}) catch message
        else
            std.fmt.allocPrint(
                self.allocator,
                "at '{s}': {s}",
                .{ tok.lexeme(), message },
            ) catch message;

        const diag = try diagnose.Diagnostic.create(
            self.allocator,
            error.Parse,
            tok.line,
            located,
            null,
        );
        try self.diagnostics.append(self.allocator, diag);

        return error.Parse;
    }

    /// Book §6.3.3: discard tokens until the next statement boundary, so
    /// parsing can resume without cascaded errors. No caller yet — the
    /// book hooks this up when declarations arrive (§8.2).
    fn synchronize(self: *Parser) void {
        _ = self.advance();

        while (!self.atEnd()) {
            if (std.meta.activeTag(self.previous().tag) == .semicolon) return;

            switch (self.peek().tag) {
                .class, .fun, ._var, ._for, ._if, ._while, .print, ._return => return,
                else => {},
            }

            _ = self.advance();
        }
    }

    fn advance(self: *Parser) token.Token {
        if (!self.atEnd()) self.cursor += 1;
        return self.previous();
    }

    fn previous(self: *Parser) token.Token {
        return self.tokens[self.cursor - 1];
    }

    fn match(self: *Parser, comptime tags: anytype) bool {
        const T = @TypeOf(tags);
        const info = @typeInfo(T);
        comptime {
            if (info != .@"struct" or !info.@"struct".is_tuple) {
                @compileError("expected a tuple like .{a, b}, got: " ++ @typeName(T));
            }
        }

        inline for (tags) |tag| {
            if (self.check(tag)) {
                _ = self.advance();
                return true;
            }
        }

        return false;
    }

    /// The plain enum behind `token.Token.Tag`; comparing tags avoids
    /// constructing payload-carrying union values.
    const Tag = std.meta.Tag(token.Token.Tag);

    fn check(self: *Parser, tag: Tag) bool {
        if (self.atEnd()) return false;
        return std.meta.activeTag(self.peek().tag) == tag;
    }

    fn peek(self: *Parser) token.Token {
        return self.tokens[self.cursor];
    }

    fn atEnd(self: *Parser) bool {
        return self.cursor >= self.tokens.len or
            std.meta.activeTag(self.tokens[self.cursor].tag) == .eof;
    }
};

comptime {
    // `synchronize` has no caller until declarations arrive (§8.2);
    // referencing it here keeps the recovery machinery compile-checked.
    _ = &Parser.synchronize;
}
