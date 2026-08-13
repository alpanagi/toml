const std = @import("std");

pub fn dupe(allocator: std.mem.Allocator, comptime T: type, value: T) std.mem.Allocator.Error!T {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |inner| return try dupe(allocator, info.child, inner);
            return null;
        },
        .error_union => |info| {
            if (value) |payload| {
                return @as(T, try dupe(allocator, info.payload, payload));
            } else |err| {
                return @as(T, err);
            }
        },
        .@"struct" => |info| {
            var result: T = undefined;
            var filled: usize = 0;

            errdefer inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime and i < filled) deinit(allocator, field.type, @field(result, field.name));
            };

            inline for (info.fields, 0..) |field, i| {
                if (!field.is_comptime) {
                    @field(result, field.name) = try dupe(allocator, field.type, @field(value, field.name));
                }
                filled = i + 1;
            }

            return result;
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("mem.dupe: cannot copy untagged union " ++ @typeName(T));
            switch (value) {
                inline else => |payload, tag| return @unionInit(T, @tagName(tag), try dupe(allocator, @TypeOf(payload), payload)),
            }
        },
        .array => |info| {
            var result: T = undefined;
            var filled: usize = 0;

            errdefer for (result[0..filled]) |item| deinit(allocator, info.child, item);

            for (value, 0..) |item, i| {
                result[i] = try dupe(allocator, info.child, item);
                filled = i + 1;
            }

            return result;
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                const result = if (comptime info.sentinel()) |sentinel|
                    try allocator.allocSentinel(info.child, value.len, sentinel)
                else
                    try allocator.alloc(info.child, value.len);

                var filled: usize = 0;

                errdefer {
                    for (result[0..filled]) |item| deinit(allocator, info.child, item);
                    allocator.free(result);
                }

                for (value, 0..) |item, i| {
                    result[i] = try dupe(allocator, info.child, item);
                    filled = i + 1;
                }

                return result;
            },
            .one => {
                const result = try allocator.create(info.child);
                errdefer allocator.destroy(result);

                result.* = try dupe(allocator, info.child, value.*);
                return result;
            },
            .many, .c => @compileError("mem.dupe: cannot copy " ++ @typeName(T) ++ " (unknown length)"),
        },
        .vector => |vector| if (@typeInfo(vector.child) == .pointer)
            @compileError("mem.dupe: cannot copy " ++ @typeName(T))
        else
            return value,
        .frame, .@"anyframe" => @compileError("mem.dupe: cannot copy " ++ @typeName(T)),
        .type, .void, .bool, .noreturn, .int, .float, .comptime_float, .comptime_int, .undefined, .null, .error_set, .@"enum", .@"fn", .@"opaque", .enum_literal => return value,
    }
}

pub fn deinit(allocator: std.mem.Allocator, comptime T: type, value: T) void {
    switch (@typeInfo(T)) {
        .optional => |info| {
            if (value) |inner| deinit(allocator, info.child, inner);
        },
        .error_union => |info| {
            if (value) |payload| deinit(allocator, info.payload, payload) else |_| {}
        },
        .@"struct" => |info| inline for (info.fields) |field| {
            if (!field.is_comptime) deinit(allocator, field.type, @field(value, field.name));
        },
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("mem.deinit: cannot free untagged union " ++ @typeName(T));
            switch (value) {
                inline else => |payload| deinit(allocator, @TypeOf(payload), payload),
            }
        },
        .array => |info| for (value) |item| deinit(allocator, info.child, item),
        .pointer => |info| switch (info.size) {
            .slice => {
                for (value) |item| deinit(allocator, info.child, item);
                allocator.free(value);
            },
            .one => {
                deinit(allocator, info.child, value.*);
                allocator.destroy(value);
            },
            .many, .c => @compileError("mem.deinit: cannot free " ++ @typeName(T) ++ " (unknown length)"),
        },
        .vector => |vector| if (@typeInfo(vector.child) == .pointer)
            @compileError("mem.deinit: cannot free " ++ @typeName(T)),
        .frame, .@"anyframe" => @compileError("mem.deinit: cannot free " ++ @typeName(T)),
        .type, .void, .bool, .noreturn, .int, .float, .comptime_float, .comptime_int, .undefined, .null, .error_set, .@"enum", .@"fn", .@"opaque", .enum_literal => {},
    }
}

test "dupe: copies an optional payload" {
    const allocator = std.testing.allocator;

    const copy = try dupe(allocator, ?[]const u8, "present");
    defer deinit(allocator, ?[]const u8, copy);

    try std.testing.expectEqualSlices(u8, "present", copy.?);
    try std.testing.expectEqual(null, try dupe(allocator, ?[]const u8, null));
}

test "dupe: copies an error union payload" {
    const allocator = std.testing.allocator;

    const copy = try dupe(allocator, anyerror![]const u8, "payload");
    defer deinit(allocator, anyerror![]const u8, copy);

    try std.testing.expectEqualSlices(u8, "payload", try copy);
    try std.testing.expectError(error.Missing, try dupe(allocator, anyerror![]const u8, error.Missing));
}

test "dupe: copies struct fields" {
    const allocator = std.testing.allocator;
    const Config = struct {
        name: []const u8,
        port: u16,
        host: ?[]const u8,
    };

    const original: Config = .{ .name = "toml", .port = 8080, .host = "localhost" };

    const copy = try dupe(allocator, Config, original);
    defer deinit(allocator, Config, copy);

    try std.testing.expectEqualSlices(u8, "toml", copy.name);
    try std.testing.expect(copy.name.ptr != original.name.ptr);
    try std.testing.expectEqual(8080, copy.port);
    try std.testing.expect(copy.host.?.ptr != original.host.?.ptr);
}

test "dupe: copies the active union payload" {
    const allocator = std.testing.allocator;
    const Setting = union(enum) {
        name: []const u8,
        port: u16,
        unset,
    };

    const original: Setting = .{ .name = "owning" };

    const copy = try dupe(allocator, Setting, original);
    defer deinit(allocator, Setting, copy);

    try std.testing.expectEqualSlices(u8, "owning", copy.name);
    try std.testing.expect(copy.name.ptr != original.name.ptr);

    try std.testing.expectEqual(8080, (try dupe(allocator, Setting, .{ .port = 8080 })).port);
    try std.testing.expectEqual(Setting.unset, try dupe(allocator, Setting, .unset));
}

test "dupe: copies array elements" {
    const allocator = std.testing.allocator;

    const original: [2][]const u8 = .{ "first", "second" };

    const copy = try dupe(allocator, [2][]const u8, original);
    defer deinit(allocator, [2][]const u8, copy);

    try std.testing.expectEqualSlices(u8, "first", copy[0]);
    try std.testing.expectEqualSlices(u8, "second", copy[1]);
    try std.testing.expect(copy[0].ptr != original[0].ptr);
}

test "dupe: copies a slice and its elements" {
    const allocator = std.testing.allocator;

    const original: []const []const u8 = &.{ "first", "second" };

    const copy = try dupe(allocator, []const []const u8, original);
    defer deinit(allocator, []const []const u8, copy);

    try std.testing.expectEqual(2, copy.len);
    try std.testing.expectEqualSlices(u8, "first", copy[0]);
    try std.testing.expect(copy.ptr != original.ptr);
    try std.testing.expect(copy[0].ptr != original[0].ptr);
}

test "dupe: copies a sentinel terminated slice" {
    const allocator = std.testing.allocator;

    const original: [:0]const u8 = "sentinel";

    const copy = try dupe(allocator, [:0]const u8, original);
    defer deinit(allocator, [:0]const u8, copy);

    try std.testing.expectEqualSlices(u8, "sentinel", copy);
    try std.testing.expectEqual(0, copy[copy.len]);
    try std.testing.expect(copy.ptr != original.ptr);
}

test "dupe: copies a single item pointer and its contents" {
    const allocator = std.testing.allocator;
    const Node = struct { name: []const u8 };

    var original: Node = .{ .name = "node" };

    const copy = try dupe(allocator, *Node, &original);
    defer deinit(allocator, *Node, copy);

    try std.testing.expect(copy != &original);
    try std.testing.expectEqualSlices(u8, "node", copy.name);
    try std.testing.expect(copy.name.ptr != original.name.ptr);
}

test "dupe: copies a const single item pointer" {
    const allocator = std.testing.allocator;
    const Node = struct { name: []const u8 };

    const original: Node = .{ .name = "node" };

    const copy = try dupe(allocator, *const Node, &original);
    defer deinit(allocator, *const Node, copy);

    try std.testing.expectEqualSlices(u8, "node", copy.name);
    try std.testing.expect(copy.name.ptr != original.name.ptr);
}

test "dupe: copies nested structures" {
    const allocator = std.testing.allocator;
    const Entry = struct { key: []const u8, values: []const []const u8 };
    const Document = struct { entries: []const Entry, name: []const u8, tags: [2][]const u8 };

    const original: Document = .{
        .name = "document",
        .tags = .{ "first", "second" },
        .entries = &.{
            .{ .key = "a", .values = &.{ "a1", "a2" } },
            .{ .key = "b", .values = &.{"b1"} },
        },
    };

    const copy = try dupe(allocator, Document, original);
    defer deinit(allocator, Document, copy);

    try std.testing.expectEqual(2, copy.entries.len);
    try std.testing.expectEqualSlices(u8, "a2", copy.entries[0].values[1]);
    try std.testing.expect(copy.entries.ptr != original.entries.ptr);
    try std.testing.expect(copy.entries[0].values[1].ptr != original.entries[0].values[1].ptr);
}

test "dupe: frees everything when an allocation fails" {
    const Entry = struct { key: []const u8, values: []const []const u8 };
    const Document = struct {
        entries: []const Entry,
        name: []const u8,
        tags: [2][]const u8,
        label: [:0]const u8,
        link: *const Entry,
    };

    const roundTrip = struct {
        fn run(allocator: std.mem.Allocator, original: Document) !void {
            const copy = try dupe(allocator, Document, original);
            deinit(allocator, Document, copy);
        }
    }.run;

    const target: Entry = .{ .key = "target", .values = &.{"t1"} };
    const original: Document = .{
        .name = "document",
        .tags = .{ "first", "second" },
        .label = "label",
        .link = &target,
        .entries = &.{
            .{ .key = "a", .values = &.{ "a1", "a2" } },
            .{ .key = "b", .values = &.{"b1"} },
        },
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, roundTrip, .{original});
}

test "dupe: copies a recursive type" {
    const allocator = std.testing.allocator;
    const Node = struct {
        name: []const u8,
        next: ?*const @This(),
    };

    const tail: Node = .{ .name = "tail", .next = null };
    const head: Node = .{ .name = "head", .next = &tail };

    const copy = try dupe(allocator, Node, head);
    defer deinit(allocator, Node, copy);

    try std.testing.expectEqualSlices(u8, "head", copy.name);
    try std.testing.expectEqualSlices(u8, "tail", copy.next.?.name);
    try std.testing.expect(copy.next.? != &tail);
    try std.testing.expect(copy.next.?.name.ptr != tail.name.ptr);
}

test "dupe: skips comptime fields" {
    const allocator = std.testing.allocator;
    const Tagged = struct {
        comptime label: []const u8 = "static",
        name: []const u8,
    };

    const copy = try dupe(allocator, Tagged, .{ .name = "name" });
    defer deinit(allocator, Tagged, copy);

    try std.testing.expectEqualSlices(u8, "static", copy.label);
    try std.testing.expectEqualSlices(u8, "name", copy.name);
}

test "dupe: passes through types that own nothing" {
    const allocator = std.testing.allocator;

    try std.testing.expectEqual(5, try dupe(allocator, u32, 5));
    try std.testing.expectEqual(1.75, try dupe(allocator, f64, 1.75));
    try std.testing.expectEqual(true, try dupe(allocator, bool, true));
    try std.testing.expectEqual({}, try dupe(allocator, void, {}));
    try std.testing.expectEqual(@Vector(3, f32){ 1, 2, 3 }, try dupe(allocator, @Vector(3, f32), .{ 1, 2, 3 }));
}

test "deinit: frees an optional payload" {
    const allocator = std.testing.allocator;

    const present: ?[]const u8 = try allocator.dupe(u8, "present");
    deinit(allocator, ?[]const u8, present);

    deinit(allocator, ?[]const u8, null);
}

test "deinit: frees an error union payload" {
    const allocator = std.testing.allocator;

    const payload: anyerror![]const u8 = try allocator.dupe(u8, "payload");
    deinit(allocator, anyerror![]const u8, payload);

    deinit(allocator, anyerror![]const u8, error.Missing);
}

test "deinit: frees struct fields" {
    const allocator = std.testing.allocator;
    const Config = struct {
        name: []const u8,
        port: u16,
        host: ?[]const u8,
    };

    const config: Config = .{
        .name = try allocator.dupe(u8, "toml"),
        .port = 8080,
        .host = try allocator.dupe(u8, "localhost"),
    };

    deinit(allocator, Config, config);
}

test "deinit: frees the active union payload" {
    const allocator = std.testing.allocator;
    const Setting = union(enum) {
        name: []const u8,
        port: u16,
        unset,
    };

    const owning: Setting = .{ .name = try allocator.dupe(u8, "owning") };
    deinit(allocator, Setting, owning);

    deinit(allocator, Setting, .{ .port = 8080 });
    deinit(allocator, Setting, .unset);
}

test "deinit: frees array elements" {
    const allocator = std.testing.allocator;

    const items: [2][]const u8 = .{
        try allocator.dupe(u8, "first"),
        try allocator.dupe(u8, "second"),
    };

    deinit(allocator, [2][]const u8, items);
}

test "deinit: frees a slice and its elements" {
    const allocator = std.testing.allocator;

    const items = try allocator.alloc([]const u8, 2);
    items[0] = try allocator.dupe(u8, "first");
    items[1] = try allocator.dupe(u8, "second");

    deinit(allocator, [][]const u8, items);
}

test "deinit: frees a sentinel terminated slice" {
    const allocator = std.testing.allocator;

    const text = try allocator.dupeZ(u8, "sentinel");
    deinit(allocator, [:0]u8, text);
}

test "deinit: frees a single item pointer and its contents" {
    const allocator = std.testing.allocator;
    const Node = struct { name: []const u8 };

    const node = try allocator.create(Node);
    node.* = .{ .name = try allocator.dupe(u8, "node") };

    deinit(allocator, *Node, node);
}

test "deinit: ignores types that own nothing" {
    const allocator = std.testing.allocator;

    deinit(allocator, u32, 5);
    deinit(allocator, f64, 1.75);
    deinit(allocator, bool, true);
    deinit(allocator, void, {});
    deinit(allocator, enum { first, second }, .first);
    deinit(allocator, anyerror, error.Missing);
    deinit(allocator, @Vector(3, f32), .{ 1, 2, 3 });
}
