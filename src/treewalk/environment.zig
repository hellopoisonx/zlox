const std = @import("std");
const interpreter = @import("interpreter.zig");
const token = @import("token.zig");

const Value = interpreter.Value;
const Token = token.Token;

/// Environment associates variable names with runtime values.
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

    /// Defines or redefines a variable in this environment.
    pub fn define(self: *Environment, name: []const u8, value: Value) std.mem.Allocator.Error!void {
        try self.values.put(self.allocator, name, value);
    }

    /// Looks up a variable dynamically through enclosing environments.
    pub fn get(self: *Environment, name: []const u8) ?Value {
        if (self.values.get(name)) |v| return v;
        if (self.enclosing) |enc| {
            return enc.get(name);
        }
        return null;
    }

    /// Assigns to an existing variable in the innermost enclosing environment.
    pub fn assign(self: *Environment, name: Token, value: Value) Error!void {
        if (self.values.getPtr(name.lexeme)) |slot| {
            slot.* = value;
            return;
        }
        if (self.enclosing) |enc| return enc.assign(name, value);
        return error.UndefinedVariable;
    }

    /// Book §11.4.2 getAt: returns the variable value at fixed ancestor distance.
    pub fn getAt(self: *Environment, distance: usize, name: []const u8) ?Value {
        return self.ancestor(distance).values.get(name);
    }

    /// Book §11.4.2 assignAt: stores a new value in the ancestor environment.
    pub fn assignAt(self: *Environment, distance: usize, name: Token, value: Value) std.mem.Allocator.Error!void {
        const env = self.ancestor(distance);
        if (env.values.getPtr(name.lexeme)) |slot| {
            slot.* = value;
            return;
        }
        try env.values.put(env.allocator, name.lexeme, value);
    }

    /// Book §11.4.2 ancestor: walks up the environment chain `distance` hops.
    fn ancestor(self: *Environment, distance: usize) *Environment {
        var env = self;
        for (0..distance) |_| {
            env = env.enclosing.?;
        }
        return env;
    }
};
