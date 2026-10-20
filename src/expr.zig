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
    grouping: Grouping,
    literal: Literal,
    unary: Unary,

    /// Heap-allocate `expr` as a node, for use in child edges.
    pub fn create(allocator: std.mem.Allocator, expr: Expr) std.mem.Allocator.Error!*Expr {
        const node = try allocator.create(Expr);
        node.* = expr;
        return node;
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

/// Literal operands of `primary`. `string` borrows the scanner's
/// source buffer, which must outlive the tree.
pub const Literal = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    nil,
};
