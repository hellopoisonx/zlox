const std = @import("std");

/// A scanned lexeme: tag plus a pointer/length span into the source
/// string; error tokens point at their message instead (book §16.2).
pub const Token = struct {
    tag: Tag,
    start: [*]const u8,
    length: usize,
    line: usize,

    pub const Tag = enum {
        // single character
        plus,
        minus,
        star,
        dot,
        slash,
        semicolon,
        comma,
        l_paren,
        r_paren,
        l_brace,
        r_brace,
        less,
        greater,
        equal,
        bang,

        // double character
        greater_equal,
        less_equal,
        equal_equal,
        bang_equal,

        // literal
        number_literal,
        string_literal,
        identifier_literal,

        // keywords
        @"and",
        @"else",
        class,
        false,
        true,
        @"for",
        fun,
        @"if",
        nil,
        @"or",
        print,
        @"return",
        super,
        this,
        @"var",
        @"while",

        // error
        @"error",

        // eof
        eof,
    };
};

/// On-demand scanner over a NUL-terminated source string: each
/// `scanToken` call returns the next token in place (book §16).
pub const Scanner = struct {
    start: [*]const u8,
    current: [*]const u8,
    line: usize,

    pub fn init(source: [:0]const u8) Scanner {
        return .{
            .start = source.ptr,
            .current = source.ptr,
            .line = 1,
        };
    }

    pub fn scanToken(self: *Scanner) Token {
        self.skipWhitespace();
        self.start = self.current;

        if (self.isAtEnd()) {
            return self.makeToken(.eof);
        }

        const c = self.advance();
        if (isAlpha(c)) return self.identifier();
        if (isDigit(c)) return self.number();

        switch (c) {
            '(' => return self.makeToken(.l_paren),
            ')' => return self.makeToken(.r_paren),
            '{' => return self.makeToken(.l_brace),
            '}' => return self.makeToken(.r_brace),
            ';' => return self.makeToken(.semicolon),
            ',' => return self.makeToken(.comma),
            '.' => return self.makeToken(.dot),
            '-' => return self.makeToken(.minus),
            '+' => return self.makeToken(.plus),
            '/' => return self.makeToken(.slash),
            '*' => return self.makeToken(.star),
            '!' => return self.makeToken(if (self.match('=')) .bang_equal else .bang),
            '=' => return self.makeToken(if (self.match('=')) .equal_equal else .equal),
            '<' => return self.makeToken(if (self.match('=')) .less_equal else .less),
            '>' => return self.makeToken(if (self.match('=')) .greater_equal else .greater),
            '"' => return self.string(),
            else => {},
        }

        return self.errorToken("Unexpected character.");
    }

    fn identifier(self: *Scanner) Token {
        while (isAlpha(self.peek()) or isDigit(self.peek())) _ = self.advance();
        return self.makeToken(self.identifierType());
    }

    fn identifierType(self: *const Scanner) Token.Tag {
        switch (self.start[0]) {
            'a' => return self.checkKeyword(1, "nd", .@"and"),
            'c' => return self.checkKeyword(1, "lass", .class),
            'e' => return self.checkKeyword(1, "lse", .@"else"),
            'f' => {
                if (self.current - self.start > 1) {
                    switch (self.start[1]) {
                        'a' => return self.checkKeyword(2, "lse", .false),
                        'o' => return self.checkKeyword(2, "r", .@"for"),
                        'u' => return self.checkKeyword(2, "n", .fun),
                        else => {},
                    }
                }
            },
            'i' => return self.checkKeyword(1, "f", .@"if"),
            'n' => return self.checkKeyword(1, "il", .nil),
            'o' => return self.checkKeyword(1, "r", .@"or"),
            'p' => return self.checkKeyword(1, "rint", .print),
            'r' => return self.checkKeyword(1, "eturn", .@"return"),
            's' => return self.checkKeyword(1, "uper", .super),
            't' => {
                if (self.current - self.start > 1) {
                    switch (self.start[1]) {
                        'h' => return self.checkKeyword(2, "is", .this),
                        'r' => return self.checkKeyword(2, "ue", .true),
                        else => {},
                    }
                }
            },
            'v' => return self.checkKeyword(1, "ar", .@"var"),
            'w' => return self.checkKeyword(1, "hile", .@"while"),
            else => {},
        }
        return .identifier_literal;
    }

    /// Trie branch: the lexeme must match `rest` exactly and end there.
    inline fn checkKeyword(
        self: *const Scanner,
        start: usize,
        comptime rest: []const u8,
        tag: Token.Tag,
    ) Token.Tag {
        if (self.current - self.start == start + rest.len and
            std.mem.eql(u8, self.start[start .. start + rest.len], rest))
        {
            return tag;
        }
        return .identifier_literal;
    }

    fn number(self: *Scanner) Token {
        while (isDigit(self.peek())) _ = self.advance();

        // Fractional part only when a digit follows the dot.
        if (self.peek() == '.' and isDigit(self.peekNext())) {
            _ = self.advance();

            while (isDigit(self.peek())) _ = self.advance();
        }

        return self.makeToken(.number_literal);
    }

    fn string(self: *Scanner) Token {
        while (self.peek() != '"' and !self.isAtEnd()) {
            if (self.peek() == '\n') self.line += 1;
            _ = self.advance();
        }

        if (self.isAtEnd()) {
            return self.errorToken("Unterminated string.");
        }

        // The closing quote.
        _ = self.advance();

        return self.makeToken(.string_literal);
    }

    inline fn skipWhitespace(self: *Scanner) void {
        while (true) {
            const c = self.peek();
            switch (c) {
                ' ', '\r', '\t' => _ = self.advance(),
                '\n' => {
                    self.line += 1;
                    _ = self.advance();
                },
                '/' => {
                    if (self.peekNext() != '/') return;
                    while (self.peek() != '\n' and !self.isAtEnd()) _ = self.advance();
                },
                else => return,
            }
        }
    }

    inline fn peek(self: *const Scanner) u8 {
        return self.current[0];
    }

    inline fn peekNext(self: *const Scanner) u8 {
        if (self.isAtEnd()) return 0;
        return self.current[1];
    }

    inline fn isAtEnd(self: *const Scanner) bool {
        return self.current[0] == 0;
    }

    inline fn match(self: *Scanner, expected: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.current[0] != expected) return false;
        self.current += 1;
        return true;
    }

    inline fn makeToken(self: *const Scanner, tag: Token.Tag) Token {
        return .{
            .tag = tag,
            .start = self.start,
            .length = self.current - self.start,
            .line = self.line,
        };
    }

    inline fn errorToken(self: *const Scanner, comptime message: []const u8) Token {
        return .{
            .tag = .@"error",
            .start = message.ptr,
            .length = message.len,
            .line = self.line,
        };
    }

    inline fn advance(self: *Scanner) u8 {
        defer self.current += 1;
        return self.current[0];
    }
};

inline fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}

inline fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}
