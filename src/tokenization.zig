const std = @import("std");

const tab: u8 = 0x09;
const space: u8 = 0x20;

const cr: u8 = 0x0D;
const lf: u8 = 0x0A;

const TokenKind = enum { new_line, identifier };
const TokenValue = union(TokenKind) {
    new_line,
    identifier: []const u8,

    pub fn deinit(self: TokenValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .identifier => |str| alloc.free(str),
            else => {},
        }
    }
};
const Token = struct {
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

fn tokenizeIdentifier(alloc: std.mem.Allocator, state: *State) !bool {
    if (isValidIdentifierCharacter(state.text[state.cursor])) {
        const identifierStart = state.cursor;
        while (state.cursor < state.text.len and
            isValidIdentifierCharacter(state.text[state.cursor]))
        {
            state.cursor += 1;
        }

        const identifier = try alloc.dupe(u8, state.text[identifierStart..state.cursor]);
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

    const token_container = try tokenize(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, token_container.tokens);
}

test "Multiline comments with padding" {
    const alloc = std.testing.allocator;
    const text = "    # This is a comment\n    # This is another one\n";

    const token_container = try tokenize(alloc, text);
    try std.testing.expectEqualSlices(Token, &.{}, token_container.tokens);
}

test "Empty line" {
    const alloc = std.testing.allocator;
    const text = "# This is a comment\n\n# This is another one\n";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqualSlices(Token, &.{Token{
        .kind = TokenKind.new_line,
        .value = null,
    }}, token_container.tokens);
}

test "Identifier" {
    const alloc = std.testing.allocator;
    const text = "Test_1234";

    var token_container = try tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectEqual(TokenKind.identifier, token_container.tokens[0].kind);
    try std.testing.expectEqualSlices(u8, text, token_container.tokens[0].value.?.identifier);
}
