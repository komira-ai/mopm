//! Debian control-file syntax: fields (`Name: value`, continuation lines start with a space), stanzas separated by
//! blank lines. The same text is the `control` file inside a .deb and a stanza of an apt `Packages` file.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Field = struct {
    name: []const u8,
    /// The text after `Name: `; a multi-line value keeps its continuation lines (each starts with a space), joined by `\n`.
    value: []const u8,
};

pub const Error = error{ BadField, BadStanza };

/// A name is letters, digits and `-`; a value one or more lines with no NUL and no carriage return.
fn checkField(f: Field) Error!void {
    if (f.name.len == 0) return error.BadField;
    for (f.name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '-') return error.BadField;
    }
    if (f.value.len == 0) return error.BadField;
    for (f.value) |ch| {
        if (ch == 0 or ch == '\r') return error.BadField;
    }
    // Every line after the first is a continuation (starts with a space): a value cannot smuggle in a new field.
    var it = std.mem.splitScalar(u8, f.value, '\n');
    _ = it.next();
    while (it.next()) |line| {
        if (line.len == 0 or line[0] != ' ') return error.BadField;
    }
    if (f.value[f.value.len - 1] == '\n') return error.BadField;
}

/// `Name: value\n` for each field.
pub fn render(a: Allocator, fields: []const Field) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (fields) |f| {
        try checkField(f);
        try out.writer().print("{s}: {s}\n", .{ f.name, f.value });
    }
    return out.toOwnedSlice();
}

/// The fields of ONE stanza (no blank line inside).
pub fn parse(a: Allocator, text: []const u8) ![]Field {
    var out = std.ArrayList(Field).init(a);
    errdefer out.deinit();
    var it = std.mem.splitScalar(u8, text, '\n');
    var cur_name: ?[]const u8 = null;
    var cur_start: usize = 0;
    var cur_end: usize = 0;
    var pos: usize = 0;
    while (it.next()) |line| {
        const line_start = pos;
        pos += line.len + 1;
        if (line.len == 0) continue;
        if (line[0] == ' ' or line[0] == '\t') {
            if (cur_name == null) return error.BadStanza;
            cur_end = line_start + line.len;
            continue;
        }
        if (cur_name) |n| try out.append(.{ .name = n, .value = text[cur_start..cur_end] });
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.BadStanza;
        cur_name = line[0..colon];
        var v = colon + 1;
        while (v < line.len and line[v] == ' ') v += 1;
        cur_start = line_start + v;
        cur_end = line_start + line.len;
    }
    if (cur_name) |n| try out.append(.{ .name = n, .value = text[cur_start..cur_end] });
    return out.toOwnedSlice();
}

pub fn get(fields: []const Field, name: []const u8) ?[]const u8 {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.value;
    }
    return null;
}

/// Splits a file of stanzas (blank-line separated) into the text of each, every one ending in `\n`.
pub fn splitStanzas(a: Allocator, text: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(a);
    errdefer out.deinit();
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const nl = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = text[i..nl];
        if (line.len == 0) {
            if (i > start) try out.append(text[start..i]);
            start = nl + 1;
        }
        i = nl + 1;
    }
    if (start < text.len) try out.append(text[start..]);
    return out.toOwnedSlice();
}

const t = std.testing;

test "render then parse gives the fields back, continuation lines included" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const fields = [_]Field{
        .{ .name = "Package", .value = "mopm" },
        .{ .name = "Description", .value = "short\n long line\n .\n more" },
    };
    const text = try render(a, &fields);
    try t.expectEqualStrings("Package: mopm\nDescription: short\n long line\n .\n more\n", text);
    const got = try parse(a, text);
    try t.expectEqual(@as(usize, 2), got.len);
    try t.expectEqualStrings("Package", got[0].name);
    try t.expectEqualStrings("mopm", got[0].value);
    try t.expectEqualStrings(fields[1].value, got[1].value);
    try t.expectEqualStrings(fields[1].value, get(got, "Description").?);
    try t.expect(get(got, "Nope") == null);
    const again = try render(a, got);
    try t.expectEqualStrings(text, again);
}

test "a value cannot carry a second field, a NUL, or an empty value" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.BadField, render(a, &.{.{ .name = "Package", .value = "mopm\nDepends: evil" }}));
    try t.expectError(error.BadField, render(a, &.{.{ .name = "Package", .value = "mo\x00pm" }}));
    try t.expectError(error.BadField, render(a, &.{.{ .name = "Package", .value = "" }}));
    try t.expectError(error.BadField, render(a, &.{.{ .name = "Pack age", .value = "x" }}));
    try t.expectError(error.BadField, render(a, &.{.{ .name = "Package", .value = "mopm\n" }}));
}

test "stanzas are split on blank lines" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try splitStanzas(a, "A: 1\nB: 2\n\nA: 3\n\n\nA: 4\n");
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("A: 1\nB: 2\n", got[0]);
    try t.expectEqualStrings("A: 3\n", got[1]);
    try t.expectEqualStrings("A: 4\n", got[2]);
    try t.expectEqual(@as(usize, 0), (try splitStanzas(a, "")).len);
}

test "a continuation with no field before it is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    try t.expectError(error.BadStanza, parse(arena.allocator(), " orphan\nA: 1\n"));
    try t.expectError(error.BadStanza, parse(arena.allocator(), "no colon here\n"));
}
