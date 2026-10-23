const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const value = @import("value.zig");
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
    allocator: std.mem.Allocator,
    ip: [*]const u8 = undefined,
    stack: [stack_max]value.Value = undefined,
    stack_top: usize = 0,

    pub fn init(allocator: std.mem.Allocator) VM {
        var vm: VM = .{
            .allocator = allocator,
        };
        vm.resetStack();
        return vm;
    }

    pub fn deinit(_: *VM) void {}

    pub fn interpret(self: *VM, source: [:0]const u8, writer: *std.Io.Writer) !InterpretResult {
        _ = self;
        try compiler.compile(source, writer);
        return .ok;
    }

    pub fn run(self: *VM, writer: *std.Io.Writer) !InterpretResult {
        while (true) {
            if (comptime debug_trace_execution) {
                try self.stackDump(writer);
                const offset = self.ip - self.chunk.?.code.items.ptr;
                _ = try debug.disassembleInstruction(writer, self.chunk.?, offset);
            }

            const instruction = std.enums.fromInt(OpCode, self.readByte()) orelse {
                return .runtime_error;
            };
            switch (instruction) {
                .@"return" => {
                    if (self.stack_top > 0) {
                        try value.printValue(writer, self.pop());
                        try writer.print("\n", .{});
                    }
                    return .ok;
                },
                .constant => {
                    const constant = self.readConstant();
                    self.push(constant);
                },
                .negate => self.push(-self.pop()),
                inline .add, .subtract, .divide, .multiply => |op| self.binaryOp(op),
            }
        }
    }

    inline fn binaryOp(self: *VM, comptime op: OpCode) void {
        const b = self.pop();
        const a = self.pop();
        const result = switch (op) {
            .add => a + b,
            .subtract => a - b,
            .multiply => a * b,
            .divide => a / b,
            else => @compileError("Unsupported binary operation for " ++ @tagName(op)),
        };
        self.push(result);
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
};
