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

    return fillValue(T, alloc, .{ .table = parsed_data_container.key_value_pairs });
}

fn fillValue(comptime T: type, alloc: std.mem.Allocator, value: parsing.Value) !T {
    if (T == []const u8) {
        if (value != .string) return TomlError.TypeMismatch;
        return alloc.dupe(u8, value.string);
    }

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
        .optional => |info| return try fillValue(info.child, alloc, value),
        .@"struct" => |info| {
            if (value != .table) return TomlError.TypeMismatch;

            var result: T = undefined;
            var filled: usize = 0;

            errdefer inline for (info.fields, 0..) |field, i| {
                if (i < filled) deinit(field.type, alloc, @field(result, field.name));
            };

            inline for (info.fields, 0..) |field, i| {
                if (findPair(value.table, field.name)) |pair| {
                    @field(result, field.name) = try fillValue(field.type, alloc, pair.value);
                } else if (field.defaultValue()) |default| {
                    @field(result, field.name) = try dupeValue(field.type, alloc, default);
                } else if (@typeInfo(field.type) == .optional) {
                    @field(result, field.name) = null;
                } else {
                    return TomlError.MissingField;
                }

                filled = i + 1;
            }

            return result;
        },
        .array => |info| {
            if (value != .array) return TomlError.TypeMismatch;
            if (value.array.len != info.len) return TomlError.TypeMismatch;

            var result: T = undefined;
            var filled: usize = 0;

            errdefer for (result[0..filled]) |item| deinit(info.child, alloc, item);

            for (value.array, 0..) |item, i| {
                result[i] = try fillValue(info.child, alloc, item);
                filled = i + 1;
            }

            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return TomlError.TypeMismatch;
            if (value != .array) return TomlError.TypeMismatch;

            const result = try alloc.alloc(info.child, value.array.len);
            var filled: usize = 0;

            errdefer {
                for (result[0..filled]) |item| deinit(info.child, alloc, item);
                alloc.free(result);
            }

            for (value.array, 0..) |item, i| {
                result[i] = try fillValue(info.child, alloc, item);
                filled = i + 1;
            }

            return result;
        },
        else => return TomlError.TypeMismatch,
    }
}

fn findPair(pairs: []const parsing.KeyValuePair, key: []const u8) ?*const parsing.KeyValuePair {
    for (pairs) |*pair| {
        if (std.mem.eql(u8, pair.key, key)) return pair;
    }
    return null;
}

fn dupeValue(comptime T: type, alloc: std.mem.Allocator, value: T) !T {
    if (T == []const u8) return alloc.dupe(u8, value);

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |inner| return try dupeValue(info.child, alloc, inner);
            return null;
        },
        .@"struct" => |info| {
            var result: T = undefined;
            var filled: usize = 0;

            errdefer inline for (info.fields, 0..) |field, i| {
                if (i < filled) deinit(field.type, alloc, @field(result, field.name));
            };

            inline for (info.fields, 0..) |field, i| {
                @field(result, field.name) = try dupeValue(field.type, alloc, @field(value, field.name));
                filled = i + 1;
            }

            return result;
        },
        .array => |info| {
            var result: T = undefined;
            var filled: usize = 0;

            errdefer for (result[0..filled]) |item| deinit(info.child, alloc, item);

            for (value, 0..) |item, i| {
                result[i] = try dupeValue(info.child, alloc, item);
                filled = i + 1;
            }

            return result;
        },
        .pointer => |info| {
            if (info.size != .slice) return value;

            const result = try alloc.alloc(info.child, value.len);
            var filled: usize = 0;

            errdefer {
                for (result[0..filled]) |item| deinit(info.child, alloc, item);
                alloc.free(result);
            }

            for (value, 0..) |item, i| {
                result[i] = try dupeValue(info.child, alloc, item);
                filled = i + 1;
            }

            return result;
        },
        else => return value,
    }
}

pub fn deinit(comptime T: type, alloc: std.mem.Allocator, value: T) void {
    if (T == []const u8) return alloc.free(value);

    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |inner| deinit(info.child, alloc, inner);
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            deinit(field.type, alloc, @field(value, field.name));
        },
        .array => |info| for (value) |item| deinit(info.child, alloc, item),
        .pointer => |info| {
            if (info.size != .slice) return;

            for (value) |item| deinit(info.child, alloc, item);
            alloc.free(value);
        },
        else => {},
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

test "Numbers fill numeric fields" {
    const alloc = std.testing.allocator;
    const text = "count = 5\nratio = 1.75\nscale = 2\n";

    const Config = struct {
        count: u32,
        ratio: f32,
        scale: f64,
    };

    const result = try parse(Config, alloc, text);

    try std.testing.expectEqual(@as(u32, 5), result.count);
    try std.testing.expectEqual(@as(f32, 1.75), result.ratio);
    try std.testing.expectEqual(@as(f64, 2), result.scale);
}

test "Number out of range returns error" {
    const alloc = std.testing.allocator;
    const text = "count = -1\n";

    const Config = struct {
        count: u32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parse(Config, alloc, text));
}

test "Array fills a fixed size array" {
    const alloc = std.testing.allocator;
    const text = "position = [0, 1.75, 0, 1]\n";

    const Config = struct {
        position: [4]f32,
    };

    const result = try parse(Config, alloc, text);

    try std.testing.expectEqual([4]f32{ 0, 1.75, 0, 1 }, result.position);
}

test "Array of the wrong length returns error" {
    const alloc = std.testing.allocator;
    const text = "position = [0, 1]\n";

    const Config = struct {
        position: [4]f32,
    };

    try std.testing.expectError(TomlError.TypeMismatch, parse(Config, alloc, text));
}

test "Array fills a slice" {
    const alloc = std.testing.allocator;
    const text = "names = [\"a\", \"b\"]\n";

    const Config = struct {
        names: [][]const u8,
    };

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqual(2, result.names.len);
    try std.testing.expectEqualSlices(u8, "a", result.names[0]);
    try std.testing.expectEqualSlices(u8, "b", result.names[1]);
}

test "Missing optional field becomes null" {
    const alloc = std.testing.allocator;
    const text = "name = \"toml\"";

    const Server = struct {
        host: []const u8,
    };
    const Config = struct {
        name: []const u8,
        server: ?Server,
    };

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqualSlices(u8, "toml", result.name);
    try std.testing.expectEqual(null, result.server);
}

test "Array of tables fills a slice of structs" {
    const alloc = std.testing.allocator;
    const text = "[[mesh]]\nid = \"floor\"\n[[mesh]]\nid = \"wall\"\n";

    const Mesh = struct {
        id: []const u8,
    };
    const Config = struct {
        mesh: []Mesh,
    };

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqual(2, result.mesh.len);
    try std.testing.expectEqualSlices(u8, "floor", result.mesh[0].id);
    try std.testing.expectEqualSlices(u8, "wall", result.mesh[1].id);
}

test "Omitted fields use defaults inside an array of tables" {
    const alloc = std.testing.allocator;
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

    const result = try parse(Level, alloc, text);
    defer deinit(Level, alloc, result);

    try std.testing.expectEqualSlices(u8, "untitled", result.name);
    try std.testing.expectEqual(2, result.mesh.len);

    try std.testing.expectEqualSlices(u8, "assets/default.obj", result.mesh[0].path);
    try std.testing.expectEqual(@as(f32, 1.0), result.mesh[0].scale);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, result.mesh[0].tint);
    try std.testing.expectEqual(0, result.mesh[0].tags.len);

    try std.testing.expectEqualSlices(u8, "assets/wall.obj", result.mesh[1].path);
    try std.testing.expectEqual(@as(f32, 2.5), result.mesh[1].scale);
}

test "Omitted fields use defaults inside a nested table" {
    const alloc = std.testing.allocator;
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

    const result = try parse(Config, alloc, text);
    defer deinit(Config, alloc, result);

    try std.testing.expectEqualSlices(u8, "localhost", result.server.host);
    try std.testing.expectEqual(@as(u16, 8080), result.server.port);
    try std.testing.expectEqualSlices(u8, "none", result.server.tls.cert);
}

test "Quoted keys fill quoted field names" {
    const alloc = std.testing.allocator;
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

    const result = try parse(Level, alloc, text);
    defer deinit(Level, alloc, result);

    try std.testing.expectEqual(1, result.entity.len);
    try std.testing.expectEqual(
        [4]f32{ 0, 1.75, 0, 1 },
        result.entity[0].@"engine/Transform".?.position,
    );
    try std.testing.expectEqual(@as(u32, 100), result.entity[0].@"game/Health".?.@"max value");
}

test "Level file" {
    const alloc = std.testing.allocator;
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

    const result = try parse(Level, alloc, text);
    defer deinit(Level, alloc, result);

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
