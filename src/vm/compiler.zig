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

const uint8_count: usize = std.math.maxInt(u8) + 1;

const Local = struct {
    name: Token,
    depth: i32,
};

const Compiler = struct {
    locals: [uint8_count]Local = undefined,
    localCount: usize = 0,
    scopeDepth: i32 = 0,
};

var currentCompiler: *Compiler = undefined;

fn initCompiler(compiler: *Compiler) void {
    compiler.localCount = 0;
    compiler.scopeDepth = 0;
    currentCompiler = compiler;
}

fn beginScope() void {
    currentCompiler.scopeDepth += 1;
}

fn markInitialized() void {
    currentCompiler.locals[currentCompiler.localCount - 1].depth = currentCompiler.scopeDepth;
}

fn identifiersEqual(a: Token, b: Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..b.length]);
}

pub fn compile(
    source: [:0]const u8,
    chunk: *Chunk,
    heap: *object.Heap,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !bool {
    var parser = Parser.init(source, heap, stdout, stderr);
    var compiler: Compiler = .{};
    initCompiler(&compiler);
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

const ParseFn = *const fn (*Parser, bool) std.mem.Allocator.Error!void;

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
    table[@backingInt(Token.Tag.@"and")] = .{ .prefix = null, .infix = Parser.and_, .precedence = .@"and" };
    table[@backingInt(Token.Tag.@"or")] = .{ .prefix = null, .infix = Parser.or_, .precedence = .@"or" };

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

    fn declaration(self: *Parser) std.mem.Allocator.Error!void {
        if (self.match(.@"var")) {
            try self.varDeclaration();
        } else {
            try self.statement();
        }
    }

    fn statement(self: *Parser) std.mem.Allocator.Error!void {
        if (self.match(.print)) {
            try self.printStatement();
        } else if (self.match(.@"if")) {
            try self.ifStatement();
        } else if (self.match(.@"while")) {
            try self.whileStatement();
        } else if (self.match(.@"for")) {
            try self.forStatement();
        } else if (self.match(.l_brace)) {
            beginScope();
            try self.block();
            try self.endScope();
        } else {
            try self.expressionStatement();
        }
    }

    fn block(self: *Parser) !void {
        while (!self.check(.r_brace) and !self.check(.eof)) {
            try self.declaration();
        }

        self.consume(.r_brace, "Expect '}' after block.");
    }

    fn endScope(self: *Parser) !void {
        currentCompiler.scopeDepth -= 1;

        while (currentCompiler.localCount > 0 and
            currentCompiler.locals[currentCompiler.localCount - 1].depth > currentCompiler.scopeDepth)
        {
            try self.emitByte(@backingInt(OpCode.pop));
            currentCompiler.localCount -= 1;
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

    fn ifStatement(self: *Parser) !void {
        self.consume(.l_paren, "Expect '(' after 'if'.");
        try self.expression();
        self.consume(.r_paren, "Expect ')' after condition.");

        const thenJump = try self.emitJump(.jump_if_false);
        try self.emitByte(@backingInt(OpCode.pop));
        try self.statement();

        const elseJump = try self.emitJump(.jump);

        self.patchJump(thenJump);
        try self.emitByte(@backingInt(OpCode.pop));

        if (self.match(.@"else")) try self.statement();
        self.patchJump(elseJump);
    }

    fn whileStatement(self: *Parser) !void {
        const loopStart = currentChunk().code.items.len;
        self.consume(.l_paren, "Expect '(' after 'while'.");
        try self.expression();
        self.consume(.r_paren, "Expect ')' after condition.");

        const exitJump = try self.emitJump(.jump_if_false);
        try self.emitByte(@backingInt(OpCode.pop));
        try self.statement();
        try self.emitLoop(loopStart);

        self.patchJump(exitJump);
        try self.emitByte(@backingInt(OpCode.pop));
    }

    fn forStatement(self: *Parser) !void {
        beginScope();
        self.consume(.l_paren, "Expect '(' after 'for'.");

        if (!self.match(.semicolon)) {
            if (self.match(.@"var")) {
                try self.varDeclaration();
            } else {
                try self.expressionStatement();
            }
        }

        var loopStart = currentChunk().code.items.len;

        var exitJump: ?usize = null;
        if (!self.match(.semicolon)) {
            try self.expression();
            self.consume(.semicolon, "Expect ';' after loop condition.");

            exitJump = try self.emitJump(.jump_if_false);
            try self.emitByte(@backingInt(OpCode.pop));
        }

        if (!self.match(.r_paren)) {
            const bodyJump = try self.emitJump(.jump);
            const incrementStart = currentChunk().code.items.len;
            try self.expression();
            try self.emitByte(@backingInt(OpCode.pop));
            self.consume(.r_paren, "Expect ')' after for clauses.");

            try self.emitLoop(loopStart);
            loopStart = incrementStart;
            self.patchJump(bodyJump);
        }

        try self.statement();
        try self.emitLoop(loopStart);

        if (exitJump) |jump| {
            self.patchJump(jump);
            try self.emitByte(@backingInt(OpCode.pop));
        }

        try self.endScope();
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

        self.declareVariable();
        if (currentCompiler.scopeDepth > 0) return 0;

        return self.identifierConstant(self.previous);
    }

    fn declareVariable(self: *Parser) void {
        if (currentCompiler.scopeDepth == 0) return;

        const name = self.previous;
        var i: usize = currentCompiler.localCount;
        while (i > 0) {
            i -= 1;
            const local = &currentCompiler.locals[i];
            if (local.depth != -1 and local.depth < currentCompiler.scopeDepth) {
                break;
            }

            if (identifiersEqual(name, local.name)) {
                self.errorAtPrevious("Already a variable with this name in this scope.");
            }
        }

        self.addLocal(name);
    }

    fn addLocal(self: *Parser, name: Token) void {
        if (currentCompiler.localCount == uint8_count) {
            self.errorAtPrevious("Too many local variables in function.");
            return;
        }

        const local = &currentCompiler.locals[currentCompiler.localCount];
        currentCompiler.localCount += 1;
        local.* = .{ .name = name, .depth = -1 };
    }

    fn defineVariable(self: *Parser, global: u8) !void {
        if (currentCompiler.scopeDepth > 0) {
            markInitialized();
            return;
        }

        try self.emitBytes(@backingInt(OpCode.define_global), global);
    }

    fn variable(self: *Parser, canAssign: bool) !void {
        try self.namedVariable(self.previous, canAssign);
    }

    fn namedVariable(self: *Parser, name: Token, canAssign: bool) !void {
        var getOp: OpCode = undefined;
        var setOp: OpCode = undefined;
        var arg: u8 = undefined;

        if (self.resolveLocal(name)) |slot| {
            getOp = .get_local;
            setOp = .set_local;
            arg = slot;
        } else {
            getOp = .get_global;
            setOp = .set_global;
            arg = try self.identifierConstant(name);
        }

        if (canAssign and self.match(.equal)) {
            try self.expression();
            try self.emitBytes(@backingInt(setOp), arg);
        } else {
            try self.emitBytes(@backingInt(getOp), arg);
        }
    }

    fn resolveLocal(self: *Parser, name: Token) ?u8 {
        var i: usize = currentCompiler.localCount;
        while (i > 0) {
            i -= 1;
            const local = &currentCompiler.locals[i];
            if (identifiersEqual(name, local.name)) {
                if (local.depth == -1) {
                    self.errorAtPrevious("Can't read local variable in its own initializer.");
                }
                return @intCast(i);
            }
        }

        return null;
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

    fn and_(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const endJump = try self.emitJump(.jump_if_false);

        try self.emitByte(@backingInt(OpCode.pop));
        try self.parsePrecedence(.@"and");

        self.patchJump(endJump);
    }

    fn or_(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const elseJump = try self.emitJump(.jump_if_false);
        const endJump = try self.emitJump(.jump);

        self.patchJump(elseJump);
        try self.emitByte(@backingInt(OpCode.pop));

        try self.parsePrecedence(.@"or");
        self.patchJump(endJump);
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

    fn emitJump(self: *Parser, instruction: OpCode) !usize {
        try self.emitByte(@backingInt(instruction));
        try self.emitByte(0xff);
        try self.emitByte(0xff);
        return currentChunk().code.items.len - 2;
    }

    fn patchJump(self: *Parser, offset: usize) void {
        const jump = currentChunk().code.items.len - offset - 2;

        if (jump > std.math.maxInt(u16)) {
            self.errorAtPrevious("Too much code to jump over.");
        }

        currentChunk().code.items[offset] = @intCast((jump >> 8) & 0xff);
        currentChunk().code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn emitLoop(self: *Parser, loopStart: usize) !void {
        try self.emitByte(@backingInt(OpCode.loop));

        const offset = currentChunk().code.items.len - loopStart + 2;
        if (offset > std.math.maxInt(u16)) {
            self.errorAtPrevious("Loop body too large.");
        }

        try self.emitByte(@intCast((offset >> 8) & 0xff));
        try self.emitByte(@intCast(offset & 0xff));
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
