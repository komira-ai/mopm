//! A strict subset of TOML 1.0, enough for mopm.toml: tables (`[a.b]`), dotted
//! keys, bare and quoted keys, basic and literal strings, decimal integers,
//! booleans, arrays and inline tables, with comments anywhere TOML allows them.
//!
//! Anything outside the subset (floats, dates, multi-line strings, arrays of
//! tables, hexadecimal integers, ...) is refused with a line:column error rather
//! than guessed at. So are the TOML rules a document can break: a key defined
//! twice, a table defined twice, an inline table extended after it is closed.
//!
//! Columns count bytes from 1. Every error sets `Diagnostic` and returns
//! `error.Invalid`; all memory comes from the arena passed to `parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Pos = struct { line: u32, col: u32 };

pub const Diagnostic = struct {
    pos: Pos = .{ .line = 0, .col = 0 },
    message: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

/// How a table came to exist, which decides what may add keys to it later.
pub const Origin = enum {
    root,
    /// `[a.b]`: the table's own header.
    header,
    /// `a` of `[a.b]` before any `[a]` header: `[a]` may still define it once.
    implicit,
    /// Made by a dotted key (`a.b = 1` makes `a`): more dotted keys may extend it.
    dotted,
    /// `{ ... }`: closed once written.
    inline_table,
};

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []const Value,
    table: *Table,

    /// "a string", "an integer", ...: for error messages.
    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .string => "a string",
            .integer => "an integer",
            .boolean => "a boolean",
            .array => "an array",
            .table => "a table",
        };
    }
};

/// One key of a table. `pos` is where its key starts in the file.
pub const Entry = struct { key: []const u8, value: Value, pos: Pos };

/// A table keeps its keys in file order.
pub const Table = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},
    origin: Origin,
    /// The header's `[`, the dotted key's part, or the inline table's `{`.
    pos: Pos,

    pub fn get(self: *const Table, key: []const u8) ?*const Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }

    fn getMut(self: *Table, key: []const u8) ?*Entry {
        for (self.entries.items) |*e| {
            if (std.mem.eql(u8, e.key, key)) return e;
        }
        return null;
    }
};

/// Sets `diag` to `at` and the formatted message, and returns `error.Invalid`.
pub fn fail(arena: Allocator, diag: *Diagnostic, at: Pos, comptime fmt: []const u8, args: anytype) Error {
    const message = std.fmt.allocPrint(arena, fmt, args) catch return error.OutOfMemory;
    diag.* = .{ .pos = at, .message = message };
    return error.Invalid;
}

/// Parses `src` into its root table, or fails with `diag` set.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!*Table {
    var p = Parser{ .arena = arena, .src = src, .diag = diag };
    return p.document();
}

const KeyPart = struct { name: []const u8, pos: Pos };

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    diag: *Diagnostic,
    i: usize = 0,
    line: u32 = 1,
    line_start: usize = 0,

    fn pos(p: *const Parser) Pos {
        return .{ .line = p.line, .col = @intCast(p.i - p.line_start + 1) };
    }

    fn failAt(p: *Parser, at: Pos, comptime fmt: []const u8, args: anytype) Error {
        return fail(p.arena, p.diag, at, fmt, args);
    }

    fn peek(p: *const Parser) ?u8 {
        return if (p.i < p.src.len) p.src[p.i] else null;
    }

    /// Whether the byte `off` past the cursor is `c`.
    fn isAt(p: *const Parser, off: usize, c: u8) bool {
        return p.i + off < p.src.len and p.src[p.i + off] == c;
    }

    fn is(p: *const Parser, c: u8) bool {
        return p.isAt(0, c);
    }

    /// Describes `c` for an error message: `'x'`, "a space", "the end of the file".
    fn found(p: *Parser, c: ?u8) Error![]const u8 {
        const b = c orelse return "the end of the file";
        if (b > 0x20 and b < 0x7f) return try std.fmt.allocPrint(p.arena, "'{c}'", .{b});
        return switch (b) {
            ' ' => "a space",
            '\t' => "a tab",
            '\n', '\r' => "the end of the line",
            else => "a non-ASCII or control character",
        };
    }

    fn newTable(p: *Parser, origin: Origin, at: Pos) Error!*Table {
        const t = try p.arena.create(Table);
        t.* = .{ .origin = origin, .pos = at };
        return t;
    }

    fn document(p: *Parser) Error!*Table {
        if (!std.unicode.utf8ValidateSlice(p.src)) {
            return p.failAt(.{ .line = 1, .col = 1 }, "the file is not valid UTF-8", .{});
        }
        if (std.mem.startsWith(u8, p.src, "\xEF\xBB\xBF")) {
            p.i = 3;
            p.line_start = 3;
        }
        const root = try p.newTable(.root, .{ .line = 1, .col = 1 });
        var current = root;
        while (true) {
            p.skipWs();
            const c = p.peek() orelse break;
            switch (c) {
                '#', '\n', '\r' => {},
                '[' => current = try p.header(root),
                else => try p.keyValue(current),
            }
            try p.lineEnd();
        }
        return root;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| {
            if (c != ' ' and c != '\t') return;
            p.i += 1;
        }
    }

    /// Steps over the line feed (or CR LF) at the cursor.
    fn newline(p: *Parser) void {
        if (p.is('\r')) p.i += 1;
        p.i += 1;
        p.line += 1;
        p.line_start = p.i;
    }

    /// Steps over a comment, up to (not over) the end of its line.
    fn comment(p: *Parser) Error!void {
        while (p.peek()) |c| {
            if (c == '\n' or c == '\r') return;
            if (isControl(c)) return p.failAt(p.pos(), "control character in a comment", .{});
            p.i += 1;
        }
    }

    /// After a header or a key/value pair: optional spaces and comment, then the
    /// end of the line or of the file.
    fn lineEnd(p: *Parser) Error!void {
        p.skipWs();
        if (p.is('#')) try p.comment();
        const c = p.peek() orelse return;
        switch (c) {
            '\n' => p.newline(),
            '\r' => {
                if (!p.isAt(1, '\n')) {
                    return p.failAt(p.pos(), "a carriage return must be followed by a line feed", .{});
                }
                p.newline();
            },
            else => return p.failAt(p.pos(), "expected the end of the line, found {s}", .{try p.found(c)}),
        }
    }

    /// `[a.b]`: makes or opens the table and returns it.
    fn header(p: *Parser, root: *Table) Error!*Table {
        const open = p.pos();
        p.i += 1;
        if (p.is('[')) {
            return p.failAt(open, "arrays of tables ([[...]]) are not supported; write an inline array of tables instead", .{});
        }
        p.skipWs();
        const parts = try p.key();
        p.skipWs();
        if (!p.is(']')) {
            return p.failAt(p.pos(), "expected ']' to close the table header, found {s}", .{try p.found(p.peek())});
        }
        p.i += 1;
        var t = root;
        for (parts[0 .. parts.len - 1]) |part| {
            if (t.getMut(part.name)) |e| {
                switch (e.value) {
                    .table => |sub| {
                        if (sub.origin == .inline_table) {
                            return p.failAt(part.pos, "'{s}' is an inline table; it cannot be extended", .{part.name});
                        }
                        t = sub;
                    },
                    else => return p.failAt(part.pos, "'{s}' is {s}, not a table", .{ part.name, e.value.typeName() }),
                }
            } else {
                const sub = try p.newTable(.implicit, open);
                try t.entries.append(p.arena, .{ .key = part.name, .value = .{ .table = sub }, .pos = part.pos });
                t = sub;
            }
        }
        const last = parts[parts.len - 1];
        if (t.getMut(last.name)) |e| {
            switch (e.value) {
                .table => |sub| {
                    if (sub.origin == .implicit) {
                        sub.origin = .header;
                        sub.pos = open;
                        return sub;
                    }
                    const full = try joinKey(p.arena, parts);
                    return p.failAt(open, "table [{s}] is already defined (at {d}:{d})", .{ full, sub.pos.line, sub.pos.col });
                },
                else => return p.failAt(last.pos, "'{s}' is {s}, not a table", .{ last.name, e.value.typeName() }),
            }
        }
        const sub = try p.newTable(.header, open);
        try t.entries.append(p.arena, .{ .key = last.name, .value = .{ .table = sub }, .pos = last.pos });
        return sub;
    }

    /// A key: one or more bare or quoted parts joined by dots.
    fn key(p: *Parser) Error![]const KeyPart {
        var parts = std.ArrayList(KeyPart).init(p.arena);
        while (true) {
            const at = p.pos();
            const c = p.peek() orelse return p.failAt(at, "expected a key, found the end of the file", .{});
            const name = switch (c) {
                '"' => try p.basicString(),
                '\'' => try p.literalString(),
                else => blk: {
                    const start = p.i;
                    while (p.peek()) |b| : (p.i += 1) {
                        if (!isBareKeyChar(b)) break;
                    }
                    if (p.i == start) return p.failAt(at, "expected a key, found {s}", .{try p.found(c)});
                    break :blk p.src[start..p.i];
                },
            };
            try parts.append(.{ .name = name, .pos = at });
            p.skipWs();
            if (!p.is('.')) break;
            p.i += 1;
            p.skipWs();
        }
        return try parts.toOwnedSlice();
    }

    /// `key = value`, added to `table`.
    fn keyValue(p: *Parser, table: *Table) Error!void {
        const parts = try p.key();
        if (!p.is('=')) {
            return p.failAt(p.pos(), "expected '=' after the key, found {s}", .{try p.found(p.peek())});
        }
        p.i += 1;
        p.skipWs();
        const v = try p.value();
        try p.insert(table, parts, v);
    }

    fn insert(p: *Parser, table: *Table, parts: []const KeyPart, v: Value) Error!void {
        var t = table;
        for (parts[0 .. parts.len - 1]) |part| {
            if (t.getMut(part.name)) |e| {
                switch (e.value) {
                    .table => |sub| switch (sub.origin) {
                        .dotted => t = sub,
                        .inline_table => return p.failAt(part.pos, "'{s}' is an inline table; it cannot be extended", .{part.name}),
                        else => return p.failAt(part.pos, "'{s}' is a table with its own [header]; add keys to it there", .{part.name}),
                    },
                    else => return p.failAt(part.pos, "'{s}' is {s}, not a table", .{ part.name, e.value.typeName() }),
                }
            } else {
                const sub = try p.newTable(.dotted, part.pos);
                try t.entries.append(p.arena, .{ .key = part.name, .value = .{ .table = sub }, .pos = part.pos });
                t = sub;
            }
        }
        const last = parts[parts.len - 1];
        if (t.get(last.name)) |e| {
            const full = try joinKey(p.arena, parts);
            return p.failAt(parts[0].pos, "duplicate key '{s}' (first defined at {d}:{d})", .{ full, e.pos.line, e.pos.col });
        }
        try t.entries.append(p.arena, .{ .key = last.name, .value = v, .pos = parts[0].pos });
    }

    fn value(p: *Parser) Error!Value {
        const at = p.pos();
        const c = p.peek() orelse return p.failAt(at, "expected a value, found the end of the file", .{});
        switch (c) {
            '"' => return .{ .string = try p.basicString() },
            '\'' => return .{ .string = try p.literalString() },
            '[' => return .{ .array = try p.array() },
            '{' => return .{ .table = try p.inlineTable() },
            else => {},
        }
        const start = p.i;
        while (p.peek()) |b| : (p.i += 1) {
            if (isDelimiter(b)) break;
        }
        const word = p.src[start..p.i];
        if (word.len == 0) return p.failAt(at, "expected a value, found {s}", .{try p.found(c)});
        if (std.mem.eql(u8, word, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, word, "false")) return .{ .boolean = false };
        return .{ .integer = try p.integer(word, at) };
    }

    fn integer(p: *Parser, word: []const u8, at: Pos) Error!i64 {
        var digits = word;
        if (digits[0] == '+' or digits[0] == '-') digits = digits[1..];
        if (digits.len == 0 or !std.ascii.isDigit(digits[0])) {
            return p.failAt(at, "unsupported value '{s}': a value is a string, an integer, a boolean, an array or an inline table", .{word});
        }
        for (digits) |d| {
            if (std.ascii.isDigit(d)) continue;
            switch (d) {
                '.', 'e', 'E' => return p.failAt(at, "floats are not supported ('{s}'); write the value as a string", .{word}),
                '-', ':', 'T', 'Z' => return p.failAt(at, "dates and times are not supported ('{s}'); write the value as a string", .{word}),
                '_' => return p.failAt(at, "underscores in integers are not supported ('{s}')", .{word}),
                'x', 'o', 'b' => return p.failAt(at, "only decimal integers are supported ('{s}')", .{word}),
                else => return p.failAt(at, "invalid integer '{s}'", .{word}),
            }
        }
        if (digits.len > 1 and digits[0] == '0') {
            return p.failAt(at, "an integer may not have a leading zero ('{s}')", .{word});
        }
        return std.fmt.parseInt(i64, word, 10) catch return p.failAt(at, "integer '{s}' does not fit in 64 bits", .{word});
    }

    fn basicString(p: *Parser) Error![]const u8 {
        const at = p.pos();
        if (std.mem.startsWith(u8, p.src[p.i..], "\"\"\"")) {
            return p.failAt(at, "multi-line strings (\"\"\") are not supported", .{});
        }
        p.i += 1;
        var out = std.ArrayList(u8).init(p.arena);
        while (true) {
            const c = p.peek() orelse return p.failAt(at, "unterminated string", .{});
            switch (c) {
                '"' => {
                    p.i += 1;
                    return try out.toOwnedSlice();
                },
                '\\' => try p.escape(&out),
                '\n', '\r' => return p.failAt(at, "unterminated string (a string ends on the line it starts)", .{}),
                else => {
                    if (isControl(c)) return p.failAt(p.pos(), "control character in a string; write it as an escape", .{});
                    try out.append(c);
                    p.i += 1;
                },
            }
        }
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) Error!void {
        const at = p.pos();
        p.i += 1;
        const c = p.peek() orelse return p.failAt(at, "unterminated string", .{});
        p.i += 1;
        switch (c) {
            'b' => try out.append(0x08),
            't' => try out.append('\t'),
            'n' => try out.append('\n'),
            'f' => try out.append(0x0c),
            'r' => try out.append('\r'),
            '"' => try out.append('"'),
            '\\' => try out.append('\\'),
            'u', 'U' => {
                const n: usize = if (c == 'u') 4 else 8;
                if (p.i + n > p.src.len) return p.failAt(at, "truncated \\{c} escape", .{c});
                const hex = p.src[p.i .. p.i + n];
                for (hex) |h| {
                    if (!std.ascii.isHex(h)) return p.failAt(at, "invalid \\{c} escape: '{s}' is not {d} hexadecimal digits", .{ c, hex, n });
                }
                const cp = std.fmt.parseInt(u32, hex, 16) catch unreachable;
                if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) {
                    return p.failAt(at, "\\{c}{s} is not a Unicode scalar value", .{ c, hex });
                }
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch unreachable;
                try out.appendSlice(buf[0..len]);
                p.i += n;
            },
            else => return p.failAt(at, "unknown escape sequence; the escapes are \\b \\t \\n \\f \\r \\\" \\\\ \\uXXXX \\UXXXXXXXX", .{}),
        }
    }

    fn literalString(p: *Parser) Error![]const u8 {
        const at = p.pos();
        if (std.mem.startsWith(u8, p.src[p.i..], "'''")) {
            return p.failAt(at, "multi-line strings (''') are not supported", .{});
        }
        p.i += 1;
        const start = p.i;
        while (true) {
            const c = p.peek() orelse return p.failAt(at, "unterminated string", .{});
            if (c == '\'') {
                const s = p.src[start..p.i];
                p.i += 1;
                return s;
            }
            if (c == '\n' or c == '\r') return p.failAt(at, "unterminated string (a string ends on the line it starts)", .{});
            if (isControl(c)) return p.failAt(p.pos(), "control character in a string", .{});
            p.i += 1;
        }
    }

    /// Spaces, line ends and comments between the elements of an array.
    fn arraySpace(p: *Parser) Error!void {
        while (p.peek()) |c| {
            switch (c) {
                ' ', '\t' => p.i += 1,
                '\n' => p.newline(),
                '\r' => {
                    if (!p.isAt(1, '\n')) {
                        return p.failAt(p.pos(), "a carriage return must be followed by a line feed", .{});
                    }
                    p.newline();
                },
                '#' => try p.comment(),
                else => return,
            }
        }
    }

    fn array(p: *Parser) Error![]const Value {
        const at = p.pos();
        p.i += 1;
        var items = std.ArrayList(Value).init(p.arena);
        while (true) {
            try p.arraySpace();
            const c = p.peek() orelse return p.failAt(at, "unterminated array", .{});
            if (c == ']') {
                p.i += 1;
                return try items.toOwnedSlice();
            }
            try items.append(try p.value());
            try p.arraySpace();
            const d = p.peek() orelse return p.failAt(at, "unterminated array", .{});
            switch (d) {
                ',' => p.i += 1,
                ']' => {
                    p.i += 1;
                    return try items.toOwnedSlice();
                },
                else => return p.failAt(p.pos(), "expected ',' or ']' in the array, found {s}", .{try p.found(d)}),
            }
        }
    }

    fn inlineTable(p: *Parser) Error!*Table {
        const at = p.pos();
        p.i += 1;
        // Built as a dotted table so its own dotted keys may nest; closed below.
        const t = try p.newTable(.dotted, at);
        p.skipWs();
        if (p.is('}')) {
            p.i += 1;
            t.origin = .inline_table;
            return t;
        }
        while (true) {
            p.skipWs();
            const c = p.peek() orelse return p.failAt(at, "unterminated inline table", .{});
            switch (c) {
                '\n', '\r' => return p.failAt(p.pos(), "an inline table must be on one line", .{}),
                '}' => return p.failAt(p.pos(), "trailing comma in an inline table", .{}),
                else => {},
            }
            try p.keyValue(t);
            p.skipWs();
            const d = p.peek() orelse return p.failAt(at, "unterminated inline table", .{});
            switch (d) {
                ',' => p.i += 1,
                '}' => {
                    p.i += 1;
                    t.origin = .inline_table;
                    return t;
                },
                '\n', '\r' => return p.failAt(p.pos(), "an inline table must be on one line", .{}),
                else => return p.failAt(p.pos(), "expected ',' or '}}' in the inline table, found {s}", .{try p.found(d)}),
            }
        }
    }
};

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ']', '}', '#' => true,
        else => false,
    };
}

fn isControl(c: u8) bool {
    return (c < 0x20 and c != '\t') or c == 0x7f;
}

/// `a.b.c` for messages.
pub fn joinKey(arena: Allocator, parts: anytype) Error![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    for (parts, 0..) |part, n| {
        if (n > 0) try out.append('.');
        try out.appendSlice(part.name);
    }
    return try out.toOwnedSlice();
}

fn expectRefused(src: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    if (parse(arena, src, &diag)) |_| {
        std.debug.print("accepted: {s}\n", .{src});
        return error.TestUnexpectedResult;
    } else |e| {
        if (e != error.Invalid) return e;
    }
    const got = try std.fmt.allocPrint(arena, "{d}:{d}: {s}", .{ diag.pos.line, diag.pos.col, diag.message });
    try std.testing.expectEqualStrings(want, got);
}

test "values, dotted keys, headers and inline tables" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostic = .{};
    const root = try parse(arena,
        \\# top
        \\a.b = "x\tyé" # trailing
        \\n = -42
        \\[t]
        \\list = [ 1, 'lit', [true],
        \\  { k = false }, # inside
        \\]
        \\"quoted key" = {}
        \\
    , &diag);
    const a = root.get("a").?.value.table;
    try std.testing.expectEqualStrings("x\ty\u{e9}", a.get("b").?.value.string);
    try std.testing.expectEqual(@as(i64, -42), root.get("n").?.value.integer);
    const t = root.get("t").?.value.table;
    const list = t.get("list").?.value.array;
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqualStrings("lit", list[1].string);
    try std.testing.expect(list[2].array[0].boolean);
    try std.testing.expect(!list[3].table.get("k").?.value.boolean);
    try std.testing.expectEqual(Origin.inline_table, t.get("quoted key").?.value.table.origin);
}

test "the TOML rules a document can break are refused" {
    try expectRefused("a = 1\na = 2\n", "2:1: duplicate key 'a' (first defined at 1:1)");
    try expectRefused("[t]\n[t]\n", "2:1: table [t] is already defined (at 1:1)");
    try expectRefused("t = { a = 1 }\nt.b = 2\n", "2:1: 't' is an inline table; it cannot be extended");
    try expectRefused("a.b = 1\n[a]\n", "2:1: table [a] is already defined (at 1:1)");
    try expectRefused("a = 1 2\n", "1:7: expected the end of the line, found '2'");
    try expectRefused("a = { b = 1, }\n", "1:14: trailing comma in an inline table");
}

test "constructs outside the subset are refused, not guessed" {
    try expectRefused("a = 1.5\n", "1:5: floats are not supported ('1.5'); write the value as a string");
    try expectRefused("a = 2026-10-14\n", "1:5: dates and times are not supported ('2026-10-14'); write the value as a string");
    try expectRefused("a = 0x10\n", "1:5: only decimal integers are supported ('0x10')");
    try expectRefused("a = \"\"\"x\"\"\"\n", "1:5: multi-line strings (\"\"\") are not supported");
    try expectRefused("[[t]]\n", "1:1: arrays of tables ([[...]]) are not supported; write an inline array of tables instead");
    try expectRefused("a = inf\n", "1:5: unsupported value 'inf': a value is a string, an integer, a boolean, an array or an inline table");
}
