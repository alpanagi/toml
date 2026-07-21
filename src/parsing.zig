const std = @import("std");

const tokenization = @import("tokenization.zig");

pub const ValueKind = enum { string, table };
pub const Value = union(ValueKind) {
    string: []const u8,
    table: []KeyValuePair,

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |string| alloc.free(string),
            .table => |table| {
                for (table) |*entry| entry.deinit(alloc);
                alloc.free(table);
            },
        }
    }
};
pub const KeyValuePair = struct {
    key: []const u8,
    value: Value,

    pub fn deinit(self: *KeyValuePair, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        self.value.deinit(alloc);
    }
};

pub const ParsedData = struct {
    key_value_pairs: []KeyValuePair,

    pub fn deinit(self: *ParsedData, alloc: std.mem.Allocator) void {
        for (self.key_value_pairs) |*key_value_pair| key_value_pair.deinit(alloc);
        alloc.free(self.key_value_pairs);
    }
};

const State = struct {
    tokens: []const tokenization.Token,
    cursor: usize,
    key_value_pairs: std.ArrayList(KeyValuePair),
    current_table_name: ?[]const u8,
    current_table_entries: std.ArrayList(KeyValuePair),
};

const ParserError = error{
    UnexpectedToken,
};

pub fn parse(alloc: std.mem.Allocator, tokens: []const tokenization.Token) !ParsedData {
    var state: State = .{
        .tokens = tokens,
        .cursor = 0,
        .key_value_pairs = std.ArrayList(KeyValuePair).empty,

        .current_table_name = null,
        .current_table_entries = std.ArrayList(KeyValuePair).empty,
    };

    while (state.cursor < state.tokens.len) {
        if (ignoreEmptyLine(&state)) continue;
        if (try parseTable(alloc, &state)) continue;
        if (try parseKeyValue(alloc, &state)) continue;

        return ParserError.UnexpectedToken;
    }

    try finalizeCurrentTable(alloc, &state);

    return ParsedData{ .key_value_pairs = try state.key_value_pairs.toOwnedSlice(alloc) };
}

fn ignoreEmptyLine(state: *State) bool {
    if (state.tokens[state.cursor].kind == .new_line) {
        state.cursor += 1;
        return true;
    }
    return false;
}

fn parseTable(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.tokens.len < state.cursor + 3) return false;
    if (state.tokens[state.cursor].kind != .left_bracket) return false;
    if (state.tokens[state.cursor + 1].kind != .identifier) return false;
    if (state.tokens[state.cursor + 2].kind != .right_bracket) return false;

    const name_dupe = try alloc.dupe(u8, state.tokens[state.cursor + 1].value.?.identifier);
    errdefer alloc.free(name_dupe);

    if (state.current_table_name != null) {
        try finalizeCurrentTable(alloc, state);
    }
    state.current_table_name = name_dupe;
    state.cursor += 3;

    return true;
}

fn parseKeyValue(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.tokens.len < state.cursor + 3) return false;
    if (state.tokens[state.cursor].kind != .identifier) return false;
    if (state.tokens[state.cursor + 1].kind != .equals) return false;
    if (state.tokens[state.cursor + 2].kind != .string) return false;
    if (state.tokens.len > state.cursor + 3 and state.tokens[state.cursor + 3].kind != .new_line) {
        return false;
    }

    const key = state.tokens[state.cursor].value.?.identifier;
    const value = state.tokens[state.cursor + 2].value.?.string;

    const key_dupe = try alloc.dupe(u8, key);
    errdefer alloc.free(key_dupe);

    const value_dupe = try alloc.dupe(u8, value);
    errdefer alloc.free(value_dupe);

    if (state.current_table_name == null) {
        try state.key_value_pairs.append(alloc, .{
            .key = key_dupe,
            .value = .{ .string = value_dupe },
        });
    } else {
        try state.current_table_entries.append(alloc, .{
            .key = key_dupe,
            .value = .{ .string = value_dupe },
        });
    }

    state.cursor += 3;
    return true;
}

fn finalizeCurrentTable(alloc: std.mem.Allocator, state: *State) !void {
    if (state.current_table_name != null) {
        const name_dupe = try alloc.dupe(u8, state.current_table_name.?);
        errdefer alloc.free(name_dupe);

        alloc.free(state.current_table_name.?);

        try state.key_value_pairs.append(alloc, KeyValuePair{
            .key = name_dupe,
            .value = .{
                .table = try state.current_table_entries.toOwnedSlice(alloc),
            },
        });

        state.current_table_name = null;
        state.current_table_entries.deinit(alloc);
        state.current_table_entries = std.ArrayList(KeyValuePair).empty;
    }
}

test "New lines" {
    const alloc = std.testing.allocator;
    const text = "\n\n\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqualSlices(KeyValuePair, &.{}, container.key_value_pairs);
}

test "Key value" {
    const alloc = std.testing.allocator;
    const text = "key = \"value\"";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(1, container.key_value_pairs.len);
    try std.testing.expectEqualSlices(u8, "key", container.key_value_pairs[0].key);
    try std.testing.expectEqualSlices(u8, "value", container.key_value_pairs[0].value.string);
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

test "Two key values on the same line" {
    const alloc = std.testing.allocator;
    const text = "key1 = \"value1\" key2 = \"value2\"";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(alloc, token_container.tokens));
}

test "Table after root key value pairs" {
    const alloc = std.testing.allocator;
    const text = "root_key = \"root_value\"\n[table]\nkey = \"value\"\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(2, container.key_value_pairs.len);

    try std.testing.expectEqualSlices(u8, "root_key", container.key_value_pairs[0].key);
    try std.testing.expectEqualSlices(u8, "root_value", container.key_value_pairs[0].value.string);

    try std.testing.expectEqualSlices(u8, "table", container.key_value_pairs[1].key);
    try std.testing.expectEqual(1, container.key_value_pairs[1].value.table.len);
    try std.testing.expectEqualSlices(u8, "key", container.key_value_pairs[1].value.table[0].key);
    try std.testing.expectEqualSlices(u8, "value", container.key_value_pairs[1].value.table[0].value.string);
}

test "Two tables" {
    const alloc = std.testing.allocator;
    const text = "[table1]\nkey1 = \"value1\"\n[table2]\nkey2 = \"value2\"\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(2, container.key_value_pairs.len);

    try std.testing.expectEqualSlices(u8, "table1", container.key_value_pairs[0].key);
    try std.testing.expectEqual(1, container.key_value_pairs[0].value.table.len);
    try std.testing.expectEqualSlices(u8, "key1", container.key_value_pairs[0].value.table[0].key);
    try std.testing.expectEqualSlices(u8, "value1", container.key_value_pairs[0].value.table[0].value.string);

    try std.testing.expectEqualSlices(u8, "table2", container.key_value_pairs[1].key);
    try std.testing.expectEqual(1, container.key_value_pairs[1].value.table.len);
    try std.testing.expectEqualSlices(u8, "key2", container.key_value_pairs[1].value.table[0].key);
    try std.testing.expectEqualSlices(u8, "value2", container.key_value_pairs[1].value.table[0].value.string);
}
