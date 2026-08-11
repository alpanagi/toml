const std = @import("std");

const tokenization = @import("tokenization.zig");

pub const ValueKind = enum { string, integer, float, array, table };
pub const Value = union(ValueKind) {
    string: []const u8,
    integer: i64,
    float: f64,
    array: []Value,
    table: []KeyValuePair,

    pub fn deinit(self: *Value, alloc: std.mem.Allocator) void {
        switch (self.*) {
            .string => |string| alloc.free(string),
            .array => |array| {
                for (array) |*item| item.deinit(alloc);
                alloc.free(array);
            },
            .table => |table| {
                for (table) |*entry| entry.deinit(alloc);
                alloc.free(table);
            },
            else => {},
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
    root: []KeyValuePair,
    path: std.ArrayList([]const u8),
};

const ParserError = error{
    UnexpectedToken,
};

pub fn parse(alloc: std.mem.Allocator, tokens: []const tokenization.Token) !ParsedData {
    var state: State = .{
        .tokens = tokens,
        .cursor = 0,
        .root = &.{},
        .path = std.ArrayList([]const u8).empty,
    };
    defer clearPath(alloc, &state);
    errdefer {
        var root = Value{ .table = state.root };
        root.deinit(alloc);
    }

    while (state.cursor < state.tokens.len) {
        if (ignoreEmptyLine(&state)) continue;
        if (try parseTable(alloc, &state)) continue;
        if (try parseKeyValue(alloc, &state)) continue;

        return ParserError.UnexpectedToken;
    }

    return ParsedData{ .key_value_pairs = state.root };
}

fn ignoreEmptyLine(state: *State) bool {
    if (state.tokens[state.cursor].kind == .new_line) {
        state.cursor += 1;
        return true;
    }
    return false;
}

fn parseTable(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.tokens[state.cursor].kind != .left_bracket) return false;

    var cursor = state.cursor + 1;
    const is_array = cursor < state.tokens.len and state.tokens[cursor].kind == .left_bracket;
    if (is_array) cursor += 1;

    var path = std.ArrayList([]const u8).empty;
    errdefer {
        for (path.items) |segment| alloc.free(segment);
        path.deinit(alloc);
    }

    while (true) {
        if (cursor >= state.tokens.len) return ParserError.UnexpectedToken;
        if (state.tokens[cursor].kind != .identifier) return ParserError.UnexpectedToken;

        const segment = try alloc.dupe(u8, state.tokens[cursor].value.?.identifier);
        errdefer alloc.free(segment);
        try path.append(alloc, segment);
        cursor += 1;

        if (cursor < state.tokens.len and state.tokens[cursor].kind == .dot) {
            cursor += 1;
            continue;
        }
        break;
    }

    if (cursor >= state.tokens.len) return ParserError.UnexpectedToken;
    if (state.tokens[cursor].kind != .right_bracket) return ParserError.UnexpectedToken;
    cursor += 1;

    if (is_array) {
        if (cursor >= state.tokens.len) return ParserError.UnexpectedToken;
        if (state.tokens[cursor].kind != .right_bracket) return ParserError.UnexpectedToken;
        cursor += 1;
    }

    if (cursor < state.tokens.len and state.tokens[cursor].kind != .new_line) {
        return ParserError.UnexpectedToken;
    }

    var container = &state.root;
    for (path.items[0 .. path.items.len - 1]) |segment| {
        container = try descend(alloc, container, segment);
    }

    const name = path.items[path.items.len - 1];
    if (is_array) {
        try appendTableToArray(alloc, container, name);
    } else {
        _ = try descend(alloc, container, name);
    }

    clearPath(alloc, state);
    state.path = path;
    state.cursor = cursor;

    return true;
}

fn parseKeyValue(alloc: std.mem.Allocator, state: *State) !bool {
    if (state.tokens[state.cursor].kind != .identifier) return false;
    if (state.cursor + 1 >= state.tokens.len) return ParserError.UnexpectedToken;
    if (state.tokens[state.cursor + 1].kind != .equals) return ParserError.UnexpectedToken;

    const key = state.tokens[state.cursor].value.?.identifier;
    state.cursor += 2;

    var value = try parseValue(alloc, state);
    errdefer value.deinit(alloc);

    if (state.cursor < state.tokens.len and state.tokens[state.cursor].kind != .new_line) {
        return ParserError.UnexpectedToken;
    }

    const container = try resolvePath(alloc, state);

    const key_dupe = try alloc.dupe(u8, key);
    errdefer alloc.free(key_dupe);

    try appendPair(alloc, container, .{ .key = key_dupe, .value = value });

    return true;
}

fn parseValue(alloc: std.mem.Allocator, state: *State) !Value {
    if (state.cursor >= state.tokens.len) return ParserError.UnexpectedToken;

    const token = state.tokens[state.cursor];
    switch (token.kind) {
        .string => {
            state.cursor += 1;
            return Value{ .string = try alloc.dupe(u8, token.value.?.string) };
        },
        .integer => {
            state.cursor += 1;
            return Value{ .integer = token.value.?.integer };
        },
        .float => {
            state.cursor += 1;
            return Value{ .float = token.value.?.float };
        },
        .left_bracket => {},
        else => return ParserError.UnexpectedToken,
    }

    state.cursor += 1;

    var array: []Value = &.{};
    errdefer {
        var value = Value{ .array = array };
        value.deinit(alloc);
    }

    while (true) {
        ignoreNewLines(state);
        if (state.cursor >= state.tokens.len) return ParserError.UnexpectedToken;

        if (state.tokens[state.cursor].kind == .right_bracket) {
            state.cursor += 1;
            return Value{ .array = array };
        }

        var item = try parseValue(alloc, state);
        errdefer item.deinit(alloc);
        try appendValue(alloc, &array, item);

        ignoreNewLines(state);
        if (state.cursor >= state.tokens.len) return ParserError.UnexpectedToken;

        switch (state.tokens[state.cursor].kind) {
            .comma => state.cursor += 1,
            .right_bracket => {
                state.cursor += 1;
                return Value{ .array = array };
            },
            else => return ParserError.UnexpectedToken,
        }
    }
}

fn ignoreNewLines(state: *State) void {
    while (state.cursor < state.tokens.len and state.tokens[state.cursor].kind == .new_line) {
        state.cursor += 1;
    }
}

fn resolvePath(alloc: std.mem.Allocator, state: *State) !*[]KeyValuePair {
    var container = &state.root;
    for (state.path.items) |segment| {
        container = try descend(alloc, container, segment);
    }
    return container;
}

fn descend(alloc: std.mem.Allocator, pairs: *[]KeyValuePair, key: []const u8) !*[]KeyValuePair {
    if (findPair(pairs.*, key)) |pair| {
        switch (pair.value) {
            .table => return &pair.value.table,
            .array => {
                if (pair.value.array.len == 0) return ParserError.UnexpectedToken;

                const last = &pair.value.array[pair.value.array.len - 1];
                if (last.* != .table) return ParserError.UnexpectedToken;
                return &last.table;
            },
            else => return ParserError.UnexpectedToken,
        }
    }

    const key_dupe = try alloc.dupe(u8, key);
    errdefer alloc.free(key_dupe);

    try appendPair(alloc, pairs, .{ .key = key_dupe, .value = .{ .table = &.{} } });

    return &pairs.*[pairs.len - 1].value.table;
}

fn appendTableToArray(alloc: std.mem.Allocator, pairs: *[]KeyValuePair, key: []const u8) !void {
    if (findPair(pairs.*, key)) |pair| {
        if (pair.value != .array) return ParserError.UnexpectedToken;
        return appendValue(alloc, &pair.value.array, .{ .table = &.{} });
    }

    const key_dupe = try alloc.dupe(u8, key);
    errdefer alloc.free(key_dupe);

    try appendPair(alloc, pairs, .{ .key = key_dupe, .value = .{ .array = &.{} } });

    return appendValue(alloc, &pairs.*[pairs.len - 1].value.array, .{ .table = &.{} });
}

fn findPair(pairs: []KeyValuePair, key: []const u8) ?*KeyValuePair {
    for (pairs) |*pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair;
    }
    return null;
}

fn appendPair(alloc: std.mem.Allocator, pairs: *[]KeyValuePair, pair: KeyValuePair) !void {
    pairs.* = try alloc.realloc(pairs.*, pairs.len + 1);
    pairs.*[pairs.len - 1] = pair;
}

fn appendValue(alloc: std.mem.Allocator, values: *[]Value, value: Value) !void {
    values.* = try alloc.realloc(values.*, values.len + 1);
    values.*[values.len - 1] = value;
}

fn clearPath(alloc: std.mem.Allocator, state: *State) void {
    for (state.path.items) |segment| alloc.free(segment);
    state.path.deinit(alloc);
    state.path = std.ArrayList([]const u8).empty;
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

test "Numbers" {
    const alloc = std.testing.allocator;
    const text = "count = 5\nratio = 1.75\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(2, container.key_value_pairs.len);
    try std.testing.expectEqual(@as(i64, 5), container.key_value_pairs[0].value.integer);
    try std.testing.expectEqual(@as(f64, 1.75), container.key_value_pairs[1].value.float);
}

test "Array" {
    const alloc = std.testing.allocator;
    const text = "position = [0, 1.75, \"end\"]\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    const array = container.key_value_pairs[0].value.array;
    try std.testing.expectEqual(3, array.len);
    try std.testing.expectEqual(@as(i64, 0), array[0].integer);
    try std.testing.expectEqual(@as(f64, 1.75), array[1].float);
    try std.testing.expectEqualSlices(u8, "end", array[2].string);
}

test "Empty array" {
    const alloc = std.testing.allocator;
    const text = "items = []\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(0, container.key_value_pairs[0].value.array.len);
}

test "Nested array" {
    const alloc = std.testing.allocator;
    const text = "matrix = [[1, 2], [3, 4]]\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    const matrix = container.key_value_pairs[0].value.array;
    try std.testing.expectEqual(2, matrix.len);
    try std.testing.expectEqual(@as(i64, 2), matrix[0].array[1].integer);
    try std.testing.expectEqual(@as(i64, 3), matrix[1].array[0].integer);
}

test "Unterminated array" {
    const alloc = std.testing.allocator;
    const text = "items = [1, 2\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(alloc, token_container.tokens));
}

test "Dotted table header" {
    const alloc = std.testing.allocator;
    const text = "[server.tls]\nenabled = \"yes\"\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(1, container.key_value_pairs.len);
    try std.testing.expectEqualSlices(u8, "server", container.key_value_pairs[0].key);

    const server = container.key_value_pairs[0].value.table;
    try std.testing.expectEqualSlices(u8, "tls", server[0].key);
    try std.testing.expectEqualSlices(u8, "yes", server[0].value.table[0].value.string);
}

test "Array of tables" {
    const alloc = std.testing.allocator;
    const text = "[[mesh]]\nid = \"a\"\n[[mesh]]\nid = \"b\"\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    try std.testing.expectEqual(1, container.key_value_pairs.len);
    try std.testing.expectEqualSlices(u8, "mesh", container.key_value_pairs[0].key);

    const meshes = container.key_value_pairs[0].value.array;
    try std.testing.expectEqual(2, meshes.len);
    try std.testing.expectEqualSlices(u8, "a", meshes[0].table[0].value.string);
    try std.testing.expectEqualSlices(u8, "b", meshes[1].table[0].value.string);
}

test "Sub table of an array of tables" {
    const alloc = std.testing.allocator;
    const text = "[[entity]]\n[entity.Transform]\nposition = [0, 1]\n[[entity]]\n[entity.Camera]\n";

    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var container = try parse(alloc, token_container.tokens);
    defer container.deinit(alloc);

    const entities = container.key_value_pairs[0].value.array;
    try std.testing.expectEqual(2, entities.len);

    try std.testing.expectEqualSlices(u8, "Transform", entities[0].table[0].key);
    try std.testing.expectEqual(2, entities[0].table[0].value.table[0].value.array.len);

    try std.testing.expectEqualSlices(u8, "Camera", entities[1].table[0].key);
    try std.testing.expectEqual(0, entities[1].table[0].value.table.len);
}
