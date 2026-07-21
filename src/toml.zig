const std = @import("std");

const tokenization = @import("tokenization.zig");
const parsing = @import("parsing.zig");

const TomlError = error{
    MissingField,
    TypeMismatch,
};

pub fn parse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) !T {
    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var parsed_data_container = try parsing.parse(alloc, token_container.tokens);
    defer parsed_data_container.deinit(alloc);

    return fillStruct(T, alloc, parsed_data_container.key_value_pairs);
}

fn fillStruct(comptime T: type, alloc: std.mem.Allocator, pairs: []const parsing.KeyValuePair) !T {
    var result: T = undefined;
    var filled: usize = 0;

    errdefer inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (i < filled) {
            if (field.type == []const u8) {
                alloc.free(@field(result, field.name));
            } else if (@typeInfo(field.type) == .@"struct") {
                deinit(field.type, alloc, @field(result, field.name));
            }
        }
    };

    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        var found_entry: ?*const parsing.KeyValuePair = null;
        for (pairs) |*candidate| {
            if (std.mem.eql(u8, candidate.key, field.name)) {
                found_entry = candidate;
                break;
            }
        }

        if (found_entry) |entry| {
            if (field.type == []const u8) {
                if (entry.value != .string) return TomlError.TypeMismatch;

                @field(result, field.name) = try alloc.dupe(u8, entry.value.string);
            } else if (@typeInfo(field.type) == .@"struct") {
                if (entry.value != .table) return TomlError.TypeMismatch;

                @field(result, field.name) = try fillStruct(field.type, alloc, entry.value.table);
            } else {
                return TomlError.TypeMismatch;
            }
        } else if (field.defaultValue()) |default| {
            @field(result, field.name) = try dupeValue(field.type, alloc, default);
        } else {
            return TomlError.MissingField;
        }

        filled = i + 1;
    }

    return result;
}

fn dupeValue(comptime T: type, alloc: std.mem.Allocator, value: T) !T {
    if (T == []const u8) {
        return alloc.dupe(u8, value);
    }

    if (@typeInfo(T) != .@"struct") return value;

    var result: T = undefined;
    var filled: usize = 0;

    errdefer inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (i < filled) {
            if (field.type == []const u8) {
                alloc.free(@field(result, field.name));
            } else if (@typeInfo(field.type) == .@"struct") {
                deinit(field.type, alloc, @field(result, field.name));
            }
        }
    };

    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        @field(result, field.name) = try dupeValue(field.type, alloc, @field(value, field.name));
        filled = i + 1;
    }

    return result;
}

pub fn deinit(comptime T: type, alloc: std.mem.Allocator, value: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (field.type == []const u8) {
            alloc.free(@field(value, field.name));
        } else if (@typeInfo(field.type) == .@"struct") {
            deinit(field.type, alloc, @field(value, field.name));
        }
    }
}

test "Parse into struct" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
    };

    const result = try parse(Config, alloc, text);
    defer alloc.free(result.name);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
}

test "Missing field uses default" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
        version: []const u8 = "unknown",
    };

    const result = try parse(Config, alloc, text);
    defer alloc.free(result.name);
    defer alloc.free(result.version);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "unknown", result.version);
}

test "Missing field without default returns error" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
        version: []const u8,
    };

    try std.testing.expectError(TomlError.MissingField, parse(Config, alloc, text));
}

test "Type mismatch returns error" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"\ncount = \"5\"";

    const Config = struct {
        name: []const u8,
        count: u32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parse(Config, alloc, text));
}

test "Nested table fills nested struct" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"\n[server]\nhost = \"localhost\"\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server,
    };

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
}

test "Missing table uses struct default" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server = .{ .host = "localhost" },
    };

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
}

test "Table with missing required field returns error" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"\n[server]\nport = \"8080\"\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server,
    };

    try std.testing.expectError(TomlError.MissingField, parse(Config, alloc, text));
}
