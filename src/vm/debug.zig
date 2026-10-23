const std = @import("std");

const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const value = @import("value.zig");

/// Print a header, then every instruction in the chunk (book §14.4).
/// Flushing the writer is left to the caller.
pub fn disassembleChunk(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    name: []const u8,
) std.Io.Writer.Error!void {
    try writer.print("== {s} ==\n", .{name});
    var offset: usize = 0;
    while (offset < chunk.code.items.len) {
        offset = try disassembleInstruction(writer, chunk, offset);
    }
}

/// Decode and print the instruction at `offset`; returns the offset of
/// the next instruction (book §14.4).
pub fn disassembleInstruction(
    writer: *std.Io.Writer,
    chunk: *const Chunk,
    offset: usize,
) std.Io.Writer.Error!usize {
    try writer.print("{d:0>4} ", .{offset});

    if (offset > 0 and chunk.lines.items[offset] == chunk.lines.items[offset - 1]) {
        try writer.print("{s:>4} ", .{"|"});
    } else {
        try writer.print("{d:>4} ", .{chunk.lines.items[offset]});
    }

    const byte = chunk.code.items[offset];
    const op = std.enums.fromInt(OpCode, byte) orelse {
        try writer.print("Unknown opcode {d}\n", .{byte});
        return offset + 1;
    };
    return switch (op) {
        .constant => |o| constantInstruction(writer, o.tag(), chunk, offset),
        .@"return",
        .negate,
        .add,
        .subtract,
        .multiply,
        .divide,
        => |o| simpleInstruction(writer, o.tag(), offset),
    };
}

fn simpleInstruction(
    writer: *std.Io.Writer,
    name: []const u8,
    offset: usize,
) std.Io.Writer.Error!usize {
    try writer.print("{s}\n", .{name});
    return offset + 1;
}

fn constantInstruction(
    writer: *std.Io.Writer,
    name: []const u8,
    chunk: *const Chunk,
    offset: usize,
) std.Io.Writer.Error!usize {
    const constant = chunk.code.items[offset + 1];
    try writer.print("{s:<16} {d:4} ", .{ name, constant });
    try value.printValue(writer, chunk.constants.values.items[constant]);
    try writer.print("\n", .{});
    return offset + 2;
}

test "disassembleInstruction exhaustive opcodes" {
    const testing = std.testing;
    var c = Chunk.init(testing.allocator);
    defer c.deinit();

    const const_idx = try c.addConstant(1.2);
    try c.writeOp(.constant, 123);
    try c.writeByte(const_idx, 123);
    try c.writeOp(.add, 123);
    try c.writeOp(.subtract, 124);
    try c.writeOp(.multiply, 124);
    try c.writeOp(.divide, 125);
    try c.writeOp(.negate, 125);
    try c.writeOp(.@"return", 125);

    var buf: [1024]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try disassembleChunk(&writer, &c, "test chunk");

    const expected =
        \\== test chunk ==
        \\0000  123 OP_CONSTANT         0 1.2
        \\0002    | OP_ADD
        \\0003  124 OP_SUBTRACT
        \\0004    | OP_MULTIPLY
        \\0005  125 OP_DIVIDE
        \\0006    | OP_NEGATE
        \\0007    | OP_RETURN
        \\
    ;
    try testing.expectEqualStrings(expected, writer.buffered());
}

test "disassembleInstruction unknown opcode" {
    const testing = std.testing;
    var c = Chunk.init(testing.allocator);
    defer c.deinit();

    try c.writeByte(255, 99);

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    const next_offset = try disassembleInstruction(&writer, &c, 0);
    try testing.expectEqual(1, next_offset);
    try testing.expectEqualStrings("0000   99 Unknown opcode 255\n", writer.buffered());
}
