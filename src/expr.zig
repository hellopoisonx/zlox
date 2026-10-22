const std = @import("std");
const token = @import("token.zig");

/// AST node. The tagged union replaces Java's class hierarchy +
/// visitor pattern: each variant is a "subclass", and an exhaustive
/// `switch` over it plays the visitor's compile-time checking role.
///
/// Children are `*Expr` so the recursive type has finite size.
/// Nodes are owned by an arena allocator: build a whole tree, free
/// it with a single `arena.deinit()`.
pub const Expr = union(enum) {
    binary: Binary,
    /// Book §10.1 `Expr.Call`: invoking any expression that evaluates to a
    /// callable. The closing parenthesis is kept for runtime error
    /// locations.
    call: Call,
    /// Book §9.3 `Expr.Logical`: `and`/`or` get their own node instead of
    /// reusing `binary` because the interpreter must short-circuit — the
    /// right operand is not always evaluated.
    logical: Logical,
    grouping: Grouping,
    literal: Literal,
    unary: Unary,
    variable: Variable,
    assign: Assign,

    /// Heap-allocate `expr` as a node, for use in child edges.
    pub fn create(allocator: std.mem.Allocator, expr: Expr) std.mem.Allocator.Error!*Expr {
        const node = try allocator.create(Expr);
        node.* = expr;
        return node;
    }
};

pub const Assign = struct {
    name: token.Token,
    value: *Expr,

    pub fn init(name: token.Token, value: *Expr) Assign {
        return .{
            .name = name,
            .value = value,
        };
    }
};

pub const Binary = struct {
    left: *Expr,
    right: *Expr,
    op: token.Token,

    pub fn init(left: *Expr, right: *Expr, op: token.Token) Binary {
        return .{
            .left = left,
            .right = right,
            .op = op,
        };
    }
};

/// Book §10.1 `Expr.Call`. The callee is arbitrary syntax — `fn(1)(2)` calls
/// the result of the first call — so `call()` in the parser loops, and
/// only the parenthesized tail marks a call. Arguments are evaluated
/// left-to-right by the interpreter.
pub const Call = struct {
    callee: *Expr,
    /// The closing `)` token: the book reports call runtime errors
    /// (not-callable, wrong arity) at this location.
    paren: token.Token,
    arguments: []const *Expr,

    pub fn init(callee: *Expr, paren: token.Token, arguments: []const *Expr) Call {
        return .{
            .callee = callee,
            .paren = paren,
            .arguments = arguments,
        };
    }
};

/// Book §9.3 `Expr.Logical`. Field order follows `Binary` in this port;
/// `op` distinguishes `and` from `or` during evaluation.
pub const Logical = struct {
    left: *Expr,
    right: *Expr,
    op: token.Token,

    pub fn init(left: *Expr, right: *Expr, op: token.Token) Logical {
        return .{
            .left = left,
            .right = right,
            .op = op,
        };
    }
};

pub const Grouping = struct {
    expression: *Expr,

    pub fn init(expression: *Expr) Grouping {
        return .{ .expression = expression };
    }
};

pub const Unary = struct {
    op: token.Token,
    right: *Expr,

    pub fn init(op: token.Token, right: *Expr) Unary {
        return .{ .op = op, .right = right };
    }
};

/// Book §8.2.1 `Expr.Variable`: a variable access — simply a wrapper
/// around the token for the variable name being looked up.
pub const Variable = struct {
    name: token.Token,

    pub fn init(name: token.Token) Variable {
        return .{ .name = name };
    }
};

/// Literal operands of `primary`. `string` borrows the scanner's
/// source buffer, which must outlive the tree.
pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    nil,
};
