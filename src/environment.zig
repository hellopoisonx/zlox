const std = @import("std");
const interpreter = @import("interpreter.zig");
const token = @import("token.zig");

const Value = interpreter.Value;
const Token = token.Token;

/// The book §8.3 `Environment` class: the store that associates variable
/// names with values — a name→value map pulled out of Interpreter because
/// it forms a nicely delineated concept. Keys are bare strings (token
/// lexemes), not tokens: every identifier token with the same text refers
/// to the same variable. Lexemes borrow source text held by the caller's
/// arena — a script run's arena, or the REPL session's arena so globals
/// keep valid keys across lines.
pub const Environment = struct {
    values: std.StringHashMapUnmanaged(Value) = .empty,
    allocator: std.mem.Allocator,
    enclosing: ?*Environment = null,

    pub const Error = error{UndefinedVariable};

    pub fn init(allocator: std.mem.Allocator) Environment {
        return .{ .allocator = allocator };
    }
    pub fn initEnclosing(allocator: std.mem.Allocator, enclosing: *Environment) Environment {
        return .{
            .allocator = allocator,
            .enclosing = enclosing,
        };
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
        if (self.values.get(name)) |v| return v;
        if (self.enclosing) |enc| {
            return enc.get(name);
        }
        return null;
    }

    /// Book §8.5's enclosing-aware `assign`: assignment is not allowed to
    /// create a variable, so a miss at the root is `error.UndefinedVariable`
    /// — the interpreter owns the token and raises the book's "Undefined
    /// variable '<name>'." RuntimeError.
    pub fn assign(self: *Environment, name: Token, value: Value) Error!void {
        if (self.values.getPtr(name.lexeme)) |slot| {
            slot.* = value;
            return;
        }
        if (self.enclosing) |enc| return enc.assign(name, value);
        return error.UndefinedVariable;
    }
};
