const std = @import("std");
const value = @import("value.zig");

/// One-byte operation codes. The disassembler prints them in the book's
/// uppercase OP_* form.
pub const OpCode = enum(u8) {
    constant,
    nil,
    true,
    false,
    equal,
    greater,
    less,
    add,
    subtract,
    multiply,
    divide,
    not,
    negate,
    print,
    jump,
    jump_if_false,
    loop,
    pop,
    get_local,
    set_local,
    define_global,
    get_global,
    set_global,
    @"return",

    const names = blk: {
        const enum_info = @typeInfo(OpCode).@"enum";
        for (enum_info.field_values, 0..) |val, i| {
            if (val != i) @compileError("OpCode values must be sequential 0..N-1");
        }
        var array: [enum_info.field_names.len][:0]const u8 = undefined;
        for (enum_info.field_names, 0..) |name, i| {
            array[i] = toUpperOp(name);
        }
        break :blk array;
    };

    fn toUpperOp(comptime name: []const u8) [:0]const u8 {
        var buf: [name.len + 3:0]u8 = undefined;
        buf[0..3].* = "OP_".*;
        for (name, 0..) |c, i| {
            buf[3 + i] = std.ascii.toUpper(c);
        }
        buf[name.len + 3] = 0;
        const final = buf;
        return &final;
    }

    pub fn tag(self: OpCode) [:0]const u8 {
        return names[@backingInt(self)];
    }
};

/// A chunk of bytecode plus its constant pool (book §14.1, §14.5).
pub const Chunk = struct {
    code: std.ArrayList(u8) = .empty,
    constants: value.ValueArray,
    lines: std.ArrayList(usize) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return .{
            .constants = value.ValueArray.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.lines.deinit(self.allocator);
        self.constants.deinit();
    }

    pub fn writeByte(self: *Chunk, byte: u8, line: usize) std.mem.Allocator.Error!void {
        try self.code.append(self.allocator, byte);
        try self.lines.append(self.allocator, line);
    }

    pub fn writeOp(self: *Chunk, op: OpCode, line: usize) std.mem.Allocator.Error!void {
        try self.writeByte(@backingInt(op), line);
    }

    /// Append a constant and return its index into the pool.
    pub fn addConstant(self: *Chunk, constant: value.Value) std.mem.Allocator.Error!usize {
        try self.constants.append(constant);
        return self.constants.values.items.len - 1;
    }
};
