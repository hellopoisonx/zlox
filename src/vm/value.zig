const std = @import("std");

/// A Lox value. Doubles for now (book §14.1); grows into a tagged union
/// once strings and objects arrive in later chapters.
pub const Value = f64;

/// Growable array of values (the book's ValueArray).
pub const ValueArray = struct {
    values: std.ArrayList(Value) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ValueArray {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ValueArray) void {
        self.values.deinit(self.allocator);
    }

    pub fn append(self: *ValueArray, value: Value) std.mem.Allocator.Error!void {
        try self.values.append(self.allocator, value);
    }
};

pub fn printValue(writer: *std.Io.Writer, val: Value) std.Io.Writer.Error!void {
    try writer.print("{d}", .{val});
}
