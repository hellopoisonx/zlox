const std = @import("std");
const object = @import("object.zig");

pub const Value = union(enum) {
    boolean: bool,
    nil,
    number: f64,
    obj: *object.Obj,
};

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
    switch (val) {
        .boolean => |boolean| try writer.print("{}", .{boolean}),
        .nil => try writer.writeAll("nil"),
        .number => |number| try writer.print("{d}", .{number}),
        .obj => |obj| try object.printObject(writer, obj),
    }
}

pub fn valuesEqual(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;

    return switch (a) {
        .boolean => |boolean| boolean == b.boolean,
        .nil => true,
        .number => |number| number == b.number,
        .obj => |a_obj| a_obj == b.obj,
    };
}

pub fn isFalsey(val: Value) bool {
    return switch (val) {
        .nil => true,
        .boolean => |boolean| !boolean,
        .number, .obj => false,
    };
}

pub fn isNumber(val: Value) bool {
    return std.meta.activeTag(val) == .number;
}

pub fn isString(val: Value) bool {
    return switch (val) {
        .obj => |obj| obj.type == .string,
        else => false,
    };
}
