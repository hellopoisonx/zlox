const std = @import("std");

pub const Diagnostic = struct {
    err: anyerror,
    message: []const u8,
    line: usize,
    cause: ?*const Diagnostic = null,

    pub fn create(allocator: std.mem.Allocator, err: anyerror, line: usize, message: []const u8, cause: ?*const Diagnostic) !*Diagnostic {
        const diag = try allocator.create(Diagnostic);
        diag.* = .{
            .cause = cause,
            .err = err,
            .message = message,
            .line = line,
        };

        return diag;
    }

    pub fn print(self: *const Diagnostic, writer: anytype) !void {
        try writer.print(
            "line: {d} error: {s} ({s})\n",
            .{
                self.line,
                self.message,
                @errorName(self.err),
            },
        );

        if (self.cause) |cause| {
            try writer.print("caused by:", .{});
            try cause.print(writer);
            try writer.print("\n", .{});
        }
    }
};
