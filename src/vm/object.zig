const std = @import("std");

pub const ObjType = enum {
    string,
};

pub const Obj = struct {
    type: ObjType,
    next: ?*Obj = null,
};

pub const ObjString = struct {
    obj: Obj,
    chars: []u8,
};

pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Heap) void {
        var object = self.objects;
        while (object) |current| {
            const next = current.next;
            self.freeObject(current);
            object = next;
        }
        self.objects = null;
    }

    pub fn copyString(self: *Heap, chars: []const u8) !*ObjString {
        return self.takeString(try self.allocator.dupe(u8, chars));
    }

    pub fn takeString(self: *Heap, chars: []u8) !*ObjString {
        errdefer self.allocator.free(chars);
        const string = try self.allocateObject(ObjString, .string);
        string.chars = chars;
        return string;
    }

    pub fn concatenate(self: *Heap, a: *ObjString, b: *ObjString) !*ObjString {
        const chars = try self.allocator.alloc(u8, a.chars.len + b.chars.len);
        @memcpy(chars[0..a.chars.len], a.chars);
        @memcpy(chars[a.chars.len..], b.chars);
        return self.takeString(chars);
    }

    fn allocateObject(self: *Heap, comptime T: type, obj_type: ObjType) !*T {
        const object = try self.allocator.create(T);
        object.obj = .{ .type = obj_type };
        object.obj.next = self.objects;
        self.objects = &object.obj;
        return object;
    }

    fn freeObject(self: *Heap, object: *Obj) void {
        switch (object.type) {
            .string => {
                const string = asString(object);
                self.allocator.free(string.chars);
                self.allocator.destroy(string);
            },
        }
    }
};

pub fn printObject(writer: *std.Io.Writer, object: *Obj) std.Io.Writer.Error!void {
    switch (object.type) {
        .string => try writer.writeAll(asString(object).chars),
    }
}

pub fn asString(object: *Obj) *ObjString {
    return @alignCast(@fieldParentPtr("obj", object));
}
