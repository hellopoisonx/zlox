const std = @import("std");
const stmt = @import("stmt.zig");
const environment = @import("environment.zig");
const interpreter = @import("interpreter.zig");

const Environment = environment.Environment;
const Interpreter = interpreter.Interpreter;
const Value = interpreter.Value;

/// Book §10.1's `LoxCallable`. Java models "anything a Lox value can call"
/// with an interface; in this port the closed set of runtime callables is
/// a tagged union, so every `switch` over it is checked when a later
/// chapter adds an implementer (classes arrive in ch.12). A `Value` stores
/// a pointer, giving Java's object identity for `==`.
pub const Callable = union(enum) {
    /// Book §10.2: implemented in the host language, e.g. `clock()`.
    native: Native,
    /// Book §10.4: a user-defined function plus the environment it closed
    /// over.
    function: LoxFunction,

    pub fn arity(self: *const Callable) usize {
        return switch (self.*) {
            .native => |n| n.arity,
            .function => |f| f.declaration.params.len,
        };
    }

    pub fn call(self: *const Callable, it: *Interpreter, arguments: []const Value) Interpreter.EvalError!Value {
        return switch (self.*) {
            .native => |n| n.run(it, arguments),
            .function => |f| f.call(it, arguments),
        };
    }

    /// The `toString()` half of the book's `stringify`: functions print as
    /// `<fn name>` (§10.4), natives as `<native fn>` (§10.2).
    pub fn stringify(self: *const Callable, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (self.*) {
            .native => "<native fn>",
            .function => |f| try std.fmt.allocPrint(allocator, "<fn {s}>", .{f.declaration.name.lexeme}),
        };
    }
};

/// A host-language function exposed to Lox. `run` receives the interpreter
/// — the book passes it to every `call()` — which e.g. lets `clock()` reach
/// the session's IO backend.
pub const Native = struct {
    arity: usize,
    run: *const fn (*Interpreter, []const Value) Interpreter.EvalError!Value,
};

/// Book §10.4 `LoxFunction`: the declaration syntax node plus the
/// environment that was active where it was declared. `call` binds
/// arguments into a fresh environment whose parent is that closure, so
/// every invocation — including recursion — gets its own parameter space,
/// and a returned function keeps the locals of the scope it closed over
/// (§10.6).
pub const LoxFunction = struct {
    declaration: stmt.Function,
    closure: *Environment,

    pub fn init(declaration: stmt.Function, closure: *Environment) LoxFunction {
        return .{
            .declaration = declaration,
            .closure = closure,
        };
    }

    /// Book §10.4/§10.6 `call`: arity was already checked by the caller.
    /// A `return` statement unwinds here as `error.Return` (§10.5), with
    /// the value parked on the interpreter; reaching the end of the body
    /// returns nil.
    pub fn call(self: *const LoxFunction, it: *Interpreter, arguments: []const Value) Interpreter.EvalError!Value {
        const env = try it.allocator.create(Environment);
        env.* = Environment.initEnclosing(it.allocator, self.closure);

        for (self.declaration.params, arguments) |param, argument| {
            try env.define(param.lexeme, argument);
        }

        // The port's stand-in for the Java call stack depth: a `return`
        // reached outside any call is reported by execute() as a runtime
        // error instead of letting `error.Return` escape to main. (Ch.11's
        // resolver makes it a static error instead.)
        it.call_depth += 1;
        defer it.call_depth -= 1;

        it.executeBlock(self.declaration.body, env) catch |err| switch (err) {
            error.Return => return it.return_value,
            else => return err,
        };
        return .nil;
    }
};
