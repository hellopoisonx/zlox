const std = @import("std");
const token = @import("token.zig");
const diagnose = @import("diagnose.zig");

pub const Scanner = struct {
    cursor: usize = 0,
    start: usize = 0,
    line: usize = 1,
    source: []const u8,
    tokens: std.ArrayList(token.Token),
    diagnostics: std.ArrayList(*diagnose.Diagnostic) = .empty,
    allocator: std.mem.Allocator,

    const keywords = std.StaticStringMap(token.Token.Tag).initComptime(.{
        .{ "and", ._and },
        .{ "class", .class },
        .{ "else", ._else },
        .{ "false", ._false },
        .{ "for", ._for },
        .{ "fun", .fun },
        .{ "if", ._if },
        .{ "nil", .nil },
        .{ "or", ._or },
        .{ "print", .print },
        .{ "return", ._return },
        .{ "super", .super },
        .{ "this", .this },
        .{ "true", ._true },
        .{ "var", ._var },
        .{ "while", ._while },
    });

    const ScannerError = error{
        unterminated_string,
    };

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Scanner {
        return .{
            .source = source,
            .tokens = .empty,
            .allocator = allocator,
        };
    }

    fn advance(self: *Scanner) ?u8 {
        if (self.is_at_end()) {
            return null;
        }
        const c = self.source[self.cursor];
        self.cursor += 1;
        return c;
    }

    fn is_at_end(self: *Scanner) bool {
        return self.cursor >= self.source.len;
    }

    fn peek(self: *Scanner) ?u8 {
        if (self.is_at_end()) {
            return null;
        }
        return self.source[self.cursor];
    }

    fn peekNext(self: *Scanner) ?u8 {
        if (self.cursor + 1 >= self.source.len) {
            return null;
        }
        return self.source[self.cursor + 1];
    }

    fn match(self: *Scanner, expected: u8) bool {
        if (self.is_at_end()) {
            return false;
        }
        if (self.source[self.cursor] != expected) {
            return false;
        }
        self.cursor += 1;
        return true;
    }

    fn getStringLiteral(self: *Scanner) ScannerError![]const u8 {
        while (self.peek()) |c| {
            if (c == '"') break;
            if (c == '\n') {
                self.line += 1;
            }
            _ = self.advance();
        } else {
            return ScannerError.unterminated_string;
        }

        // consume end quote
        _ = self.advance();

        return self.source[self.start + 1 .. self.cursor - 1]; // remove quotes
    }

    fn getNumberLiteral(self: *Scanner) !f64 {
        while (self.peek()) |c| {
            if (!isDigit(c)) break;
            _ = self.advance();
        }

        if (self.peek() == '.' and isDigit(self.peekNext() orelse 0)) {
            // consume dot
            _ = self.advance();

            while (self.peek()) |c| {
                if (!isDigit(c)) break;
                _ = self.advance();
            }
        }

        return try std.fmt.parseFloat(f64, self.source[self.start..self.cursor]);
    }

    fn getIdentifierLiteral(self: *Scanner) []const u8 {
        while (self.peek()) |c| {
            if (!isAlpha(c) and !isDigit(c)) break;
            _ = self.advance();
        }

        return self.source[self.start..self.cursor];
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn scan(self: *Scanner) !void {
        self.start = self.cursor;
        const c = self.advance() orelse return;
        const tag: ?token.Token.Tag = switch (c) {
            ' ', '\r', '\t' => null,
            '\n' => blk: {
                self.line += 1;
                break :blk null;
            },
            '/' => if (self.match('/')) blk: {
                // comment goes until end of line
                while (self.peek()) |next| {
                    if (next == '\n') break;
                    _ = self.advance();
                }
                break :blk null;
            } else .slash,
            '*' => .star,
            '-' => .minus,
            '+' => .plus,
            '.' => .dot,
            '(' => .l_paren,
            ')' => .r_paren,
            ';' => .semicolon,
            ',' => .comma,
            '{' => .l_brace,
            '}' => .r_brace,
            '>' => if (self.match('=')) .greater_equal else .greater,
            '<' => if (self.match('=')) .less_equal else .less,
            '!' => if (self.match('=')) .bang_equal else .bang,
            '=' => if (self.match('=')) .equal_equal else .equal,
            // Book §4.5: an unterminated string is reported and skipped;
            // no token is produced for the broken literal.
            '"' => blk: {
                const str = self.getStringLiteral() catch {
                    try self.reportError("Unterminated string.");
                    break :blk null;
                };
                break :blk @as(?token.Token.Tag, .{ .string_literal = str });
            },
            '0'...'9' => .{ .number_literal = try self.getNumberLiteral() },
            'a'...'z', 'A'...'Z', '_' => blk: {
                const text = self.getIdentifierLiteral();
                break :blk keywords.get(text) orelse .{ .identifier_literal = text };
            },
            // Book §4.5: report the offending character, then keep scanning.
            else => blk: {
                try self.reportError("Unexpected character.");
                break :blk null;
            },
        };

        if (tag) |t| {
            try self.addToken(t);
        }
    }

    fn addToken(self: *Scanner, tag: token.Token.Tag) !void {
        // EOF has no source text (the book's EOF token also has an empty
        // lexeme); every other token spans start..cursor.
        const text = if (std.meta.activeTag(tag) == .eof)
            ""
        else
            self.source[self.start..self.cursor];

        try self.tokens.append(self.allocator, token.Token{
            .tag = tag,
            .lexeme = text,
            .line = self.line,
        });
    }

    /// The book's `Lox.error(line, message)` for scan-time failures:
    /// collect a Diagnostic for main to print (the port never prints at
    /// the error site) and keep scanning — a bad character doesn't stop
    /// the run.
    fn reportError(self: *Scanner, message: []const u8) std.mem.Allocator.Error!void {
        const diag = try diagnose.Diagnostic.create(
            self.allocator,
            error.Scan,
            self.line,
            message,
            null,
        );
        try self.diagnostics.append(self.allocator, diag);
    }

    pub fn scanAll(self: *Scanner) !void {
        while (!self.is_at_end()) {
            try self.scan();
        }
        try self.addToken(.eof);
    }
};
