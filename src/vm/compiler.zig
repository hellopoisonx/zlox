const std = @import("std");

const scan = @import("scan.zig");

/// Temporary front end (book §16.2): drive the scanner on demand and
/// print each token until end of file; the real compiler arrives in
/// chapter 17. Flushing the writer is left to the caller.
pub fn compile(source: [:0]const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    var scanner = scan.Scanner.init(source);

    var line: usize = 0;
    while (true) {
        const token = scanner.scanToken();
        if (token.line != line) {
            try writer.print("{d:>4} ", .{token.line});
            line = token.line;
        } else {
            try writer.print("   | ", .{});
        }
        try writer.print("{s} '{s}'\n", .{ @tagName(token.tag), token.start[0..token.length] });

        if (token.tag == .eof) break;
    }
}
