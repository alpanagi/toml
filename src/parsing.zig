const std = @import("std");

const tokenization = @import("tokenization.zig");

const Token = tokenization.Token;

pub const KeyValuePair = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    array: std.ArrayList(Value),
    table: std.ArrayList(KeyValuePair),
};

pub const ParserError = error{
    UnexpectedToken,
    NotATable,
    TableRedefined,
    DuplicateKey,
    EmptyPath,
};

const State = struct {
    tokens: []const Token,
    cursor: usize,
    root_table: std.ArrayList(KeyValuePair),
    path: std.ArrayList([]const u8),
};

pub fn parse(arena: *std.heap.ArenaAllocator, tokens: []const Token) ![]KeyValuePair {
    const allocator = arena.allocator();
    var state: State = .{
        .tokens = tokens,
        .cursor = 0,
        .root_table = .empty,
        .path = .empty,
    };

    while (state.cursor < state.tokens.len) {
        if (ignoreNewLines(&state, &state.cursor)) continue;
        if (try parseTable(allocator, &state)) continue;
        if (try parseKeyValue(allocator, &state)) continue;

        return ParserError.UnexpectedToken;
    }

    return state.root_table.items;
}

fn ignoreNewLines(state: *State, cursor: *usize) bool {
    const start = cursor.*;
    while (isToken(state, cursor.*, .new_line)) cursor.* += 1;
    return start != cursor.*;
}

fn parseTable(allocator: std.mem.Allocator, state: *State) !bool {
    if (!isToken(state, state.cursor, .left_bracket)) return false;

    var cursor = state.cursor + 1;
    const is_array_element = consumeToken(state, &cursor, .left_bracket);

    var path = std.ArrayList([]const u8).empty;
    while (true) {
        if (cursor >= state.tokens.len) return ParserError.UnexpectedToken;

        const name = state.tokens[cursor].getText() orelse return ParserError.UnexpectedToken;
        const segment = try allocator.dupe(u8, name);
        try path.append(allocator, segment);
        cursor += 1;

        if (!consumeToken(state, &cursor, .dot)) break;
    }

    if (!consumeToken(state, &cursor, .right_bracket)) return ParserError.UnexpectedToken;
    if (is_array_element and !consumeToken(state, &cursor, .right_bracket)) return ParserError.UnexpectedToken;

    if (!isEndOfLine(state, cursor)) return ParserError.UnexpectedToken;

    try insertTable(allocator, &state.root_table, path.items, is_array_element);

    state.path = path;
    state.cursor = cursor;
    return true;
}

fn parseKeyValue(allocator: std.mem.Allocator, state: *State) !bool {
    const key = state.tokens[state.cursor].getText() orelse return false;

    var cursor = state.cursor + 1;
    if (!consumeToken(state, &cursor, .equals)) return ParserError.UnexpectedToken;

    const value = try parseValue(allocator, state, &cursor);

    if (!isEndOfLine(state, cursor)) return ParserError.UnexpectedToken;

    const key_dupe = try allocator.dupe(u8, key);
    const path = try std.mem.concat(allocator, []const u8, &.{ state.path.items, &.{key_dupe} });
    try insertValue(allocator, &state.root_table, path, value);

    state.cursor = cursor;
    return true;
}

fn parseValue(allocator: std.mem.Allocator, state: *State, cursor: *usize) (ParserError || std.mem.Allocator.Error)!Value {
    if (cursor.* >= state.tokens.len) return ParserError.UnexpectedToken;

    switch (state.tokens[cursor.*]) {
        .string => |text| {
            cursor.* += 1;
            return .{ .string = try allocator.dupe(u8, text) };
        },
        .integer => |integer| {
            cursor.* += 1;
            return .{ .integer = integer };
        },
        .float => |float| {
            cursor.* += 1;
            return .{ .float = float };
        },
        .left_bracket => return .{ .array = try parseArray(allocator, state, cursor) },
        else => return ParserError.UnexpectedToken,
    }
}

fn parseArray(allocator: std.mem.Allocator, state: *State, cursor: *usize) (ParserError || std.mem.Allocator.Error)!std.ArrayList(Value) {
    if (!consumeToken(state, cursor, .left_bracket)) return ParserError.UnexpectedToken;

    var array: std.ArrayList(Value) = .empty;

    while (true) {
        _ = ignoreNewLines(state, cursor);
        if (consumeToken(state, cursor, .right_bracket)) return array;

        try array.append(allocator, try parseValue(allocator, state, cursor));

        _ = ignoreNewLines(state, cursor);
        if (consumeToken(state, cursor, .comma)) continue;
        if (consumeToken(state, cursor, .right_bracket)) return array;

        return ParserError.UnexpectedToken;
    }
}

fn insertTable(
    allocator: std.mem.Allocator,
    root: *std.ArrayList(KeyValuePair),
    path: []const []const u8,
    is_array_element: bool,
) !void {
    if (path.len == 0) return ParserError.EmptyPath;

    const container = try descendPath(allocator, root, path[0..(path.len - 1)]);
    const key = path[path.len - 1];

    if (findPair(container.items, key)) |pair| {
        switch (pair.value) {
            .table => if (is_array_element) return ParserError.TableRedefined,
            .array => |*array| {
                if (!is_array_element) return ParserError.TableRedefined;
                try array.append(allocator, .{ .table = .empty });
            },
            else => return ParserError.TableRedefined,
        }
        return;
    }

    if (is_array_element) {
        var array: std.ArrayList(Value) = .empty;
        try array.append(allocator, .{ .table = .empty });
        try container.append(allocator, .{ .key = key, .value = .{ .array = array } });
    } else {
        try container.append(allocator, .{ .key = key, .value = .{ .table = .empty } });
    }
}

fn insertValue(
    allocator: std.mem.Allocator,
    root: *std.ArrayList(KeyValuePair),
    path: []const []const u8,
    value: Value,
) !void {
    if (path.len == 0) return ParserError.EmptyPath;

    const container = try descendPath(allocator, root, path[0 .. path.len - 1]);
    const key = path[path.len - 1];

    if (findPair(container.items, key) != null) return ParserError.DuplicateKey;
    try container.append(allocator, .{ .key = key, .value = value });
}

fn descendPath(
    allocator: std.mem.Allocator,
    root: *std.ArrayList(KeyValuePair),
    path: []const []const u8,
) !*std.ArrayList(KeyValuePair) {
    var cursor = root;
    for (path) |segment| {
        if (findPair(cursor.items, segment)) |pair| {
            switch (pair.value) {
                .table => |*table| cursor = table,
                .array => |*array| {
                    if (array.items.len == 0) return ParserError.NotATable;
                    const last = &array.items[array.items.len - 1];
                    if (last.* != .table) return ParserError.NotATable;
                    cursor = &last.table;
                },
                else => return ParserError.NotATable,
            }
        } else {
            try cursor.append(allocator, .{ .key = segment, .value = .{ .table = .empty } });
            cursor = &cursor.items[cursor.items.len - 1].value.table;
        }
    }

    return cursor;
}

fn findPair(pairs: []KeyValuePair, key: []const u8) ?*KeyValuePair {
    for (pairs) |*pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair;
    }
    return null;
}

fn isEndOfLine(state: *const State, cursor: usize) bool {
    return cursor >= state.tokens.len or isToken(state, cursor, .new_line);
}

fn consumeToken(state: *State, cursor: *usize, expected: std.meta.Tag(Token)) bool {
    if (!isToken(state, cursor.*, expected)) return false;
    cursor.* += 1;
    return true;
}

fn isToken(state: *const State, cursor: usize, expected: std.meta.Tag(Token)) bool {
    return cursor < state.tokens.len and state.tokens[cursor] == expected;
}

test "newline: input of only newlines produces no pairs" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\n\n\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqualSlices(KeyValuePair, &.{}, pairs);
}

test "table: parses consecutive tables" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[table1]\nkey1 = \"value1\"\n[table2]\nkey2 = \"value2\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(2, pairs.len);

    try std.testing.expectEqualSlices(u8, "table1", pairs[0].key);
    try std.testing.expectEqual(1, pairs[0].value.table.items.len);
    try std.testing.expectEqualSlices(u8, "key1", pairs[0].value.table.items[0].key);
    try std.testing.expectEqualSlices(u8, "value1", pairs[0].value.table.items[0].value.string);

    try std.testing.expectEqualSlices(u8, "table2", pairs[1].key);
    try std.testing.expectEqual(1, pairs[1].value.table.items.len);
    try std.testing.expectEqualSlices(u8, "key2", pairs[1].value.table.items[0].key);
    try std.testing.expectEqualSlices(u8, "value2", pairs[1].value.table.items[0].value.string);
}

test "table: keeps root pairs declared before a header" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "root_key = \"root_value\"\n[table]\nkey = \"value\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(2, pairs.len);

    try std.testing.expectEqualSlices(u8, "root_key", pairs[0].key);
    try std.testing.expectEqualSlices(u8, "root_value", pairs[0].value.string);

    try std.testing.expectEqualSlices(u8, "table", pairs[1].key);
    try std.testing.expectEqual(1, pairs[1].value.table.items.len);
    try std.testing.expectEqualSlices(u8, "key", pairs[1].value.table.items[0].key);
    try std.testing.expectEqualSlices(u8, "value", pairs[1].value.table.items[0].value.string);
}

test "table: dotted header nests tables" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[server.tls]\nenabled = \"yes\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(1, pairs.len);
    try std.testing.expectEqualSlices(u8, "server", pairs[0].key);

    const server = pairs[0].value.table.items;
    try std.testing.expectEqualSlices(u8, "tls", server[0].key);
    try std.testing.expectEqualSlices(u8, "yes", server[0].value.table.items[0].value.string);
}

test "table: accepts a quoted header segment" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[[entity]]\n[entity.\"engine/Transform\"]\nposition = [0, 1]\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    const entities = pairs[0].value.array.items;
    try std.testing.expectEqual(1, entities.len);
    try std.testing.expectEqualSlices(u8, "engine/Transform", entities[0].table.items[0].key);
    try std.testing.expectEqual(2, entities[0].table.items[0].value.table.items[0].value.array.items.len);
}

test "table: accepts every segment quoted" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[\"a/b\".\"c/d\"]\nkey = \"value\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqualSlices(u8, "a/b", pairs[0].key);

    const inner = pairs[0].value.table.items;
    try std.testing.expectEqualSlices(u8, "c/d", inner[0].key);
    try std.testing.expectEqualSlices(u8, "value", inner[0].value.table.items[0].value.string);
}

test "table: array of tables collects each element" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[[mesh]]\nid = \"a\"\n[[mesh]]\nid = \"b\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(1, pairs.len);
    try std.testing.expectEqualSlices(u8, "mesh", pairs[0].key);

    const meshes = pairs[0].value.array.items;
    try std.testing.expectEqual(2, meshes.len);
    try std.testing.expectEqualSlices(u8, "a", meshes[0].table.items[0].value.string);
    try std.testing.expectEqualSlices(u8, "b", meshes[1].table.items[0].value.string);
}

test "table: sub table attaches to the last array element" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "[[entity]]\n[entity.Transform]\nposition = [0, 1]\n[[entity]]\n[entity.Camera]\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    const entities = pairs[0].value.array.items;
    try std.testing.expectEqual(2, entities.len);

    try std.testing.expectEqualSlices(u8, "Transform", entities[0].table.items[0].key);
    try std.testing.expectEqual(2, entities[0].table.items[0].value.table.items[0].value.array.items.len);

    try std.testing.expectEqualSlices(u8, "Camera", entities[1].table.items[0].key);
    try std.testing.expectEqual(0, entities[1].table.items[0].value.table.items.len);
}

test "table: rejects redefining a table as an array of tables" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "[a]\n[[a]]\n");
    try std.testing.expectError(ParserError.TableRedefined, parse(&arena, tokens));
}

test "table: rejects redefining an array of tables as a table" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "[[a]]\n[a]\n");
    try std.testing.expectError(ParserError.TableRedefined, parse(&arena, tokens));
}

test "table: rejects a header naming an existing value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "a = 1\n[a]\n");
    try std.testing.expectError(ParserError.TableRedefined, parse(&arena, tokens));
}

test "table: rejects a path through a value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "a = 1\n[a.b]\n");
    try std.testing.expectError(ParserError.NotATable, parse(&arena, tokens));
}

test "table: rejects a path through an empty array" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "a = []\n[a.b]\n");
    try std.testing.expectError(ParserError.NotATable, parse(&arena, tokens));
}

test "table: rejects a path through an array of values" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "a = [1, 2]\n[a.b]\n");
    try std.testing.expectError(ParserError.NotATable, parse(&arena, tokens));
}

test "key: parses a key and its value" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "key = \"value\"";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(1, pairs.len);
    try std.testing.expectEqualSlices(u8, "key", pairs[0].key);
    try std.testing.expectEqualSlices(u8, "value", pairs[0].value.string);
}

test "key: accepts a quoted key" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "\"engine/Transform\" = \"value\"\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqualSlices(u8, "engine/Transform", pairs[0].key);
    try std.testing.expectEqualSlices(u8, "value", pairs[0].value.string);
}

test "key: rejects a key without equals" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "key key key";
    const tokens = try tokenization.tokenize(&arena, text);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(&arena, tokens));
}

test "key: rejects two assignments on one line" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "key1 = \"value1\" key2 = \"value2\"";
    const tokens = try tokenization.tokenize(&arena, text);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(&arena, tokens));
}

test "key: rejects a duplicate key" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "a = 1\na = 2\n");
    try std.testing.expectError(ParserError.DuplicateKey, parse(&arena, tokens));
}

test "key: rejects a key colliding with an existing table" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, "[a.b]\n[a]\nb = 1\n");
    try std.testing.expectError(ParserError.DuplicateKey, parse(&arena, tokens));
}

test "value: parses integers and floats" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "count = 5\nratio = 1.75\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(2, pairs.len);
    try std.testing.expectEqual(@as(i64, 5), pairs[0].value.integer);
    try std.testing.expectEqual(@as(f64, 1.75), pairs[1].value.float);
}

test "value: rejects a bare identifier" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "key = not_a_string";
    const tokens = try tokenization.tokenize(&arena, text);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(&arena, tokens));
}

test "array: parses mixed element types" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "position = [0, 1.75, \"end\"]\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    const array = pairs[0].value.array.items;
    try std.testing.expectEqual(3, array.len);
    try std.testing.expectEqual(@as(i64, 0), array[0].integer);
    try std.testing.expectEqual(@as(f64, 1.75), array[1].float);
    try std.testing.expectEqualSlices(u8, "end", array[2].string);
}

test "array: parses an empty array" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "items = []\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    try std.testing.expectEqual(0, pairs[0].value.array.items.len);
}

test "array: parses nested arrays" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "matrix = [[1, 2], [3, 4]]\n";
    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parse(&arena, tokens);

    const matrix = pairs[0].value.array.items;
    try std.testing.expectEqual(2, matrix.len);
    try std.testing.expectEqual(@as(i64, 2), matrix[0].array.items[1].integer);
    try std.testing.expectEqual(@as(i64, 3), matrix[1].array.items[0].integer);
}

test "array: rejects an unterminated array" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text = "items = [1, 2\n";
    const tokens = try tokenization.tokenize(&arena, text);

    try std.testing.expectError(ParserError.UnexpectedToken, parse(&arena, tokens));
}
