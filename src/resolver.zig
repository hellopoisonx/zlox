const std = @import("std");
const diagnose = @import("diagnose.zig");
const expr = @import("expr.zig");
const interpreter = @import("interpreter.zig");
const stmt = @import("stmt.zig");
const token = @import("token.zig");

const Expr = expr.Expr;
const Stmt = stmt.Stmt;
const Token = token.Token;

/// Book §11 Resolver: static semantic analysis pass for variable resolution.
pub const Resolver = struct {
    allocator: std.mem.Allocator,
    interpreter: *interpreter.Interpreter,
    scopes: std.ArrayList(std.StringHashMapUnmanaged(bool)) = .empty,
    diagnostics: std.ArrayList(*diagnose.Diagnostic) = .empty,
    current_function: FunctionType = .none,

    pub const FunctionType = enum {
        none,
        function,
    };
    pub const Error = std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, interp: *interpreter.Interpreter) Resolver {
        return .{ .allocator = allocator, .interpreter = interp };
    }

    /// Resolves a list of statements.
    pub fn resolve(self: *Resolver, statements: []const *Stmt) Error!void {
        for (statements) |s| {
            try self.resolveStmt(s);
        }
    }

    /// Resolves one statement.
    fn resolveStmt(self: *Resolver, s: *const Stmt) Error!void {
        switch (s.*) {
            // New local block scope.
            .block => |b| {
                try self.beginScope();
                try self.resolve(b.statements);
                self.endScope();
            },

            .expression => |st| try self.resolveExpr(st.expression),

            .function => |f| {
                try self.declare(f.name);
                try self.define(f.name);
                try self.resolveFunction(f, .function);
            },

            // Resolve both condition and branches.
            ._if => |i| {
                try self.resolveExpr(i.cond);
                try self.resolveStmt(i.thenBranch);
                if (i.elseBranch) |e| try self.resolveStmt(e);
            },

            .print => |st| try self.resolveExpr(st.expression),

            ._return => |r| {
                if (self.current_function == .none) {
                    try self.errorAt(r.keyword, "Can't return from top-level code.");
                }
                if (r.value) |v| try self.resolveExpr(v);
            },

            // Declare -> resolve initializer -> define.
            .var_decl => |v| {
                try self.declare(v.name);
                if (v.initializer) |initializer| {
                    try self.resolveExpr(initializer);
                }
                try self.define(v.name);
            },

            // Resolve condition and body.
            ._while => |w| {
                try self.resolveExpr(w.cond);
                try self.resolveStmt(w.body);
            },
        }
    }

    /// Resolves one expression.
    fn resolveExpr(self: *Resolver, e: *const Expr) Error!void {
        switch (e.*) {
            // Resolve value then target variable.
            .assign => |a| {
                try self.resolveExpr(a.value);
                try self.resolveLocal(e, a.name);
            },

            .binary => |b| {
                try self.resolveExpr(b.left);
                try self.resolveExpr(b.right);
            },

            // Resolve callee then arguments in order.
            .call => |c| {
                try self.resolveExpr(c.callee);
                for (c.arguments) |argument| {
                    try self.resolveExpr(argument);
                }
            },

            .grouping => |g| try self.resolveExpr(g.expression),

            .literal => {},

            // Resolve both operands.
            .logical => |l| {
                try self.resolveExpr(l.left);
                try self.resolveExpr(l.right);
            },

            .unary => |u| try self.resolveExpr(u.right),

            // Disallow reading local variable in its own initializer.
            .variable => |v| {
                if (self.scopes.items.len > 0) {
                    const scope = &self.scopes.items[self.scopes.items.len - 1];
                    if (scope.get(v.name.lexeme)) |defined| {
                        if (!defined) {
                            try self.errorAt(v.name, "Can't read local variable in its own initializer.");
                        }
                    }
                }
                try self.resolveLocal(e, v.name);
            },
        }
    }

    fn resolveFunction(self: *Resolver, f: stmt.Function, function_type: FunctionType) Error!void {
        const enclosing_function = self.current_function;
        self.current_function = function_type;
        defer self.current_function = enclosing_function;

        try self.beginScope();
        for (f.params) |param| {
            try self.declare(param);
            try self.define(param);
        }
        try self.resolve(f.body);
        self.endScope();
    }

    fn beginScope(self: *Resolver) Error!void {
        try self.scopes.append(self.allocator, .empty);
    }

    fn endScope(self: *Resolver) void {
        var scope = self.scopes.pop().?;
        scope.deinit(self.allocator);
    }

    fn declare(self: *Resolver, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        if (scope.contains(name.lexeme)) {
            try self.errorAt(name, "Already a variable with this name in this scope.");
        }
        try scope.put(self.allocator, name.lexeme, false);
    }
    fn define(self: *Resolver, name: Token) Error!void {
        if (self.scopes.items.len == 0) return;
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        try scope.put(self.allocator, name.lexeme, true);
    }

    fn resolveLocal(self: *Resolver, e: *const Expr, name: Token) Error!void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].contains(name.lexeme)) {
                try self.interpreter.resolve(e, self.scopes.items.len - 1 - i);
                return;
            }
        }
    }

    fn errorAt(self: *Resolver, tok: Token, message: []const u8) Error!void {
        const located = std.fmt.allocPrint(
            self.allocator,
            "at '{s}': {s}",
            .{ tok.lexeme, message },
        ) catch message;

        const diag = try diagnose.Diagnostic.create(
            self.allocator,
            error.Resolve,
            tok.line,
            located,
            null,
        );
        try self.diagnostics.append(self.allocator, diag);
    }
};
