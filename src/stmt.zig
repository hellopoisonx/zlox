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
    print: Print,
    var_decl: Var,

    /// Heap-allocate `stmt` as a node, for use in statement lists.
    pub fn create(allocator: std.mem.Allocator, stmt: Stmt) std.mem.Allocator.Error!*Stmt {
        const node = try allocator.create(Stmt);
        node.* = stmt;
        return node;
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
