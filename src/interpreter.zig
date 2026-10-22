const std = @import("std");
const expr = @import("expr.zig");
const token = @import("token.zig");
const stmt = @import("stmt.zig");
const environment = @import("environment.zig");
const callable = @import("callable.zig");
const Environment = environment.Environment;

/// A runtime Lox value boxed as a tagged union.
pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    /// Callable pointer (user function or native).
    callable: *callable.Callable,
    instance: *callable.Instance,
    nil,

    fn stringify(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (self) {
            .number => |n| try formatNumber(allocator, n),
            .boolean => |b| if (b) "true" else "false",
            // The bytes already outlive this run (scanner source buffer
            // or arena concat); no copy needed.
            .string => |s| s,
            .callable => |c| try c.stringify(allocator),
            .instance => |i| try i.stringify(allocator),
            .nil => "nil",
        };
    }
};

/// The number half of the book §7.4 `stringify`: Java's
/// `Double.toString` followed by the book's trailing-".0" strip, so
/// `3.0` prints as `3`. Double.toString's rules, ported: shortest
/// round-trip digits; plain decimal form iff 1e-3 <= |v| < 1e7, else
/// computerized scientific notation ("1.0E7", "1.0E-4"); and the
/// special spellings NaN / Infinity / -Infinity.
/// (Only subnormal extremes differ: Java isn't shortest there, e.g.
/// 5e-324 prints "4.9E-324" vs our "5.0E-324".)
fn formatNumber(allocator: std.mem.Allocator, n: f64) std.mem.Allocator.Error![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isPositiveInf(n)) return "Infinity";
    if (std.math.isNegativeInf(n)) return "-Infinity";

    // Shortest round-trip digits in scientific form: "-d.dddde±x".
    const sci = try std.fmt.allocPrint(allocator, "{e}", .{n});
    const e_pos = std.mem.indexOfScalar(u8, sci, 'e').?;
    var mantissa = sci[0..e_pos];
    // "{e}" only ever emits a valid i32 exponent (|exp| <= 324 for f64).
    const exponent = std.fmt.parseInt(i32, sci[e_pos + 1 ..], 10) catch unreachable;

    var negative = false;
    if (mantissa[0] == '-') {
        negative = true;
        mantissa = mantissa[1..];
    }

    // digits with the point removed: value == d1.d2d3... * 10^exponent
    var digits_buf: [32]u8 = undefined;
    var digits_len: usize = 0;
    for (mantissa) |c| {
        if (c == '.') continue;
        digits_buf[digits_len] = c;
        digits_len += 1;
    }
    const digits = digits_buf[0..digits_len];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (negative) try out.append(allocator, '-');
    if (exponent >= -3 and exponent <= 6) {
        // Plain decimal form; int_len = digit count before the point.
        const int_len = exponent + 1;
        if (int_len <= 0) {
            try out.appendSlice(allocator, "0.");
            try out.appendNTimes(allocator, '0', @intCast(-int_len));
            try out.appendSlice(allocator, digits);
        } else if (int_len >= @as(i32, @intCast(digits_len))) {
            try out.appendSlice(allocator, digits);
            try out.appendNTimes(allocator, '0', @intCast(int_len - @as(i32, @intCast(digits_len))));
            try out.appendSlice(allocator, ".0");
        } else {
            const split: usize = @intCast(int_len);
            try out.appendSlice(allocator, digits[0..split]);
            try out.append(allocator, '.');
            try out.appendSlice(allocator, digits[split..]);
        }
    } else {
        // Computerized scientific notation: d.ddddEn (no '+').
        try out.append(allocator, digits[0]);
        try out.append(allocator, '.');
        if (digits_len > 1) {
            try out.appendSlice(allocator, digits[1..]);
        } else {
            try out.append(allocator, '0');
        }
        try out.print(allocator, "E{d}", .{exponent});
    }

    var text = try out.toOwnedSlice(allocator);
    if (std.mem.endsWith(u8, text, ".0")) text = text[0 .. text.len - 2];
    return text;
}

/// The book §7.3.1 RuntimeError: the token locating where in the user's
/// code the failure happened, plus a Lox-level message. Zig error values
/// carry only a tag — no payload — so this struct is the payload; it parks
/// on the interpreter between "throw" and "catch", the same side-channel
/// pattern parser.zig uses for diagnostics (the port of the book's
/// `Lox.error` channel).
pub const RuntimeError = struct {
    token: token.Token,
    message: []const u8,
};

/// Interpreter executes syntax trees.
pub const Interpreter = struct {
    runtime_error: ?RuntimeError = null,
    allocator: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    globals: *Environment,
    environment: *Environment,
    /// Book §11.4.1 locals: maps local variable expressions to scope distance.
    locals: std.AutoHashMapUnmanaged(*const expr.Expr, usize) = .empty,
    return_value: Value = .nil,
    call_depth: usize = 0,

    /// Evaluation can run function bodies (a call), which print, so
    /// `Writer.Error` is part of the set. `Return` travels through this
    /// error set but is always caught by `LoxFunction.call`.
    pub const EvalError = error{ RuntimeError, Return } || std.mem.Allocator.Error || std.Io.Writer.Error;
    /// Errors from executing statements: evaluation plus stdout writes.
    pub const ExecError = EvalError;

    /// Book §8.3: the interpreter owns one global environment for its own
    /// lifetime — a script run or the whole REPL session (jlox's static
    /// interpreter) — allocated in the caller's arena. Book §10.2: the
    /// native `clock` is installed in that global scope at construction.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        stdout: *std.Io.Writer,
    ) std.mem.Allocator.Error!Interpreter {
        const global = try allocator.create(Environment);
        global.* = Environment.init(allocator);

        const clock = try allocator.create(callable.Callable);
        clock.* = .{ .native = .{ .arity = 0, .run = clockNative } };
        try global.define("clock", .{ .callable = clock });

        return .{
            .allocator = allocator,
            .io = io,
            .stdout = stdout,
            .globals = global,
            .environment = global,
        };
    }

    /// Executes a list of statements in order.
    pub fn interpret(
        self: *Interpreter,
        statements: []const *stmt.Stmt,
    ) ExecError!void {
        for (statements) |s| {
            try self.execute(s);
        }
    }

    /// Book §11.4.1 resolve: records variable scope distance.
    pub fn resolve(self: *Interpreter, e: *const expr.Expr, depth: usize) std.mem.Allocator.Error!void {
        try self.locals.put(self.allocator, e, depth);
    }

    /// Executes a single statement.
    fn execute(
        self: *Interpreter,
        s: *const stmt.Stmt,
    ) ExecError!void {
        switch (s.*) {
            .expression => |st| _ = try self.evaluate(st.expression),

            // Book §10.4 visitFunctionStmt: wrap declaration and environment into callable.
            .function => |f| {
                const closure = try self.allocator.create(callable.Callable);
                closure.* = .{ .function = .init(f, self.environment, false) };
                try self.environment.define(f.name.lexeme, .{ .callable = closure });
            },

            // Book §8.1.3 visitPrintStmt: evaluate and print value.
            .print => |st| {
                const value = try self.evaluate(st.expression);
                const text = try value.stringify(self.allocator);
                try self.stdout.print("{s}\n", .{text});
            },

            // Book §10.5 visitReturnStmt: evaluate value and unwind with error.Return.
            ._return => |r| {
                var value: Value = .nil;
                if (r.value) |v| {
                    value = try self.evaluate(v);
                }
                if (self.call_depth == 0) {
                    return self.runtimeError(r.keyword, "Can't return from top-level code.");
                }
                self.return_value = value;
                return error.Return;
            },

            // Book §8.3 visitVarStmt: evaluate initializer (or nil) and define variable.
            .var_decl => |st| {
                var value: Value = .nil;
                if (st.initializer) |initializer| {
                    value = try self.evaluate(initializer);
                }
                try self.environment.define(st.name.lexeme, value);
            },

            // Book §8.5 visitBlock: run statements in enclosed block environment.
            .block => |b| {
                const block_env = try self.allocator.create(Environment);
                block_env.* = Environment.initEnclosing(self.allocator, self.environment);
                try self.executeBlock(b.statements, block_env);
            },

            ._if => |i| {
                if (isTruthy(try self.evaluate(i.cond))) {
                    try self.execute(i.thenBranch);
                } else if (i.elseBranch) |e| {
                    try self.execute(e);
                }
            },

            // Book §9.4 visitWhileStmt: re-evaluate the condition before
            // every iteration, including the first. The body is any
            // statement — the grammar does not require a block.
            ._while => |w| {
                while (isTruthy(try self.evaluate(w.cond))) {
                    try self.execute(w.body);
                }
            },
            .class => |c| {
                try self.environment.define(c.name.lexeme, .nil);

                var methods: std.StringHashMapUnmanaged(callable.LoxFunction) = .empty;
                for (c.methods) |method| {
                    const is_init = std.mem.eql(u8, method.name.lexeme, "init");
                    const fn_obj = callable.LoxFunction.init(method, self.environment, is_init);
                    try methods.put(self.allocator, method.name.lexeme, fn_obj);
                }

                const klass = try self.allocator.create(callable.LoxClass);
                klass.* = callable.LoxClass.init(c.name, methods);

                const call_obj = try self.allocator.create(callable.Callable);
                call_obj.* = .{ .class = klass };

                self.environment.assign(c.name, .{ .callable = call_obj }) catch |err| switch (err) {
                    error.UndefinedVariable => unreachable,
                };
            },
        }
    }

    /// Book §8.5 executeBlock: runs statements in given environment, then restores previous.
    pub fn executeBlock(
        self: *Interpreter,
        statements: []const *stmt.Stmt,
        env: *Environment,
    ) ExecError!void {
        const previous = self.environment;
        defer self.environment = previous;
        self.environment = env;

        for (statements) |s| {
            try self.execute(s);
        }
    }

    fn evaluate(self: *Interpreter, e: *const expr.Expr) EvalError!Value {
        return switch (e.*) {

            // Book §11.4.2 visitVariableExpr: look up resolved local or fallback to global.
            .variable => |v| try self.lookUpVariable(v.name, e),
            .literal => |lit| switch (lit) {
                .number => |n| .{ .number = n },
                .string => |s| .{ .string = s },
                .boolean => |b| .{ .boolean = b },
                .nil => .nil,
            },

            .grouping => |g| self.evaluate(g.expression),

            .call => |c| blk: {
                const callee = try self.evaluate(c.callee);

                var arguments: std.ArrayList(Value) = .empty;
                for (c.arguments) |argument| {
                    try arguments.append(self.allocator, try self.evaluate(argument));
                }

                const function = switch (callee) {
                    .callable => |f| f,
                    else => return self.runtimeError(c.paren, "Can only call functions and classes."),
                };

                if (arguments.items.len != function.arity()) {
                    return self.runtimeErrorf(c.paren, "Expected {d} arguments but got {d}.", .{
                        function.arity(),
                        arguments.items.len,
                    });
                }

                break :blk try function.call(self, arguments.items);
            },

            .unary => |u| blk: {
                const right = try self.evaluate(u.right);
                break :blk switch (u.op.tag) {
                    .minus => .{ .number = -(try self.checkNumberOperand(u.op, right)) },
                    .bang => .{ .boolean = !isTruthy(right) },
                    // The `unary` grammar (§6.1) admits no other operators.
                    else => unreachable,
                };
            },

            // §7.2.5: operands are evaluated left-to-right — user-visible
            // semantics per the book's "left" aside — and both before
            // either operand's type is checked (the "operand" aside, §7.3.1).
            .binary => |b| blk: {
                const left = try self.evaluate(b.left);
                const right = try self.evaluate(b.right);
                break :blk switch (b.op.tag) {
                    .minus, .slash, .star => blk2: {
                        const n = try self.checkNumberOperands(b.op, left, right);
                        break :blk2 .{ .number = switch (b.op.tag) {
                            .minus => n[0] - n[1],
                            .slash => n[0] / n[1],
                            .star => n[0] * n[1],
                            else => unreachable,
                        } };
                    },

                    // `+` is overloaded: numbers add, strings concatenate.
                    .plus => {
                        if (std.meta.activeTag(left) == .number and std.meta.activeTag(right) == .number) {
                            break :blk .{ .number = left.number + right.number };
                        }
                        if (std.meta.activeTag(left) == .string and std.meta.activeTag(right) == .string) {
                            const joined = try std.mem.concat(self.allocator, u8, &.{ left.string, right.string });
                            break :blk .{ .string = joined };
                        }
                        return self.runtimeError(b.op, "Operands must be two numbers or two strings.");
                    },

                    .greater, .greater_equal, .less, .less_equal => blk2: {
                        const n = try self.checkNumberOperands(b.op, left, right);
                        break :blk2 .{ .boolean = switch (b.op.tag) {
                            .greater => n[0] > n[1],
                            .greater_equal => n[0] >= n[1],
                            .less => n[0] < n[1],
                            .less_equal => n[0] <= n[1],
                            else => unreachable,
                        } };
                    },

                    .bang_equal => .{ .boolean = !checkEqual(left, right) },
                    .equal_equal => .{ .boolean = checkEqual(left, right) },

                    // The `binary` grammar (§6.1) produces exactly these ten
                    // operators, all handled above.
                    else => unreachable,
                };
            },

            // Book §9.3 visitLogicalExpr: evaluate the left operand, and
            // return it unchanged when its truthiness already decides the
            // result — that is the short circuit; the right operand's
            // side effects never run. Otherwise the right operand is the
            // result. Lox returns an operand value, not a coerced boolean.
            .logical => |l| blk: {
                const left = try self.evaluate(l.left);
                switch (l.op.tag) {
                    ._or => if (isTruthy(left)) break :blk left,
                    ._and => if (!isTruthy(left)) break :blk left,
                    else => unreachable,
                }
                break :blk try self.evaluate(l.right);
            },

            // Book §11.4.2 visitAssignExpr: assign to resolved local or global.
            .assign => |a| blk: {
                const value = try self.evaluate(a.value);
                if (self.locals.get(e)) |distance| {
                    try self.environment.assignAt(distance, a.name, value);
                } else {
                    self.globals.assign(a.name, value) catch |err| switch (err) {
                        error.UndefinedVariable => return self.runtimeErrorf(a.name, "Undefined variable '{s}'.", .{a.name.lexeme}),
                    };
                }
                break :blk value;
            },

            .get => |g| blk: {
                const object = try self.evaluate(g.object);
                switch (object) {
                    .instance => |inst| break :blk try inst.get(self, g.name),
                    else => return self.runtimeError(g.name, "Only instances have properties."),
                }
            },

            .set => |s| blk: {
                const object = try self.evaluate(s.object);
                const inst = switch (object) {
                    .instance => |i| i,
                    else => return self.runtimeError(s.name, "Only instances have fields."),
                };

                const value = try self.evaluate(s.value);
                try inst.set(s.name, value);
                break :blk value;
            },

            .this => |th| try self.lookUpVariable(th.keyword, e),
        };
    }

    /// Book §11.4.2 lookUpVariable: fetch a variable at the resolved distance or from globals.
    fn lookUpVariable(self: *Interpreter, name: token.Token, e: *const expr.Expr) EvalError!Value {
        if (self.locals.get(e)) |distance| {
            if (self.environment.getAt(distance, name.lexeme)) |val| {
                return val;
            }
            return self.runtimeErrorf(name, "Undefined variable '{s}'.", .{name.lexeme});
        } else {
            return self.globals.get(name.lexeme) orelse
                return self.runtimeErrorf(name, "Undefined variable '{s}'.", .{name.lexeme});
        }
    }

    /// Book §7.3.1's `throw new RuntimeError(token, message)`. The payload
    /// parks on the interpreter because Zig errors carry only a tag;
    /// `error.RuntimeError` unwinds the recursive evaluate() calls exactly
    /// like the Java exception.
    pub fn runtimeError(self: *Interpreter, tok: token.Token, message: []const u8) EvalError {
        self.runtime_error = .{ .token = tok, .message = message };
        return error.RuntimeError;
    }

    /// `runtimeError` with an allocated, formatted message — the
    /// "Undefined variable '<name>'." report interpolates the name.
    pub fn runtimeErrorf(self: *Interpreter, tok: token.Token, comptime fmt: []const u8, args: anytype) EvalError {
        const message = std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
        return self.runtimeError(tok, message);
    }

    /// The book's checkNumberOperand (§7.3.1): the unary `-` cast guard.
    fn checkNumberOperand(self: *Interpreter, op: token.Token, v: Value) EvalError!f64 {
        return switch (v) {
            .number => |n| n,
            else => self.runtimeError(op, "Operand must be a number."),
        };
    }

    /// The book's checkNumberOperands (§7.3.1): arithmetic and comparison
    /// guards. Left is checked first, matching the book's ordering.
    fn checkNumberOperands(self: *Interpreter, op: token.Token, a: Value, b: Value) EvalError![2]f64 {
        const x = switch (a) {
            .number => |n| n,
            else => return self.runtimeError(op, "Operands must be numbers."),
        };
        const y = switch (b) {
            .number => |n| n,
            else => return self.runtimeError(op, "Operands must be numbers."),
        };
        return .{ x, y };
    }
};

/// The book's isEqual (§7.2.5): equality never does implicit conversion.
/// Different types are never equal (no NullPointerException on `nil` —
/// handled by the tag switch). Strings compare by content (Java's
/// `String.equals`; clox gets the same via interning). Numbers follow
/// Java's `Double.equals`: it compares `doubleToLongBits`, so every NaN
/// equals every other NaN (the book's "nan" aside: Lox does NOT follow
/// IEEE 754) and +0.0 does NOT equal -0.0.
fn checkEqual(a: Value, b: Value) bool {
    return switch (a) {
        .nil => std.meta.activeTag(b) == .nil,
        .number => |x| switch (b) {
            // doubleToLongBits canonicalizes all NaN payloads/signs to
            // one bit pattern, hence the isNan check before the bit
            // comparison.
            .number => |y| (std.math.isNan(x) and std.math.isNan(y)) or
                @as(u64, @bitCast(x)) == @as(u64, @bitCast(y)),
            else => false,
        },
        .boolean => |x| switch (b) {
            .boolean => |y| x == y,
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        // Java compares objects with `equals`, and LoxFunction/native
        // callables don't override it, so identity is pointer equality.
        .callable => |x| switch (b) {
            .callable => |y| x == y,
            else => false,
        },
        .instance => |x| switch (b) {
            .instance => |y| x == y,
            else => false,
        },
    };
}

/// Lox follows Ruby's rule (book §7.2.4): `false` and `nil` are falsey,
/// everything else — including functions — is truthy.
fn isTruthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .nil => false,
        .number, .string, .callable, .instance => true,
    };
}

/// Book §10.2's native `clock()`: seconds since the Unix epoch as a
/// double. Reads the real-time clock through the session's IO backend,
/// the counterpart of Java's `System.currentTimeMillis() / 1000.0`.
fn clockNative(it: *Interpreter, _: []const Value) Interpreter.EvalError!Value {
    const millis = std.Io.Clock.real.now(it.io).toMilliseconds();
    return .{ .number = @as(f64, @floatFromInt(millis)) / 1000.0 };
}
