//! A YAML reader for spec/api/openapi.yaml, in Zig: the build has no PyYAML.
//!
//! Chosen over a JSON copy of the file. A copy is a second source of truth
//! that a test would have to keep equal to the first, which needs a YAML
//! reader anyway; the document is written in a small, regular subset of YAML,
//! and a reader of that subset that REFUSES everything else (with the line
//! number) is smaller and cannot drift.
//!
//! The subset, read into `std.json.Value`:
//!   - block mappings and block sequences, nested by indentation (spaces
//!     only); a mapping may start on the line of a sequence dash (`- name: x`)
//!   - flow mappings and sequences on ONE line: `{ a: 1, b: [x, y] }`
//!   - plain scalars (typed: null / ~ / empty, true / false, integers, simple
//!     decimals, otherwise strings), "double quoted" scalars (escapes \\ \"
//!     \/ \n \t \r \0 \uXXXX) and 'single quoted' scalars ('' for a quote)
//!   - the literal block scalars `|` and `|-`
//!   - comments (a `#` at the start of a token), blank lines
//!   - mapping keys are always strings; a repeated key is an error (PyYAML
//!     keeps the last one without a word)
//! Refused, with a message: tabs, document markers (`---`, `...`), anchors,
//! aliases and tags (`&` `*` `!`), merge keys, `?` keys, folded scalars `>`,
//! `|+` and indentation indicators, multi-line plain or quoted scalars,
//! multi-line flow collections, a sequence at the indentation of its key,
//! a flow collection used as a key, and any text left over after a value.
//!
//! One difference from PyYAML worth knowing: YAML 1.1 reads the plain words
//! yes / no / on / off as booleans; this reader keeps them strings.

const std = @import("std");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub fn parse(a: Allocator, text: []const u8) !Value {
    var lines = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| try lines.append(std.mem.trimRight(u8, raw, "\r"));
    var p = P{ .a = a, .lines = lines.items };
    for (p.lines, 0..) |l, n| {
        p.i = n;
        if (std.mem.indexOfScalar(u8, l, '\t') != null) return p.fail("a tab (indent with spaces)", .{});
        if (std.mem.startsWith(u8, l, "---") or std.mem.startsWith(u8, l, "...")) return p.fail("a document marker", .{});
    }
    p.i = 0;
    const v = try p.parseBlock();
    if (p.sig() != null) return p.fail("content that does not belong to the document", .{});
    return v;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// Nothing but spaces, or a comment.
fn blank(line: []const u8) bool {
    const n = indentOf(line);
    return n == line.len or line[n] == '#';
}

fn isDash(content: []const u8) bool {
    return content.len > 0 and content[0] == '-' and (content.len == 1 or content[1] == ' ');
}

/// `s` without a trailing comment and trailing spaces. A quote opens a quoted
/// scalar only at the start of a token, so an apostrophe in prose is prose.
fn stripComment(s: []const u8) []const u8 {
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (quote != 0) {
            if (quote == '"' and c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        const token_start = i == 0 or s[i - 1] == ' ' or s[i - 1] == '[' or s[i - 1] == '{' or s[i - 1] == ',';
        if ((c == '"' or c == '\'') and token_start) {
            quote = c;
        } else if (c == '#' and token_start) {
            return std.mem.trimRight(u8, s[0..i], " ");
        }
    }
    return std.mem.trimRight(u8, s, " ");
}

const Kv = struct { key: []const u8, rest: []const u8 };

const P = struct {
    a: Allocator,
    lines: [][]const u8,
    i: usize = 0,

    fn fail(self: *P, comptime fmt: []const u8, args: anytype) error{YamlUnsupported} {
        std.debug.print("yaml line {d}: " ++ fmt ++ " (tests/drivers/yaml.zig reads a subset of YAML; see its header)\n", .{self.i + 1} ++ args);
        return error.YamlUnsupported;
    }

    /// The index of the next line that holds content, without consuming it.
    fn sig(self: *P) ?usize {
        while (self.i < self.lines.len) : (self.i += 1) {
            if (!blank(self.lines[self.i])) return self.i;
        }
        return null;
    }

    fn parseBlock(self: *P) anyerror!Value {
        const at = self.sig() orelse return .null;
        const line = self.lines[at];
        const ind = indentOf(line);
        const content = stripComment(line[ind..]);
        if (isDash(content)) return self.parseSeq(ind);
        if ((try self.splitKey(content)) != null) return self.parseMap(ind);
        self.i += 1;
        return self.parseInline(content);
    }

    /// `key: rest` for a line that is a mapping entry, else null.
    fn splitKey(self: *P, content: []const u8) !?Kv {
        if (content.len == 0) return null;
        const c0 = content[0];
        if (c0 == '{' or c0 == '[') return null;
        if (c0 == '"' or c0 == '\'') {
            var pos: usize = 0;
            const key = try self.quoted(content, &pos);
            if (pos < content.len and content[pos] == ':' and (pos + 1 == content.len or content[pos + 1] == ' ')) {
                return Kv{ .key = key, .rest = std.mem.trim(u8, content[pos + 1 ..], " ") };
            }
            return null;
        }
        var k: usize = 0;
        while (k < content.len) : (k += 1) {
            if (content[k] == ':' and (k + 1 == content.len or content[k + 1] == ' ')) {
                return Kv{ .key = std.mem.trimRight(u8, content[0..k], " "), .rest = std.mem.trim(u8, content[k + 1 ..], " ") };
            }
        }
        return null;
    }

    fn parseMap(self: *P, ind: usize) anyerror!Value {
        var map = std.json.ObjectMap.init(self.a);
        while (true) {
            const at = self.sig() orelse break;
            const line = self.lines[at];
            const li = indentOf(line);
            if (li < ind) break;
            if (li > ind) return self.fail("unexpected indentation", .{});
            const content = stripComment(line[li..]);
            if (isDash(content)) return self.fail("a sequence at the indentation of its key", .{});
            const kv = (try self.splitKey(content)) orelse return self.fail("expected 'key: value', found '{s}'", .{content});
            if (map.contains(kv.key)) return self.fail("the key '{s}' is repeated", .{kv.key});
            self.i += 1;
            var val: Value = .null;
            if (kv.rest.len == 0) {
                if (self.sig()) |n| {
                    if (indentOf(self.lines[n]) > ind) val = try self.parseBlock();
                }
            } else if (kv.rest[0] == '|' or kv.rest[0] == '>') {
                val = try self.blockScalar(kv.rest, ind);
            } else {
                val = try self.parseInline(kv.rest);
            }
            try map.put(kv.key, val);
        }
        return .{ .object = map };
    }

    fn parseSeq(self: *P, ind: usize) anyerror!Value {
        var arr = std.json.Array.init(self.a);
        while (true) {
            const at = self.sig() orelse break;
            const line = self.lines[at];
            const li = indentOf(line);
            if (li < ind) break;
            if (li > ind) return self.fail("unexpected indentation", .{});
            const content = stripComment(line[li..]);
            if (!isDash(content)) break;
            const rest = std.mem.trimLeft(u8, content[1..], " ");
            if (rest.len == 0) {
                self.i += 1;
                var item: Value = .null;
                if (self.sig()) |n| {
                    if (indentOf(self.lines[n]) > ind) item = try self.parseBlock();
                }
                try arr.append(item);
            } else if (isDash(rest) or (try self.splitKey(rest)) != null) {
                // `- key: value` / `- - x`: read the rest of the line as a block
                // that starts at its own column.
                const col = li + (content.len - rest.len);
                const buf = try self.a.alloc(u8, col + rest.len);
                @memset(buf[0..col], ' ');
                @memcpy(buf[col..], rest);
                self.lines[at] = buf;
                try arr.append(try self.parseBlock());
            } else {
                self.i += 1;
                try arr.append(try self.parseInline(rest));
            }
        }
        return .{ .array = arr };
    }

    /// A `|` or `|-` scalar whose lines are indented deeper than `parent`.
    fn blockScalar(self: *P, header: []const u8, parent: usize) anyerror!Value {
        const keep_newline = std.mem.eql(u8, header, "|");
        if (!keep_newline and !std.mem.eql(u8, header, "|-")) {
            return self.fail("the block scalar header '{s}' (only | and |- are read)", .{header});
        }
        var first = self.i;
        while (first < self.lines.len and indentOf(self.lines[first]) == self.lines[first].len) first += 1;
        var out = std.ArrayList(u8).init(self.a);
        if (first < self.lines.len and indentOf(self.lines[first]) > parent) {
            const cind = indentOf(self.lines[first]);
            var count: usize = 0; // lines taken, trailing blank ones included
            var last_text: usize = 0; // lines up to the last one with text
            while (self.i < self.lines.len) {
                const l = self.lines[self.i];
                const li = indentOf(l);
                if (li == l.len) {
                    count += 1;
                    self.i += 1;
                    continue;
                }
                if (li < cind) break;
                count += 1;
                last_text = count;
                self.i += 1;
            }
            const start = self.i - count;
            var n: usize = 0;
            while (n < last_text) : (n += 1) {
                const l = self.lines[start + n];
                if (n > 0) try out.append('\n');
                if (l.len > cind) try out.appendSlice(l[cind..]);
            }
            if (keep_newline) try out.append('\n');
        }
        return .{ .string = out.items };
    }

    /// A scalar or a one-line flow collection, with nothing after it.
    fn parseInline(self: *P, s: []const u8) anyerror!Value {
        var pos: usize = 0;
        const v = try self.flow(s, &pos, false);
        skipWs(s, &pos);
        if (pos != s.len) return self.fail("text after the value: '{s}'", .{s[pos..]});
        return v;
    }

    fn skipWs(s: []const u8, pos: *usize) void {
        while (pos.* < s.len and s[pos.*] == ' ') pos.* += 1;
    }

    /// One node starting at `pos`. `in_flow`: a plain scalar ends at , ] }.
    fn flow(self: *P, s: []const u8, pos: *usize, in_flow: bool) anyerror!Value {
        skipWs(s, pos);
        if (pos.* >= s.len) return self.fail("a flow collection that is not closed on this line", .{});
        switch (s[pos.*]) {
            '{' => {
                pos.* += 1;
                var map = std.json.ObjectMap.init(self.a);
                while (true) {
                    skipWs(s, pos);
                    if (pos.* >= s.len) return self.fail("a flow mapping that is not closed on this line", .{});
                    if (s[pos.*] == '}') {
                        pos.* += 1;
                        break;
                    }
                    const key: []const u8 = if (s[pos.*] == '"' or s[pos.*] == '\'')
                        try self.quoted(s, pos)
                    else
                        std.mem.trim(u8, try self.plainUntil(s, pos, true), " ");
                    skipWs(s, pos);
                    if (pos.* >= s.len or s[pos.*] != ':') return self.fail("a flow mapping entry without ':' ('{s}')", .{key});
                    pos.* += 1;
                    skipWs(s, pos);
                    var val: Value = .null;
                    if (pos.* < s.len and s[pos.*] != ',' and s[pos.*] != '}') val = try self.flow(s, pos, true);
                    if (map.contains(key)) return self.fail("the key '{s}' is repeated", .{key});
                    try map.put(key, val);
                    skipWs(s, pos);
                    if (pos.* < s.len and s[pos.*] == ',') pos.* += 1;
                }
                return .{ .object = map };
            },
            '[' => {
                pos.* += 1;
                var arr = std.json.Array.init(self.a);
                while (true) {
                    skipWs(s, pos);
                    if (pos.* >= s.len) return self.fail("a flow sequence that is not closed on this line", .{});
                    if (s[pos.*] == ']') {
                        pos.* += 1;
                        break;
                    }
                    try arr.append(try self.flow(s, pos, true));
                    skipWs(s, pos);
                    if (pos.* < s.len and s[pos.*] == ',') pos.* += 1;
                }
                return .{ .array = arr };
            },
            '"', '\'' => return .{ .string = try self.quoted(s, pos) },
            '&', '*', '!', '%', '@', '`', '>', '?' => return self.fail("'{c}' (anchors, aliases, tags, folded scalars and '?' keys are not read)", .{s[pos.*]}),
            '|' => return self.fail("a block scalar where a value is not the whole of a mapping entry", .{}),
            else => {
                const text = std.mem.trim(u8, try self.plainUntil(s, pos, in_flow), " ");
                return typed(text);
            },
        }
    }

    /// Plain text from `pos` to the end of the scalar: in a flow collection a
    /// `,` `]` `}` or a `:` before a space ends it (`as_key`: any `:` that
    /// ends the key); outside, the end of the line.
    fn plainUntil(self: *P, s: []const u8, pos: *usize, as_key_or_flow: bool) ![]const u8 {
        _ = self;
        const begin = pos.*;
        while (pos.* < s.len) : (pos.* += 1) {
            const c = s[pos.*];
            if (!as_key_or_flow) continue;
            if (c == ',' or c == ']' or c == '}') break;
            if (c == ':' and (pos.* + 1 == s.len or s[pos.* + 1] == ' ' or s[pos.* + 1] == ',' or s[pos.* + 1] == '}')) break;
        }
        return s[begin..pos.*];
    }

    /// A quoted scalar starting at the quote at `pos`; leaves `pos` after it.
    fn quoted(self: *P, s: []const u8, pos: *usize) ![]const u8 {
        const q = s[pos.*];
        pos.* += 1;
        var out = std.ArrayList(u8).init(self.a);
        while (true) {
            if (pos.* >= s.len) return self.fail("a quoted scalar that does not end on its line", .{});
            const c = s[pos.*];
            pos.* += 1;
            if (c == q) {
                if (q == '\'' and pos.* < s.len and s[pos.*] == '\'') {
                    try out.append('\'');
                    pos.* += 1;
                    continue;
                }
                return out.items;
            }
            if (q == '"' and c == '\\') {
                if (pos.* >= s.len) return self.fail("a quoted scalar that ends in a backslash", .{});
                const e = s[pos.*];
                pos.* += 1;
                switch (e) {
                    '\\', '"', '/' => try out.append(e),
                    'n' => try out.append('\n'),
                    't' => try out.append('\t'),
                    'r' => try out.append('\r'),
                    '0' => try out.append(0),
                    'u' => {
                        if (pos.* + 4 > s.len) return self.fail("a short \\u escape", .{});
                        const cp = std.fmt.parseInt(u21, s[pos.* .. pos.* + 4], 16) catch return self.fail("a bad \\u escape", .{});
                        pos.* += 4;
                        var buf: [4]u8 = undefined;
                        const n = std.unicode.utf8Encode(cp, &buf) catch return self.fail("a \\u escape that is not a character", .{});
                        try out.appendSlice(buf[0..n]);
                    },
                    else => return self.fail("the escape \\{c}", .{e}),
                }
                continue;
            }
            try out.append(c);
        }
    }
};

/// A plain scalar's type.
fn typed(text: []const u8) Value {
    if (text.len == 0 or std.mem.eql(u8, text, "~") or std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "Null") or std.mem.eql(u8, text, "NULL")) return .null;
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "True") or std.mem.eql(u8, text, "TRUE")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false") or std.mem.eql(u8, text, "False") or std.mem.eql(u8, text, "FALSE")) return .{ .bool = false };
    var digits = text;
    if (digits[0] == '-' or digits[0] == '+') digits = digits[1..];
    var dots: usize = 0;
    var numeric = digits.len > 0;
    for (digits) |c| {
        if (c == '.') {
            dots += 1;
        } else if (c < '0' or c > '9') numeric = false;
    }
    if (numeric and dots == 0) {
        if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .integer = i } else |_| {}
    }
    if (numeric and dots == 1 and digits[0] != '.' and digits[digits.len - 1] != '.') {
        if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
    }
    return .{ .string = text };
}

// ------------------------------------------------------------------ tests

fn parseOk(a: Allocator, text: []const u8) !Value {
    return parse(a, text);
}

test "yaml: the subset openapi.yaml is written in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc =
        \\openapi: 3.1.0
        \\# a comment
        \\info:
        \\  version: "1.0.0"   # trailing
        \\  description: |
        \\    first line
        \\
        \\    third # not a comment
        \\  n: 12
        \\  ratio: 0.5
        \\  off: null
        \\servers:
        \\  - url: https://{host}/api/v1
        \\    variables:
        \\      host:
        \\        enum:
        \\          - a.example
        \\          - b.example
        \\  - plain
        \\paths:
        \\  /x/{id}:
        \\    get:
        \\      responses:
        \\        "200":
        \\          headers:
        \\            h: { $ref: "#/components/h" }
        \\          schema: { type: string, maxLength: 5, enum: [a, 'it''s', "q\"x"], nested: { k: [1, 2] } }
        \\        default: { $ref: "#/components/responses/Error" }
        \\  empty:
        \\x-errors:
        \\  e1: { status: 400, message: "'{name}' is bad.", hint: "Use 'mopm x'." }
    ;
    const v = try parseOk(a, doc);
    try std.testing.expectEqualStrings("3.1.0", v.object.get("openapi").?.string);
    const info = v.object.get("info").?.object;
    try std.testing.expectEqualStrings("1.0.0", info.get("version").?.string);
    try std.testing.expectEqualStrings("first line\n\nthird # not a comment\n", info.get("description").?.string);
    try std.testing.expectEqual(@as(i64, 12), info.get("n").?.integer);
    try std.testing.expectEqual(@as(f64, 0.5), info.get("ratio").?.float);
    try std.testing.expect(info.get("off").? == .null);
    const servers = v.object.get("servers").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), servers.len);
    try std.testing.expectEqualStrings("https://{host}/api/v1", servers[0].object.get("url").?.string);
    const hosts = servers[0].object.get("variables").?.object.get("host").?.object.get("enum").?.array.items;
    try std.testing.expectEqualStrings("b.example", hosts[1].string);
    try std.testing.expectEqualStrings("plain", servers[1].string);
    const get = v.object.get("paths").?.object.get("/x/{id}").?.object.get("get").?.object;
    const resp = get.get("responses").?.object;
    const schema = resp.get("200").?.object.get("schema").?.object;
    try std.testing.expectEqual(@as(i64, 5), schema.get("maxLength").?.integer);
    const en = schema.get("enum").?.array.items;
    try std.testing.expectEqualStrings("it's", en[1].string);
    try std.testing.expectEqualStrings("q\"x", en[2].string);
    try std.testing.expectEqualStrings("#/components/h", resp.get("200").?.object.get("headers").?.object.get("h").?.object.get("$ref").?.string);
    try std.testing.expectEqualStrings("#/components/responses/Error", resp.get("default").?.object.get("$ref").?.string);
    try std.testing.expect(v.object.get("paths").?.object.get("empty").? == .null);
    const e1 = v.object.get("x-errors").?.object.get("e1").?.object;
    try std.testing.expectEqualStrings("'{name}' is bad.", e1.get("message").?.string);
}

test "yaml: what the subset does not cover is refused with a message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const refused = [_][]const u8{
        "a: &x 1\n",
        "a: *x\n",
        "a: !!str 1\n",
        "a: >\n  folded\n",
        "a: |+\n  keep\n",
        "a:\n\tb: 1\n",
        "---\na: 1\n",
        "a: 1\na: 2\n",
        "a:\n- x\n- y\n",
        "a: [1,\n  2]\n",
        "a: \"unterminated\n",
        "a: b\n  c\n",
        "a: 1\n b: 2\n",
        "a: {b: 1} extra\n",
        "? complex\n: value\n",
        // A plain scalar in a flow mapping ends at the comma: what follows is a key with no value.
        "a: { d: An URL, from here. }\n",
    };
    for (refused) |text| {
        if (parse(a, text)) |_| {
            std.debug.print("yaml was accepted: {s}\n", .{text});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
