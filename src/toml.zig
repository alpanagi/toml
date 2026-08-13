const std = @import("std");

const tokenization = @import("tokenization.zig");
const parsing = @import("parsing.zig");
const mem = @import("mem.zig");

const findPair = parsing.findPair;

pub const KeyValuePair = parsing.KeyValuePair;
pub const Value = parsing.Value;

pub const TomlError = error{
    MissingField,
    TypeMismatch,
};

pub fn parseAlloc(allocator: std.mem.Allocator, comptime T: type, text: []const u8) !T {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const tokens = try tokenization.tokenize(&arena, text);
    const pairs = try parsing.parse(&arena, tokens);

    return fromValue(allocator, T, .{
        .table = std.ArrayList(KeyValuePair).fromOwnedSlice(pairs),
    });
}

pub fn parseRaw(arena: *std.heap.ArenaAllocator, text: []const u8) !Value {
    const tokens = try tokenization.tokenize(arena, text);
    const pairs = try parsing.parse(arena, tokens);

    return .{ .table = std.ArrayList(KeyValuePair).fromOwnedSlice(pairs) };
}

pub fn fromValue(allocator: std.mem.Allocator, comptime T: type, value: Value) !T {
    switch (@typeInfo(T)) {
        .int => {
            if (value != .integer) return TomlError.TypeMismatch;
            return std.math.cast(T, value.integer) orelse TomlError.TypeMismatch;
        },
        .float => switch (value) {
            .integer => |integer| return @floatFromInt(integer),
            .float => |float| return @floatCast(float),
            else => return TomlError.TypeMismatch,
        },
        .optional => |info| return try fromValue(allocator, info.child, value),
        .@"struct" => |info| {
            if (value != .table) return TomlError.TypeMismatch;

            var result: T = undefined;
            var filled: usize = 0;

            errdefer inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime and i < filled) mem.deinit(allocator, field.type, @field(result, field.name));
            };

            inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime) {
                    if (findPair(value.table.items, field.name)) |pair| {
                        @field(result, field.name) = try fromValue(allocator, field.type, pair.value);
                    } else if (field.defaultValue()) |default| {
                        @field(result, field.name) = try mem.dupe(allocator, field.type, default);
                    } else if (@typeInfo(field.type) == .optional) {
                        @field(result, field.name) = null;
                    } else {
                        return TomlError.MissingField;
                    }
                }

                filled = i + 1;
            }

            return result;
        },
        .array => |info| {
            if (value != .array) return TomlError.TypeMismatch;
            if (value.array.items.len != info.len) return TomlError.TypeMismatch;

            var result: T = undefined;
            var filled: usize = 0;

            errdefer for (result[0..filled]) |item| mem.deinit(allocator, info.child, item);

            for (value.array.items, 0..) |item, i| {
                result[i] = try fromValue(allocator, info.child, item);
                filled = i + 1;
            }

            if (comptime info.sentinel()) |sentinel| result[info.len] = sentinel;

            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return TomlError.TypeMismatch;

            switch (value) {
                .string => |string| {
                    if (info.child != u8) return TomlError.TypeMismatch;

                    if (comptime info.sentinel()) |sentinel| {
                        const result = try allocator.allocSentinel(u8, string.len, sentinel);
                        @memcpy(result, string);
                        return result;
                    }

                    return allocator.dupe(u8, string);
                },
                .array => |array| {
                    const result = if (comptime info.sentinel()) |sentinel|
                        try allocator.allocSentinel(info.child, array.items.len, sentinel)
                    else
                        try allocator.alloc(info.child, array.items.len);

                    var filled: usize = 0;

                    errdefer {
                        for (result[0..filled]) |item| mem.deinit(allocator, info.child, item);
                        allocator.free(result);
                    }

                    for (array.items, 0..) |item, i| {
                        result[i] = try fromValue(allocator, info.child, item);
                        filled = i + 1;
                    }

                    return result;
                },
                else => return TomlError.TypeMismatch,
            }
        },
        else => return TomlError.TypeMismatch,
    }
}

test "int: fills an integer field" {
    const allocator = std.testing.allocator;
    const text = "count = 5\n";

    const Config = struct {
        count: u32,
    };

    const result = try parseAlloc(allocator, Config, text);

    try std.testing.expectEqual(@as(u32, 5), result.count);
}

test "int: rejects a string value" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\ncount = \"5\"";

    const Config = struct {
        name: []const u8,
        count: u32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "int: rejects a value out of range" {
    const allocator = std.testing.allocator;
    const text = "count = -1\n";

    const Config = struct {
        count: u32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "float: fills a float field" {
    const allocator = std.testing.allocator;
    const text = "ratio = 1.75\n";

    const Config = struct {
        ratio: f32,
    };

    const result = try parseAlloc(allocator, Config, text);

    try std.testing.expectEqual(@as(f32, 1.75), result.ratio);
}

test "float: accepts an integer value" {
    const allocator = std.testing.allocator;
    const text = "scale = 2\n";

    const Config = struct {
        scale: f64,
    };

    const result = try parseAlloc(allocator, Config, text);

    try std.testing.expectEqual(@as(f64, 2), result.scale);
}

test "float: rejects a string value" {
    const allocator = std.testing.allocator;
    const text = "ratio = \"1.75\"\n";

    const Config = struct {
        ratio: f32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "optional: fills a present value" {
    const allocator = std.testing.allocator;
    const text = "[server]\nhost = \"localhost\"\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        server: ?Server,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "localhost", result.server.?.host);
}

test "optional: uses the default of a missing field" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\n";

    const Config = struct {
        name: []const u8,
        port: ?u16 = 8080,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqual(@as(?u16, 8080), result.port);
}

test "optional: missing field becomes null" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: ?Server,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqual(null, result.server);
}

test "optional: rejects a present value of the wrong type" {
    const allocator = std.testing.allocator;
    const text = "server = 5\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        server: ?Server,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "struct: fills a nested struct from a table" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\n[server]\nhost = \"localhost\"\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
}

test "struct: uses the default of a missing field" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
        version: []const u8 = "unknown",
    };

    const result = try parseAlloc(allocator, Config, text);
    defer allocator.free(result.name);
    defer allocator.free(result.version);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "unknown", result.version);
}

test "struct: uses a struct default for a missing table" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server = .{ .host = "localhost" },
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
}

test "struct: uses defaults inside a nested table" {
    const allocator = std.testing.allocator;
    const text = "[server]\nhost = \"localhost\"\n";

    const Tls = struct {
        cert: []const u8 = "none",
    };
    const Server = struct {
        host: []const u8,
        port: u16 = 8080,
        tls: Tls = .{},
    };
    const Config = struct {
        server: Server,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
    try std.testing.expectEqual(@as(u16, 8080), result.server.port);
    try std.testing.expectEqualSlices(u8, "none", result.server.tls.cert);
}

test "struct: uses defaults inside an array of tables" {
    const allocator = std.testing.allocator;
    const text = "[[mesh]]\nid = \"floor\"\n[[mesh]]\nid = \"wall\"\npath = \"assets/wall.obj\"\nscale = 2.5\n";

    const Mesh = struct {
        id: []const u8,
        path: []const u8 = "assets/default.obj",
        scale: f32 = 1.0,
        tint: [4]f32 = .{ 1, 1, 1, 1 },
        tags: [][]const u8 = &.{},
    };
    const Level = struct {
        mesh: []Mesh,
        name: []const u8 = "untitled",
    };

    const result = try parseAlloc(allocator, Level, text);
    defer mem.deinit(allocator, Level, result);

    try std.testing.expectEqualSlices(u8, "untitled", result.name);
    try std.testing.expectEqual(2, result.mesh.len);

    try std.testing.expectEqualSlices(u8, "assets/default.obj", result.mesh[0].path);
    try std.testing.expectEqual(@as(f32, 1.0), result.mesh[0].scale);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, result.mesh[0].tint);
    try std.testing.expectEqual(0, result.mesh[0].tags.len);

    try std.testing.expectEqualSlices(u8, "assets/wall.obj", result.mesh[1].path);
    try std.testing.expectEqual(@as(f32, 2.5), result.mesh[1].scale);
}

test "struct: matches a quoted key to a quoted field name" {
    const allocator = std.testing.allocator;
    const text =
        \\[[entity]]
        \\    [entity."engine/Transform"]
        \\    position = [0,1.75,0,1]
        \\    [entity."game/Health"]
        \\    "max value" = 100
        \\
    ;

    const Transform = struct {
        position: [4]f32,
    };
    const Health = struct {
        @"max value": u32,
    };
    const Entity = struct {
        @"engine/Transform": ?Transform = null,
        @"game/Health": ?Health = null,
    };
    const Level = struct {
        entity: []Entity,
    };

    const result = try parseAlloc(allocator, Level, text);
    defer mem.deinit(allocator, Level, result);

    try std.testing.expectEqual(1, result.entity.len);
    try std.testing.expectEqual(
        [4]f32{ 0, 1.75, 0, 1 },
        result.entity[0].@"engine/Transform".?.position,
    );
    try std.testing.expectEqual(@as(u32, 100), result.entity[0].@"game/Health".?.@"max value");
}

test "struct: keeps comptime fields at their declared value" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\nkind = \"ignored\"\n";

    const Config = struct {
        comptime kind: []const u8 = "static",
        name: []const u8,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "static", result.kind);
    try std.testing.expectEqualSlices(u8, "toml", result.name);
}

test "struct: rejects a non table value" {
    const allocator = std.testing.allocator;
    const text = "server = 5\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        server: Server,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "struct: rejects a missing field without a default" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
        version: []const u8,
    };

    try std.testing.expectError(TomlError.MissingField, parseAlloc(allocator, Config, text));
}

test "struct: rejects a nested table missing a required field" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\n[server]\nport = \"8080\"\n";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: Server,
    };

    try std.testing.expectError(TomlError.MissingField, parseAlloc(allocator, Config, text));
}

test "array: fills a fixed size array" {
    const allocator = std.testing.allocator;
    const text = "position = [0, 1.75, 0, 1]\n";

    const Config = struct {
        position: [4]f32,
    };

    const result = try parseAlloc(allocator, Config, text);

    try std.testing.expectEqual([4]f32{ 0, 1.75, 0, 1 }, result.position);
}

test "array: fills a sentinel terminated array" {
    const allocator = std.testing.allocator;
    const text = "values = [1, 2, 3]\n";

    const Config = struct {
        values: [3:0]i64,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, &result.values);
    try std.testing.expectEqual(0, result.values[result.values.len]);
}

test "array: rejects a non array value" {
    const allocator = std.testing.allocator;
    const text = "position = \"origin\"\n";

    const Config = struct {
        position: [4]f32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "array: rejects an array of the wrong length" {
    const allocator = std.testing.allocator;
    const text = "position = [0, 1]\n";

    const Config = struct {
        position: [4]f32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "array: frees filled elements when an element fails" {
    const allocator = std.testing.allocator;
    const text = "names = [\"a\", 5]\n";

    const Config = struct {
        names: [2][]const u8,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "slice: fills a string field" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"";

    const Config = struct {
        name: []const u8,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer allocator.free(result.name);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
}

test "slice: fills a slice of strings" {
    const allocator = std.testing.allocator;
    const text = "names = [\"a\", \"b\"]\n";

    const Config = struct {
        names: [][]const u8,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqual(2, result.names.len);
    try std.testing.expectEqualSlices(u8, "a", result.names[0]);
    try std.testing.expectEqualSlices(u8, "b", result.names[1]);
}

test "slice: fills a slice of structs from an array of tables" {
    const allocator = std.testing.allocator;
    const text = "[[mesh]]\nid = \"floor\"\n[[mesh]]\nid = \"wall\"\n";

    const Mesh = struct {
        id: []const u8,
    };
    const Config = struct {
        mesh: []Mesh,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqual(2, result.mesh.len);
    try std.testing.expectEqualSlices(u8, "floor", result.mesh[0].id);
    try std.testing.expectEqualSlices(u8, "wall", result.mesh[1].id);
}

test "slice: fills an empty slice from an empty array" {
    const allocator = std.testing.allocator;
    const text = "names = []\n";

    const Config = struct {
        names: [][]const u8,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqual(0, result.names.len);
}

test "slice: fills a sentinel terminated string field" {
    const allocator = std.testing.allocator;
    const text = "name = \"toml\"\n";

    const Config = struct {
        name: [:0]const u8,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqual(0, result.name[result.name.len]);
}

test "slice: fills a sentinel terminated slice" {
    const allocator = std.testing.allocator;
    const text = "values = [1, 2, 3]\n";

    const Config = struct {
        values: [:0]const i64,
    };

    const result = try parseAlloc(allocator, Config, text);
    defer mem.deinit(allocator, Config, result);

    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, result.values);
    try std.testing.expectEqual(0, result.values[result.values.len]);
}

test "slice: rejects a string for a non byte slice" {
    const allocator = std.testing.allocator;
    const text = "ratios = \"1.75\"\n";

    const Config = struct {
        ratios: []f32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "slice: rejects a non array value" {
    const allocator = std.testing.allocator;
    const text = "names = 5\n";

    const Config = struct {
        names: [][]const u8,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "slice: frees filled elements when an element fails" {
    const allocator = std.testing.allocator;
    const text = "names = [\"a\", 5]\n";

    const Config = struct {
        names: [][]const u8,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parseAlloc(allocator, Config, text));
}

test "parseAlloc: parses a document" {
    const allocator = std.testing.allocator;
    const text =
        \\[[mesh]]
        \\id = "floor"
        \\path = "assets/meshes/floor.obj"
        \\
        \\[[entity]]
        \\    [entity.Transform]
        \\    position = [0,0,0,1]
        \\    [entity.Mesh]
        \\    id = "floor"
        \\
        \\[[entity]]
        \\    [entity.Camera]
        \\    [entity.Transform]
        \\    position = [0,1.75,0,1]
        \\    [entity.Active]
        \\
    ;

    const MeshAsset = struct {
        id: []const u8,
        path: []const u8,
    };
    const Transform = struct {
        position: [4]f32,
    };
    const MeshComponent = struct {
        id: []const u8,
    };
    const Camera = struct {};
    const Active = struct {};
    const Entity = struct {
        Transform: ?Transform = null,
        Mesh: ?MeshComponent = null,
        Camera: ?Camera = null,
        Active: ?Active = null,
    };
    const Level = struct {
        mesh: []MeshAsset,
        entity: []Entity,
    };

    const result = try parseAlloc(allocator, Level, text);
    defer mem.deinit(allocator, Level, result);

    try std.testing.expectEqual(1, result.mesh.len);
    try std.testing.expectEqualSlices(u8, "floor", result.mesh[0].id);
    try std.testing.expectEqualSlices(u8, "assets/meshes/floor.obj", result.mesh[0].path);

    try std.testing.expectEqual(2, result.entity.len);

    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, result.entity[0].Transform.?.position);
    try std.testing.expectEqualSlices(u8, "floor", result.entity[0].Mesh.?.id);
    try std.testing.expectEqual(null, result.entity[0].Camera);
    try std.testing.expectEqual(null, result.entity[0].Active);

    try std.testing.expectEqual([4]f32{ 0, 1.75, 0, 1 }, result.entity[1].Transform.?.position);
    try std.testing.expectEqual(null, result.entity[1].Mesh);
    try std.testing.expect(result.entity[1].Camera != null);
    try std.testing.expect(result.entity[1].Active != null);
}

test "parseRaw: returns the root as a table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const root = try parseRaw(&arena, "name = \"toml\"\ncount = 5\n");

    try std.testing.expectEqual(2, root.table.items.len);
    try std.testing.expectEqualSlices(u8, "toml", findPair(root.table.items, "name").?.value.string);
    try std.testing.expectEqual(5, findPair(root.table.items, "count").?.value.integer);
}

test "parseRaw: keeps nested tables and arrays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const text = "[server]\nhost = \"localhost\"\nports = [80, 443]\n";
    const root = try parseRaw(&arena, text);

    const server = findPair(root.table.items, "server").?.value;
    try std.testing.expectEqualSlices(u8, "localhost", findPair(server.table.items, "host").?.value.string);

    const ports = findPair(server.table.items, "ports").?.value.array.items;
    try std.testing.expectEqual(2, ports.len);
    try std.testing.expectEqual(443, ports[1].integer);
}

test "parseRaw: fills a type from a value the caller selects" {
    const allocator = std.testing.allocator;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const text =
        \\[[entity]]
        \\    [entity.Transform]
        \\    position = [0,1.75,0,1]
        \\
    ;

    const Transform = struct { position: [4]f32 };

    const root = try parseRaw(&arena, text);
    const entities = findPair(root.table.items, "entity").?.value.array.items;
    const component = findPair(entities[0].table.items, "Transform").?;

    const transform = try fromValue(allocator, Transform, component.value);
    defer mem.deinit(allocator, Transform, transform);

    try std.testing.expectEqual([4]f32{ 0, 1.75, 0, 1 }, transform.position);
}
