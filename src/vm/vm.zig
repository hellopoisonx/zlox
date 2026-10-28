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
pub const frames_max: usize = 64;
pub const stack_max: usize = frames_max * (std.math.maxInt(u8) + 1);

pub const CallFrame = struct {
    closure: *object.ObjClosure = undefined,
    ip: [*]const u8 = undefined,
    slots_index: usize = 0,

    pub fn instructionOffset(self: *const CallFrame) usize {
        return @intFromPtr(self.ip) - @intFromPtr(self.closure.function.chunk.code.items.ptr);
    }
};

pub const VM = struct {
    frames: [frames_max]CallFrame = undefined,
    frame_count: usize = 0,
    heap: object.Heap,
    globals: std.AutoHashMapUnmanaged(*object.ObjString, value.Value) = .empty,
    stack: [stack_max]value.Value = undefined,
    stack_top: usize = 0,
    openUpvalues: ?*object.ObjUpvalue = null,

    pub fn init(allocator: std.mem.Allocator) !VM {
        var vm: VM = .{
            .heap = object.Heap.init(allocator),
        };
        vm.resetStack();
        try vm.defineNative("clock", clockNative);
        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit(self.heap.allocator());
        self.heap.deinit();
    }

    pub fn interpret(
        self: *VM,
        source: [:0]const u8,
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
    ) !InterpretResult {
        self.heap.log_writer = stdout;
        defer self.heap.log_writer = null;

        const maybe_function = try compiler.compile(source, &self.heap, stdout, stderr);
        const function = maybe_function orelse return .compile_error;

        self.push(.{ .obj = &function.obj });
        const closure = try self.heap.newClosure(function);
        _ = self.pop();
        self.push(.{ .obj = &closure.obj });
        self.call(closure, 0, stderr) catch |err| switch (err) {
            error.RuntimeError => return .runtime_error,
            else => |e| return e,
        };

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
                const frame = self.currentFrame();
                _ = try debug.disassembleInstruction(stdout, &frame.closure.function.chunk, frame.instructionOffset());
            }

            const instruction = std.enums.fromInt(OpCode, self.readByte()) orelse {
                return .runtime_error;
            };
            switch (instruction) {
                .@"return" => {
                    const result = self.pop();
                    const slots_index = self.currentFrame().slots_index;
                    self.closeUpvalues(&self.stack[slots_index]);
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        _ = self.pop();
                        return .ok;
                    }

                    self.stack_top = slots_index;
                    self.push(result);
                },
                .call => {
                    const arg_count = self.readByte();
                    try self.callValue(self.peek(arg_count), arg_count, stderr);
                },
                .closure => {
                    const function = object.asFunction(self.readConstant().obj);
                    const closure = try self.heap.newClosure(function);
                    self.push(.{ .obj = &closure.obj });

                    const slots_index = self.currentFrame().slots_index;
                    var i: usize = 0;
                    while (i < closure.upvalues.len) : (i += 1) {
                        const is_local = self.readByte() != 0;
                        const index = self.readByte();
                        closure.upvalues[i] = if (is_local)
                            try self.captureUpvalue(&self.stack[slots_index + @as(usize, index)])
                        else
                            self.currentFrame().closure.upvalues[@as(usize, index)];
                    }
                },
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
                .jump => {
                    const offset = self.readShort();
                    self.currentFrame().ip += offset;
                },
                .jump_if_false => {
                    const offset = self.readShort();
                    if (value.isFalsey(self.peek(0))) self.currentFrame().ip += offset;
                },
                .loop => {
                    const offset = self.readShort();
                    self.currentFrame().ip -= offset;
                },
                .pop => _ = self.pop(),
                .close_upvalue => {
                    self.closeUpvalues(&self.stack[self.stack_top - 1]);
                    _ = self.pop();
                },
                .get_local => {
                    const slot = self.readByte();
                    self.push(self.stack[self.currentFrame().slots_index + slot]);
                },
                .set_local => {
                    const slot = self.readByte();
                    self.stack[self.currentFrame().slots_index + slot] = self.peek(0);
                },
                .get_upvalue => {
                    const slot = self.readByte();
                    const upvalue = self.currentFrame().closure.upvalues[slot] orelse unreachable;
                    self.push(upvalue.location.*);
                },
                .set_upvalue => {
                    const slot = self.readByte();
                    const upvalue = self.currentFrame().closure.upvalues[slot] orelse unreachable;
                    upvalue.location.* = self.peek(0);
                },
                .define_global => {
                    const name = self.readString();
                    try self.globals.put(self.heap.allocator(), name, self.peek(0));
                    _ = self.pop();
                },
                .get_global => {
                    const name = self.readString();
                    const global = self.globals.get(name) orelse
                        return self.runtimeErrorFormat(stderr, "Undefined variable '{s}'.", .{name.chars});
                    self.push(global);
                },
                .set_global => {
                    const name = self.readString();
                    const global = self.globals.getPtr(name) orelse
                        return self.runtimeErrorFormat(stderr, "Undefined variable '{s}'.", .{name.chars});
                    global.* = self.peek(0);
                },
            }
        }
    }

    fn callValue(self: *VM, callee: value.Value, arg_count: u8, stderr: *std.Io.Writer) !void {
        switch (callee) {
            .obj => |obj| switch (obj.type) {
                .closure => return self.call(object.asClosure(obj), arg_count, stderr),
                .native => {
                    const native_function = object.asNative(obj).function;
                    const result = native_function(arg_count, self.stack[self.stack_top - arg_count ..].ptr);
                    self.stack_top -= @as(usize, arg_count) + 1;
                    self.push(result);
                    return;
                },
                .function, .string, .upvalue => {},
            },
            else => {},
        }

        return self.runtimeError(stderr, "Can only call functions and classes.");
    }

    fn call(self: *VM, closure: *object.ObjClosure, arg_count: u8, stderr: *std.Io.Writer) !void {
        const function = closure.function;
        if (arg_count != function.arity) {
            return self.runtimeErrorFormat(stderr, "Expected {d} arguments but got {d}.", .{ function.arity, arg_count });
        }

        if (self.frame_count == frames_max) {
            return self.runtimeError(stderr, "Stack overflow.");
        }

        const frame = &self.frames[self.frame_count];
        self.frame_count += 1;
        frame.closure = closure;
        frame.ip = function.chunk.code.items.ptr;
        frame.slots_index = self.stack_top - @as(usize, arg_count) - 1;
    }

    fn defineNative(self: *VM, name: []const u8, native_function: object.NativeFn) !void {
        self.push(.{ .obj = &(try self.heap.copyString(name)).obj });
        self.push(.{ .obj = &(try self.heap.newNative(native_function)).obj });
        try self.globals.put(self.heap.allocator(), object.asString(self.stack[0].obj), self.stack[1]);
        _ = self.pop();
        _ = self.pop();
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
        const b = object.asString(self.peek(0).obj);
        const a = object.asString(self.peek(1).obj);
        const result = try self.heap.concatenate(a, b);
        _ = self.pop();
        _ = self.pop();
        self.push(.{ .obj = &result.obj });
    }

    fn captureUpvalue(self: *VM, local: *value.Value) !*object.ObjUpvalue {
        var prev_upvalue: ?*object.ObjUpvalue = null;
        var upvalue = self.openUpvalues;
        while (upvalue) |current| {
            if (@intFromPtr(current.location) <= @intFromPtr(local)) break;
            prev_upvalue = current;
            upvalue = current.next;
        }

        if (upvalue) |current| {
            if (current.location == local) return current;
        }

        const created = try self.heap.newUpvalue(local);
        created.next = upvalue;
        if (prev_upvalue) |prev| {
            prev.next = created;
        } else {
            self.openUpvalues = created;
        }
        return created;
    }

    fn closeUpvalues(self: *VM, last: *value.Value) void {
        while (self.openUpvalues) |upvalue| {
            if (@intFromPtr(upvalue.location) < @intFromPtr(last)) break;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed;
            self.openUpvalues = upvalue.next;
        }
    }

    fn runtimeError(self: *VM, stderr: *std.Io.Writer, message: []const u8) error{RuntimeError} {
        return self.runtimeErrorFormat(stderr, "{s}", .{message});
    }

    fn runtimeErrorFormat(self: *VM, stderr: *std.Io.Writer, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
        stderr.print(fmt ++ "\n", args) catch {};

        var index = self.frame_count;
        while (index > 0) {
            index -= 1;
            const frame = &self.frames[index];
            const function = frame.closure.function;
            const offset = frame.instructionOffset();
            const line = function.chunk.lines.items[if (offset > 0) offset - 1 else 0];
            if (function.name) |name| {
                stderr.print("[line {d}] in {s}()\n", .{ line, name.chars }) catch {};
            } else {
                stderr.print("[line {d}] in script\n", .{line}) catch {};
            }
        }

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

    inline fn currentFrame(self: *VM) *CallFrame {
        return &self.frames[self.frame_count - 1];
    }

    inline fn readByte(self: *VM) u8 {
        const frame = self.currentFrame();
        defer frame.ip += 1;
        return frame.ip[0];
    }

    inline fn readShort(self: *VM) u16 {
        const high: u16 = self.readByte();
        const low: u16 = self.readByte();
        return (high << 8) | low;
    }

    inline fn readConstant(self: *VM) value.Value {
        return self.currentFrame().closure.function.chunk.constants.values.items[self.readByte()];
    }

    inline fn readString(self: *VM) *object.ObjString {
        return object.asString(self.readConstant().obj);
    }

    pub inline fn resetStack(self: *VM) void {
        self.closeUpvalues(&self.stack[0]);
        self.stack_top = 0;
        self.frame_count = 0;
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

fn clockNative(arg_count: u8, args: [*]value.Value) value.Value {
    _ = arg_count;
    _ = args;
    const io = std.Io.Threaded.global_single_threaded.io();
    const nanoseconds = std.Io.Clock.now(.cpu_process, io).nanoseconds;
    return .{ .number = @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_s };
}
