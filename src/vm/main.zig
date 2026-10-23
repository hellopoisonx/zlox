const std = @import("std");
const Io = std.Io;
const czlox = @import("czlox");

/// Chapter 14 smoke: hand-assemble a chunk and disassemble it.
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var chunk = czlox.chunk.Chunk.init(init.gpa);
    defer chunk.deinit();

    try chunk.writeOp(.constant, 123);
    var constant = try chunk.addConstant(1.2);
    try chunk.writeByte(constant, 123);
    try chunk.writeOp(.negate, 123);

    try chunk.writeOp(.constant, 123);
    constant = try chunk.addConstant(2.2);
    try chunk.writeByte(constant, 123);

    try chunk.writeOp(.add, 123);

    try chunk.writeOp(.constant, 123);
    constant = try chunk.addConstant(9.2);
    try chunk.writeByte(constant, 123);

    try chunk.writeOp(.divide, 123);

    try chunk.writeOp(.@"return", 123);

    var vm = czlox.vm.VM.init(gpa);
    defer vm.deinit();

    _ = try vm.interpret(&chunk, stdout);
    try stdout.flush();
}
