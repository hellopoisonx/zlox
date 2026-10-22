const std = @import("std");
const token = @import("token.zig");
const expr = @import("expr.zig");
const diagnose = @import("diagnose.zig");
const stmt = @import("stmt.zig");

/// Recursive-descent parser for the chapter 10 grammar (§10.1–§10.6):
///
///   program     → declaration* EOF ;
///   declaration → funDecl | varDecl | statement ;
///   funDecl     → "fun" function ;
///   function    → IDENTIFIER "(" parameters? ")" block ;
///   parameters  → IDENTIFIER ( "," IDENTIFIER )* ;
///   varDecl     → "var" IDENTIFIER ( "=" expression )? ";" ;
///   statement   → exprStmt | forStmt | ifStmt | printStmt | returnStmt
///               | whileStmt | block ;
///   exprStmt    → expression ";" ;
///   printStmt   → "print" expression ";" ;
///   returnStmt  → "return" expression? ";" ;
///   ifStmt      → "if" "(" expression ")" statement
///               ( "else" statement )? ;
///   whileStmt   → "while" "(" expression ")" statement ;
///   forStmt     → "for" "(" ( varDecl | exprStmt | ";" ) expression? ";"
///                 expression? ")" statement ;
///   block       → "{" declaration* "}" ;
///
/// `for` is desugared to block/while nodes while parsing (§9.5.1), so the
/// interpreter never sees it.
///
/// Calls are a postfix operator on primaries (§10.1), so `unary` descends
/// into `call`; the loop in `call()` keeps the callee expression arbitrary
/// (`fn(1)(2)`). On top of the chapter 6 expression grammar, `assignment`
/// slots in above the short-circuiting logical operators (§9.3), which in
/// turn sit above `equality`; `primary` gained IDENTIFIER in §8.2.1:
///
///   expression → assignment ;
///   assignment → IDENTIFIER "=" assignment | logic_or ;
///   logic_or   → logic_and ( "or" logic_and )* ;
///   logic_and  → equality ( "and" equality )* ;
///   equality   → comparison ( ( "!=" | "==" ) comparison )* ;
///   comparison → term ( ( ">" | ">=" | "<" | "<=" ) term )* ;
///   term       → factor ( ( "-" | "+" ) factor )* ;
///   factor     → unary ( ( "/" | "*" ) unary )* ;
///   unary      → ( "!" | "-" ) unary | call ;
///   call       → primary ( "(" arguments? ")" )* ;
///   arguments  → expression ( "," expression )* ;
///   primary    → NUMBER | STRING | "true" | "false" | "nil"
///               | "(" expression ")" | IDENTIFIER ;
///
/// Syntax errors (book §6.3) are recorded as `Diagnostic`s — the port's
/// stand-in for the book's Lox.error side channel. `error.Parse` unwinds the
/// descent the same way the book's ParseError exception does; `declaration`
/// recovers via `synchronize()`, so the parser never crashes or hangs on
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

    /// Parses a whole program — declarations until EOF, the `program`
    /// rule (book §8.2.2). Each declaration is its own recovery point:
    /// on a syntax error, `synchronize()` skips to the next statement
    /// boundary and parsing continues, so one bad declaration doesn't
    /// cascade.
    pub fn parse(self: *Parser) Error!std.ArrayList(*stmt.Stmt) {
        var statements: std.ArrayList(*stmt.Stmt) = .empty;

        while (!self.atEnd()) {
            if (try self.declaration()) |s| {
                try statements.append(self.allocator, s);
            }
        }

        return statements;
    }

    /// Book §8.2.2/§10.3: `declaration → funDecl | varDecl | statement`.
    /// `fun` is matched before the generic statement fallthrough, exactly
    /// like the other keyword-led statements. This is the method the
    /// program loop repeats, so it is the panic-mode recovery point: on
    /// `error.Parse`, `synchronize()` discards tokens to the next
    /// statement boundary and parsing resumes with the next declaration.
    /// The book catches here and returns null; the port does the same
    /// (parse() then skips it — diagnostics already gate execution).
    fn declaration(self: *Parser) Error!?*stmt.Stmt {
        const declared: Error!*stmt.Stmt = if (self.match(.{.class}))
            self.classDeclaration()
        else if (self.match(.{.fun}))
            self.function("function")
        else if (self.match(.{._var}))
            self.varDeclaration()
        else
            self.statement();

        return declared catch |err| switch (err) {
            error.Parse => {
                self.synchronize();
                return null;
            },
            else => err,
        };
    }

    /// Book §8.2.2: `varDecl → "var" IDENTIFIER ( "=" expression )? ";"`.
    /// The `var` keyword is already consumed.
    fn varDeclaration(self: *Parser) Error!*stmt.Stmt {
        const name = try self.consume(.identifier_literal, "Expect variable name.");

        var initializer: ?*expr.Expr = null;
        if (self.match(.{.equal})) {
            initializer = try self.expression();
        }

        _ = try self.consume(.semicolon, "Expect ';' after variable declaration.");
        return try stmt.Stmt.create(self.allocator, .{ .var_decl = .init(name, initializer) });
    }

    /// Book §12.2 / §13.1: `classDecl → "class" IDENTIFIER ( "<" IDENTIFIER )? "{" function* "}" ;`.
    fn classDeclaration(self: *Parser) Error!*stmt.Stmt {
        const name = try self.consume(.identifier_literal, "Expect class name.");

        var superclass: ?*expr.Expr = null;
        if (self.match(.{.less})) {
            _ = try self.consume(.identifier_literal, "Expect superclass name.");
            superclass = try expr.Expr.create(self.allocator, .{
                .variable = .init(self.previous()),
            });
        }

        _ = try self.consume(.l_brace, "Expect '{' before class body.");

        var methods: std.ArrayList(stmt.Function) = .empty;
        while (!self.check(.r_brace) and !self.atEnd()) {
            try methods.append(self.allocator, try self.functionDecl("method"));
        }

        _ = try self.consume(.r_brace, "Expect '}' after class body.");
        return try stmt.Stmt.create(self.allocator, .{
            .class = .init(name, superclass, try methods.toOwnedSlice(self.allocator)),
        });
    }

    fn functionDecl(self: *Parser, comptime kind: []const u8) Error!stmt.Function {
        const name = try self.consume(
            .identifier_literal,
            std.fmt.comptimePrint("Expect {s} name.", .{kind}),
        );
        _ = try self.consume(
            .l_paren,
            std.fmt.comptimePrint("Expect '(' after {s} name.", .{kind}),
        );

        var parameters: std.ArrayList(token.Token) = .empty;
        if (!self.check(.r_paren)) {
            while (true) {
                if (parameters.items.len >= 255) {
                    try self.errorAt(self.peek(), "Can't have more than 255 parameters.");
                }

                try parameters.append(
                    self.allocator,
                    try self.consume(.identifier_literal, "Expect parameter name."),
                );
                if (!self.match(.{.comma})) break;
            }
        }
        _ = try self.consume(.r_paren, "Expect ')' after parameters.");

        _ = try self.consume(
            .l_brace,
            std.fmt.comptimePrint("Expect '{{' before {s} body.", .{kind}),
        );
        const body = try self.block();
        return stmt.Function.init(name, try parameters.toOwnedSlice(self.allocator), body);
    }

    fn function(self: *Parser, comptime kind: []const u8) Error!*stmt.Stmt {
        return try stmt.Stmt.create(self.allocator, .{
            .function = try self.functionDecl(kind),
        });
    }

    /// Book §9.2/§9.4/§9.5/§10.5: dispatch on the leading keyword. `for`,
    /// `if`, `print`, `return`, and `while` are the keyword-led statements
    /// so far; `{` starts a block and anything else must be an expression
    /// statement — the standard fallthrough, since an expression's first
    /// token is hard to recognize proactively.
    fn statement(self: *Parser) Error!*stmt.Stmt {
        if (self.match(.{._for})) {
            return self.forStatement();
        }
        if (self.match(.{._if})) {
            return self.ifStatement();
        }
        if (self.match(.{.print})) {
            return self.printStatement();
        }
        if (self.match(.{._return})) {
            return self.returnStatement();
        }
        if (self.match(.{._while})) {
            return self.whileStatement();
        }
        if (self.match(.{.l_brace})) {
            return self.blockStatement();
        }
        return self.expressionStatement();
    }

    /// Book §9.2: `ifStmt → "if" "(" expression ")" statement
    /// ( "else" statement )? ;`. The `if` keyword is already consumed.
    /// Eagerly matching `else` right after the then branch gives it the
    /// standard dangling-else binding: the nearest preceding `if` claims
    /// the clause before any outer `if` gets a chance.
    fn ifStatement(self: *Parser) Error!*stmt.Stmt {
        _ = try self.consume(.l_paren, "Expect '(' after 'if'.");
        const cond = try self.expression();
        _ = try self.consume(.r_paren, "Expect ')' after if condition.");
        const then = try self.statement();
        var _else: ?*stmt.Stmt = null;
        if (self.match(.{._else})) {
            _else = try self.statement();
        }

        return try stmt.Stmt.create(self.allocator, .{ ._if = .init(cond, then, _else) });
    }

    /// Book §9.4: `whileStmt → "while" "(" expression ")" statement ;`.
    /// The `while` keyword is already consumed.
    fn whileStatement(self: *Parser) Error!*stmt.Stmt {
        _ = try self.consume(.l_paren, "Expect '(' after 'while'.");
        const cond = try self.expression();
        _ = try self.consume(.r_paren, "Expect ')' after condition.");
        const body = try self.statement();

        return try stmt.Stmt.create(self.allocator, .{ ._while = .init(cond, body) });
    }

    /// Book §9.5: `forStmt → "for" "(" ( varDecl | exprStmt | ";" )
    /// expression? ";" expression? ")" statement ;`. The `for` keyword is
    /// already consumed.
    ///
    /// §9.5.1 desugars the statement into nodes the interpreter already
    /// handles, working backward: append the increment to the body, wrap
    /// that in a `while`, then wrap the loop in a block with the
    /// initializer. No `Stmt.For` node exists.
    fn forStatement(self: *Parser) Error!*stmt.Stmt {
        _ = try self.consume(.l_paren, "Expect '(' after 'for'.");

        // Initializer: omitted, a variable declaration, or an expression
        // statement. `varDeclaration` expects the `var` already consumed.
        var initializer: ?*stmt.Stmt = null;
        if (self.match(.{.semicolon})) {
            initializer = null;
        } else if (self.match(.{._var})) {
            initializer = try self.varDeclaration();
        } else {
            initializer = try self.expressionStatement();
        }

        // Condition: optional; omitted means the loop has no exit test.
        var condition: ?*expr.Expr = null;
        if (!self.check(.semicolon)) {
            condition = try self.expression();
        }
        _ = try self.consume(.semicolon, "Expect ';' after loop condition.");

        // Increment: optional, terminated by the closing parenthesis.
        var increment: ?*expr.Expr = null;
        if (!self.check(.r_paren)) {
            increment = try self.expression();
        }
        _ = try self.consume(.r_paren, "Expect ')' after for clauses.");

        var body = try self.statement();

        // Desugar the increment into the body: `{ body; increment; }`.
        if (increment) |inc| {
            const stmts = try self.allocator.alloc(*stmt.Stmt, 2);
            stmts[0] = body;
            stmts[1] = try stmt.Stmt.create(
                self.allocator,
                .{ .expression = .init(inc) },
            );
            body = try self.blockOf(stmts);
        }

        // Desugar the loop: `while (condition) body`, with `true` filling
        // in an omitted condition so it loops forever.
        const cond = condition orelse
            try expr.Expr.create(self.allocator, .{ .literal = .{ .boolean = true } });
        body = try stmt.Stmt.create(self.allocator, .{ ._while = .init(cond, body) });

        // Desugar the initializer: it runs once before the loop, in a
        // scope that encloses the loop body.
        if (initializer) |initial| {
            const stmts = try self.allocator.alloc(*stmt.Stmt, 2);
            stmts[0] = initial;
            stmts[1] = body;
            body = try self.blockOf(stmts);
        }

        return body;
    }

    fn blockStatement(self: *Parser) Error!*stmt.Stmt {
        const stmts = try self.block();
        return try self.blockOf(stmts);
    }

    /// Allocate a `Stmt.Block` around already-built statements — shared by
    /// real braced blocks and the synthetic blocks the `for` desugaring
    /// creates.
    fn blockOf(self: *Parser, statements: []const *stmt.Stmt) Error!*stmt.Stmt {
        return try stmt.Stmt.create(self.allocator, .{ .block = .init(statements) });
    }

    fn block(self: *Parser) Error![]const *stmt.Stmt {
        var list = std.ArrayList(*stmt.Stmt).empty;

        // The explicit atEnd() check keeps a missing '}' from looping
        // forever; a declaration that hit a syntax error recovered to null
        // (its diagnostic is already recorded) and is skipped, just as
        // parse() does at the top level.
        while (!self.check(.r_brace) and !self.atEnd()) {
            if (try self.declaration()) |s| try list.append(self.allocator, s);
        }

        _ = try self.consume(.r_brace, "Expect '}' after block.");
        return list.toOwnedSlice(self.allocator);
    }

    /// Book §8.1.2: `printStmt → "print" expression ";"`. The `print`
    /// keyword itself is already consumed.
    fn printStatement(self: *Parser) Error!*stmt.Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after value.");
        return try stmt.Stmt.create(self.allocator, .{ .print = .init(value) });
    }

    /// Book §10.5: `returnStmt → "return" expression? ";"`. The `return`
    /// keyword is already consumed. A semicolon cannot begin an
    /// expression, so testing for it is how the optional value is
    /// detected; omitting it is equivalent to `return nil;`.
    fn returnStatement(self: *Parser) Error!*stmt.Stmt {
        const keyword = self.previous();
        var value: ?*expr.Expr = null;
        if (!self.check(.semicolon)) {
            value = try self.expression();
        }

        _ = try self.consume(.semicolon, "Expect ';' after return value.");
        return try stmt.Stmt.create(self.allocator, .{ ._return = .init(keyword, value) });
    }

    /// Book §8.1.2: `exprStmt → expression ";"`.
    fn expressionStatement(self: *Parser) Error!*stmt.Stmt {
        const value = try self.expression();
        _ = try self.consume(.semicolon, "Expect ';' after expression.");
        return try stmt.Stmt.create(self.allocator, .{ .expression = .init(value) });
    }

    fn expression(self: *Parser) Error!*expr.Expr {
        return try self.assignment();
    }

    fn assignment(self: *Parser) Error!*expr.Expr {
        const e = try self.logicOr();

        if (self.match(.{.equal})) {
            const equals = self.previous();
            const value = try self.assignment();

            switch (e.*) {
                .variable => |v| {
                    return try expr.Expr.create(
                        self.allocator,
                        .{ .assign = .init(v.name, value) },
                    );
                },
                .get => |g| {
                    return try expr.Expr.create(
                        self.allocator,
                        .{ .set = .init(g.object, g.name, value) },
                    );
                },
                else => {
                    try self.errorAt(equals, "Invalid assignment target.");
                },
            }
        }

        return e;
    }

    /// Book §9.3: `logic_or → logic_and ( "or" logic_and )* ;` — the
    /// lowest-precedence binary level, just above assignment. The node is
    /// `logical`, not `binary`, because evaluation short-circuits.
    fn logicOr(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.logicAnd();

        while (self.match(.{._or})) {
            const op = self.previous();
            const right = try self.logicAnd();
            e = try expr.Expr.create(self.allocator, .{ .logical = .init(e, right, op) });
        }

        return e;
    }

    /// Book §9.3: `logic_and → equality ( "and" equality )* ;` — binds
    /// tighter than `or`, so `a or b and c` parses as `a or (b and c)`.
    fn logicAnd(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.equality();

        while (self.match(.{._and})) {
            const op = self.previous();
            const right = try self.equality();
            e = try expr.Expr.create(self.allocator, .{ .logical = .init(e, right, op) });
        }

        return e;
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

    /// unary → ( "!" | "-" ) unary | call ;
    fn unary(self: *Parser) Error!*expr.Expr {
        if (self.match(.{ .bang, .minus })) {
            const op = self.previous();
            const right = try self.unary();
            return try expr.Expr.create(self.allocator, .{ .unary = .init(op, right) });
        }

        return try self.call();
    }

    /// Book §10.1: `call → primary ( "(" arguments? ")" )* ;`. Calls are a
    /// postfix operator with the highest precedence. The callee can be any
    /// primary-derived expression, and the loop lets its result be called
    /// again — `getCallback()()`.
    fn call(self: *Parser) Error!*expr.Expr {
        var e: *expr.Expr = try self.primary();

        while (true) {
            if (self.match(.{.l_paren})) {
                e = try self.finishCall(e);
            } else if (self.match(.{.dot})) {
                const name = try self.consume(.identifier_literal, "Expect property name after '.'.");
                e = try expr.Expr.create(self.allocator, .{
                    .get = .init(e, name),
                });
            } else {
                break;
            }
        }

        return e;
    }

    /// Book §10.1: `finishCall` parses the argument list after a consumed
    /// `(`, then wraps callee + arguments + the closing paren into a Call
    /// node. A `)` immediately means zero arguments.
    fn finishCall(self: *Parser, callee: *expr.Expr) Error!*expr.Expr {
        var arguments: std.ArrayList(*expr.Expr) = .empty;
        if (!self.check(.r_paren)) {
            while (true) {
                // Book §10.1.1: report but do not throw — a long argument
                // list is not a parsing dead end.
                if (arguments.items.len >= 255) {
                    try self.errorAt(self.peek(), "Can't have more than 255 arguments.");
                }

                try arguments.append(self.allocator, try self.expression());
                if (!self.match(.{.comma})) break;
            }
        }

        const paren = try self.consume(.r_paren, "Expect ')' after arguments.");
        return try expr.Expr.create(self.allocator, .{
            .call = .init(callee, paren, try arguments.toOwnedSlice(self.allocator)),
        });
    }

    /// primary → NUMBER | STRING | "true" | "false" | "nil"
    ///          | "(" expression ")" | IDENTIFIER ;
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

        // Book §8.2.2: an identifier is a variable access expression.
        if (self.match(.{.identifier_literal})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .variable = .init(self.previous()) },
            );
        }

        if (self.match(.{.l_paren})) {
            const grouped = try self.expression();
            _ = try self.consume(.r_paren, "Expect ')' after expression.");
            return try expr.Expr.create(self.allocator, .{ .grouping = .init(grouped) });
        }
        if (self.match(.{.super})) {
            const keyword = self.previous();
            _ = try self.consume(.dot, "Expect '.' after 'super'.");
            const method = try self.consume(.identifier_literal, "Expect superclass method name.");
            return try expr.Expr.create(
                self.allocator,
                .{ .super = .init(keyword, method) },
            );
        }

        if (self.match(.{.this})) {
            return try expr.Expr.create(
                self.allocator,
                .{ .this = .init(self.previous()) },
            );
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
    /// token's location, without unwinding. `consume`/`primary` wrap this
    /// in `reportError`; `assignment` uses it alone, since the book's
    /// invalid-target error does not throw (the parser is not confused and
    /// must keep parsing).
    fn errorAt(self: *Parser, tok: token.Token, message: []const u8) Error!void {
        const located = if (std.meta.activeTag(tok.tag) == .eof)
            std.fmt.allocPrint(self.allocator, "at end: {s}", .{message}) catch message
        else
            std.fmt.allocPrint(
                self.allocator,
                "at '{s}': {s}",
                .{ tok.lexeme, message },
            ) catch message;

        const diag = try diagnose.Diagnostic.create(
            self.allocator,
            error.Parse,
            tok.line,
            located,
            null,
        );
        try self.diagnostics.append(self.allocator, diag);
    }

    /// `errorAt` plus the ParseError unwind — the book's
    /// `throw error(token, message)`.
    fn reportError(self: *Parser, tok: token.Token, message: []const u8) Error!void {
        try self.errorAt(tok, message);
        return error.Parse;
    }

    /// Book §6.3.3: discard tokens until the next statement boundary, so
    /// parsing can resume without cascaded errors. Wired at each
    /// declaration by §8.2's panic-mode recovery.
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
