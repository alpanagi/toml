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

    var result: T = undefined;

    var allocated = std.ArrayList([]const u8).empty;
    defer allocated.deinit(alloc);
    errdefer for (allocated.items) |item| alloc.free(item);

    const fields = @typeInfo(T).@"struct".fields;
    try allocated.ensureTotalCapacity(alloc, fields.len);

    inline for (fields) |field| {
        var found = false;

        for (parsed_data_container.items) |item| {
            switch (item.kind) {
                .key_value => {
                    const key_value = item.value.?.key_value;
                    if (std.mem.eql(u8, field.name, key_value.key)) {
                        switch (field.type) {
                            []const u8 => {
                                const duped = try alloc.dupe(u8, key_value.value);
                                allocated.appendAssumeCapacity(duped);
                                @field(result, field.name) = duped;
                            },
                            else => return TomlError.TypeMismatch,
                        }
                        found = true;
                        break;
                    }
                },
            }
        }

        if (!found) {
            if (field.defaultValue()) |default| {
                switch (field.type) {
                    []const u8 => {
                        const duped = try alloc.dupe(u8, default);
                        allocated.appendAssumeCapacity(duped);
                        @field(result, field.name) = duped;
                    },
                    else => @field(result, field.name) = default,
                }
            } else {
                return TomlError.MissingField;
            }
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

    const result = parse(Config, alloc, text);
    if (result) |value| {
        alloc.free(value.name);
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(TomlError.MissingField, err);
    }
}

test "Type mismatch returns error" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"\ncount = \"5\"";

    const Config = struct {
        name: []const u8,
        count: u32,
    };

    const result = parse(Config, alloc, text);
    if (result) |value| {
        alloc.free(value.name);
        return error.TestUnexpectedSuccess;
    } else |err| {
        try std.testing.expectEqual(TomlError.TypeMismatch, err);
    }
}
