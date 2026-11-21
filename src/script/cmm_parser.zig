//! The scanner and syntax parser for script text.
//!
//! It only scans and checks syntax - it produces no instructions and
//! evaluates no expressions, which is all the data needs it to do.

const std = @import("std");

pub const number_token = 0x105;

pub const identifier_token = 0x107;

pub const string_token = 0x109;

pub const eof_token = 0x143;

const keywords = [_]Keyword{
    .{ .name = "do", .id = 0x13c },       .{ .name = "if", .id = 0x138 },
    .{ .name = "for", .id = 0x13d },      .{ .name = "int", .id = 0x128 },
    .{ .name = "auto", .id = 0x124 },     .{ .name = "case", .id = 0x136 },
    .{ .name = "char", .id = 0x126 },     .{ .name = "long", .id = 0x129 },
    .{ .name = "goto", .id = 0x13e },     .{ .name = "void", .id = 0x130 },
    .{ .name = "else", .id = 0x139 },     .{ .name = "enum", .id = 0x133 },
    .{ .name = "const", .id = 0x12e },    .{ .name = "break", .id = 0x140 },
    .{ .name = "float", .id = 0x12c },    .{ .name = "short", .id = 0x127 },
    .{ .name = "while", .id = 0x13b },    .{ .name = "union", .id = 0x132 },
    .{ .name = "sleep", .id = 0x142 },    .{ .name = "extern", .id = 0x122 },
    .{ .name = "return", .id = 0x141 },   .{ .name = "signed", .id = 0x12a },
    .{ .name = "sizeof", .id = 0x10a },   .{ .name = "static", .id = 0x123 },
    .{ .name = "struct", .id = 0x131 },   .{ .name = "switch", .id = 0x13a },
    .{ .name = "double", .id = 0x12d },   .{ .name = "default", .id = 0x137 },
    .{ .name = "typedef", .id = 0x121 },  .{ .name = "continue", .id = 0x13f },
    .{ .name = "register", .id = 0x125 }, .{ .name = "unsigned", .id = 0x12b },
    .{ .name = "volatile", .id = 0x12f },
};

pub const Token = struct {
    id: u32 = eof_token,
    spelling: [256]u8 = @splat(0),
    spelling_length: usize = 0,
    value_kind: ?u32 = null,
    value_bits: u32 = 0,
    string_bytes: [256]u8 = @splat(0),
    string_length: usize = 0,

    pub fn text(self: *const Token) []const u8 {
        return self.spelling[0..self.spelling_length];
    }

    pub fn string(self: *const Token) []const u8 {
        return self.string_bytes[0..self.string_length];
    }

    fn append(self: *Token, byte: u8) !void {
        if (self.spelling_length == self.spelling.len - 1) return error.CmmTokenTooLong;
        self.spelling[self.spelling_length] = byte;
        self.spelling_length += 1;
    }
};

pub const Lexer = struct {
    source: []const u8,
    cursor: usize = 0,
    current: u8 = 0x7f,
    read_depth: usize = 0,

    pub fn init(source: []const u8) !Lexer {
        if (std.mem.indexOfScalar(u8, source, 0) != null) return error.InvalidCmmSource;
        var lexer = Lexer{ .source = source };
        try lexer.read();
        return lexer;
    }

    pub fn next(self: *Lexer) !Token {
        while (self.current == ' ') try self.read();
        var token: Token = .{};
        if (self.current == 0x7f) return token;
        if (std.ascii.isAlphabetic(self.current)) {
            while (std.ascii.isAlphanumeric(self.current)) {
                try token.append(self.current);
                try self.read();
            }
            token.id = identifier_token;
            for (keywords) |keyword| if (std.mem.eql(u8, token.text(), keyword.name)) {
                token.id = keyword.id;
                break;
            };
            return token;
        }
        if (std.ascii.isDigit(self.current)) {
            var digits: usize = 0;
            var value = try self.number(&token, 0, &digits);
            token.value_kind = 0;
            if (self.current == '.') {
                try self.read();
                try token.append('.');
                token.value_kind = 1;
                const integer_digits = digits;
                value = try self.number(&token, value, &digits);
                const exponent: i32 = @as(i32, @intCast(integer_digits)) - @as(i32, @intCast(digits));
                value = @floatCast(@as(f64, value) * std.math.pow(f64, 10, @floatFromInt(exponent)));
            }
            if (digits > 20) return error.CmmNumberTooLong;
            if (token.value_kind.? == 0) {
                if (value > 32767) return error.CmmIntegerOutOfRange;
                token.value_bits = @intFromFloat(value);
            } else {
                token.value_bits = @bitCast(value);
            }
            token.id = number_token;
            return token;
        }
        if (self.current == '"') {
            token.id = string_token;
            token.value_kind = 2;
            try token.append('"');
            try self.read();
            while (self.current != 0x7f) {
                self.current = '"';
                try token.append('"');
                try self.read();
                if (self.current != '"') break;
                try token.append('"');
                if (token.string_length == token.string_bytes.len - 1) return error.CmmTokenTooLong;
                token.string_bytes[token.string_length] = '"';
                token.string_length += 1;
                try self.read();
            }
            return token;
        }

        const first = self.current;
        try token.append(first);
        token.id = first;
        switch (first) {
            '(', ')', ',', '.', ':', ';', '?', '[', ']', '{', '}', '~' => try self.read(),
            '!', '%', '&', '*', '+', '-', '/', '<', '=', '>', '^', '|' => {
                try self.read();
                const second = self.current;
                const combined: ?u32 = switch (first) {
                    '!' => if (second == '=') 0x113 else null,
                    '%' => if (second == '=') 0x118 else null,
                    '&' => if (second == '=') 0x11d else if (second == '&') 0x114 else null,
                    '*' => if (second == '=') 0x116 else null,
                    '+' => if (second == '+') 0x10c else if (second == '=') 0x119 else null,
                    '-' => if (second == '-') 0x10d else if (second == '=') 0x11a else if (second == '>') 0x10b else null,
                    '/' => if (second == '=') 0x117 else null,
                    '<' => if (second == '=') 0x110 else if (second == '<') 0x10e else null,
                    '=' => if (second == '=') 0x112 else null,
                    '>' => if (second == '=') 0x111 else if (second == '>') 0x10f else null,
                    '^' => if (second == '=') 0x11e else null,
                    '|' => if (second == '=') 0x11f else if (second == '|') 0x115 else null,
                    else => unreachable,
                };
                if (combined) |id| {
                    token.id = id;
                    try token.append(second);
                    try self.read();
                    if ((first == '<' and second == '<') or (first == '>' and second == '>')) {
                        if (self.current == '=') {
                            token.id = if (first == '<') 0x11b else 0x11c;
                            try token.append('=');
                        }
                        try self.read();
                    }
                }
            },
            else => return error.InvalidCmmCharacter,
        }
        return token;
    }

    fn read(self: *Lexer) anyerror!void {
        if (self.cursor == self.source.len) {
            self.current = 0x7f;
            return;
        }
        self.current = self.source[self.cursor];
        self.cursor += 1;
        if (self.current == '\t' or self.current == '\n') {
            self.current = ' ';
        } else if (self.current == '/' and self.cursor < self.source.len and self.source[self.cursor] == '*') {
            self.cursor += 1;
            if (self.read_depth == 256) return error.CmmCommentTooDeep;
            self.read_depth += 1;
            defer self.read_depth -= 1;
            var nesting: usize = 1;
            while (true) {
                try self.read();
                if (self.current == '/') {
                    try self.read();
                    if (self.current == '*') {
                        nesting += 1;
                        try self.read();
                        if (self.current == '*') {
                            try self.read();
                            if (self.current == '/') nesting -= 1;
                        }
                    }
                } else if (self.current == '*') {
                    try self.read();
                    if (self.current == '/') nesting -= 1;
                }
                if (nesting == 0 or self.current == 0x7f) break;
            }
            if (nesting != 0) return error.UnterminatedCmmComment;
        }
    }

    fn number(self: *Lexer, token: *Token, initial: f32, count: *usize) !f32 {
        if (!std.ascii.isDigit(self.current)) return error.InvalidCmmNumber;
        var value = initial;
        while (std.ascii.isDigit(self.current)) {
            try token.append(self.current);
            count.* += 1;
            if (count.* <= 20) value = @floatCast(@as(f64, value) * 10 + @as(f64, @floatFromInt(self.current - '0')));
            try self.read();
        }
        return value;
    }
};

const Keyword = struct { name: []const u8, id: u32 };

pub const Parser = struct {
    lexer: Lexer,
    current: Token,
    depth: usize = 0,

    pub fn init(source: []const u8) !Parser {
        var lexer = try Lexer.init(source);
        const current = try lexer.next();
        return .{ .lexer = lexer, .current = current };
    }

    pub fn statement(self: *Parser) anyerror!void {
        if (self.depth == 256) return error.CmmSyntaxTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        switch (self.current.id) {
            '{' => {},
            identifier_token => {
                try self.advance();
                if (self.current.id != '=') return error.CmmMissingAssignment;
                try self.advance();
                try self.expression();
            },
            0x138 => {
                try self.advance();
                try self.expression();
                try self.statement();
                if (self.current.id == 0x139) {
                    try self.advance();
                    try self.statement();
                }
            },
            0x13a => {
                try self.advance();
                try self.expression();
                if (self.current.id != '{') return error.CmmMissingSwitchOpen;
                try self.advance();
                if (self.current.id == 0x136 or self.current.id == 0x137) return error.CmmMissingSwitchColon;
                if (self.current.id != '}') return error.CmmMissingSwitchClose;
                try self.advance();
            },
            0x13b, 0x13d => {
                try self.advance();
                try self.expression();
                try self.statement();
            },
            0x13c => {
                try self.advance();
                try self.statement();
                if (self.current.id != 0x13b) return error.CmmMissingWhile;
                try self.advance();
                try self.expression();
            },
            0x142 => try self.advance(),
            else => return error.CmmUnsupportedStatement,
        }
        if (contains(&.{ '{', identifier_token, 0x138, 0x13a, 0x13b, 0x13d, 0x13c, 0x142 }, self.current.id))
            return error.CmmMissingSemicolon;
        if (!contains(&.{ '}', ';', 0x139, eof_token }, self.current.id)) return error.CmmUnexpectedToken;
    }

    pub fn expression(self: *Parser) anyerror!void {
        if (self.depth == 256) return error.CmmSyntaxTooDeep;
        self.depth += 1;
        defer self.depth -= 1;
        try self.simple();
        if (contains(&.{ '>', '<', 0x112, 0x111, 0x110, 0x113 }, self.current.id)) {
            try self.advance();
            try self.simple();
        }
    }

    fn advance(self: *Parser) !void {
        self.current = try self.lexer.next();
    }

    fn simple(self: *Parser) !void {
        if (self.current.id == '+' or self.current.id == '-') try self.advance();
        try self.term();
        while (contains(&.{ '+', '-', 0x115 }, self.current.id)) {
            try self.advance();
            try self.term();
        }
    }

    fn term(self: *Parser) !void {
        try self.factor();
        while (contains(&.{ '*', '/', '%', 0x114 }, self.current.id)) {
            try self.advance();
            try self.factor();
        }
    }

    fn factor(self: *Parser) anyerror!void {
        while (self.current.id == '!') try self.advance();
        switch (self.current.id) {
            number_token, identifier_token, string_token => try self.advance(),
            '(' => {
                try self.advance();
                try self.expression();
                if (self.current.id != ')') return error.CmmMissingExpressionClose;
                try self.advance();
            },
            else => return error.CmmInvalidExpression,
        }
    }
};

fn contains(values: []const u32, value: u32) bool {
    return std.mem.indexOfScalar(u32, values, value) != null;
}

test "CMM scanner preserves shipped operator and string quirks" {
    var lexer = try Lexer.init("if If 32767 12.5 a<<b x>>=2 \"abc\"");
    try std.testing.expectEqual(@as(u32, 0x138), (try lexer.next()).id);
    try std.testing.expectEqual(@as(u32, identifier_token), (try lexer.next()).id);
    try std.testing.expectEqual(@as(u32, 32767), (try lexer.next()).value_bits);
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 12.5))), (try lexer.next()).value_bits);
    try std.testing.expectEqualStrings("a", (try lexer.next()).text());
    try std.testing.expectEqual(@as(u32, 0x10e), (try lexer.next()).id);
    try std.testing.expectEqualStrings("x", (try lexer.next()).text());
    try std.testing.expectEqual(@as(u32, 0x11c), (try lexer.next()).id);
    try std.testing.expectEqual(@as(u32, 2), (try lexer.next()).value_bits);
    const string_value = try lexer.next();
    try std.testing.expectEqualStrings("\"\"", string_value.text());
    try std.testing.expectEqualStrings("", string_value.string());
    try std.testing.expectEqualStrings("bc", (try lexer.next()).text());
}

test "CMM syntax consumes expressions without implementing execution" {
    var parser = try Parser.init("answer = (1 + 2) * 3 <= 12;");
    try parser.statement();
    try std.testing.expectEqual(@as(u32, ';'), parser.current.id);
    var call = try Parser.init("answer = InvObject(1);");
    try std.testing.expectError(error.CmmUnexpectedToken, call.statement());
    var block = try Parser.init("{ answer = 1; }");
    try std.testing.expectError(error.CmmMissingSemicolon, block.statement());
    var invalid = try Lexer.init("alpha_beta");
    _ = try invalid.next();
    try std.testing.expectError(error.InvalidCmmCharacter, invalid.next());
    var overflow = try Lexer.init("32768");
    try std.testing.expectError(error.CmmIntegerOutOfRange, overflow.next());
}

test "CMM scanner and syntax parser match the reference fixtures" {
    const a = std.testing.allocator;
    const bytes = std.Io.Dir.cwd().readFileAlloc(std.testing.io, "testdata/cmm-parser-reference.json", a, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer a.free(bytes);
    const FixtureToken = struct {
        token: u32,
        lexeme: []const u8,
        value_type: ?u32 = null,
        value_bits: ?u32 = null,
        string: ?[]const u8 = null,
    };
    const Fixture = struct {
        lexical: []const struct { source: []const u8, tokens: []const FixtureToken, stalled: bool },
        statements: []const struct { source: []const u8, token: u32, errors: u32 },
    };
    const parsed = try std.json.parseFromSlice(Fixture, a, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    for (parsed.value.lexical) |sample| {
        var lexer = try Lexer.init(sample.source);
        for (sample.tokens, 0..) |expected, i| {
            if (expected.token == 0x144 or (sample.stalled and i + 1 == sample.tokens.len)) {
                if (lexer.next()) |_| return error.ExpectedCmmLexicalError else |_| {}
                break;
            }
            const actual = try lexer.next();
            try std.testing.expectEqual(expected.token, actual.id);
            if (expected.token != eof_token) try std.testing.expectEqualStrings(expected.lexeme, actual.text());
            if (expected.value_type) |kind| try std.testing.expectEqual(kind, actual.value_kind.?);
            if (expected.value_bits) |bits| try std.testing.expectEqual(bits, actual.value_bits);
            if (expected.string) |string| try std.testing.expectEqualStrings(string, actual.string());
        }
    }
    for (parsed.value.statements) |sample| {
        var parser = try Parser.init(sample.source);
        if (sample.errors == 0) {
            try parser.statement();
            try std.testing.expectEqual(sample.token, parser.current.id);
        } else {
            if (parser.statement()) |_| return error.ExpectedCmmSyntaxError else |_| {}
        }
    }
}
