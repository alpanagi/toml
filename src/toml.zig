const std = @import("std");

const tokenization = @import("tokenization.zig");
const parsing = @import("parsing.zig");

const TomlError = error{
    UnknownKey,
};

pub fn parse(comptime T: type, alloc: std.mem.Allocator, text: []const u8) !T {
    var token_container = try tokenization.tokenize(alloc, text);
    defer token_container.deinit(alloc);

    var parsed_data_container = try parsing.parse(alloc, token_container.tokens);
    defer parsed_data_container.deinit(alloc);

    for (parsed_data_container.items) |item| {
        switch (item.kind) {
            .key_value => {
                const key_value = item.value.?.key_value;
                var matched = false;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, key_value.key)) {
                        matched = true;
                        break;
                    }
                }

                if (!matched) {
                    return TomlError.UnknownKey;
                }
            },
        }
    }

    var result: T = undefined;
    for (parsed_data_container.items) |item| {
        switch (item.kind) {
            .key_value => {
                const key_value = item.value.?.key_value;
                inline for (@typeInfo(T).@"struct".fields) |field| {
                    if (std.mem.eql(u8, field.name, key_value.key)) {
                        @field(result, field.name) = try alloc.dupe(u8, key_value.value);
                        break;
                    }
                }
            },
        }
    }

    return result;
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

test "Unknown key" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        version: []const u8,
    };

    try std.testing.expectError(TomlError.UnknownKey, parse(Config, alloc, text));
}
