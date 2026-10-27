const std = @import("std");
const Io = std.Io;
const czlox = @import("czlox");

/// The book's repl(): read one line at a time and interpret it (§16.1).
fn repl(vm: *czlox.vm.VM, io: Io, stdout: *Io.Writer, stderr: *Io.Writer) !void {
    var stdin_buffer: [1024]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
    const stdin = &stdin_reader.interface;

    var line_buffer: [1024]u8 = undefined;

    while (true) {
        try stdout.print("> ", .{});
        try stdout.flush();

        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                try stdout.print("\n", .{});
                try stdout.flush();
                return;
            },
            error.StreamTooLong => {
                // Discard the rest of the over-long line; the prompt
                // must survive any input.
                while (true) {
                    const byte = stdin.takeByte() catch |e| switch (e) {
                        error.EndOfStream => return,
                        else => return e,
                    };
                    if (byte == '\n') break;
                }
                continue;
            },
            else => return err,
        };
        // takeDelimiterExclusive stops before the delimiter; consume it
        // so the next take advances past this line.
        _ = stdin.takeByte() catch |e| switch (e) {
            error.EndOfStream => {},
            else => return e,
        };

        // The scanner walks a NUL-terminated string, and the reader
        // reuses its buffer on the next take, so copy and terminate.
        if (line.len >= line_buffer.len) continue;
        @memcpy(line_buffer[0..line.len], line);
        line_buffer[line.len] = 0;
        const source = line_buffer[0..line.len :0];

        _ = try vm.interpret(source, stdout, stderr);
        try stdout.flush();
    }
}

/// The book's runFile(): run a script, exit 65 on compile error and 70
/// on runtime error (§16.1).
fn runFile(
    vm: *czlox.vm.VM,
    io: Io,
    path: []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !void {
    var file_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer file_arena.deinit();
    const arena = file_arena.allocator();

    const raw = Io.Dir.cwd().readFileAlloc(
        io,
        path,
        arena,
        Io.Limit.limited(16 * 1024 * 1024),
    ) catch {
        try stderr.print("Could not open file \"{s}\".\n", .{path});
        try stderr.flush();
        std.process.exit(74);
    };
    // The scanner walks a NUL-terminated string.
    const raw_z = try arena.alloc(u8, raw.len + 1);
    @memcpy(raw_z[0..raw.len], raw);
    raw_z[raw.len] = 0;
    const source = raw_z[0..raw.len :0];

    const result = try vm.interpret(source, stdout, stderr);
    try stdout.flush();

    switch (result) {
        .ok => {},
        .compile_error => std.process.exit(65),
        .runtime_error => std.process.exit(70),
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

    var vm = czlox.vm.VM.init(init.gpa);
    defer vm.deinit();

    if (args.len == 1) {
        try repl(&vm, io, stdout, stderr);
    } else if (args.len == 2) {
        try runFile(&vm, io, args[1], stdout, stderr);
    } else {
        try stderr.print("Usage: czlox [path]\n", .{});
        try stderr.flush();
        std.process.exit(64);
    }

    try stdout.flush();
    try stderr.flush();
}
