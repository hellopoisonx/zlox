const std = @import("std");
const build_options = @import("build_options");
const chunk_mod = @import("chunk.zig");
const compiler_mod = @import("compiler.zig");
const value = @import("value.zig");
const vm_mod = @import("vm.zig");

const stress_gc: bool = build_options.stress_gc;
const log_gc: bool = build_options.log_gc;
const gc_heap_grow_factor: usize = 2;
pub const ObjType = enum {
    function,
    native,
    string,
    closure,
    upvalue,
};

pub const Obj = struct {
    type: ObjType,
    isMarked: bool = false,
    next: ?*Obj = null,
};

pub const ObjString = struct {
    obj: Obj,
    chars: []u8,
};

pub const NativeFn = *const fn (arg_count: u8, args: [*]value.Value) value.Value;

pub const ObjFunction = struct {
    obj: Obj,
    arity: u8 = 0,
    upvalueCount: usize = 0,
    chunk: chunk_mod.Chunk,
    name: ?*ObjString = null,
};

pub const ObjNative = struct {
    obj: Obj,
    function: NativeFn,
};

pub const ObjUpvalue = struct {
    obj: Obj,
    location: *value.Value,
    closed: value.Value = .nil,
    next: ?*ObjUpvalue = null,
};

pub const ObjClosure = struct {
    obj: Obj,
    function: *ObjFunction,
    upvalues: []?*ObjUpvalue,
};

pub const Heap = struct {
    backing_allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    strings: std.StringHashMapUnmanaged(*ObjString) = .empty,
    bytesAllocated: usize = 0,
    nextGC: usize = 1024 * 1024,
    gray_stack: std.ArrayList(*Obj) = .empty,
    log_writer: ?*std.Io.Writer = null,

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = gcAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = gcFree,
    };

    pub fn init(backing_allocator: std.mem.Allocator) Heap {
        return .{ .backing_allocator = backing_allocator };
    }

    pub fn allocator(self: *Heap) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *Heap) void {
        self.strings.deinit(self.allocator());
        var object = self.objects;
        while (object) |current| {
            const next = current.next;
            self.freeObject(current);
            object = next;
        }
        self.objects = null;
        self.gray_stack.deinit(self.backing_allocator);
    }

    pub fn newFunction(self: *Heap) !*ObjFunction {
        const function = try self.createObject(ObjFunction, .function);
        function.arity = 0;
        function.upvalueCount = 0;
        function.chunk = chunk_mod.Chunk.init(self.allocator());
        function.name = null;
        self.registerObject(ObjFunction, function);
        return function;
    }

    pub fn newNative(self: *Heap, function: NativeFn) !*ObjNative {
        const native = try self.createObject(ObjNative, .native);
        native.function = function;
        self.registerObject(ObjNative, native);
        return native;
    }

    pub fn newClosure(self: *Heap, function: *ObjFunction) !*ObjClosure {
        const upvalues = try self.allocator().alloc(?*ObjUpvalue, function.upvalueCount);
        errdefer self.allocator().free(upvalues);
        @memset(upvalues, null);

        const closure = try self.createObject(ObjClosure, .closure);
        closure.function = function;
        closure.upvalues = upvalues;
        self.registerObject(ObjClosure, closure);
        return closure;
    }

    pub fn newUpvalue(self: *Heap, slot: *value.Value) !*ObjUpvalue {
        const upvalue = try self.createObject(ObjUpvalue, .upvalue);
        upvalue.location = slot;
        upvalue.closed = .nil;
        upvalue.next = null;
        self.registerObject(ObjUpvalue, upvalue);
        return upvalue;
    }

    pub fn copyString(self: *Heap, chars: []const u8) !*ObjString {
        if (self.strings.get(chars)) |string| return string;
        return self.takeString(try self.allocator().dupe(u8, chars));
    }

    pub fn takeString(self: *Heap, chars: []u8) !*ObjString {
        if (self.strings.get(chars)) |string| {
            self.allocator().free(chars);
            return string;
        }

        const string = self.createObject(ObjString, .string) catch |err| {
            self.allocator().free(chars);
            return err;
        };
        string.chars = chars;
        self.registerObject(ObjString, string);

        self.push(.{ .obj = &string.obj });
        defer _ = self.pop();
        try self.strings.put(self.allocator(), string.chars, string);
        return string;
    }

    pub fn concatenate(self: *Heap, a: *ObjString, b: *ObjString) !*ObjString {
        const chars = try self.allocator().alloc(u8, a.chars.len + b.chars.len);
        @memcpy(chars[0..a.chars.len], a.chars);
        @memcpy(chars[a.chars.len..], b.chars);
        return self.takeString(chars);
    }

    pub fn collectGarbage(self: *Heap) void {
        const before = if (comptime log_gc) self.bytesAllocated else {};
        if (comptime log_gc) {
            self.logGc("-- gc begin\n", .{});
        }

        self.markRoots();
        self.traceReferences();
        self.tableRemoveWhite();
        self.sweep();

        self.nextGC = self.bytesAllocated * gc_heap_grow_factor;

        if (comptime log_gc) {
            self.logGc("-- gc end\n", .{});
            self.logGc(
                "   collected {d} bytes (from {d} to {d}) next at {d}\n",
                .{ before - self.bytesAllocated, before, self.bytesAllocated, self.nextGC },
            );
        }
    }

    pub fn markValue(self: *Heap, val: value.Value) void {
        switch (val) {
            .obj => |object| self.markObject(object),
            .boolean, .nil, .number => {},
        }
    }

    pub fn markObject(self: *Heap, maybe_object: ?*Obj) void {
        const object = maybe_object orelse return;
        if (object.isMarked) return;

        if (comptime log_gc) {
            self.logObject("mark", object);
        }

        object.isMarked = true;
        self.gray_stack.append(self.backing_allocator, object) catch std.process.exit(1);
    }

    pub fn push(self: *Heap, val: value.Value) void {
        self.vm().push(val);
    }

    pub fn pop(self: *Heap) value.Value {
        return self.vm().pop();
    }

    fn vm(self: *Heap) *vm_mod.VM {
        return @alignCast(@fieldParentPtr("heap", self));
    }

    fn markRoots(self: *Heap) void {
        const vm_instance = self.vm();
        for (vm_instance.stack[0..vm_instance.stack_top]) |slot| {
            self.markValue(slot);
        }

        for (vm_instance.frames[0..vm_instance.frame_count]) |*frame| {
            self.markObject(&frame.closure.obj);
        }

        var upvalue = vm_instance.openUpvalues;
        while (upvalue) |current| : (upvalue = current.next) {
            self.markObject(&current.obj);
        }

        self.markTable(&vm_instance.globals);
        compiler_mod.markCompilerRoots(self);
    }

    fn markTable(self: *Heap, table: *std.AutoHashMapUnmanaged(*ObjString, value.Value)) void {
        var it = table.iterator();
        while (it.next()) |entry| {
            self.markObject(&entry.key_ptr.*.obj);
            self.markValue(entry.value_ptr.*);
        }
    }

    fn markArray(self: *Heap, array: *const value.ValueArray) void {
        for (array.values.items) |item| {
            self.markValue(item);
        }
    }

    fn traceReferences(self: *Heap) void {
        while (self.gray_stack.pop()) |object| {
            self.blackenObject(object);
        }
    }

    fn blackenObject(self: *Heap, object: *Obj) void {
        if (comptime log_gc) {
            self.logObject("blacken", object);
        }

        switch (object.type) {
            .closure => {
                const closure = asClosure(object);
                self.markObject(&closure.function.obj);
                for (closure.upvalues) |maybe_upvalue| {
                    if (maybe_upvalue) |upvalue| self.markObject(&upvalue.obj);
                }
            },
            .function => {
                const function = asFunction(object);
                if (function.name) |name| self.markObject(&name.obj);
                self.markArray(&function.chunk.constants);
            },
            .upvalue => self.markValue(asUpvalue(object).closed),
            .native, .string => {},
        }
    }

    fn tableRemoveWhite(self: *Heap) void {
        var it = self.strings.iterator();
        while (it.next()) |entry| {
            const string = entry.value_ptr.*;
            if (!string.obj.isMarked) {
                self.strings.removeByPtr(entry.key_ptr);
            }
        }
    }

    fn sweep(self: *Heap) void {
        var previous: ?*Obj = null;
        var object = self.objects;
        while (object) |current| {
            if (current.isMarked) {
                current.isMarked = false;
                previous = current;
                object = current.next;
            } else {
                const unreached = current;
                object = current.next;
                if (previous) |prev| {
                    prev.next = object;
                } else {
                    self.objects = object;
                }

                self.freeObject(unreached);
            }
        }
    }

    fn createObject(self: *Heap, comptime T: type, obj_type: ObjType) !*T {
        const object = try self.allocator().create(T);
        object.obj = .{
            .type = obj_type,
            .isMarked = false,
            .next = null,
        };
        return object;
    }

    fn registerObject(self: *Heap, comptime T: type, typed_object: *T) void {
        const object = &typed_object.obj;
        object.next = self.objects;
        self.objects = object;

        if (comptime log_gc) {
            self.logGc("0x{x} allocate {d} for {d}\n", .{
                @intFromPtr(object),
                @sizeOf(T),
                @backingInt(object.type),
            });
        }
    }

    fn freeObject(self: *Heap, object: *Obj) void {
        if (comptime log_gc) {
            self.logGc("0x{x} free type {d}\n", .{
                @intFromPtr(object),
                @backingInt(object.type),
            });
        }

        switch (object.type) {
            .function => {
                const function = asFunction(object);
                function.chunk.deinit();
                self.allocator().destroy(function);
            },
            .native => self.allocator().destroy(asNative(object)),
            .string => {
                const string = asString(object);
                self.allocator().free(string.chars);
                self.allocator().destroy(string);
            },
            .closure => {
                const closure = asClosure(object);
                self.allocator().free(closure.upvalues);
                self.allocator().destroy(closure);
            },
            .upvalue => self.allocator().destroy(asUpvalue(object)),
        }
    }

    fn gcAlloc(
        ctx: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        self.bytesAllocated += len;
        if (comptime stress_gc) {
            self.collectGarbage();
        }
        if (self.bytesAllocated > self.nextGC) {
            self.collectGarbage();
        }
        const ptr = self.backing_allocator.rawAlloc(len, alignment, ret_addr) orelse {
            self.bytesAllocated -= len;
            return null;
        };
        return ptr;
    }

    fn gcFree(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *Heap = @ptrCast(@alignCast(ctx));
        self.backing_allocator.rawFree(memory, alignment, ret_addr);
        self.bytesAllocated -= memory.len;
    }

    fn logGc(self: *Heap, comptime fmt: []const u8, args: anytype) void {
        if (self.log_writer) |writer| {
            writer.print(fmt, args) catch {};
            return;
        }
        var buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buf);
        const writer = &stdout_writer.interface;
        writer.print(fmt, args) catch {};
        writer.flush() catch {};
    }

    fn logObject(self: *Heap, comptime action: []const u8, object: *Obj) void {
        if (self.log_writer) |writer| {
            writer.print("0x{x} {s} ", .{ @intFromPtr(object), action }) catch {};
            value.printValue(writer, .{ .obj = object }) catch {};
            writer.writeAll("\n") catch {};
            return;
        }
        var buf: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writer(std.Io.Threaded.global_single_threaded.io(), &buf);
        const writer = &stdout_writer.interface;
        writer.print("0x{x} {s} ", .{ @intFromPtr(object), action }) catch {};
        value.printValue(writer, .{ .obj = object }) catch {};
        writer.writeAll("\n") catch {};
        writer.flush() catch {};
    }
};

pub fn printObject(writer: *std.Io.Writer, object: *Obj) std.Io.Writer.Error!void {
    switch (object.type) {
        .function => try printFunction(writer, asFunction(object)),
        .native => try writer.writeAll("<native fn>"),
        .string => try writer.writeAll(asString(object).chars),
        .closure => try printFunction(writer, asClosure(object).function),
        .upvalue => try writer.writeAll("upvalue"),
    }
}

fn printFunction(writer: *std.Io.Writer, function: *ObjFunction) std.Io.Writer.Error!void {
    if (function.name) |name| {
        try writer.print("<fn {s}>", .{name.chars});
    } else {
        try writer.writeAll("<script>");
    }
}

pub fn asFunction(object: *Obj) *ObjFunction {
    return @alignCast(@fieldParentPtr("obj", object));
}

pub fn asNative(object: *Obj) *ObjNative {
    return @alignCast(@fieldParentPtr("obj", object));
}

pub fn asString(object: *Obj) *ObjString {
    return @alignCast(@fieldParentPtr("obj", object));
}

pub fn asClosure(object: *Obj) *ObjClosure {
    return @alignCast(@fieldParentPtr("obj", object));
}

pub fn asUpvalue(object: *Obj) *ObjUpvalue {
    return @alignCast(@fieldParentPtr("obj", object));
}
