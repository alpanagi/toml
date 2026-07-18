const std = @import("std");

const tokenization = @import("tokenization.zig");

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub const ParsedDataKind = enum { key_value };
pub const ParsedDataValue = union(ParsedDataKind) {
    key_value: KeyValue,

    pub fn deinit(self: ParsedDataValue, alloc: std.mem.Allocator) void {
        switch (self) {
            .key_value => |key_value| {
                alloc.free(key_value.key);
                alloc.free(key_value.value);
            },
        }
    }
};
pub const ParsedData = struct {
    kind: ParsedDataKind,
    value: ?ParsedDataValue,

    pub fn deinit(self: *ParsedData, alloc: std.mem.Allocator) void {
        if (self.value) |*value| value.deinit(alloc);
    }
};

pub const ParsedDataContainer = struct {
    items: []ParsedData,

    pub fn deinit(self: *ParsedDataContainer, alloc: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(alloc);
        alloc.free(self.items);
    }
};

const State = struct {
    tokens: []const tokenization.Token,
    cursor: usize,
    items: std.ArrayList(ParsedData),
};

const ParserError = error{
    UnexpectedToken,
};

pub fn parse(alloc: std.mem.Allocator, tokens: []const tokenization.Token) !ParsedDataContainer {
    var state: State = .{
        .tokens = tokens,
        .cursor = 0,
        .items = std.ArrayList(ParsedData).empty,
    };

    while (state.cursor < state.tokens.len) {
        if (ignoreEmptyLine(&state)) continue;
        if (try parseKeyValue(alloc, &state)) continue;

        return ParserError.UnexpectedToken;
    }

    return ParsedDataContainer{ .items = try state.items.toOwnedSlice(alloc) };
}

fn ignoreEmptyLine(state: *State) bool {
    if (state.tokens[state.cursor].kind == .new_line) {
        state.cursor += 1;
        return true;
    }
    return false;
}

fn parseKeyValue(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.tokens.len < state.cursor + 3) return false;
    if (state.tokens[state.cursor].kind != .identifier) return false;
    if (state.tokens[state.cursor + 1].kind != .equals) return false;
    if (state.tokens[state.cursor + 2].kind != .string) return false;

    const key = state.tokens[state.cursor].value.?.identifier;
    const value = state.tokens[state.cursor + 2].value.?.string;

    try state.items.append(alloc, .{
        .kind = ParsedDataKind.key_value,
        .value = ParsedDataValue{ .key_value = .{
            .key = try alloc.dupe(u8, key),
            .value = try alloc.dupe(u8, value),
        } },
    });
    state.cursor += 3;
    return true;
}

test "New lines" {
    const alloc = std.testing.allocator;
    const text = "\n\n\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqualSlices(ParsedData, &.{}, container.items);
}

test "Key value" {
    const alloc = std.testing.allocator;
    const text = "key = \"value\"";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(1, container.items.len);
    try std.testing.expectEqual(ParsedDataKind.key_value, container.items[0].kind);
    try std.testing.expectEqualSlices(u8, "key", container.items[0].value.?.key_value.key);
    try std.testing.expectEqualSlices(u8, "value", container.items[0].value.?.key_value.value);
}

test "Missing equals" {
    const alloc = std.testing.allocator;
    const text = "key key key";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(alloc, token_container.tokens));
}

test "Missing string value" {
    const alloc = std.testing.allocator;
    const text = "key = not_a_string";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(alloc, token_container.tokens));
}
