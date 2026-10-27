const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const value = @import("value.zig");
const object = @import("object.zig");
const debug = @import("debug.zig");
const compiler = @import("compiler.zig");
const build_options = @import("build_options");

pub const InterpretResult = enum {
    ok,
    compile_error,
    runtime_error,
};

pub const debug_trace_execution: bool = build_options.trace_execution;
pub const stack_max: usize = 256;
pub const VM = struct {
    chunk: ?*Chunk = null,
    heap: object.Heap,
    globals: std.StringHashMapUnmanaged(value.Value) = .empty,
    ip: [*]const u8 = undefined,
    stack: [stack_max]value.Value = undefined,
    stack_top: usize = 0,

    pub fn init(allocator: std.mem.Allocator) VM {
        var vm: VM = .{
            .heap = object.Heap.init(allocator),
        };
        vm.resetStack();
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit(self.heap.allocator);
        self.heap.deinit();
    }

    pub fn interpret(
        self: *VM,
        source: [:0]const u8,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !InterpretResult {
        var chunk = Chunk.init(self.heap.allocator);
        defer chunk.deinit();
        if (!(try compiler.compile(source, &chunk, &self.heap, stdout, stderr))) return .compile_error;

        self.chunk = &chunk;
        self.ip = chunk.code.items.ptr;
        return try self.run(stdout, stderr);
    }

    pub fn run(self: *VM, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !InterpretResult {
        return self.execute(stdout, stderr) catch |err| switch (err) {
            error.RuntimeError => .runtime_error,
            else => |e| return e,
        };
    }

    fn execute(self: *VM, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !InterpretResult {
        while (true) {
            if (comptime debug_trace_execution) {
                try self.stackDump(stdout);
                const offset = self.ip - self.chunk.?.code.items.ptr;
                _ = try debug.disassembleInstruction(stdout, self.chunk.?, offset);
            }

            const instruction = std.enums.fromInt(OpCode, self.readByte()) orelse {
                return .runtime_error;
            };
            switch (instruction) {
                .@"return" => return .ok,
                .constant => {
                    const constant = self.readConstant();
                    self.push(constant);
                },
                .nil => self.push(.nil),
                .true => self.push(.{ .boolean = true }),
                .false => self.push(.{ .boolean = false }),
                .equal => {
                    const b = self.pop();
                    const a = self.pop();
                    self.push(.{ .boolean = value.valuesEqual(a, b) });
                },
                .greater => try self.binaryOp(.greater, stderr),
                .less => try self.binaryOp(.less, stderr),
                .add => try self.binaryOp(.add, stderr),
                .subtract => try self.binaryOp(.subtract, stderr),
                .multiply => try self.binaryOp(.multiply, stderr),
                .divide => try self.binaryOp(.divide, stderr),
                .not => self.push(.{ .boolean = value.isFalsey(self.pop()) }),
                .negate => {
                    if (!value.isNumber(self.peek(0))) {
                        return self.runtimeError(stderr, "Operand must be a number.");
                    }
                    self.push(.{ .number = -self.pop().number });
                },
                .print => {
                    try value.printValue(stdout, self.pop());
                    try stdout.print("\n", .{});
                },
                .pop => _ = self.pop(),
                .define_global => {
                    const name = self.readString();
                    try self.globals.put(self.heap.allocator, name.chars, self.pop());
                },
                .get_global => {
                    const name = self.readString();
                    const global = self.globals.get(name.chars) orelse
                        return self.runtimeErrorFormat(stderr, "Undefined variable '{s}'.", .{name.chars});
                    self.push(global);
                },
                .set_global => {
                    const name = self.readString();
                    const global = self.globals.getPtr(name.chars) orelse
                        return self.runtimeErrorFormat(stderr, "Undefined variable '{s}'.", .{name.chars});
                    global.* = self.peek(0);
                },
            }
        }
    }

    inline fn binaryOp(self: *VM, comptime op: OpCode, stderr: *std.Io.Writer) !void {
        if (op == .add) {
            if (value.isString(self.peek(1)) and value.isString(self.peek(0))) {
                try self.concatenate();
                return;
            }
            if (!value.isNumber(self.peek(1)) or !value.isNumber(self.peek(0))) {
                return self.runtimeError(stderr, "Operands must be two numbers or two strings.");
            }
            const b = self.pop().number;
            const a = self.pop().number;
            self.push(.{ .number = a + b });
            return;
        }

        if (!value.isNumber(self.peek(1)) or !value.isNumber(self.peek(0))) {
            return self.runtimeError(stderr, "Operands must be numbers.");
        }

        const b = self.pop().number;
        const a = self.pop().number;
        self.push(switch (op) {
            .subtract => .{ .number = a - b },
            .multiply => .{ .number = a * b },
            .divide => .{ .number = a / b },
            .greater => .{ .boolean = a > b },
            .less => .{ .boolean = a < b },
            else => @compileError("Unsupported binary operation for " ++ @tagName(op)),
        });
    }

    fn concatenate(self: *VM) !void {
        const b = object.asString(self.pop().obj);
        const a = object.asString(self.pop().obj);
        const result = try self.heap.concatenate(a, b);
        self.push(.{ .obj = &result.obj });
    }

    fn runtimeError(self: *VM, stderr: *std.Io.Writer, message: []const u8) error{RuntimeError} {
        return self.runtimeErrorFormat(stderr, "{s}", .{message});
    }

    fn runtimeErrorFormat(self: *VM, stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
        stderr.print(fmt ++ "\n", args) catch {};
        const instruction = (self.ip - self.chunk.?.code.items.ptr) - 1;
        const line = self.chunk.?.lines.items[instruction];
        stderr.print("[line {d}] in script\n", .{line}) catch {};
        stderr.flush() catch {};
        self.resetStack();
        return error.RuntimeError;
    }

    inline fn stackDump(self: *const VM, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("          ");
        for (self.stack[0..self.stack_top]) |slot| {
            try writer.writeAll("[ ");
            try value.printValue(writer, slot);
            try writer.writeAll(" ]");
        }
        try writer.writeAll("\n");
    }

    inline fn readByte(self: *VM) u8 {
        defer self.ip += 1;
        return self.ip[0];
    }

    inline fn readConstant(self: *VM) value.Value {
        return self.chunk.?.constants.values.items[self.readByte()];
    }

    inline fn readString(self: *VM) *object.ObjString {
        return object.asString(self.readConstant().obj);
    }

    pub inline fn resetStack(self: *VM) void {
        self.stack_top = 0;
    }

    pub inline fn push(self: *VM, v: value.Value) void {
        self.stack[self.stack_top] = v;
        self.stack_top += 1;
    }

    pub inline fn pop(self: *VM) value.Value {
        self.stack_top -= 1;
        return self.stack[self.stack_top];
    }

    pub inline fn peek(self: *const VM, distance: usize) value.Value {
        return self.stack[self.stack_top - 1 - distance];
    }
};
