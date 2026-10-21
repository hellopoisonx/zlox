const std = @import("std");
const expr = @import("expr.zig");
const token = @import("token.zig");
const stmt = @import("stmt.zig");
const environment = @import("environment.zig");
const Environment = environment.Environment;

/// A runtime Lox value — the port of the book §7.1 `java.lang.Object` box.
/// The tagged union takes Java's place: each variant is one Lox type, and
/// the discriminant is the runtime answer to "which kind of value is this?".
/// Scalars are stored inline by value; `string` borrows the scanner's
/// source buffer — except strings created at runtime by `+`, which are
/// allocated from the run's arena (see `Interpreter.interpret`).
pub const Value = union(enum) {
    number: f64,
    boolean: bool,
    string: []const u8,
    nil,

    fn stringify(self: Value, allocator: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
        return switch (self) {
            .number => |n| try formatNumber(allocator, n),
            .boolean => |b| if (b) "true" else "false",
            // The bytes already outlive this run (scanner source buffer
            // or arena concat); no copy needed.
            .string => |s| s,
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

/// The book's Interpreter class. The book's `throw new RuntimeError(...)`
/// becomes two steps here: park the payload in `runtime_error`, then
/// return `error.RuntimeError` — `try` at every call site replays the Java
/// exception's stack unwind. The global environment (§8.3) lives here so
/// bindings outlive any single statement.
pub const Interpreter = struct {
    runtime_error: ?RuntimeError = null,
    allocator: std.mem.Allocator,
    environment: Environment,

    pub const EvalError = error{RuntimeError} || std.mem.Allocator.Error || environment.Environment.Error;
    /// Errors from executing statements: evaluation plus the stdout
    /// writes that `print` statements make.
    pub const ExecError = EvalError || std.Io.Writer.Error;

    pub fn init(allocator: std.mem.Allocator) Interpreter {
        return .{
            .allocator = allocator,
            .environment = Environment.init(allocator),
        };
    }

    /// Executes a whole program — statements in order (book §8.1.3's
    /// `interpret(List<Stmt>)`). `stdout` receives `print` output, the
    /// port of the book's `System.out.println` inside visitPrintStmt;
    /// the caller owns flushing. On `error.RuntimeError`, `runtime_error`
    /// holds the token and message for the caller to report (§7.4), and
    /// the remaining statements do not run — the book wraps the whole
    /// loop in one try block.
    pub fn interpret(
        self: *Interpreter,
        statements: []const *stmt.Stmt,
        stdout: *std.Io.Writer,
    ) ExecError!void {
        for (statements) |s| {
            try self.execute(s, stdout);
        }
    }

    /// The statement analogue of `evaluate` (book §8.1.3): dispatch one
    /// statement node.
    fn execute(
        self: *Interpreter,
        s: *const stmt.Stmt,
        stdout: *std.Io.Writer,
    ) ExecError!void {
        switch (s.*) {
            // Expression statement: evaluate for side effects, discard
            // the value (book §8.1.3).
            .expression => |st| _ = try self.evaluate(self.allocator, st.expression),

            // Print statement: stringify the value, then dump it to
            // stdout (book §8.1.3).
            .print => |st| {
                const value = try self.evaluate(self.allocator, st.expression);
                const text = try value.stringify(self.allocator);
                try stdout.print("{s}\n", .{text});
            },

            // Book §8.3 visitVarStmt: evaluate the initializer if there
            // is one; a variable without one holds nil. define() never
            // checks for an existing binding, so redefinition is legal.
            .var_decl => |st| {
                var value: Value = .nil;
                if (st.initializer) |initializer| {
                    value = try self.evaluate(self.allocator, initializer);
                }
                try self.environment.define(st.name.lexeme(), value);
            },
        }
    }

    /// Post-order traversal (book §7.2.3): each node evaluates its children
    /// before doing its own work.
    fn evaluate(self: *Interpreter, allocator: std.mem.Allocator, e: *const expr.Expr) EvalError!Value {
        return switch (e.*) {

            // Book §8.3 visitVariableExpr: forward to the environment.
            // A miss is the book's "Undefined variable" RuntimeError —
            // deferred to runtime so a function body may refer to a
            // variable defined later (ch.10).
            .variable => |v| self.environment.get(v.name.lexeme()) orelse
                return self.runtimeErrorf(v.name, "Undefined variable '{s}'.", .{v.name.lexeme()}),
            // §7.2.1: a literal is syntax that already holds its runtime
            // value; evaluation just unwraps it.
            .literal => |lit| switch (lit) {
                .number => |n| .{ .number = n },
                .string => |s| .{ .string = s },
                .boolean => |b| .{ .boolean = b },
                .nil => .nil,
            },

            // §7.2.2: parentheses group without computing anything.
            .grouping => |g| self.evaluate(allocator, g.expression),

            // §7.2.3: evaluate the operand first, then apply the operator.
            .unary => |u| blk: {
                const right = try self.evaluate(allocator, u.right);
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
                const left = try self.evaluate(allocator, b.left);
                const right = try self.evaluate(allocator, b.right);
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
                            const joined = try std.mem.concat(allocator, u8, &.{ left.string, right.string });
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
            .assign => |a| blk: {
                const value = try self.evaluate(self.allocator, a.value);
                try self.environment.assign(a.name, value);
                break :blk value;
            },
        };
    }

    /// Book §7.3.1's `throw new RuntimeError(token, message)`. The payload
    /// parks on the interpreter because Zig errors carry only a tag;
    /// `error.RuntimeError` unwinds the recursive evaluate() calls exactly
    /// like the Java exception.
    fn runtimeError(self: *Interpreter, tok: token.Token, message: []const u8) EvalError {
        self.runtime_error = .{ .token = tok, .message = message };
        return error.RuntimeError;
    }

    /// `runtimeError` with an allocated, formatted message — the
    /// "Undefined variable '<name>'." report interpolates the name.
    fn runtimeErrorf(self: *Interpreter, tok: token.Token, comptime fmt: []const u8, args: anytype) EvalError {
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
/// Java's `Double.equals`, so NaN == NaN and 0 == -0 is false — Lox does
/// NOT follow IEEE 754 here (book's "nan" aside).
fn checkEqual(a: Value, b: Value) bool {
    return switch (a) {
        .nil => std.meta.activeTag(b) == .nil,
        // Bit comparison is Java's Double.equals: NaN equals NaN, and
        // +0.0 does NOT equal -0.0. Every NaN the interpreter can
        // produce (0/0 and friends) carries the same canonical bit
        // pattern, so bit equality matches doubleToLongBits.
        .number => |x| switch (b) {
            .number => |y| @as(u64, @bitCast(x)) == @as(u64, @bitCast(y)),
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
    };
}

/// Lox follows Ruby's rule (book §7.2.4): `false` and `nil` are falsey,
/// everything else is truthy.
fn isTruthy(v: Value) bool {
    return switch (v) {
        .boolean => |b| b,
        .nil => false,
        .number, .string => true,
    };
}
