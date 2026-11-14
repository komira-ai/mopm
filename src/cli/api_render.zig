//! The text of a registry answer for people: a JSON value as indented `key: value` lines.
//!
//!   an object          one `key: value` line per key, in the order of the JSON; null values are left out
//!   a nested object    `key:` and its lines indented two more spaces; an empty one is `key: {}`
//!   an array of scalars `key: a, b, c`; an empty array is `key: (none)`
//!   an array of objects `key:` and each object as `  - first_key: v`, its other keys indented four spaces
//!   a string           as it is; a number or a bool as JSON writes it
//!   a top-level scalar one line

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const Writer = std.ArrayList(u8).Writer;

/// `value` as text, every line ending in a newline.
pub fn render(arena: Allocator, value: Value) Allocator.Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    switch (value) {
        .object => |o| try writeObject(arena, w, o, 0),
        .array => |a| {
            if (countNonNull(a.items) == 0) {
                try w.writeAll("(none)\n");
            } else if (allScalars(a.items)) {
                try writeJoined(w, a.items);
                try w.writeByte('\n');
            } else {
                try writeItems(arena, w, a.items, 0);
            }
        },
        else => {
            try writeScalar(w, value);
            try w.writeByte('\n');
        },
    }
    return out.items;
}

fn isScalar(v: Value) bool {
    return switch (v) {
        .object, .array, .null => false,
        else => true,
    };
}

fn countNonNull(items: []const Value) usize {
    var n: usize = 0;
    for (items) |v| {
        if (v != .null) n += 1;
    }
    return n;
}

fn allScalars(items: []const Value) bool {
    for (items) |v| {
        if (v != .null and !isScalar(v)) return false;
    }
    return true;
}

fn countNonNullEntries(o: std.json.ObjectMap) usize {
    var n: usize = 0;
    for (o.values()) |v| {
        if (v != .null) n += 1;
    }
    return n;
}

fn writeScalar(w: Writer, v: Value) Allocator.Error!void {
    switch (v) {
        .string => |s| try w.writeAll(s),
        .number_string => |s| try w.writeAll(s),
        // std.json writes a float in scientific notation (`1.5e0`); text reads better as the plain decimal.
        .float => |f| try w.print("{d}", .{f}),
        else => try std.json.stringify(v, .{}, w),
    }
}

fn writeJoined(w: Writer, items: []const Value) Allocator.Error!void {
    var first = true;
    for (items) |v| {
        if (v == .null) continue;
        if (!first) try w.writeAll(", ");
        first = false;
        try writeScalar(w, v);
    }
}

fn indentBy(w: Writer, n: usize) Allocator.Error!void {
    try w.writeByteNTimes(' ', n);
}

fn writeObject(arena: Allocator, w: Writer, o: std.json.ObjectMap, indent: usize) Allocator.Error!void {
    for (o.keys(), o.values()) |key, v| {
        switch (v) {
            .null => {},
            .object => |child| {
                try indentBy(w, indent);
                if (countNonNullEntries(child) == 0) {
                    try w.print("{s}: {{}}\n", .{key});
                } else {
                    try w.print("{s}:\n", .{key});
                    try writeObject(arena, w, child, indent + 2);
                }
            },
            .array => |a| {
                try indentBy(w, indent);
                if (countNonNull(a.items) == 0) {
                    try w.print("{s}: (none)\n", .{key});
                } else if (allScalars(a.items)) {
                    try w.print("{s}: ", .{key});
                    try writeJoined(w, a.items);
                    try w.writeByte('\n');
                } else {
                    try w.print("{s}:\n", .{key});
                    try writeItems(arena, w, a.items, indent + 2);
                }
            },
            else => {
                try indentBy(w, indent);
                try w.print("{s}: ", .{key});
                try writeScalar(w, v);
                try w.writeByte('\n');
            },
        }
    }
}

/// The items of a list whose dashes stand at column `dash`: an object has its first key after the dash and the others
/// under it; a scalar is written after the dash; an array inside a list is written as JSON.
fn writeItems(arena: Allocator, w: Writer, items: []const Value, dash: usize) Allocator.Error!void {
    for (items) |item| {
        switch (item) {
            .null => {},
            .object => |o| {
                try indentBy(w, dash);
                if (countNonNullEntries(o) == 0) {
                    try w.writeAll("- {}\n");
                    continue;
                }
                var tmp = std.ArrayList(u8).init(arena);
                try writeObject(arena, tmp.writer(), o, dash + 2);
                try w.writeAll("- ");
                try w.writeAll(tmp.items[dash + 2 ..]);
            },
            .array => {
                try indentBy(w, dash);
                try w.writeAll("- ");
                try std.json.stringify(item, .{}, w);
                try w.writeByte('\n');
            },
            else => {
                try indentBy(w, dash);
                try w.writeAll("- ");
                try writeScalar(w, item);
                try w.writeByte('\n');
            },
        }
    }
}

fn parse(arena: Allocator, text: []const u8) !Value {
    return std.json.parseFromSliceLeaky(Value, arena, text, .{});
}

fn expectRender(text: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings(expected, try render(a, try parse(a, text)));
}

test "a flat object is one key: value line per key, strings raw and numbers and bools as JSON writes them" {
    try expectRender(
        \\{"handle":"ada","github_id":42,"read_only":false,"ratio":1.5}
    ,
        \\handle: ada
        \\github_id: 42
        \\read_only: false
        \\ratio: 1.5
        \\
    );
}

test "a nested object is its key and its lines indented two spaces" {
    try expectRender(
        \\{"a":{"b":{"c":"d"},"e":1},"f":2}
    ,
        \\a:
        \\  b:
        \\    c: d
        \\  e: 1
        \\f: 2
        \\
    );
}

test "an array of scalars is one comma separated line" {
    try expectRender(
        \\{"scopes":["publish","read"],"counts":[1,2,3]}
    ,
        \\scopes: publish, read
        \\counts: 1, 2, 3
        \\
    );
}

test "an empty array is (none) and an empty object is {}" {
    try expectRender(
        \\{"members":[],"extra":{}}
    ,
        \\members: (none)
        \\extra: {}
        \\
    );
}

test "an array of objects is a list: the first key after the dash, the others four spaces in" {
    try expectRender(
        \\{"members":[{"user":"ada","role":"owner"},{"user":"bob","role":"member"}],"namespace":"acme"}
    ,
        \\members:
        \\  - user: ada
        \\    role: owner
        \\  - user: bob
        \\    role: member
        \\namespace: acme
        \\
    );
}

test "an object of a list that holds a nested object and an array keeps their lines under its key" {
    try expectRender(
        \\{"files":[{"name":"a","tags":["x","y"],"meta":{"size":3}}]}
    ,
        \\files:
        \\  - name: a
        \\    tags: x, y
        \\    meta:
        \\      size: 3
        \\
    );
}

test "a null is left out of an object, a list and a line of scalars" {
    try expectRender(
        \\{"a":null,"b":"x","c":[null,"y",null],"d":[{"e":null,"f":1}],"g":[null]}
    ,
        \\b: x
        \\c: y
        \\d:
        \\  - f: 1
        \\g: (none)
        \\
    );
}

test "an object of a list with nothing but nulls is {}" {
    try expectRender(
        \\{"a":[{"b":null},{"c":1}]}
    ,
        \\a:
        \\  - {}
        \\  - c: 1
        \\
    );
}

test "a top-level scalar is one line" {
    try expectRender("\"hello\"", "hello\n");
    try expectRender("7", "7\n");
    try expectRender("true", "true\n");
    try expectRender("null", "null\n");
}

test "a top-level array is a line of scalars, (none), or a list" {
    try expectRender("[\"a\",\"b\"]", "a, b\n");
    try expectRender("[]", "(none)\n");
    try expectRender("[{\"a\":1,\"b\":2}]", "- a: 1\n  b: 2\n");
}

test "scalars and arrays inside a list are written after the dash" {
    try expectRender(
        \\{"mixed":[{"a":1},"s",[1,2]]}
    ,
        \\mixed:
        \\  - a: 1
        \\  - s
        \\  - [1,2]
        \\
    );
}
