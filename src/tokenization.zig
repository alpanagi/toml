const std = @import("std");

const tab: u8 = 0x09;
const space: u8 = 0x20;

const cr: u8 = 0x0D;
const lf: u8 = 0x0A;

pub const TokenKind = enum {
    new_line,
    equals,
    left_bracket,
    right_bracket,
    comma,
    dot,
    identifier,
    string,
    integer,
    float,
};
pub const TokenValue = union(TokenKind) {
    new_line,
    equals,
    left_bracket,
    right_bracket,
    comma,
    dot,
    identifier: []const u8,
    string: []const u8,
    integer: i64,
    float: f64,

    pub fn deinit(self: TokenValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .identifier => |value| alloc.free(value),
            .string => |value| alloc.free(value),
            else => {},
        }
    }
};
pub const Token = struct {
    kind: TokenKind,
    value: ?TokenValue,

    pub fn deinit(self: *Token, alloc: std.mem.Allocator) void {
        if (self.value) |*value| value.deinit(alloc);
    }
};
const TokenContainer = struct {
    tokens: []Token,

    pub fn deinit(self: *TokenContainer, alloc: std.mem.Allocator) void {
        for (self.tokens) |*item| item.deinit(alloc);
        alloc.free(self.tokens);
    }
};

const State = struct {
    text: []const u8,
    cursor: usize,
    tokens: std.ArrayList(Token),
};

const TokenizerError = error{
    UnknownCharacter,
    UnterminatedString,
    InvalidNumber,
};

pub fn tokenize(alloc: std.mem.Allocator, text: []const u8) !TokenContainer {
    var state: State = .{
        .text = text,
        .cursor = 0,
        .tokens = std.ArrayList(Token).empty,
    };

    while (state.cursor < text.len) {
        if (ignoreWhitespace(&state)) continue;
        if (ignoreComment(&state)) continue;

        if (try tokenizeNewLine(alloc, &state)) continue;
        if (try tokenizeSymbols(alloc, &state)) continue;
        if (try tokenizeString(alloc, &state)) continue;
        if (try tokenizeNumber(alloc, &state)) continue;
        if (try tokenizeIdentifier(alloc, &state)) continue;

        return TokenizerError.UnknownCharacter;
    }

    return TokenContainer{ .tokens = try state.tokens.toOwnedSlice(alloc) };
}

fn ignoreWhitespace(state: *State) bool {
    if (state.text[state.cursor] == space or state.text[state.cursor] == tab) {
        while (state.cursor < state.text.len and
            (state.text[state.cursor] == space or state.text[state.cursor] == tab))
        {
            state.cursor += 1;
        }
        return true;
    }
    return false;
}

fn ignoreComment(state: *State) bool {
    if (state.text[state.cursor] == '#') {
        while (state.cursor < state.text.len and
            state.text[state.cursor] != lf and
            state.text[state.cursor] != cr)
        {
            state.cursor += 1;
        }
        return true;
    }
    return false;
}

fn tokenizeNewLine(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.text[state.cursor] == lf) {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.new_line, .value = null });
        return true;
    }

    if (state.text[state.cursor] == cr and
        state.cursor < state.text.len - 1 and
        state.text[state.cursor + 1] == lf)
    {
        state.cursor += 2;
        try state.tokens.append(alloc, .{ .kind = TokenKind.new_line, .value = null });
        return true;
    }

    return false;
}

fn tokenizeSymbols(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.text[state.cursor] == '=') {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.equals, .value = null });
        return true;
    }

    if (state.text[state.cursor] == '[') {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.left_bracket, .value = null });
        return true;
    }

    if (state.text[state.cursor] == ']') {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.right_bracket, .value = null });
        return true;
    }

    if (state.text[state.cursor] == ',') {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.comma, .value = null });
        return true;
    }

    if (state.text[state.cursor] == '.') {
        state.cursor += 1;
        try state.tokens.append(alloc, .{ .kind = TokenKind.dot, .value = null });
        return true;
    }

    return false;
}

fn tokenizeNumber(alloc: std.mem.Allocator, state: *State) !bool {
    var number_end = state.cursor;
    if (state.text[number_end] == '+' or state.text[number_end] == '-') number_end += 1;

    if (number_end >= state.text.len) return false;
    if (!std.ascii.isDigit(state.text[number_end])) return false;

    var is_float = false;
    while (number_end < state.text.len and isValidNumberCharacter(state.text[number_end])) {
        if (state.text[number_end] == '.') is_float = true;
        number_end += 1;
    }

    const number = state.text[state.cursor..number_end];
    state.cursor = number_end;

    if (is_float) {
        const value = std.fmt.parseFloat(f64, number) catch return TokenizerError.InvalidNumber;
        try state.tokens.append(alloc, .{
            .kind = TokenKind.float,
            .value = TokenValue{ .float = value },
        });
        return true;
    }

    const value = std.fmt.parseInt(i64, number, 10) catch return TokenizerError.InvalidNumber;
    try state.tokens.append(alloc, .{
        .kind = TokenKind.integer,
        .value = TokenValue{ .integer = value },
    });
    return true;
}

fn isValidNumberCharacter(character: u8) bool {
    return switch (character) {
        '0'...'9', '_', '.' => true,
        else => false,
    };
}

fn tokenizeString(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.text[state.cursor] == '"') {
        const string_start = state.cursor;
        var string_end = state.cursor + 1;

        while (string_end < state.text.len and state.text[string_end] != '"') {
            string_end += 1;
        }

        if (string_end == state.text.len) {
            return TokenizerError.UnterminatedString;
        }

        if (string_start + 1 == string_end) {
            state.cursor += 2;
            try state.tokens.append(alloc, .{
                .kind = TokenKind.string,
                .value = TokenValue{ .string = "" },
            });
            return true;
        }

        const string = try alloc.dupe(u8, state.text[(string_start + 1)..string_end]);
        state.cursor = string_end + 1;
        try state.tokens.append(alloc, .{
            .kind = TokenKind.string,
            .value = TokenValue{ .string = string },
        });
        return true;
    }
    return false;
}

fn tokenizeIdentifier(alloc: std.mem.Allocator, state: *State) !bool {
    if (isValidIdentifierCharacter(state.text[state.cursor])) {
        const identifier_start = state.cursor;
        while (state.cursor < state.text.len and
            isValidIdentifierCharacter(state.text[state.cursor]))
        {
            state.cursor += 1;
        }

        const identifier = try alloc.dupe(u8, state.text[identifier_start..state.cursor]);
        try state.tokens.append(alloc, .{
            .kind = TokenKind.identifier,
            .value = TokenValue{ .identifier = identifier },
        });
        return true;
    }
    return false;
}

fn isValidIdentifierCharacter(character: u8) bool {
    return switch (character) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => true,
        else => false,
    };
}

test "Comment" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment";

    const token_container = try tokenize(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, token_container.tokens);
}

test "Multiline comments" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment\n# This is another one\n";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.new_line, .value = null },
        Token{ .kind = TokenKind.new_line, .value = null },
    }, token_container.tokens);
}

test "Multiline comments with padding" {
    const alloc = std.testing.allocator;
    const text = "    # This is a comment\n    # This is another one\n";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.new_line, .value = null },
        Token{ .kind = TokenKind.new_line, .value = null },
    }, token_container.tokens);
}

test "Empty line" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment\n\n# This is another one\n";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.new_line, .value = null },
        Token{ .kind = TokenKind.new_line, .value = null },
        Token{ .kind = TokenKind.new_line, .value = null },
    }, token_container.tokens);
}

test "Identifier" {
    const alloc = std.testing.allocator;
    const text = "Test_1234";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqual(TokenKind.identifier, token_container.tokens[0].kind);
    try std.testing.expectEqualSlices(u8, text, token_container.tokens[0].value.?.identifier);
}

test "equals" {
    const alloc = std.testing.allocator;
    const text = " = ";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqual(TokenKind.equals, token_container.tokens[0].kind);
}

test "String" {
    const alloc = std.testing.allocator;
    const text = "\"asdf\"";
    const expected = "asdf";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqual(TokenKind.string, token_container.tokens[0].kind);
    try std.testing.expectEqualSlices(u8, expected, token_container.tokens[0].value.?.string);
}

test "Brackets" {
    const alloc = std.testing.allocator;
    const text = "[]";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.left_bracket, .value = null },
        Token{ .kind = TokenKind.right_bracket, .value = null },
    }, token_container.tokens);
}

test "Comma and dot" {
    const alloc = std.testing.allocator;
    const text = ",.";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.comma, .value = null },
        Token{ .kind = TokenKind.dot, .value = null },
    }, token_container.tokens);
}

test "Integers" {
    const alloc = std.testing.allocator;
    const text = "0 42 -7 +9 1_000";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.integer, .value = .{ .integer = 0 } },
        Token{ .kind = TokenKind.integer, .value = .{ .integer = 42 } },
        Token{ .kind = TokenKind.integer, .value = .{ .integer = -7 } },
        Token{ .kind = TokenKind.integer, .value = .{ .integer = 9 } },
        Token{ .kind = TokenKind.integer, .value = .{ .integer = 1000 } },
    }, token_container.tokens);
}

test "Floats" {
    const alloc = std.testing.allocator;
    const text = "1.75 -0.5";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{
        Token{ .kind = TokenKind.float, .value = .{ .float = 1.75 } },
        Token{ .kind = TokenKind.float, .value = .{ .float = -0.5 } },
    }, token_container.tokens);
}

test "Identifier starting with a dash" {
    const alloc = std.testing.allocator;
    const text = "-key";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqual(TokenKind.identifier, token_container.tokens[0].kind);
    try std.testing.expectEqualSlices(u8, text, token_container.tokens[0].value.?.identifier);
}

test "Invalid number" {
    const alloc = std.testing.allocator;
    const text = "1.2.3";

    try std.testing.expectError(TokenizerError.InvalidNumber, tokenize(alloc, text));
}

test "Unterminated string" {
    const alloc = std.testing.allocator;
    const text = "\"asdf";

    try std.testing.expectError(TokenizerError.UnterminatedString, tokenize(alloc, text));
}
