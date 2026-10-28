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
        .get_local, .set_local => |o| byteInstruction(writer, o.tag(), chunk, offset),
        .jump, .jump_if_false => |o| jumpInstruction(writer, o.tag(), 1, chunk, offset),
        .loop => |o| jumpInstruction(writer, o.tag(), -1, chunk, offset),
        .constant, .define_global, .get_global, .set_global => |o| constantInstruction(writer, o.tag(), chunk, offset),
        .nil,
        .true,
        .false,
        .equal,
        .greater,
        .less,
        .add,
        .subtract,
        .multiply,
        .divide,
        .not,
        .negate,
        .print,
        .pop,
        .@"return",
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

fn byteInstruction(
    writer: *std.Io.Writer,
    name: []const u8,
    chunk: *const Chunk,
    offset: usize,
) std.Io.Writer.Error!usize {
    const slot = chunk.code.items[offset + 1];
    try writer.print("{s:<16} {d:4}\n", .{ name, slot });
    return offset + 2;
}

fn jumpInstruction(
    writer: *std.Io.Writer,
    name: []const u8,
    sign: i32,
    chunk: *const Chunk,
    offset: usize,
) std.Io.Writer.Error!usize {
    const jump: u16 = (@as(u16, chunk.code.items[offset + 1]) << 8) | chunk.code.items[offset + 2];
    const target = @as(i32, @intCast(offset)) + 3 + sign * @as(i32, jump);
    try writer.print("{s:<16} {d:4} -> {d}\n", .{ name, offset, target });
    return offset + 3;
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
