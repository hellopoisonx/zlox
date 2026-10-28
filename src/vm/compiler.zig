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

const CompileError = std.mem.Allocator.Error || std.Io.Writer.Error;

const uint8_count: usize = std.math.maxInt(u8) + 1;

const FunctionType = enum {
    script,
    function,
};

const Local = struct {
    name: Token,
    depth: i32,
    isCaptured: bool = false,
};

const Upvalue = struct {
    index: u8,
    isLocal: bool,
};

const Compiler = struct {
    enclosing: ?*Compiler = null,
    function: *object.ObjFunction = undefined,
    type: FunctionType,
    locals: [uint8_count]Local = undefined,
    localCount: usize = 0,
    upvalues: [uint8_count]Upvalue = undefined,
    scopeDepth: i32 = 0,
};

var currentCompiler: ?*Compiler = null;

fn activeCompiler() *Compiler {
    return currentCompiler.?;
}

fn initCompiler(
    compiler_instance: *Compiler,
    function_type: FunctionType,
    parser: *Parser,
) !void {
    compiler_instance.enclosing = currentCompiler;
    compiler_instance.type = function_type;
    compiler_instance.localCount = 0;
    compiler_instance.scopeDepth = 0;
    compiler_instance.function = try parser.heap.newFunction();
    currentCompiler = compiler_instance;
    if (function_type != .script) {
        compiler_instance.function.name = try parser.heap.copyString(
            parser.previous.start[0..parser.previous.length],
        );
    }

    compiler_instance.locals[0] = .{ .name = unnamedToken(), .depth = 0 };
    compiler_instance.localCount = 1;
}

fn unnamedToken() Token {
    return .{ .tag = .identifier_literal, .start = "", .length = 0, .line = 0 };
}

fn beginScope() void {
    activeCompiler().scopeDepth += 1;
}

fn markInitialized() void {
    if (activeCompiler().scopeDepth == 0) return;
    activeCompiler().locals[activeCompiler().localCount - 1].depth = activeCompiler().scopeDepth;
}

fn identifiersEqual(a: Token, b: Token) bool {
    if (a.length != b.length) return false;
    return std.mem.eql(u8, a.start[0..a.length], b.start[0..b.length]);
}

fn resolveLocal(parser: *Parser, compiler_instance: *Compiler, name: Token) ?u8 {
    var i: usize = compiler_instance.localCount;
    while (i > 0) {
        i -= 1;
        const local = &compiler_instance.locals[i];
        if (identifiersEqual(name, local.name)) {
            if (local.depth == -1) {
                parser.errorAtPrevious("Can't read local variable in its own initializer.");
            }
            return @intCast(i);
        }
    }

    return null;
}

fn addUpvalue(parser: *Parser, compiler_instance: *Compiler, index: u8, is_local: bool) u8 {
    const upvalue_count = compiler_instance.function.upvalueCount;

    var i: usize = 0;
    while (i < upvalue_count) : (i += 1) {
        const upvalue = &compiler_instance.upvalues[i];
        if (upvalue.index == index and upvalue.isLocal == is_local) {
            return @intCast(i);
        }
    }

    if (upvalue_count == uint8_count) {
        parser.errorAtPrevious("Too many closure variables in function.");
        return 0;
    }

    compiler_instance.upvalues[upvalue_count] = .{ .index = index, .isLocal = is_local };
    compiler_instance.function.upvalueCount += 1;
    return @intCast(upvalue_count);
}

fn resolveUpvalue(parser: *Parser, compiler_instance: *Compiler, name: Token) ?u8 {
    const enclosing = compiler_instance.enclosing orelse return null;

    if (resolveLocal(parser, enclosing, name)) |local| {
        enclosing.locals[local].isCaptured = true;
        return addUpvalue(parser, compiler_instance, local, true);
    }

    if (resolveUpvalue(parser, enclosing, name)) |upvalue| {
        return addUpvalue(parser, compiler_instance, upvalue, false);
    }

    return null;
}

pub fn compile(
    source: [:0]const u8,
    heap: *object.Heap,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !?*object.ObjFunction {
    var parser = Parser.init(source, heap, stdout, stderr);
    var compiler_instance: Compiler = undefined;
    defer currentCompiler = null;
    try initCompiler(&compiler_instance, .script, &parser);
    parser.advance();
    while (!parser.match(.eof)) {
        try parser.declaration();
    }
    const function = try parser.endCompiler();
    return if (parser.hadError) null else function;
}

pub fn markCompilerRoots(heap: *object.Heap) void {
    var compiler_cursor = currentCompiler;
    while (compiler_cursor) |current| : (compiler_cursor = current.enclosing) {
        heap.markObject(&current.function.obj);
    }
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

    table[@backingInt(Token.Tag.l_paren)] = .{ .prefix = Parser.grouping, .infix = Parser.call, .precedence = .call };
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

    fn declaration(self: *Parser) CompileError!void {
        if (self.match(.fun)) {
            try self.funDeclaration();
        } else if (self.match(.@"var")) {
            try self.varDeclaration();
        } else {
            try self.statement();
        }
    }

    fn statement(self: *Parser) CompileError!void {
        if (self.match(.print)) {
            try self.printStatement();
        } else if (self.match(.@"if")) {
            try self.ifStatement();
        } else if (self.match(.@"return")) {
            try self.returnStatement();
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
        activeCompiler().scopeDepth -= 1;

        while (activeCompiler().localCount > 0 and
            activeCompiler().locals[activeCompiler().localCount - 1].depth > activeCompiler().scopeDepth)
        {
            const local = &activeCompiler().locals[activeCompiler().localCount - 1];
            if (local.isCaptured) {
                try self.emitByte(@backingInt(OpCode.close_upvalue));
            } else {
                try self.emitByte(@backingInt(OpCode.pop));
            }
            activeCompiler().localCount -= 1;
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

    fn funDeclaration(self: *Parser) !void {
        const global = try self.parseVariable("Expect function name.");
        markInitialized();
        try self.compileFunction(.function);
        try self.defineVariable(global);
    }

    fn compileFunction(self: *Parser, function_type: FunctionType) !void {
        var compiler_instance: Compiler = undefined;
        try initCompiler(&compiler_instance, function_type, self);
        beginScope();

        self.consume(.l_paren, "Expect '(' after function name.");
        if (!self.check(.r_paren)) {
            while (true) {
                if (compiler_instance.function.arity == std.math.maxInt(u8)) {
                    self.errorAtCurrent("Can't have more than 255 parameters.");
                } else {
                    compiler_instance.function.arity += 1;
                }
                const constant = try self.parseVariable("Expect parameter name.");
                try self.defineVariable(constant);
                if (!self.match(.comma)) break;
            }
        }
        self.consume(.r_paren, "Expect ')' after parameters.");
        self.consume(.l_brace, "Expect '{' before function body.");
        try self.block();

        const function = try self.endCompiler();
        try self.emitBytes(@backingInt(OpCode.closure), try self.makeConstant(.{ .obj = &function.obj }));

        var i: usize = 0;
        while (i < function.upvalueCount) : (i += 1) {
            const upvalue = compiler_instance.upvalues[i];
            try self.emitByte(if (upvalue.isLocal) 1 else 0);
            try self.emitByte(upvalue.index);
        }
    }

    fn returnStatement(self: *Parser) !void {
        if (activeCompiler().type == .script) {
            self.errorAtPrevious("Can't return from top-level code.");
        }

        if (self.match(.semicolon)) {
            try self.emitReturn();
        } else {
            try self.expression();
            self.consume(.semicolon, "Expect ';' after return value.");
            try self.emitByte(@backingInt(OpCode.@"return"));
        }
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
        if (activeCompiler().scopeDepth > 0) return 0;

        return self.identifierConstant(self.previous);
    }

    fn declareVariable(self: *Parser) void {
        if (activeCompiler().scopeDepth == 0) return;

        const name = self.previous;
        var i: usize = activeCompiler().localCount;
        while (i > 0) {
            i -= 1;
            const local = &activeCompiler().locals[i];
            if (local.depth != -1 and local.depth < activeCompiler().scopeDepth) {
                break;
            }

            if (identifiersEqual(name, local.name)) {
                self.errorAtPrevious("Already a variable with this name in this scope.");
            }
        }

        self.addLocal(name);
    }

    fn addLocal(self: *Parser, name: Token) void {
        if (activeCompiler().localCount == uint8_count) {
            self.errorAtPrevious("Too many local variables in function.");
            return;
        }

        const local = &activeCompiler().locals[activeCompiler().localCount];
        activeCompiler().localCount += 1;
        local.* = .{ .name = name, .depth = -1 };
    }

    fn defineVariable(self: *Parser, global: u8) !void {
        if (activeCompiler().scopeDepth > 0) {
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

        if (resolveLocal(self, activeCompiler(), name)) |slot| {
            getOp = .get_local;
            setOp = .set_local;
            arg = slot;
        } else if (resolveUpvalue(self, activeCompiler(), name)) |upvalue| {
            getOp = .get_upvalue;
            setOp = .set_upvalue;
            arg = upvalue;
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

    fn call(self: *Parser, canAssign: bool) !void {
        _ = canAssign;
        const arg_count = try self.argumentList();
        try self.emitBytes(@backingInt(OpCode.call), arg_count);
    }

    fn argumentList(self: *Parser) !u8 {
        var arg_count: u8 = 0;
        if (!self.check(.r_paren)) {
            while (true) {
                try self.expression();

                if (arg_count == std.math.maxInt(u8)) {
                    self.errorAtPrevious("Can't have more than 255 arguments.");
                } else {
                    arg_count += 1;
                }
                if (!self.match(.comma)) break;
            }
        }
        self.consume(.r_paren, "Expect ')' after arguments.");
        return arg_count;
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
        self.heap.push(constant);
        defer _ = self.heap.pop();
        const index = try currentChunk().addConstant(constant);
        if (index > std.math.maxInt(u8)) {
            self.errorAtPrevious("Too many constants in one chunk.");
            return 0;
        }
        return @intCast(index);
    }

    fn endCompiler(self: *Parser) !*object.ObjFunction {
        try self.emitReturn();

        const function = activeCompiler().function;
        if (comptime print_code) {
            if (!self.hadError) {
                const name = if (function.name) |function_name| function_name.chars else "<script>";
                try debug.disassembleChunk(self.stdout, &function.chunk, name);
            }
        }

        currentCompiler = activeCompiler().enclosing;
        return function;
    }

    fn emitReturn(self: *Parser) !void {
        try self.emitByte(@backingInt(OpCode.nil));
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
        return &activeCompiler().function.chunk;
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
