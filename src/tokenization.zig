const std = @import("std");

const tab: u8 = 0x09;
const space: u8 = 0x20;

const cr: u8 = 0x0D;
const lf: u8 = 0x0A;

const TokenKind = enum { new_line };
const TokenValue = union(TokenKind) { new_line };
const Token = struct { kind: TokenKind, value: ?TokenValue };

const State = struct {
    text: []const u8,
    cursor: usize,
    tokens: std.ArrayList(Token),
};

const TokenizerError = error{
    UnknownCharacter,
};

pub fn tokenizeAlloc(alloc: std.mem.Allocator, text: []const u8) ![]Token {
    var state: State = .{
        .text = text,
        .cursor = 0,
        .tokens = std.ArrayList(Token).empty,
    };

    while (state.cursor < text.len) {
        if (ignoreWhitespace(&state)) continue;
        if (ignoreComment(&state)) continue;
        if (try tokenizeNewLine(alloc, &state)) continue;

        return TokenizerError.UnknownCharacter;
    }

    return state.tokens.toOwnedSlice(alloc);
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
        while (state.cursor < state.text.len) {
            if (state.text[state.cursor] == lf) {
                state.cursor += 1;
                break;
            }
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

test "Comment" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment";

    const tokens = try tokenizeAlloc(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, tokens);
}

test "Multiline comments" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment\n# This is another one\n";

    const tokens = try tokenizeAlloc(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, tokens);
}

test "Multiline comments with padding" {
    const alloc = std.testing.allocator;
    const text = "    # This is a comment\n    # This is another one\n";

    const tokens = try tokenizeAlloc(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, tokens);
}

test "Tokenize empty lines" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment\n\n# This is another one\n";

    const tokens = try tokenizeAlloc(alloc, text);
    defer alloc.free(tokens);
    try std.testing.expectEqualSlices(Token, &.{Token{
        .kind = TokenKind.new_line,
        .value = null,
    }}, tokens);
}
