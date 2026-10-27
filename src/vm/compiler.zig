const std = @import("std");

const Chunk = @import("chunk.zig").Chunk;
const OpCode = @import("chunk.zig").OpCode;
const Scanner = @import("scan.zig").Scanner;
const Token = @import("scan.zig").Token;
const value = @import("value.zig");
const object = @import("object.zig");
const debug = @import("debug.zig");
const build_options = @import("build_options");

const print_code: bool = build_options.print_code;

var compilingChunk: *Chunk = undefined;

pub fn compile(
    source: [:0]const u8,
    chunk: *Chunk,
    heap: *object.Heap,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !bool {
    var parser = Parser.init(source, heap, stdout, stderr);
    compilingChunk = chunk;
    parser.advance();
    while (!parser.match(.eof)) {
        try parser.declaration();
    }
    try parser.endCompiler();
    return !parser.hadError;
}

const Precedence = enum {
    none,
    assignment,
    @"or",
    @"and",
    equality,
    comparison,
    term,
    factor,
    unary,
    call,
    primary,
};

const ParseFn = *const fn (*Parser, bool) anyerror!void;

const ParseRule = struct {
    prefix: ?ParseFn,
    infix: ?ParseFn,
    precedence: Precedence,
};

const rule_count = std.enums.values(Token.Tag).len;

const rules: [rule_count]ParseRule = buildRules();

fn buildRules() [rule_count]ParseRule {
    var table: [rule_count]ParseRule = undefined;
    for (&table) |*rule| rule.* = .{ .prefix = null, .infix = null, .precedence = .none };

    table[@backingInt(Token.Tag.l_paren)] = .{ .prefix = Parser.grouping, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.minus)] = .{ .prefix = Parser.unary, .infix = Parser.binary, .precedence = .term };
    table[@backingInt(Token.Tag.plus)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .term };
    table[@backingInt(Token.Tag.slash)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .factor };
    table[@backingInt(Token.Tag.star)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .factor };
    table[@backingInt(Token.Tag.bang)] = .{ .prefix = Parser.unary, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.bang_equal)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .equality };
    table[@backingInt(Token.Tag.equal_equal)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .equality };
    table[@backingInt(Token.Tag.greater)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .comparison };
    table[@backingInt(Token.Tag.greater_equal)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .comparison };
    table[@backingInt(Token.Tag.less)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .comparison };
    table[@backingInt(Token.Tag.less_equal)] = .{ .prefix = null, .infix = Parser.binary, .precedence = .comparison };
    table[@backingInt(Token.Tag.false)] = .{ .prefix = Parser.literal, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.nil)] = .{ .prefix = Parser.literal, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.true)] = .{ .prefix = Parser.literal, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.number_literal)] = .{ .prefix = Parser.number, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.string_literal)] = .{ .prefix = Parser.string, .infix = null, .precedence = .none };
    table[@backingInt(Token.Tag.identifier_literal)] = .{ .prefix = Parser.variable, .infix = null, .precedence = .none };

    return table;
}

fn getRule(tag: Token.Tag) *const ParseRule {
    return &rules[@backingInt(tag)];
}

const Parser = struct {
    scanner: Scanner,
    heap: *object.Heap,
    current: Token,
    previous: Token,
    hadError: bool,
    panicMode: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,

    fn init(source: [:0]const u8, heap: *object.Heap, stdout: *std.Io.Writer, stderr: *std.Io.Writer) Parser {
        return .{
            .scanner = Scanner.init(source),
            .heap = heap,
            .current = undefined,
            .previous = undefined,
            .hadError = false,
            .panicMode = false,
            .stdout = stdout,
            .stderr = stderr,
        };
    }

    fn advance(self: *Parser) void {
        self.previous = self.current;
        while (true) {
            self.current = self.scanner.scanToken();
            if (self.current.tag != .@"error") break;
            self.errorAtCurrent(self.current.start[0..self.current.length]);
        }
    }

    fn consume(self: *Parser, tag: Token.Tag, message: []const u8) void {
        if (self.current.tag == tag) {
            self.advance();
            return;
        }
        self.errorAtCurrent(message);
    }

    fn check(self: *Parser, tag: Token.Tag) bool {
        return self.current.tag == tag;
    }

    fn match(self: *Parser, tag: Token.Tag) bool {
        if (!self.check(tag)) return false;
        self.advance();
        return true;
    }

    fn declaration(self: *Parser) !void {
        if (self.match(.@"var")) {
            try self.varDeclaration();
        } else {
            try self.statement();
        }
    }

    fn statement(self: *Parser) !void {
        if (self.match(.print)) {
            try self.printStatement();
        } else {
            try self.expressionStatement();
        }
    }

    fn varDeclaration(self: *Parser) !void {
        const global = try self.parseVariable("Expect variable name.");

        if (self.match(.equal)) {
            try self.expression();
        } else {
            try self.emitByte(@backingInt(OpCode.nil));
        }
        self.consume(.semicolon, "Expect ';' after variable declaration.");

        try self.defineVariable(global);
    }

    fn printStatement(self: *Parser) !void {
        try self.expression();
        self.consume(.semicolon, "Expect ';' after value.");
        try self.emitByte(@backingInt(OpCode.print));
    }

    fn expressionStatement(self: *Parser) !void {
        try self.expression();
        self.consume(.semicolon, "Expect ';' after expression.");
        try self.emitByte(@backingInt(OpCode.pop));
    }

    fn expression(self: *Parser) !void {
        try self.parsePrecedence(.assignment);
    }

    fn parsePrecedence(self: *Parser, precedence: Precedence) !void {
        self.advance();

        const prefixRule = getRule(self.previous.tag).prefix orelse {
            self.errorAtPrevious("Expect expression.");
            return;
        };

        const canAssign = @backingInt(precedence) <= @backingInt(Precedence.assignment);
        try prefixRule(self, canAssign);

        while (@backingInt(precedence) <= @backingInt(getRule(self.current.tag).precedence)) {
            self.advance();
            const infixRule = getRule(self.previous.tag).infix orelse unreachable;
            try infixRule(self, canAssign);
        }

        if (canAssign and self.match(.equal)) {
            self.errorAtPrevious("Invalid assignment target.");
        }
    }

    fn parseVariable(self: *Parser, message: []const u8) !u8 {
        self.consume(.identifier_literal, message);
        return self.identifierConstant(self.previous);
    }

    fn defineVariable(self: *Parser, global: u8) !void {
        try self.emitBytes(@backingInt(OpCode.define_global), global);
    }

    fn variable(self: *Parser, canAssign: bool) !void {
        try self.namedVariable(self.previous, canAssign);
    }

    fn namedVariable(self: *Parser, name: Token, canAssign: bool) !void {
        const arg = try self.identifierConstant(name);

        if (canAssign and self.match(.equal)) {
            try self.expression();
            try self.emitBytes(@backingInt(OpCode.set_global), arg);
        } else {
            try self.emitBytes(@backingInt(OpCode.get_global), arg);
        }
    }

    fn identifierConstant(self: *Parser, name: Token) !u8 {
        const identifier = try self.heap.copyString(name.start[0..name.length]);
        return self.makeConstant(.{ .obj = &identifier.obj });
    }

    fn grouping(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        try self.expression();
        self.consume(.r_paren, "Expect ')' after expression.");
    }

    fn unary(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const operatorTag = self.previous.tag;
        try self.parsePrecedence(.unary);
        switch (operatorTag) {
            .bang => try self.emitByte(@backingInt(OpCode.not)),
            .minus => try self.emitByte(@backingInt(OpCode.negate)),
            else => {},
        }
    }

    fn number(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const parsed = std.fmt.parseFloat(f64, self.previous.start[0..self.previous.length]) catch unreachable;
        try self.emitConstant(.{ .number = parsed });
    }

    fn string(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const chars = self.previous.start[1 .. self.previous.length - 1];
        const string_literal = try self.heap.copyString(chars);
        try self.emitConstant(.{ .obj = &string_literal.obj });
    }

    fn literal(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const op: OpCode = switch (self.previous.tag) {
            .false => .false,
            .nil => .nil,
            .true => .true,
            else => unreachable,
        };
        try self.emitByte(@backingInt(op));
    }

    fn binary(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const operatorTag = self.previous.tag;
        const rule = getRule(operatorTag);
        const operandPrecedence = std.enums.fromInt(Precedence, @backingInt(rule.precedence) + 1) orelse unreachable;
        try self.parsePrecedence(operandPrecedence);

        switch (operatorTag) {
            .bang_equal => try self.emitBytes(@backingInt(OpCode.equal), @backingInt(OpCode.not)),
            .equal_equal => try self.emitByte(@backingInt(OpCode.equal)),
            .greater => try self.emitByte(@backingInt(OpCode.greater)),
            .greater_equal => try self.emitBytes(@backingInt(OpCode.less), @backingInt(OpCode.not)),
            .less => try self.emitByte(@backingInt(OpCode.less)),
            .less_equal => try self.emitBytes(@backingInt(OpCode.greater), @backingInt(OpCode.not)),
            .plus => try self.emitByte(@backingInt(OpCode.add)),
            .minus => try self.emitByte(@backingInt(OpCode.subtract)),
            .star => try self.emitByte(@backingInt(OpCode.multiply)),
            .slash => try self.emitByte(@backingInt(OpCode.divide)),
            else => {},
        }
    }

    fn emitConstant(self: *Parser, constant: value.Value) !void {
        try self.emitBytes(@backingInt(OpCode.constant), try self.makeConstant(constant));
    }

    fn makeConstant(self: *Parser, constant: value.Value) !u8 {
        const index = try currentChunk().addConstant(constant);
        if (index > std.math.maxInt(u8)) {
            self.errorAtPrevious("Too many constants in one chunk.");
            return 0;
        }
        return @intCast(index);
    }

    fn endCompiler(self: *Parser) !void {
        try self.emitReturn();

        if (comptime print_code) {
            if (!self.hadError) {
                try debug.disassembleChunk(self.stdout, currentChunk(), "code");
            }
        }
    }

    fn emitReturn(self: *Parser) !void {
        try self.emitByte(@backingInt(OpCode.@"return"));
    }

    fn emitBytes(self: *Parser, byte1: u8, byte2: u8) !void {
        try self.emitByte(byte1);
        try self.emitByte(byte2);
    }

    fn emitByte(self: *Parser, byte: u8) !void {
        try currentChunk().writeByte(byte, self.previous.line);
    }

    fn currentChunk() *Chunk {
        return compilingChunk;
    }

    fn errorAtCurrent(self: *Parser, message: []const u8) void {
        self.errorAt(self.current, message);
    }

    fn errorAtPrevious(self: *Parser, message: []const u8) void {
        self.errorAt(self.previous, message);
    }

    fn errorAt(self: *Parser, token: Token, message: []const u8) void {
        if (self.panicMode) return;
        self.panicMode = true;

        self.stderr.print("[line {d}] Error", .{token.line}) catch {};
        if (token.tag == .eof) {
            self.stderr.print(" at end", .{}) catch {};
        } else if (token.tag != .@"error") {
            self.stderr.print(" at '{s}'", .{token.start[0..token.length]}) catch {};
        }
        self.stderr.print(": {s}\n", .{message}) catch {};
        self.stderr.flush() catch {};

        self.hadError = true;
    }
};
