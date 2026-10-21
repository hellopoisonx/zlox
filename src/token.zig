const std = @import("std");

pub const Token = struct {
    tag: Tag,
    /// Raw source text of the token, as the book's `Token.lexeme` stores
    /// it — quotes included for strings, the literal digits for numbers.
    /// Error messages print this, so `print 1 2;` reports at '2', not at
    /// a token kind name.
    lexeme: []const u8,
    line: usize,

    pub const Tag = union(enum) {
        // single character
        plus,
        minus,
        star,
        dot,
        slash,
        semicolon,
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
        number_literal: f64,
        string_literal: []const u8,
        identifier_literal: []const u8,

        // keywords
        _and,
        _else,
        class,
        _false,
        _true,
        _for,
        fun,
        _if,
        nil,
        _or,
        print,
        _return,
        super,
        this,
        _var,
        _while,

        // eof
        eof,

        pub fn name(self: Tag) []const u8 {
            return switch (self) {
                .plus => "PLUS",
                .minus => "MINUS",
                .star => "STAR",
                .dot => "DOT",
                .slash => "SLASH",
                .semicolon => "SEMICOLON",
                .l_paren => "LEFT_PAREN",
                .r_paren => "RIGHT_PAREN",
                .l_brace => "LEFT_BRACE",
                .r_brace => "RIGHT_BRACE",
                .less => "LESS",
                .greater => "GREATER",
                .equal => "EQUAL",
                .bang => "BANG",
                .greater_equal => "GREATER_EQUAL",
                .less_equal => "LESS_EQUAL",
                .equal_equal => "EQUAL_EQUAL",
                .bang_equal => "BANG_EQUAL",
                .number_literal => "NUMBER",
                .string_literal => "STRING",
                .identifier_literal => "IDENTIFIER",
                ._and => "AND",
                ._else => "ELSE",
                .class => "CLASS",
                ._false => "FALSE",
                ._true => "TRUE",
                ._for => "FOR",
                .fun => "FUN",
                ._if => "IF",
                .nil => "NIL",
                ._or => "OR",
                .print => "PRINT",
                ._return => "RETURN",
                .super => "SUPER",
                .this => "THIS",
                ._var => "VAR",
                ._while => "WHILE",
                .eof => "EOF",
            };
        }
        pub fn format(self: Tag, w: *std.Io.Writer) std.Io.Writer.Error!void {
            switch (self) {
                .plus => try w.print("PLUS (+)", .{}),
                .minus => try w.print("MINUS (-)", .{}),
                .star => try w.print("STAR (*)", .{}),
                .dot => try w.print("DOT (.)", .{}),
                .slash => try w.print("SLASH (/)", .{}),
                .semicolon => try w.print("SEMICOLON (;)", .{}),
                .l_paren => try w.print("LEFT_PAREN (()", .{}),
                .r_paren => try w.print("RIGHT_PAREN ())", .{}),
                .l_brace => try w.print("LEFT_BRACE ({{)", .{}),
                .r_brace => try w.print("RIGHT_BRACE (}})", .{}),
                .less => try w.print("LESS (<)", .{}),
                .greater => try w.print("GREATER (>)", .{}),
                .equal => try w.print("EQUAL (=)", .{}),
                .bang => try w.print("BANG (!)", .{}),
                .greater_equal => try w.print("GREATER_EQUAL (>=)", .{}),
                .less_equal => try w.print("LESS_EQUAL (<=)", .{}),
                .equal_equal => try w.print("EQUAL_EQUAL (==)", .{}),
                .bang_equal => try w.print("BANG_EQUAL (!=)", .{}),
                .number_literal => |n| try w.print("NUMBER ({d})", .{n}),
                .string_literal => |s| try w.print("STRING (\"{s}\")", .{s}),
                .identifier_literal => |s| try w.print("IDENTIFIER ({s})", .{s}),
                ._and => try w.print("AND (and)", .{}),
                ._else => try w.print("ELSE (else)", .{}),
                .class => try w.print("CLASS (class)", .{}),
                ._false => try w.print("FALSE (false)", .{}),
                ._true => try w.print("TRUE (true)", .{}),
                ._for => try w.print("FOR (for)", .{}),
                .fun => try w.print("FUN (fun)", .{}),
                ._if => try w.print("IF (if)", .{}),
                .nil => try w.print("NIL (nil)", .{}),
                ._or => try w.print("OR (or)", .{}),
                .print => try w.print("PRINT (print)", .{}),
                ._return => try w.print("RETURN (return)", .{}),
                .super => try w.print("SUPER (super)", .{}),
                .this => try w.print("THIS (this)", .{}),
                ._var => try w.print("VAR (var)", .{}),
                ._while => try w.print("WHILE (while)", .{}),
                .eof => try w.print("EOF", .{}),
            }
        }
    };

    pub fn format(self: Token, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("Token(line: {d:2}, tag: {f})", .{ self.line, self.tag });
    }
};
