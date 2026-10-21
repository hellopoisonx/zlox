const std = @import("std");
const interpreter = @import("interpreter.zig");
const token = @import("token.zig");

const Value = interpreter.Value;
const Token = token.Token;

/// The book §8.3 `Environment` class: the store that associates variable
/// names with values — a name→value map pulled out of Interpreter because
/// it forms a nicely delineated concept. Keys are bare strings (token
/// lexemes), not tokens: every identifier token with the same text refers
/// to the same variable. Lexemes borrow the scanner's source buffer,
/// which the run's arena keeps alive as long as the environment.
pub const Environment = struct {
    values: std.StringHashMapUnmanaged(Value) = .empty,
    allocator: std.mem.Allocator,

    pub const Error = error{UndefinedVariable};

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .allocator = allocator };
    }

    /// Book §8.3 `define`: bind a name to a value — deliberately without
    /// checking whether it's already present, so redefining a variable
    /// with `var` is legal (the book keeps REPL and script rules the
    /// same).
    pub fn define(self: *Environment, name: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.values.put(self.allocator, name, value);
    }

    /// Book §8.3 `get`: look a name up. Null is the "not bound" answer —
    /// the caller owns the token and raises the book's "Undefined
    /// variable" RuntimeError; deferring to runtime (not parse time)
    /// keeps referring to a not-yet-defined variable legal inside
    /// function bodies (which arrive in ch.10).
    pub fn get(self: *Environment, name: []const u8) ?Value {
        return self.values.get(name);
    }

    pub fn assign(self: *Environment, name: Token, value: Value) !void {
        if (self.values.contains(name.lexeme())) {
            try self.values.put(self.allocator, name.lexeme(), value);
        } else {
            return error.UndefinedVariable;
        }
    }
};
