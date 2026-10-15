//! A JSON Schema (draft 2020-12) validator for the schemas of this repository,
//! in Zig: the build has no Python `jsonschema`.
//!
//! It implements exactly the keywords the schemas under spec/ and the schemas
//! inside spec/api/openapi.yaml use, and REFUSES every other keyword with a
//! message naming it and where it stands (`error.UnsupportedKeyword`), so a
//! schema that grows a keyword this file does not check cannot pass silently.
//! `checkSchema` walks a whole schema (every branch, not only the branches an
//! instance reaches) and does the refusing; `validate` runs it first.
//!
//! Assertions implemented:
//!   type (a name or a list of names), enum, const, required, properties,
//!   additionalProperties (a schema or a boolean), items (one schema),
//!   minItems, maxItems, uniqueItems, minLength, maxLength (in code points),
//!   minimum, maximum, pattern (regex.zig; `search`), allOf, anyOf, oneOf,
//!   if/then/else, dependentRequired, $ref (a local "#/..." JSON pointer into
//!   the document given as the root).
//! Annotations accepted and not asserted: $schema, $id, $comment, title,
//!   description, default, examples, example, deprecated, readOnly,
//!   writeOnly, externalDocs, format (like the Python library, `format` is
//!   not asserted unless asked to), and any `x-` extension.
//!
//! An error is one string, `<instance path>: <what is wrong>`; the instance
//! path is a JSON pointer ("" is the document).

const std = @import("std");
const regex = @import("regex.zig");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const Errors = std.ArrayList([]const u8);

const Keyword = enum {
    @"type",
    @"enum",
    @"const",
    required,
    properties,
    additionalProperties,
    items,
    minItems,
    maxItems,
    uniqueItems,
    minLength,
    maxLength,
    minimum,
    maximum,
    pattern,
    allOf,
    anyOf,
    oneOf,
    @"if",
    then,
    @"else",
    dependentRequired,
    @"$ref",
};

const annotations = [_][]const u8{
    "$schema", "$id",         "$comment",  "title",     "description", "default",
    "examples", "example",    "deprecated", "readOnly", "writeOnly",   "externalDocs",
    "format",
};

const type_names = [_][]const u8{ "null", "boolean", "object", "array", "number", "integer", "string" };

fn isAnnotation(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "x-")) return true;
    for (annotations) |k| {
        if (std.mem.eql(u8, k, key)) return true;
    }
    return false;
}

fn bad(comptime fmt: []const u8, args: anytype) error{BadSchema} {
    std.debug.print("invalid schema: " ++ fmt ++ "\n", args);
    return error.BadSchema;
}

/// Refuses a schema that uses a keyword this file does not implement, or
/// gives a keyword a value of the wrong shape. `where` names the schema in
/// the message (a file, or a file and a JSON pointer).
pub fn checkSchema(a: Allocator, schema: Value, where: []const u8) anyerror!void {
    switch (schema) {
        .bool => return,
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |e| {
                const key = e.key_ptr.*;
                const v = e.value_ptr.*;
                if (isAnnotation(key)) continue;
                const kw = std.meta.stringToEnum(Keyword, key) orelse {
                    std.debug.print(
                        "unsupported JSON Schema keyword \"{s}\" at {s}: tests/drivers/jsonschema.zig does not implement it; " ++
                            "implement it there (with a test) before the schema may use it\n",
                        .{ key, where },
                    );
                    return error.UnsupportedKeyword;
                };
                const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ where, key });
                try checkKeyword(a, kw, v, sub);
            }
        },
        else => return bad("{s}: a schema is an object or a boolean", .{where}),
    }
}

fn isCount(v: Value) bool {
    return v == .integer and v.integer >= 0;
}

fn checkKeyword(a: Allocator, kw: Keyword, v: Value, where: []const u8) anyerror!void {
    switch (kw) {
        .@"type" => switch (v) {
            .string => |s| try checkTypeName(s, where),
            .array => |arr| for (arr.items) |t| {
                if (t != .string) return bad("{s}: type names are strings", .{where});
                try checkTypeName(t.string, where);
            },
            else => return bad("{s}: type is a name or a list of names", .{where}),
        },
        .@"enum" => if (v != .array) return bad("{s}: enum is an array", .{where}),
        .@"const" => {},
        .required => {
            if (v != .array) return bad("{s}: required is an array", .{where});
            for (v.array.items) |n| if (n != .string) return bad("{s}: required names are strings", .{where});
        },
        .properties => {
            if (v != .object) return bad("{s}: properties is an object", .{where});
            var it = v.object.iterator();
            while (it.next()) |e| {
                const sub = try std.fmt.allocPrint(a, "{s}/{s}", .{ where, e.key_ptr.* });
                try checkSchema(a, e.value_ptr.*, sub);
            }
        },
        .additionalProperties, .items, .@"if", .then, .@"else" => try checkSchema(a, v, where),
        .minItems, .maxItems, .minLength, .maxLength => if (!isCount(v)) return bad("{s}: a non-negative integer is required", .{where}),
        .uniqueItems => if (v != .bool) return bad("{s}: uniqueItems is a boolean", .{where}),
        .minimum, .maximum => if (toF64(v) == null) return bad("{s}: a number is required", .{where}),
        .pattern => {
            if (v != .string) return bad("{s}: pattern is a string", .{where});
            _ = try regex.Regex.compile(a, v.string);
        },
        .allOf, .anyOf, .oneOf => {
            if (v != .array or v.array.items.len == 0) return bad("{s}: a non-empty array of schemas is required", .{where});
            for (v.array.items, 0..) |s, i| {
                const sub = try std.fmt.allocPrint(a, "{s}/{d}", .{ where, i });
                try checkSchema(a, s, sub);
            }
        },
        .dependentRequired => {
            if (v != .object) return bad("{s}: dependentRequired is an object", .{where});
            var it = v.object.iterator();
            while (it.next()) |e| {
                if (e.value_ptr.* != .array) return bad("{s}: dependentRequired maps names to arrays", .{where});
            }
        },
        .@"$ref" => if (v != .string or !std.mem.startsWith(u8, v.string, "#")) {
            return bad("{s}: only a local \"#/...\" $ref is supported", .{where});
        },
    }
}

fn checkTypeName(name: []const u8, where: []const u8) !void {
    for (type_names) |t| {
        if (std.mem.eql(u8, t, name)) return;
    }
    return bad("{s}: \"{s}\" is not a JSON type", .{ where, name });
}

pub fn toF64(v: Value) ?f64 {
    return switch (v) {
        .integer => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

/// JSON equality: numbers by value (1 equals 1.0), no coercion between types.
pub fn eql(x: Value, y: Value) bool {
    switch (x) {
        .null => return y == .null,
        .bool => |b| return y == .bool and y.bool == b,
        .integer, .float, .number_string => {
            const l = toF64(x) orelse return false;
            const r = toF64(y) orelse return false;
            return l == r;
        },
        .string => |s| return y == .string and std.mem.eql(u8, s, y.string),
        .array => |arr| {
            if (y != .array or y.array.items.len != arr.items.len) return false;
            for (arr.items, y.array.items) |p, q| {
                if (!eql(p, q)) return false;
            }
            return true;
        },
        .object => |obj| {
            if (y != .object or y.object.count() != obj.count()) return false;
            var it = obj.iterator();
            while (it.next()) |e| {
                const other = y.object.get(e.key_ptr.*) orelse return false;
                if (!eql(e.value_ptr.*, other)) return false;
            }
            return true;
        },
    }
}

fn typeIs(name: []const u8, v: Value) bool {
    if (std.mem.eql(u8, name, "null")) return v == .null;
    if (std.mem.eql(u8, name, "boolean")) return v == .bool;
    if (std.mem.eql(u8, name, "object")) return v == .object;
    if (std.mem.eql(u8, name, "array")) return v == .array;
    if (std.mem.eql(u8, name, "string")) return v == .string;
    if (std.mem.eql(u8, name, "number")) return toF64(v) != null;
    if (std.mem.eql(u8, name, "integer")) {
        if (v == .integer) return true;
        const f = toF64(v) orelse return false;
        return f == @floor(f);
    }
    return false;
}

fn codePoints(s: []const u8) usize {
    var n: usize = 0;
    for (s) |b| {
        if (b & 0xC0 != 0x80) n += 1;
    }
    return n;
}

/// Where a `$ref` may point: the document the references are relative to.
pub const Validator = struct {
    a: Allocator,
    root: Value,

    /// Every way `inst` violates `schema` (empty when it conforms). Refuses
    /// an unsupported keyword anywhere in `schema` first.
    pub fn errors(self: Validator, schema: Value, inst: Value) anyerror!Errors {
        try checkSchema(self.a, schema, "(schema)");
        var errs = Errors.init(self.a);
        try self.check(schema, inst, "", &errs, 0);
        return errs;
    }

    fn add(self: Validator, errs: *Errors, path: []const u8, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.a, fmt, args);
        try errs.append(try std.fmt.allocPrint(self.a, "{s}: {s}", .{ path, msg }));
    }

    fn resolve(self: Validator, ref: []const u8) !Value {
        if (std.mem.eql(u8, ref, "#")) return self.root;
        if (!std.mem.startsWith(u8, ref, "#/")) return bad("$ref {s}: only \"#\" and \"#/...\" are supported", .{ref});
        var cur = self.root;
        var parts = std.mem.splitScalar(u8, ref[2..], '/');
        while (parts.next()) |raw| {
            const t1 = try std.mem.replaceOwned(u8, self.a, raw, "~1", "/");
            const part = try std.mem.replaceOwned(u8, self.a, t1, "~0", "~");
            switch (cur) {
                .object => |o| cur = o.get(part) orelse return bad("$ref {s}: no member \"{s}\"", .{ ref, part }),
                .array => |arr| {
                    const i = std.fmt.parseInt(usize, part, 10) catch return bad("$ref {s}: \"{s}\" is not an index", .{ ref, part });
                    if (i >= arr.items.len) return bad("$ref {s}: no element {d}", .{ ref, i });
                    cur = arr.items[i];
                },
                else => return bad("$ref {s}: \"{s}\" is inside a scalar", .{ ref, part }),
            }
        }
        return cur;
    }

    fn conforms(self: Validator, schema: Value, inst: Value, path: []const u8, depth: u32) anyerror!bool {
        var scratch = Errors.init(self.a);
        try self.check(schema, inst, path, &scratch, depth);
        return scratch.items.len == 0;
    }

    fn check(self: Validator, schema: Value, inst: Value, path: []const u8, errs: *Errors, depth: u32) anyerror!void {
        if (depth > 200) return bad("$ref nesting deeper than 200 at {s}", .{path});
        switch (schema) {
            .bool => |ok| {
                if (!ok) try self.add(errs, path, "False schema does not allow the value", .{});
                return;
            },
            .object => {},
            else => return bad("a schema is an object or a boolean", .{}),
        }
        const obj = schema.object;
        var it = obj.iterator();
        while (it.next()) |e| {
            const kw = std.meta.stringToEnum(Keyword, e.key_ptr.*) orelse continue; // an annotation (checkSchema refused the rest)
            const v = e.value_ptr.*;
            switch (kw) {
                .@"type" => {
                    var ok = false;
                    switch (v) {
                        .string => |s| ok = typeIs(s, inst),
                        .array => |arr| for (arr.items) |t| {
                            if (typeIs(t.string, inst)) ok = true;
                        },
                        else => {},
                    }
                    if (!ok) try self.add(errs, path, "the value is not of type {s}", .{try stringify(self.a, v)});
                },
                .@"enum" => {
                    var ok = false;
                    for (v.array.items) |m| {
                        if (eql(m, inst)) ok = true;
                    }
                    if (!ok) try self.add(errs, path, "{s} is not one of {s}", .{ try stringify(self.a, inst), try stringify(self.a, v) });
                },
                .@"const" => if (!eql(v, inst)) try self.add(errs, path, "{s} was expected", .{try stringify(self.a, v)}),
                .required => if (inst == .object) {
                    for (v.array.items) |n| {
                        if (!inst.object.contains(n.string)) try self.add(errs, path, "'{s}' is a required property", .{n.string});
                    }
                },
                .properties => if (inst == .object) {
                    var pit = v.object.iterator();
                    while (pit.next()) |pe| {
                        if (inst.object.get(pe.key_ptr.*)) |child| {
                            const sub = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ path, pe.key_ptr.* });
                            try self.check(pe.value_ptr.*, child, sub, errs, depth + 1);
                        }
                    }
                },
                .additionalProperties => if (inst == .object) {
                    const declared: ?Value = obj.get("properties");
                    var iit = inst.object.iterator();
                    while (iit.next()) |ie| {
                        if (declared) |d| {
                            if (d.object.contains(ie.key_ptr.*)) continue;
                        }
                        const sub = try std.fmt.allocPrint(self.a, "{s}/{s}", .{ path, ie.key_ptr.* });
                        if (v == .bool and !v.bool) {
                            try self.add(errs, path, "additional property '{s}' is not allowed", .{ie.key_ptr.*});
                        } else {
                            try self.check(v, ie.value_ptr.*, sub, errs, depth + 1);
                        }
                    }
                },
                .items => if (inst == .array) {
                    for (inst.array.items, 0..) |child, i| {
                        const sub = try std.fmt.allocPrint(self.a, "{s}/{d}", .{ path, i });
                        try self.check(v, child, sub, errs, depth + 1);
                    }
                },
                .minItems => if (inst == .array and inst.array.items.len < @as(usize, @intCast(v.integer))) {
                    try self.add(errs, path, "the array has {d} items, at least {d} are required", .{ inst.array.items.len, v.integer });
                },
                .maxItems => if (inst == .array and inst.array.items.len > @as(usize, @intCast(v.integer))) {
                    try self.add(errs, path, "the array has {d} items, at most {d} are allowed", .{ inst.array.items.len, v.integer });
                },
                .uniqueItems => if (v.bool and inst == .array) {
                    const items = inst.array.items;
                    for (items, 0..) |x, i| {
                        for (items[i + 1 ..]) |y| {
                            if (eql(x, y)) {
                                try self.add(errs, path, "the array has a repeated item {s}", .{try stringify(self.a, x)});
                                break;
                            }
                        }
                    }
                },
                .minLength => if (inst == .string and codePoints(inst.string) < @as(usize, @intCast(v.integer))) {
                    try self.add(errs, path, "the string is shorter than {d}", .{v.integer});
                },
                .maxLength => if (inst == .string and codePoints(inst.string) > @as(usize, @intCast(v.integer))) {
                    try self.add(errs, path, "the string is longer than {d}", .{v.integer});
                },
                .minimum => if (toF64(inst)) |n| {
                    if (inst != .string and n < toF64(v).?) try self.add(errs, path, "{s} is below the minimum {s}", .{ try stringify(self.a, inst), try stringify(self.a, v) });
                },
                .maximum => if (toF64(inst)) |n| {
                    if (inst != .string and n > toF64(v).?) try self.add(errs, path, "{s} is above the maximum {s}", .{ try stringify(self.a, inst), try stringify(self.a, v) });
                },
                .pattern => if (inst == .string) {
                    const re = try regex.Regex.compile(self.a, v.string);
                    if (!re.search(inst.string)) try self.add(errs, path, "'{s}' does not match {s}", .{ inst.string, v.string });
                },
                .allOf => for (v.array.items) |s| try self.check(s, inst, path, errs, depth + 1),
                .anyOf => {
                    var ok = false;
                    for (v.array.items) |s| {
                        if (try self.conforms(s, inst, path, depth + 1)) ok = true;
                    }
                    if (!ok) try self.add(errs, path, "the value matches none of the anyOf schemas", .{});
                },
                .oneOf => {
                    var n: usize = 0;
                    for (v.array.items) |s| {
                        if (try self.conforms(s, inst, path, depth + 1)) n += 1;
                    }
                    if (n != 1) try self.add(errs, path, "the value matches {d} of the oneOf schemas, not exactly one", .{n});
                },
                .@"if" => {
                    if (try self.conforms(v, inst, path, depth + 1)) {
                        if (obj.get("then")) |t| try self.check(t, inst, path, errs, depth + 1);
                    } else if (obj.get("else")) |el| {
                        try self.check(el, inst, path, errs, depth + 1);
                    }
                },
                .then, .@"else" => {}, // applied by "if"
                .dependentRequired => if (inst == .object) {
                    var dit = v.object.iterator();
                    while (dit.next()) |de| {
                        if (!inst.object.contains(de.key_ptr.*)) continue;
                        for (de.value_ptr.*.array.items) |need| {
                            if (!inst.object.contains(need.string)) {
                                try self.add(errs, path, "'{s}' is a dependency of '{s}'", .{ need.string, de.key_ptr.* });
                            }
                        }
                    }
                },
                .@"$ref" => {
                    const target = try self.resolve(v.string);
                    try self.check(target, inst, path, errs, depth + 1);
                },
            }
        }
    }
};

fn stringify(a: Allocator, v: Value) ![]const u8 {
    const full = try std.json.stringifyAlloc(a, v, .{});
    return if (full.len > 120) full[0..120] else full;
}

// ------------------------------------------------------------------ tests

fn parse(a: Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, a, text, .{})).value;
}

/// `inst` against `schema`: the number of errors.
fn count(a: Allocator, schema: []const u8, inst: []const u8) !usize {
    const s = try parse(a, schema);
    const v = Validator{ .a = a, .root = s };
    return (try v.errors(s, try parse(a, inst))).items.len;
}

const Case = struct { schema: []const u8, inst: []const u8, bad_count: usize };

test "jsonschema: each keyword accepts what it should and refuses what it should not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]Case{
        .{ .schema = "{\"type\":\"string\"}", .inst = "\"x\"", .bad_count = 0 },
        .{ .schema = "{\"type\":\"string\"}", .inst = "1", .bad_count = 1 },
        .{ .schema = "{\"type\":[\"string\",\"null\"]}", .inst = "null", .bad_count = 0 },
        .{ .schema = "{\"type\":\"integer\"}", .inst = "1.0", .bad_count = 0 },
        .{ .schema = "{\"type\":\"integer\"}", .inst = "1.5", .bad_count = 1 },
        .{ .schema = "{\"type\":\"number\"}", .inst = "true", .bad_count = 1 },
        .{ .schema = "{\"enum\":[\"a\",1]}", .inst = "1", .bad_count = 0 },
        .{ .schema = "{\"enum\":[\"a\",1]}", .inst = "\"b\"", .bad_count = 1 },
        .{ .schema = "{\"const\":{\"k\":[1]}}", .inst = "{\"k\":[1]}", .bad_count = 0 },
        .{ .schema = "{\"const\":{\"k\":[1]}}", .inst = "{\"k\":[2]}", .bad_count = 1 },
        .{ .schema = "{\"required\":[\"a\",\"b\"]}", .inst = "{\"a\":1,\"b\":2}", .bad_count = 0 },
        .{ .schema = "{\"required\":[\"a\",\"b\"]}", .inst = "{\"a\":1}", .bad_count = 1 },
        .{ .schema = "{\"properties\":{\"a\":{\"type\":\"string\"}}}", .inst = "{\"a\":1}", .bad_count = 1 },
        .{ .schema = "{\"properties\":{\"a\":{\"type\":\"string\"}}}", .inst = "{\"b\":1}", .bad_count = 0 },
        .{ .schema = "{\"properties\":{\"a\":{}},\"additionalProperties\":false}", .inst = "{\"a\":1,\"b\":2}", .bad_count = 1 },
        .{ .schema = "{\"properties\":{\"a\":{}},\"additionalProperties\":{\"type\":\"integer\"}}", .inst = "{\"a\":\"x\",\"b\":2}", .bad_count = 0 },
        .{ .schema = "{\"properties\":{\"a\":{}},\"additionalProperties\":{\"type\":\"integer\"}}", .inst = "{\"a\":1,\"b\":\"x\"}", .bad_count = 1 },
        .{ .schema = "{\"items\":{\"type\":\"integer\"}}", .inst = "[1,2,\"x\"]", .bad_count = 1 },
        .{ .schema = "{\"minItems\":2}", .inst = "[1]", .bad_count = 1 },
        .{ .schema = "{\"minItems\":2}", .inst = "[1,2]", .bad_count = 0 },
        .{ .schema = "{\"maxItems\":1}", .inst = "[1,2]", .bad_count = 1 },
        .{ .schema = "{\"uniqueItems\":true}", .inst = "[1,2,1.0]", .bad_count = 1 },
        .{ .schema = "{\"uniqueItems\":true}", .inst = "[1,\"1\"]", .bad_count = 0 },
        .{ .schema = "{\"minLength\":2}", .inst = "\"a\"", .bad_count = 1 },
        .{ .schema = "{\"minLength\":2}", .inst = "\"\\u00e9\\u00e9\"", .bad_count = 0 },
        .{ .schema = "{\"maxLength\":2}", .inst = "\"abc\"", .bad_count = 1 },
        .{ .schema = "{\"minimum\":1}", .inst = "0", .bad_count = 1 },
        .{ .schema = "{\"minimum\":1}", .inst = "1", .bad_count = 0 },
        .{ .schema = "{\"maximum\":1}", .inst = "2", .bad_count = 1 },
        .{ .schema = "{\"minimum\":1}", .inst = "\"0\"", .bad_count = 0 },
        .{ .schema = "{\"pattern\":\"^a+$\"}", .inst = "\"aaa\"", .bad_count = 0 },
        .{ .schema = "{\"pattern\":\"^a+$\"}", .inst = "\"aab\"", .bad_count = 1 },
        .{ .schema = "{\"allOf\":[{\"type\":\"string\"},{\"minLength\":3}]}", .inst = "\"ab\"", .bad_count = 1 },
        .{ .schema = "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", .inst = "true", .bad_count = 1 },
        .{ .schema = "{\"anyOf\":[{\"type\":\"string\"},{\"type\":\"integer\"}]}", .inst = "3", .bad_count = 0 },
        .{ .schema = "{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}", .inst = "3", .bad_count = 1 },
        .{ .schema = "{\"oneOf\":[{\"type\":\"number\"},{\"type\":\"integer\"}]}", .inst = "3.5", .bad_count = 0 },
        .{ .schema = "{\"if\":{\"properties\":{\"k\":{\"const\":1}}},\"then\":{\"required\":[\"x\"]}}", .inst = "{\"k\":1}", .bad_count = 1 },
        .{ .schema = "{\"if\":{\"properties\":{\"k\":{\"const\":1}}},\"then\":{\"required\":[\"x\"]}}", .inst = "{\"k\":2}", .bad_count = 0 },
        .{ .schema = "{\"if\":{\"properties\":{\"k\":{\"const\":1}}},\"else\":{\"required\":[\"y\"]}}", .inst = "{\"k\":2}", .bad_count = 1 },
        .{ .schema = "{\"dependentRequired\":{\"a\":[\"b\"]}}", .inst = "{\"a\":1}", .bad_count = 1 },
        .{ .schema = "{\"dependentRequired\":{\"a\":[\"b\"]}}", .inst = "{\"b\":1}", .bad_count = 0 },
        .{ .schema = "{\"properties\":{\"a\":{\"$ref\":\"#/properties/b\"},\"b\":{\"type\":\"string\"}}}", .inst = "{\"a\":1}", .bad_count = 1 },
        .{ .schema = "{\"format\":\"uri\",\"description\":\"d\",\"x-note\":1,\"type\":\"string\"}", .inst = "\"not a uri\"", .bad_count = 0 },
    };
    for (cases) |c| {
        const got = try count(a, c.schema, c.inst);
        if ((got == 0) != (c.bad_count == 0)) {
            std.debug.print("schema {s} on {s}: {d} errors, expected {s}\n", .{ c.schema, c.inst, got, if (c.bad_count == 0) "none" else "some" });
            return error.TestUnexpectedResult;
        }
    }
}

test "jsonschema: a keyword that is not implemented is refused loudly, wherever it stands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const unsupported = [_][]const u8{
        "{\"multipleOf\":2}",
        "{\"properties\":{\"a\":{\"patternProperties\":{}}}}",
        "{\"anyOf\":[{\"type\":\"string\"},{\"contains\":{}}]}",
        "{\"properties\":{\"a\":{\"not\":{}}}}",
        "{\"$defs\":{}}",
        "{\"prefixItems\":[]}",
        "{\"exclusiveMinimum\":1}",
        "{\"items\":{\"unevaluatedProperties\":false}}",
    };
    for (unsupported) |text| {
        const s = try parse(a, text);
        // Even an instance that no branch reaches must not hide it.
        if (checkSchema(a, s, "(test)")) |_| {
            std.debug.print("schema {s} was accepted\n", .{text});
            return error.TestUnexpectedResult;
        } else |err| {
            if (err != error.UnsupportedKeyword) return err;
        }
    }
    // A wrongly shaped value is refused too.
    for ([_][]const u8{ "{\"type\":\"strng\"}", "{\"required\":\"a\"}", "{\"minLength\":-1}", "{\"pattern\":\"(?=a)\"}", "{\"allOf\":[]}" }) |text| {
        if (checkSchema(a, try parse(a, text), "(test)")) |_| {
            std.debug.print("schema {s} was accepted\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
