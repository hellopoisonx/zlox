const std = @import("std");
const stmt = @import("stmt.zig");
const environment = @import("environment.zig");
const interpreter = @import("interpreter.zig");
const token = @import("token.zig");

const Environment = environment.Environment;
const Interpreter = interpreter.Interpreter;
const Value = interpreter.Value;
const Token = token.Token;
/// Book §10.1's `LoxCallable`. Java models "anything a Lox value can call"
/// with an interface; in this port the closed set of runtime callables is
/// a tagged union, so every `switch` over it is checked when a later
/// chapter adds an implementer (classes arrive in ch.12). A `Value` stores
/// a pointer, giving Java's object identity for `==`.
pub const Callable = union(enum) {
    native: Native,
    function: LoxFunction,
    class: *LoxClass,
    pub fn arity(self: *const Callable) usize {
        return switch (self.*) {
            .native => |n| n.arity,
            .function => |f| f.declaration.params.len,
            .class => |c| c.arity(),
        };
    }

    pub fn call(self: *const Callable, it: *Interpreter, arguments: []const Value) Interpreter.EvalError!Value {
        return switch (self.*) {
            .native => |n| n.run(it, arguments),
            .function => |f| f.call(it, arguments),
            .class => |c| c.call(it, arguments),
        };
    }

    /// The `toString()` half of the book's `stringify`: functions print as
    /// `<fn name>` (§10.4), natives as `<native fn>` (§10.2).
    pub fn stringify(self: *const Callable, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (self.*) {
            .native => "<native fn>",
            .function => |f| try std.fmt.allocPrint(allocator, "<fn {s}>", .{f.declaration.name.lexeme}),
            .class => |c| c.name.lexeme,
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
    is_initializer: bool = false,

    pub fn init(declaration: stmt.Function, closure: *Environment, is_initializer: bool) LoxFunction {
        return .{
            .declaration = declaration,
            .closure = closure,
            .is_initializer = is_initializer,
        };
    }

    pub fn bind(self: *const LoxFunction, allocator: std.mem.Allocator, instance: *Instance) std.mem.Allocator.Error!*Callable {
        const env = try allocator.create(Environment);
        env.* = Environment.initEnclosing(allocator, self.closure);
        try env.define("this", .{ .instance = instance });

        const bound = try allocator.create(Callable);
        bound.* = .{
            .function = .{
                .declaration = self.declaration,
                .closure = env,
                .is_initializer = self.is_initializer,
            },
        };
        return bound;
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
            error.Return => {
                if (self.is_initializer) {
                    return self.closure.getAt(0, "this").?;
                }
                return it.return_value;
            },
            else => return err,
        };
        if (self.is_initializer) {
            return self.closure.getAt(0, "this").?;
        }
        return .nil;
    }
};

/// Book §12.3 LoxClass: runtime representation of a class.
pub const LoxClass = struct {
    name: Token,
    methods: std.StringHashMapUnmanaged(LoxFunction),

    pub fn init(name: Token, methods: std.StringHashMapUnmanaged(LoxFunction)) LoxClass {
        return .{
            .name = name,
            .methods = methods,
        };
    }

    pub fn findMethod(self: *const LoxClass, name: []const u8) ?LoxFunction {
        return self.methods.get(name);
    }

    pub fn arity(self: *const LoxClass) usize {
        if (self.findMethod("init")) |initializer| {
            return initializer.declaration.params.len;
        }
        return 0;
    }

    pub fn call(self: *LoxClass, it: *Interpreter, arguments: []const Value) Interpreter.EvalError!Value {
        const instance = try it.allocator.create(Instance);
        instance.* = Instance.init(it.allocator, self);

        if (self.findMethod("init")) |initializer| {
            const bound = try initializer.bind(it.allocator, instance);
            _ = try bound.call(it, arguments);
        }

        return .{ .instance = instance };
    }
};

/// Book §12.3/§12.4 LoxInstance: runtime representation of an instance of a class.
pub const Instance = struct {
    allocator: std.mem.Allocator,
    klass: *const LoxClass,
    fields: std.StringHashMapUnmanaged(Value) = .empty,

    pub fn init(allocator: std.mem.Allocator, klass: *const LoxClass) Instance {
        return .{
            .allocator = allocator,
            .klass = klass,
        };
    }

    pub fn get(self: *Instance, it: *Interpreter, name: Token) Interpreter.EvalError!Value {
        if (self.fields.get(name.lexeme)) |val| {
            return val;
        }

        if (self.klass.findMethod(name.lexeme)) |method| {
            const bound = try method.bind(it.allocator, self);
            return .{ .callable = bound };
        }

        return it.runtimeErrorf(name, "Undefined property '{s}'.", .{name.lexeme});
    }

    pub fn set(self: *Instance, name: Token, value: Value) std.mem.Allocator.Error!void {
        try self.fields.put(self.allocator, name.lexeme, value);
    }

    pub fn stringify(self: *const Instance, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return try std.fmt.allocPrint(allocator, "{s} instance", .{self.klass.name.lexeme});
    }
};
