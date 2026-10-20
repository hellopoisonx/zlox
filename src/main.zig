const std = @import("std");
const Io = std.Io;
const zlox = @import("zlox");

/// One Lox run (the book's Lox.run): scan, parse, execute the statement
/// program. Only `print` statements produce output — since ch.8 the
/// REPL takes full statements and no longer echoes expression values
/// (book §8.1.3). The result says which error flag the book's Lox would
/// have set — syntax errors are `hadError` (exit 65), interpreter
/// failures are `hadRuntimeError` (exit 70).
const RunResult = enum { ok, syntax_error, runtime_error };

fn run(source: []const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !RunResult {
    // Each run gets its own arena: tokens, tree, and diagnostics are all
    // freed together when it returns.
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var scanner = zlox.scanner.Scanner.init(arena, source);
    try scanner.scanAll();

    var parser = zlox.parser.Parser.init(arena, scanner.tokens.items);
    const statements = try parser.parse();

    // The book reports scan errors as they happen, then parse errors.
    for (scanner.diagnostics.items) |diag| {
        try diag.print(stderr);
    }
    for (parser.diagnostics.items) |diag| {
        try diag.print(stderr);
    }
    try stderr.flush();

    // Stop if there was a syntax error (book: `if (hadError) return;`).
    if (scanner.diagnostics.items.len > 0 or
        parser.diagnostics.items.len > 0) return .syntax_error;

    var interpreter = zlox.interpreter.Interpreter.init(arena);
    if (interpreter.interpret(statements.items, stdout)) {
        try stdout.flush();
        return .ok;
    } else |err| switch (err) {
        // The book's Lox.runtimeError: report the message with its
        // line and keep going — the REPL survives, script mode exits 70.
        error.RuntimeError => {
            // Prior `print` output must reach stdout before the report —
            // Java's System.out.println auto-flushes (book §8.1.3).
            try stdout.flush();
            const rerr = interpreter.runtime_error.?;
            const diag = try zlox.diagnose.Diagnostic.create(
                arena,
                error.RuntimeError,
                rerr.token.line,
                rerr.message,
                null,
            );
            try diag.print(stderr);
            try stderr.flush();
            return .runtime_error;
        },
        else => return err,
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len > 2) {
        try stderr.print("usage: zlox [script]\n", .{});
        try stderr.flush();
        std.process.exit(64);
    }

    if (args.len == 2) {
        var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer file_arena.deinit();
        const source = try Io.Dir.cwd().readFileAlloc(
            io,
            args[1],
            file_arena.allocator(),
            Io.Limit.limited(16 * 1024 * 1024),
        );

        const result = try run(source, stdout, stderr);
        // Indicate errors in the exit code (book §4.1: 65; §7.4: 70).
        switch (result) {
            .ok => {},
            .syntax_error => std.process.exit(65),
            .runtime_error => std.process.exit(70),
        }
        return;
    }

    // No script: interactive prompt (the book's REPL branch).
    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    try stdout.print("zlox — Crafting Interpreters (Ctrl+D to exit)\n", .{});
    try stdout.flush();

    loop: while (true) {
        try stdout.print("> ", .{});
        try stdout.flush();

        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            error.StreamTooLong => {
                // Discard the rest of the over-long line; the prompt must
                // survive any input (book §6.3: never crash or hang).
                while (true) {
                    const byte = stdin.takeByte() catch |e| switch (e) {
                        error.EndOfStream => break :loop,
                        else => return e,
                    };
                    if (byte == '\n') break;
                }
                continue;
            },
            else => return err,
        };
        // takeDelimiterExclusive stops before the delimiter; consume it so
        // the next take advances past this line.
        _ = stdin.takeByte() catch |e| switch (e) {
            error.EndOfStream => {}, // final line had no trailing newline
            else => return e,
        };

        _ = try run(line, stdout, stderr);
    }

    try stdout.flush();
}
