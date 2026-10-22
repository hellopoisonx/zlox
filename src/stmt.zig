const std = @import("std");
const expr = @import("expr.zig");
const token = @import("token.zig");

/// Statement AST node — the port of the book §8.1.1 `Stmt` class
/// hierarchy. Statements produce no value; they exist for their side
/// effects. Like `expr.Expr`, the tagged union replaces Java's
/// subclasses + visitor pattern, children are pointers so recursive
/// types stay finite, and nodes live in the run's arena.
pub const Stmt = union(enum) {
    expression: Expression,
    /// Book §10.3 `Stmt.Function`: a named declaration that, when
    /// executed, creates a closure and binds it in the current scope.
    function: Function,
    print: Print,
    /// Book §10.5 `Stmt.Return`; `return` is a Zig keyword, hence the
    /// leading underscore used elsewhere in this port.
    _return: Return,
    var_decl: Var,
    block: Block,
    _if: If,
    _while: While,
    class: Class,
    /// Heap-allocate `stmt` as a node, for use in statement lists.
    pub fn create(allocator: std.mem.Allocator, stmt: Stmt) std.mem.Allocator.Error!*Stmt {
        const node = try allocator.create(Stmt);
        node.* = stmt;
        return node;
    }
};

pub const If = struct {
    cond: *expr.Expr,
    thenBranch: *Stmt,
    elseBranch: ?*Stmt,

    pub fn init(cond: *expr.Expr, thenBranch: *Stmt, elseBranch: ?*Stmt) If {
        return .{
            .cond = cond,
            .thenBranch = thenBranch,
            .elseBranch = elseBranch,
        };
    }
};

/// Book §9.4 `Stmt.While`: `while (condition) body`. The condition is
/// re-evaluated before every iteration; nothing else is carried.
pub const While = struct {
    cond: *expr.Expr,
    body: *Stmt,

    pub fn init(cond: *expr.Expr, body: *Stmt) While {
        return .{
            .cond = cond,
            .body = body,
        };
    }
};

/// Book §10.3 `Stmt.Function`: name, parameter-name tokens, and the body
/// statements (always a braced block per the grammar). The syntax node is
/// also the declaration that `LoxFunction` wraps at runtime.
pub const Function = struct {
    name: token.Token,
    params: []const token.Token,
    body: []const *Stmt,

    pub fn init(name: token.Token, params: []const token.Token, body: []const *Stmt) Function {
        return .{
            .name = name,
            .params = params,
            .body = body,
        };
    }
};

/// Book §10.5 `Stmt.Return`: the keyword token locates runtime errors and
/// the optional value (`return;` means `return nil;`).
pub const Return = struct {
    keyword: token.Token,
    value: ?*expr.Expr,

    pub fn init(keyword: token.Token, value: ?*expr.Expr) Return {
        return .{
            .keyword = keyword,
            .value = value,
        };
    }
};

/// Book §8.5 `Stmt.Block`: a braced series of declarations whose
/// execution gets a fresh environment (see Interpreter.executeBlock).
pub const Block = struct {
    statements: []const *Stmt,

    pub fn init(stmts: []const *Stmt) Block {
        return .{
            .statements = stmts,
        };
    }
};

/// Book §8.1.1 `Stmt.Expression`: evaluate the inner expression and
/// discard the value — a statement whose whole point is the effect.
pub const Expression = struct {
    expression: *expr.Expr,

    pub fn init(expression: *expr.Expr) Expression {
        return .{ .expression = expression };
    }
};

/// Book §8.1.1 `Stmt.Print`: evaluate, stringify, write to stdout.
pub const Print = struct {
    expression: *expr.Expr,

    pub fn init(expression: *expr.Expr) Print {
        return .{ .expression = expression };
    }
};

/// Book §8.2.1 `Stmt.Var`
pub const Var = struct {
    name: token.Token,
    /// Null when the declaration has no `=` initializer clause (book
    /// §8.2.1: the field is null).
    initializer: ?*expr.Expr,

    pub fn init(name: token.Token, initializer: ?*expr.Expr) Var {
        return .{
            .name = name,
            .initializer = initializer,
        };
    }
};

/// Book §12.2 `Stmt.Class`: class declaration with a name and a list of methods.
pub const Class = struct {
    name: token.Token,
    methods: []const Function,

    pub fn init(name: token.Token, methods: []const Function) Class {
        return .{
            .name = name,
            .methods = methods,
        };
    }
};
