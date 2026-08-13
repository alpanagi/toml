const std = @import("std");

const tab: u8 = 0x09;
const space: u8 = 0x20;
const cr: u8 = 0x0D;
const lf: u8 = 0x0A;

pub const Token = union(enum) {
    new_line,
    comma,
    dot,
    equals,
    left_bracket,
    right_bracket,
    integer: i64,
    float: f64,
    identifier: []const u8,
    string: []const u8,

    pub fn getText(self: Token) ?[]const u8 {
        return switch (self) {
            .identifier, .string => |value| value,
            else => null,
        };
    }
};

pub const TokenizerError = error{
    UnknownCharacter,
    UnterminatedString,
    InvalidNumber,
};

const State = struct {
    text: []const u8,
    cursor: usize,
    tokens: std.ArrayList(Token),
};

pub fn tokenize(arena: *std.heap.ArenaAllocator, text: []const u8) ![]Token {
    const allocator = arena.allocator();
    var state: State = .{
        .text = text,
        .cursor = 0,
        .tokens = std.ArrayList(Token).empty,
    };

    while (state.cursor < text.len) {
        if (ignoreWhitespace(&state)) continue;
        if (ignoreComment(&state)) continue;

        if (try tokenizeNewLine(allocator, &state)) continue;
        if (try tokenizeSymbols(allocator, &state)) continue;
        if (try tokenizeString(allocator, &state)) continue;
        if (try tokenizeNumber(allocator, &state)) continue;
        if (try tokenizeIdentifier(allocator, &state)) continue;

        return TokenizerError.UnknownCharacter;
    }

    return state.tokens.items;
}

fn ignoreWhitespace(state: *State) bool {
    const start = state.cursor;
    while (state.cursor < state.text.len) {
        if (state.text[state.cursor] != space and state.text[state.cursor] != tab) break;
        state.cursor += 1;
    }
    return start != state.cursor;
}

fn ignoreComment(state: *State) bool {
    if (state.text[state.cursor] != '#') return false;

    while (state.cursor < state.text.len) {
        if (state.text[state.cursor] == lf or state.text[state.cursor] == cr) break;
        state.cursor += 1;
    }
    return true;
}

fn tokenizeNewLine(allocator: std.mem.Allocator, state: *State) !bool {
    const width: usize = switch (state.text[state.cursor]) {
        lf => 1,
        cr => block: {
            if (state.cursor + 1 >= state.text.len) return false;
            if (state.text[state.cursor + 1] != lf) return false;
            break :block 2;
        },
        else => return false,
    };

    state.cursor += width;
    try state.tokens.append(allocator, .new_line);
    return true;
}

fn tokenizeSymbols(allocator: std.mem.Allocator, state: *State) !bool {
    const token: Token = switch (state.text[state.cursor]) {
        '=' => .equals,
        '.' => .dot,
        ',' => .comma,
        '[' => .left_bracket,
        ']' => .right_bracket,
        else => return false,
    };

    state.cursor += 1;
    try state.tokens.append(allocator, token);
    return true;
}

fn tokenizeString(allocator: std.mem.Allocator, state: *State) !bool {
    if (state.text[state.cursor] != '"') return false;

    const start = state.cursor + 1;
    var cursor = start;

    while (cursor < state.text.len and state.text[cursor] != '"') {
        cursor += 1;
    }

    if (cursor == state.text.len) return TokenizerError.UnterminatedString;

    state.cursor = cursor + 1;
    const string = try allocator.dupe(u8, state.text[start..cursor]);
    try state.tokens.append(allocator, .{ .string = string });
    return true;
}

fn tokenizeNumber(allocator: std.mem.Allocator, state: *State) !bool {
    const start = state.cursor;
    var cursor = start;
    if (state.text[cursor] == '+' or state.text[cursor] == '-') cursor += 1;

    if (cursor >= state.text.len) return false;
    if (!std.ascii.isDigit(state.text[cursor])) return false;

    var is_float = false;
    while (cursor < state.text.len) {
        switch (state.text[cursor]) {
            '0'...'9', '_' => {},
            '.' => is_float = true,
            else => break,
        }
        cursor += 1;
    }

    state.cursor = cursor;
    const number = state.text[start..cursor];
    const token: Token = if (is_float)
        .{ .float = std.fmt.parseFloat(f64, number) catch return TokenizerError.InvalidNumber }
    else
        .{ .integer = std.fmt.parseInt(i64, number, 10) catch return TokenizerError.InvalidNumber };

    try state.tokens.append(allocator, token);
    return true;
}

fn tokenizeIdentifier(allocator: std.mem.Allocator, state: *State) !bool {
    const start = state.cursor;
    var cursor = start;

    while (cursor < state.text.len) {
        switch (state.text[cursor]) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => cursor += 1,
            else => break,
        }
    }
    if (cursor == start) return false;

    state.cursor = cursor;
    const identifier = try allocator.dupe(u8, state.text[start..cursor]);
    try state.tokens.append(allocator, .{ .identifier = identifier });
    return true;
}

test "whitespace: ignores tabs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\t=\t,\t";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .equals, .comma }, tokens);
}

test "comment: produces no tokens" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "# This is a comment";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{}, tokens);
}

test "comment: keeps the newline ending of each comment" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "# This is a comment\n# This is another one\n";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .new_line, .new_line }, tokens);
}

test "comment: ignores leading whitespace" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "  # This is a comment\n  = 1\n";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .new_line, .equals, .{ .integer = 1 }, .new_line }, tokens);
}

test "comment: ignores a comment following a value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "= 1 # This is a comment\n";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .equals, .{ .integer = 1 }, .new_line }, tokens);
}

test "newline: blank line emits its own token" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[\n\n]";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .left_bracket, .new_line, .new_line, .right_bracket }, tokens);
}

test "newline: parses CRLF as a single token" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[\r\n]";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .left_bracket, .new_line, .right_bracket }, tokens);
}

test "newline: rejects a lone carriage return" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\r";
    try std.testing.expectError(TokenizerError.UnknownCharacter, tokenize(&arena, text));
}

test "newline: rejects a carriage return not followed by a line feed" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\ra";
    try std.testing.expectError(TokenizerError.UnknownCharacter, tokenize(&arena, text));
}

test "symbol: parses equals surrounded by spaces" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = " = ";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expect(.equals == tokens[0]);
}

test "symbol: parses brackets" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[]";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .left_bracket, .right_bracket }, tokens);
}

test "symbol: parses comma and dot" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = ",.";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{ .comma, .dot }, tokens);
}

test "string: strips the surrounding quotes" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\"asdf\"";
    const expected = "asdf";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expect(.string == tokens[0]);
    try std.testing.expectEqualSlices(u8, expected, tokens[0].string);
}

test "string: accepts an empty string" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\"\"";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expect(.string == tokens[0]);
    try std.testing.expectEqualSlices(u8, "", tokens[0].string);
}

test "string: rejects unterminated input with UnterminatedString" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\"asdf";
    try std.testing.expectError(TokenizerError.UnterminatedString, tokenize(&arena, text));
}

test "number: parses integers with signs and underscores" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "0 42 -7 +9 1_000";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{
        .{ .integer = 0 },
        .{ .integer = 42 },
        .{ .integer = -7 },
        .{ .integer = 9 },
        .{ .integer = 1000 },
    }, tokens);
}

test "number: parses floats with signs and underscores" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "1.75 -0.5 +2.25 1_000.5";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqualSlices(Token, &.{
        .{ .float = 1.75 },
        .{ .float = -0.5 },
        .{ .float = 2.25 },
        .{ .float = 1000.5 },
    }, tokens);
}

test "number: rejects 1.2.3 with InvalidNumber" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "1.2.3";
    try std.testing.expectError(TokenizerError.InvalidNumber, tokenize(&arena, text));
}

test "identifier: accepts letters, digits and underscores" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "Test_1234";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expect(.identifier == tokens[0]);
    try std.testing.expectEqualSlices(u8, text, tokens[0].identifier);
}

test "identifier: allows a leading dash" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "-key";

    const tokens = try tokenize(&arena, text);
    try std.testing.expectEqual(1, tokens.len);
    try std.testing.expect(.identifier == tokens[0]);
    try std.testing.expectEqualSlices(u8, text, tokens[0].identifier);
}

test "tokenize: rejects an unknown character" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "?";
    try std.testing.expectError(TokenizerError.UnknownCharacter, tokenize(&arena, text));
}
