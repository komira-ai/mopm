//! A format-preserving editor for mopm.toml: text in, text out.
//!
//! `setKey` and `removeKey` change one `key = value` entry of one table and
//! keep every other byte as it was: comments, blank lines, key order, spacing,
//! line endings (CRLF stays CRLF) and the presence or absence of the final
//! newline.
//!
//! The editor finds entries with its own line scanner rather than the parser's
//! tree, because it needs byte offsets (where a value starts and ends, where a
//! line ends) that the parser does not keep. The scanner understands the whole
//! lexical layer of TOML (strings of all four kinds, nested arrays and inline
//! tables, comments), so it may skip over a value the `toml` parser refuses;
//! `setKey` therefore parses its result with `toml.parse` and fails if the
//! result is not a document mopm can read.
//!
//! Keys and table names are matched by their decoded text: `"a"`, `'a'` and `a`
//! are one key, and `[ package . metadata ]` is the table `package.metadata`.
//!
//! Not supported (`error.UnsupportedEdit`, never a guess): a table written as
//! an array of tables (`[[x]]`), a table (or one of its parents) written as an
//! inline table or built from dotted keys elsewhere (`x = { ... }`, `x.y = 1`),
//! and a dotted key inside the edited table whose first segment is the key.

const std = @import("std");
const Allocator = std.mem.Allocator;
const toml = @import("toml.zig");

pub const Error = error{
    /// The file or the value is not valid TOML text, or the edited file would not parse.
    InvalidToml,
    /// The edit would need a TOML construct this editor does not rewrite.
    UnsupportedEdit,
    OutOfMemory,
};

/// Sets `key` in `[table]` to `value_toml` (TOML text of one value, such as
/// `"\"^0.4\""` or `"{ path = \"../x\" }"`) and returns the new file text.
///
/// An existing key keeps its spelling, the spacing around `=` and its trailing
/// comment; only the value changes. A new key becomes a new line right after
/// the table's last entry. A missing table is appended at the end of the file.
///
/// The result is parsed with `toml.parse`, so `error.InvalidToml` also means the
/// whole file is outside what mopm reads (an `[[x]]` section, a float or a
/// multi-line string anywhere in it), even if the edited table is fine.
/// `removeKey` does not parse its result and edits such a file.
pub fn setKey(arena: Allocator, src: []const u8, table: []const u8, key: []const u8, value_toml: []const u8) ![]const u8 {
    const target = try parseTablePath(arena, table);
    const value_end = try skipValue(value_toml, 0);
    if (value_end != value_toml.len) return error.InvalidToml;
    const stmts = try scan(arena, src);
    const loc = try locate(arena, stmts, target, key);
    const eol = detectEol(src);
    var out = std.ArrayList(u8).init(arena);

    if (loc.pair) |pair_idx| {
        const s = stmts[pair_idx];
        try out.appendSlice(src[0..s.val_start]);
        try out.appendSlice(value_toml);
        try out.appendSlice(src[s.val_end..]);
    } else if (loc.header) |header_idx| {
        const anchor = stmts[loc.last orelse header_idx];
        if (anchor.end == anchor.content_end) {
            // The anchor line is the last one and has no line end: keep it that way.
            try out.appendSlice(src);
            try out.appendSlice(eol);
            try appendEntry(&out, key, value_toml);
        } else {
            try out.appendSlice(src[0..anchor.end]);
            try appendEntry(&out, key, value_toml);
            try out.appendSlice(eol);
            try out.appendSlice(src[anchor.end..]);
        }
    } else {
        try out.appendSlice(src);
        if (src.len > 0) {
            if (!std.mem.endsWith(u8, src, "\n")) try out.appendSlice(eol);
            if (!endsWithBlankLine(src)) try out.appendSlice(eol);
        }
        try out.append('[');
        try out.appendSlice(std.mem.trim(u8, table, " \t"));
        try out.append(']');
        try out.appendSlice(eol);
        try appendEntry(&out, key, value_toml);
        try out.appendSlice(eol);
    }

    const result = try out.toOwnedSlice();
    try validate(arena, result);
    return result;
}

/// Removes `key` from `[table]`, with its whole line (all lines of a
/// multi-line value, and a trailing comment), and returns the new file text.
/// Returns null when the table or the key is absent. The result is not parsed.
pub fn removeKey(arena: Allocator, src: []const u8, table: []const u8, key: []const u8) !?[]const u8 {
    const target = try parseTablePath(arena, table);
    const stmts = try scan(arena, src);
    const loc = try locate(arena, stmts, target, key);
    if (loc.header == null) return null;
    const pair_idx = loc.pair orelse return null;
    const s = stmts[pair_idx];
    var from = s.start;
    if (s.end == s.content_end and from > 0 and src[from - 1] == '\n') {
        // The removed line was the last and had no line end: the line end before
        // it becomes the file's end of text, as it was before the line was added.
        from -= 1;
        if (from > 0 and src[from - 1] == '\r') from -= 1;
    }
    var out = std.ArrayList(u8).init(arena);
    try out.appendSlice(src[0..from]);
    try out.appendSlice(src[s.end..]);
    return try out.toOwnedSlice();
}

const root_owner = std.math.maxInt(usize);

const Kind = enum { header, array_header, pair };

/// One statement of the file: a table header or a `key = value` pair.
const Stmt = struct {
    kind: Kind,
    /// Decoded name path: of the header, or of the (possibly dotted) key.
    parts: []const []const u8,
    /// Offset of the start of the line the statement starts on.
    start: usize,
    /// Pairs only: the value's first byte and the byte after its last.
    val_start: usize,
    val_end: usize,
    /// The byte after the statement's last content (comment included), before its line end.
    content_end: usize,
    /// The byte after the statement's line end (the end of the file if it has none).
    end: usize,
    /// Pairs only: index of the header the pair sits under, or `root_owner`.
    owner: usize,
};

const Located = struct {
    /// The `[table]` header.
    header: ?usize = null,
    /// The pair with the key.
    pair: ?usize = null,
    /// The last pair of the table.
    last: ?usize = null,
};

const KeyParse = struct { parts: []const []const u8, end: usize };
const StrParse = struct { text: []const u8, end: usize };
const Tail = struct { content_end: usize, end: usize };

fn isBare(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn skipWs(src: []const u8, from: usize) usize {
    var i = from;
    while (i < src.len and (src[i] == ' ' or src[i] == '\t')) i += 1;
    return i;
}

/// "\r\n" when the first line end of the file is one, else "\n".
fn detectEol(src: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, src, '\n')) |n| {
        if (n > 0 and src[n - 1] == '\r') return "\r\n";
    }
    return "\n";
}

fn endsWithBlankLine(src: []const u8) bool {
    return std.mem.endsWith(u8, src, "\n\n") or std.mem.endsWith(u8, src, "\n\r\n");
}

/// Appends `key = value` (no line end), quoting the key if it is not bare.
fn appendEntry(out: *std.ArrayList(u8), key: []const u8, value_toml: []const u8) !void {
    var bare = key.len > 0;
    for (key) |c| {
        if (!isBare(c)) bare = false;
    }
    if (bare) {
        try out.appendSlice(key);
    } else {
        try out.append('"');
        for (key) |c| {
            switch (c) {
                '"' => try out.appendSlice("\\\""),
                '\\' => try out.appendSlice("\\\\"),
                '\n' => try out.appendSlice("\\n"),
                '\r' => try out.appendSlice("\\r"),
                '\t' => try out.appendSlice("\\t"),
                else => {
                    if (c < 0x20 or c == 0x7f) {
                        var buf: [6]u8 = undefined;
                        const esc = std.fmt.bufPrint(&buf, "\\u{X:0>4}", .{c}) catch unreachable;
                        try out.appendSlice(esc);
                    } else {
                        try out.append(c);
                    }
                },
            }
        }
        try out.append('"');
    }
    try out.appendSlice(" = ");
    try out.appendSlice(value_toml);
}

fn validate(arena: Allocator, text: []const u8) Error!void {
    var diag: toml.Diagnostic = .{};
    _ = toml.parse(arena, text, &diag) catch |e| switch (e) {
        error.Invalid => return error.InvalidToml,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn parseTablePath(arena: Allocator, table: []const u8) Error![]const []const u8 {
    const start = skipWs(table, 0);
    if (start >= table.len) return error.UnsupportedEdit;
    const kp = try parseKey(arena, table, start);
    if (skipWs(table, kp.end) != table.len) return error.InvalidToml;
    return kp.parts;
}

fn pathEql(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn pathStartsWith(a: []const []const u8, prefix: []const []const u8) bool {
    if (a.len < prefix.len) return false;
    return pathEql(a[0..prefix.len], prefix);
}

fn concatPath(arena: Allocator, a: []const []const u8, b: []const []const u8) Error![]const []const u8 {
    const buf = try arena.alloc([]const u8, a.len + b.len);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return buf;
}

/// Finds the table's header, the key's pair and the table's last pair, or
/// refuses a file where the table is built in a way this editor cannot edit.
fn locate(arena: Allocator, stmts: []const Stmt, target: []const []const u8, key: []const u8) Error!Located {
    var loc = Located{};
    const no_parts: []const []const u8 = &[_][]const u8{};
    for (stmts, 0..) |s, idx| {
        switch (s.kind) {
            .array_header => {
                if (pathStartsWith(target, s.parts)) return error.UnsupportedEdit;
            },
            .header => {
                if (loc.header == null and pathEql(s.parts, target)) loc.header = idx;
            },
            .pair => {
                const base = if (s.owner == root_owner) no_parts else stmts[s.owner].parts;
                const in_target = s.owner != root_owner and stmts[s.owner].kind == .header and pathEql(base, target);
                if (in_target) {
                    loc.last = idx;
                    if (s.parts.len > 1) {
                        if (std.mem.eql(u8, s.parts[0], key)) return error.UnsupportedEdit;
                    } else if (std.mem.eql(u8, s.parts[0], key)) {
                        loc.pair = idx;
                    }
                } else {
                    const full = try concatPath(arena, base, s.parts);
                    // `x = { ... }` at or above the table.
                    if (pathStartsWith(target, full)) return error.UnsupportedEdit;
                    // A dotted key reaching down into the table from above it.
                    if (base.len < target.len and pathStartsWith(full, target)) return error.UnsupportedEdit;
                }
            },
        }
    }
    return loc;
}

/// After a statement: spaces, an optional comment, then a line end or the end of the file.
fn lineTail(src: []const u8, from: usize) Error!Tail {
    var j = skipWs(src, from);
    if (j < src.len and src[j] == '#') {
        while (j < src.len and src[j] != '\n' and src[j] != '\r') j += 1;
    }
    if (j >= src.len) return .{ .content_end = j, .end = j };
    if (src[j] == '\n') return .{ .content_end = j, .end = j + 1 };
    if (src[j] == '\r' and j + 1 < src.len and src[j + 1] == '\n') return .{ .content_end = j, .end = j + 2 };
    return error.InvalidToml;
}

/// Splits the file into headers and pairs, with the offsets the edits need.
fn scan(arena: Allocator, src: []const u8) Error![]const Stmt {
    var list = std.ArrayList(Stmt).init(arena);
    var i: usize = if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) 3 else 0;
    var owner: usize = root_owner;
    while (i < src.len) {
        const start = i;
        const j = skipWs(src, i);
        if (j >= src.len) break;
        const c = src[j];
        if (c == '\n') {
            i = j + 1;
            continue;
        }
        if (c == '\r') {
            if (j + 1 < src.len and src[j + 1] == '\n') {
                i = j + 2;
                continue;
            }
            return error.InvalidToml;
        }
        if (c == '#') {
            var cj = j;
            while (cj < src.len and src[cj] != '\n') cj += 1;
            i = if (cj < src.len) cj + 1 else cj;
            continue;
        }
        if (c == '[') {
            const is_array = j + 1 < src.len and src[j + 1] == '[';
            const open: usize = if (is_array) 2 else 1;
            const hp = try parseKey(arena, src, skipWs(src, j + open));
            var hk = skipWs(src, hp.end);
            var closed: usize = 0;
            while (closed < open) : (closed += 1) {
                if (hk >= src.len or src[hk] != ']') return error.InvalidToml;
                hk += 1;
            }
            const htail = try lineTail(src, hk);
            const idx = list.items.len;
            try list.append(.{
                .kind = if (is_array) .array_header else .header,
                .parts = hp.parts,
                .start = start,
                .val_start = 0,
                .val_end = 0,
                .content_end = htail.content_end,
                .end = htail.end,
                .owner = root_owner,
            });
            owner = idx;
            i = htail.end;
            continue;
        }
        const pp = try parseKey(arena, src, j);
        var pk = skipWs(src, pp.end);
        if (pk >= src.len or src[pk] != '=') return error.InvalidToml;
        pk = skipWs(src, pk + 1);
        const value_end = try skipValue(src, pk);
        const ptail = try lineTail(src, value_end);
        try list.append(.{
            .kind = .pair,
            .parts = pp.parts,
            .start = start,
            .val_start = pk,
            .val_end = value_end,
            .content_end = ptail.content_end,
            .end = ptail.end,
            .owner = owner,
        });
        i = ptail.end;
    }
    return try list.toOwnedSlice();
}

/// A key of one or more bare or quoted parts joined by dots, decoded.
fn parseKey(arena: Allocator, src: []const u8, from: usize) Error!KeyParse {
    var parts = std.ArrayList([]const u8).init(arena);
    var i = from;
    while (true) {
        if (i >= src.len) return error.InvalidToml;
        const c = src[i];
        if (c == '"') {
            const r = try readBasic(arena, src, i);
            try parts.append(r.text);
            i = r.end;
        } else if (c == '\'') {
            const r = try readLiteral(src, i);
            try parts.append(r.text);
            i = r.end;
        } else {
            var j = i;
            while (j < src.len and isBare(src[j])) j += 1;
            if (j == i) return error.InvalidToml;
            try parts.append(src[i..j]);
            i = j;
        }
        const after = skipWs(src, i);
        if (after < src.len and src[after] == '.') {
            i = skipWs(src, after + 1);
        } else {
            break;
        }
    }
    return .{ .parts = try parts.toOwnedSlice(), .end = i };
}

/// A one-line basic string starting at the quote `start`, escapes decoded.
fn readBasic(arena: Allocator, src: []const u8, start: usize) Error!StrParse {
    var out = std.ArrayList(u8).init(arena);
    var i = start + 1;
    while (true) {
        if (i >= src.len) return error.InvalidToml;
        const c = src[i];
        if (c == '"') return .{ .text = try out.toOwnedSlice(), .end = i + 1 };
        if (c == '\n' or c == '\r') return error.InvalidToml;
        if (c != '\\') {
            try out.append(c);
            i += 1;
            continue;
        }
        if (i + 1 >= src.len) return error.InvalidToml;
        const esc = src[i + 1];
        const simple: ?u8 = switch (esc) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (simple) |byte| {
            try out.append(byte);
            i += 2;
            continue;
        }
        if (esc != 'u' and esc != 'U') return error.InvalidToml;
        const n: usize = if (esc == 'u') 4 else 8;
        if (i + 2 + n > src.len) return error.InvalidToml;
        const cp = std.fmt.parseInt(u32, src[i + 2 .. i + 2 + n], 16) catch return error.InvalidToml;
        if (cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF)) return error.InvalidToml;
        var buf: [4]u8 = undefined;
        const written = std.unicode.utf8Encode(@intCast(cp), &buf) catch return error.InvalidToml;
        try out.appendSlice(buf[0..written]);
        i += 2 + n;
    }
}

/// A one-line literal string starting at the quote `start`.
fn readLiteral(src: []const u8, start: usize) Error!StrParse {
    var i = start + 1;
    while (i < src.len) : (i += 1) {
        if (src[i] == '\'') return .{ .text = src[start + 1 .. i], .end = i + 1 };
        if (src[i] == '\n' or src[i] == '\r') return error.InvalidToml;
    }
    return error.InvalidToml;
}

/// The offset after the value that starts at `from`: a string of any of the
/// four kinds, an array or inline table (which may span lines and hold
/// comments), or a bare word such as a number or `true`.
fn skipValue(src: []const u8, from: usize) Error!usize {
    if (from >= src.len) return error.InvalidToml;
    const c = src[from];
    if (c == '"' or c == '\'') return skipString(src, from);
    if (c == '[' or c == '{') {
        var depth: usize = 0;
        var i = from;
        while (i < src.len) {
            const d = src[i];
            switch (d) {
                '"', '\'' => i = try skipString(src, i),
                '#' => {
                    while (i < src.len and src[i] != '\n') i += 1;
                },
                '[', '{' => {
                    depth += 1;
                    i += 1;
                },
                ']', '}' => {
                    depth -= 1;
                    i += 1;
                    if (depth == 0) return i;
                },
                else => i += 1,
            }
        }
        return error.InvalidToml;
    }
    var j = from;
    while (j < src.len) : (j += 1) {
        switch (src[j]) {
            ' ', '\t', '\n', '\r', ',', ']', '}', '#' => break,
            else => {},
        }
    }
    if (j == from) return error.InvalidToml;
    return j;
}

/// The offset after the string (basic or literal, single or triple quoted) at `from`.
fn skipString(src: []const u8, from: usize) Error!usize {
    const q = src[from];
    const triple = from + 2 < src.len and src[from + 1] == q and src[from + 2] == q;
    var i = from + (if (triple) @as(usize, 3) else @as(usize, 1));
    while (i < src.len) {
        const c = src[i];
        if (q == '"' and c == '\\') {
            i += 2;
            continue;
        }
        if (triple) {
            if (c == q and i + 2 < src.len and src[i + 1] == q and src[i + 2] == q) {
                i += 3;
                // Up to two more quotes belong to the string's content.
                var extra: usize = 0;
                while (extra < 2 and i < src.len and src[i] == q) : (extra += 1) i += 1;
                return i;
            }
        } else {
            if (c == q) return i + 1;
            if (c == '\n' or c == '\r') return error.InvalidToml;
        }
        i += 1;
    }
    return error.InvalidToml;
}

fn expectSet(src: []const u8, table: []const u8, key: []const u8, value: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try setKey(arena_state.allocator(), src, table, key, value);
    try std.testing.expectEqualStrings(want, got);
}

fn expectRemove(src: []const u8, table: []const u8, key: []const u8, want: ?[]const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const got = try removeKey(arena_state.allocator(), src, table, key);
    if (want) |w| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(w, got.?);
    } else {
        try std.testing.expect(got == null);
    }
}

fn expectSetError(src: []const u8, table: []const u8, key: []const u8, value: []const u8, want: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(want, setKey(arena_state.allocator(), src, table, key, value));
}

fn expectRemoveError(src: []const u8, table: []const u8, key: []const u8, want: anyerror) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    try std.testing.expectError(want, removeKey(arena_state.allocator(), src, table, key));
}

test "replacing a value keeps the trailing comment and the spacing" {
    // Catches: rewriting the whole line, which drops the comment or reflows `=`.
    try expectSet(
        "[dependencies]\nfoo   =   \"^0.1\"  # pinned\nbar = 1\n",
        "dependencies",
        "foo",
        "\"^0.2\"",
        "[dependencies]\nfoo   =   \"^0.2\"  # pinned\nbar = 1\n",
    );
}

test "CRLF files stay CRLF on replace and on insert" {
    // Catches: writing a bare LF into a CRLF file, or dropping the CR of the old line.
    try expectSet("[d]\r\nfoo = \"1\"\r\nbar = 2\r\n", "d", "foo", "\"2\"", "[d]\r\nfoo = \"2\"\r\nbar = 2\r\n");
    try expectSet("[d]\r\nfoo = \"1\"\r\nbar = 2\r\n", "d", "baz", "3", "[d]\r\nfoo = \"1\"\r\nbar = 2\r\nbaz = 3\r\n");
}

test "an insert goes after the last entry, before the comments of the next table" {
    // Catches: appending after the blank line and the comment that belong to [dev].
    try expectSet(
        "[dependencies]\na = 1\nb = 2\n\n# about dev\n[dev]\nc = 3\n",
        "dependencies",
        "z",
        "9",
        "[dependencies]\na = 1\nb = 2\nz = 9\n\n# about dev\n[dev]\nc = 3\n",
    );
    // Catches: losing the header line as the anchor when the table has no entries.
    try expectSet("[t]\n\n[u]\n", "t", "k", "1", "[t]\nk = 1\n\n[u]\n");
}

test "a missing table is created at the end of the file" {
    // Catches: a missing blank line, a doubled blank line, or a lost final newline.
    try expectSet("a = 1\n", "t", "k", "1", "a = 1\n\n[t]\nk = 1\n");
    try expectSet("a = 1", "t", "k", "1", "a = 1\n\n[t]\nk = 1\n");
    try expectSet("a = 1\n\n", "t", "k", "1", "a = 1\n\n[t]\nk = 1\n");
    try expectSet("", "t", "k", "1", "[t]\nk = 1\n");
    try expectSet("a = 1\r\n", "t", "k", "1", "a = 1\r\n\r\n[t]\r\nk = 1\r\n");
}

test "a new key that is not bare is quoted" {
    // Catches: writing `a b = 1`, which does not parse.
    try expectSet("[t]\n", "t", "a b", "1", "[t]\n\"a b\" = 1\n");
}

test "removing a single-line entry takes its line and comment, nothing else" {
    // Catches: leaving the comment or a blank line behind, or eating the next line.
    try expectRemove("[t]\na = 1 # c\nb = 2\n", "t", "a", "[t]\nb = 2\n");
    try expectRemove("[t]\r\na = 1\r\nb = 2\r\n", "t", "b", "[t]\r\na = 1\r\n");
}

test "removing a multi-line array or string removes every line of it" {
    // Catches: stopping at the first line and leaving `"y",` and `]` behind.
    try expectRemove(
        "[t]\na = 1\nlist = [\n  \"x\", # first\n  \"y\", # ]\n] # done\nb = 2\n",
        "t",
        "list",
        "[t]\na = 1\nb = 2\n",
    );
    // Catches: ending a multi-line string at its first line, or at a quote-like byte inside it.
    try expectRemove(
        "[t]\ns = \"\"\"\nline \" one\n\\\"\"\" two\"\"\" # c\nb = 2\n",
        "t",
        "s",
        "[t]\nb = 2\n",
    );
}

test "removing an absent key or table gives null" {
    // Catches: an error or an unchanged copy where the caller expects "nothing to do".
    try expectRemove("[t]\na = 1\n", "t", "zz", null);
    try expectRemove("[t]\na = 1\n", "nope", "a", null);
    // Catches: finding the key in a different table.
    try expectRemove("[t]\na = 1\n[u]\nb = 2\n", "t", "b", null);
}

test "quoted keys and quoted tables match by decoded name" {
    // Catches: comparing raw spellings, so 'x' and "x" and x are three keys.
    try expectSet("[\"a.b\"]\n'x' = 1\n\"y.z\" = 2\n", "\"a.b\"", "x", "5", "[\"a.b\"]\n'x' = 5\n\"y.z\" = 2\n");
    try expectRemove("[\"a.b\"]\n'x' = 1\n\"y.z\" = 2\n", "\"a.b\"", "y.z", "[\"a.b\"]\n'x' = 1\n");
    try expectSet("[t]\n\"x\" = 1\n", "t", "x", "2", "[t]\n\"x\" = 2\n");
    // Catches: splitting a quoted table name at its dot.
    try expectRemove("[\"a.b\"]\nx = 1\n[a.b]\ny = 1\n", "\"a.b\"", "y", null);
}

test "a dotted table header matches by decoded path" {
    // Catches: matching the header text byte for byte, so spacing or quotes defeat it.
    try expectSet("[package.metadata]\nk = 1\n", "package.metadata", "k", "2", "[package.metadata]\nk = 2\n");
    try expectSet("[ package . \"metadata\" ]\nk = 1\n", "package.metadata", "k", "2", "[ package . \"metadata\" ]\nk = 2\n");
    try expectSet("[package]\nname = \"x\"\n", "package . metadata", "k", "2", "[package]\nname = \"x\"\n\n[package . metadata]\nk = 2\n");
    // Catches: treating a sub-table's keys as the parent's, or its header as the parent's.
    try expectSet("[t.sub]\nx = 1\n", "t", "a", "2", "[t.sub]\nx = 1\n\n[t]\na = 2\n");
    try expectRemove("[t.sub]\nx = 1\n", "t", "x", null);
}

test "constructs the editor cannot rewrite are refused" {
    // Catches: editing `a` as if `a.b = 1` were not there, leaving a duplicate or a conflict.
    try expectSetError("[t]\na.b = 1\n", "t", "a", "2", error.UnsupportedEdit);
    try expectRemoveError("[t]\na.b = 1\n", "t", "a", error.UnsupportedEdit);
    // Catches: treating an array of tables as a plain table.
    try expectSetError("[[t]]\na = 1\n", "t", "a", "2", error.UnsupportedEdit);
    try expectRemoveError("[[t]]\na = 1\n", "t", "a", error.UnsupportedEdit);
    // Catches: adding a [t] header next to an inline-table definition of t.
    try expectSetError("t = { a = 1 }\n", "t", "b", "2", error.UnsupportedEdit);
    try expectRemoveError("t = { a = 1 }\n", "t", "a", error.UnsupportedEdit);
    try expectSetError("[p]\nm = { a = 1 }\n", "p.m", "b", "2", error.UnsupportedEdit);
    // Catches: adding a [t] header when dotted keys above already build t.
    try expectSetError("t.a = 1\n", "t", "b", "2", error.UnsupportedEdit);
    // Catches: refusing a dotted key of a different name, which is harmless.
    try expectSet("[t]\nx.y = 1\na = 1\n", "t", "a", "2", "[t]\nx.y = 1\na = 2\n");
}

test "a value that does not parse is an error and edits nothing" {
    // Catches: returning text the manifest reader will then refuse.
    try expectSetError("[t]\na = 1\n", "t", "a", "{ oops", error.InvalidToml);
    try expectSetError("[t]\na = 1\n", "t", "a", "1.5", error.InvalidToml);
    try expectSetError("[t]\na = 1\n", "t", "b", "1 2", error.InvalidToml);
    try expectSetError("[t]\na = 1\n", "t", "b", "", error.InvalidToml);
    // Catches: a value that smuggles in a second entry.
    try expectSetError("[t]\na = 1\n", "t", "b", "1\nc = 2", error.InvalidToml);
}

test "setting then removing a key that was absent restores the bytes" {
    // Catches: an insert and a remove that are not inverses (blank lines, final newline, CR).
    const cases = [_][]const u8{
        "[t]\na = 1\n\n[u]\nb = 2\n",
        "[t]\na = 1",
        "[t]\r\na = 1\r\n\r\n# c\r\n[u]\r\nb = 2\r\n",
        "[t]\n",
        "# only a comment\n[t]\nlist = [\n  1,\n]\n",
        "[t]",
        "[t]\r\na = 1",
    };
    for (cases) |original| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const added = try setKey(arena, original, "t", "k", "\"v\"");
        try std.testing.expect(!std.mem.eql(u8, original, added));
        const back = (try removeKey(arena, added, "t", "k")).?;
        try std.testing.expectEqualStrings(original, back);
    }
}

test "keys that share a prefix are different keys" {
    // Catches: matching by prefix, so `http` replaces or removes `http_client`.
    try expectSet("[t]\nhttp_client = 1\nhttp = 2\n", "t", "http", "3", "[t]\nhttp_client = 1\nhttp = 3\n");
    try expectSet("[t]\nhttp_client = 1\n", "t", "http", "3", "[t]\nhttp_client = 1\nhttp = 3\n");
    try expectRemove("[t]\nhttp_client = 1\n", "t", "http", null);
}

test "an indented table header is found and keeps its indent" {
    // Catches: requiring the header at column 0, which appends a second [t].
    try expectSet("  [t]\na = 1\n", "t", "b", "2", "  [t]\na = 1\nb = 2\n");
    try expectSet("  [t]\n", "t", "b", "2", "  [t]\nb = 2\n");
}

test "hash and bracket bytes inside strings and comments are not syntax" {
    // Catches: ending a value at a `#` in a string, or reading `]` in a string as a close.
    try expectSet("[t]\na = \"x#y]\"\nb = 1\n", "t", "a", "2", "[t]\na = 2\nb = 1\n");
    try expectSet("[t]\na = 'x#[y'\nb = 1\n", "t", "b", "2", "[t]\na = 'x#[y'\nb = 2\n");
    try expectRemove("[t]\na = \"x#y]\"\nb = 1\n", "t", "a", "[t]\nb = 1\n");
    // Catches: reading a comment line that starts with `[` as a table header.
    try expectSet("[t]\n# [x] = 1\na = 1\n# [u]\n", "t", "b", "2", "[t]\n# [x] = 1\na = 1\nb = 2\n# [u]\n");
    try expectRemove("[t]\n# [x]\na = 1\n", "x", "a", null);
}

test "a multi-line value is replaced as a whole" {
    // Catches: replacing only up to the first line end, which leaves `1,` and `]` behind.
    try expectSet("[t]\nlist = [\n  1,\n] # c\nb = 2\n", "t", "list", "[2]", "[t]\nlist = [2] # c\nb = 2\n");
}

test "CRLF around multi-line values and a missing final line end" {
    // Catches: mishandling the CR of a multi-line value's lines or of its comment line.
    try expectRemove(
        "[t]\r\nlist = [\r\n  1, # ]\r\n  2,\r\n] # done\r\nb = 2\r\n",
        "t",
        "list",
        "[t]\r\nb = 2\r\n",
    );
    // Catches: leaving the CR of the previous line when the last line has no line end.
    try expectRemove("[t]\r\na = 1\r\nb = 2", "t", "b", "[t]\r\na = 1");
    try expectRemove("[t]\r\na = 1\r\nlist = [\r\n  1,\r\n]", "t", "list", "[t]\r\na = 1");
}

test "a table that is only a header, with no final newline, takes an entry" {
    // Catches: using the missing line end of the header as an insert offset.
    try expectSet("[t]", "t", "k", "1", "[t]\nk = 1");
    try expectSet("[t]\r\na = 1", "t", "k", "1", "[t]\r\na = 1\r\nk = 1");
}

test "removing the only key of a table created by setKey leaves the empty header" {
    // Pins: set on a missing table then remove is not an inverse; the header stays.
    try expectRemove("a = 1\n\n[t]\nk = 1\n", "t", "k", "a = 1\n\n[t]\n");
}

test "a key that clashes with a sub-table is refused by the parse check" {
    // Catches: returning text with `sub` both a table and a key.
    try expectSetError("[t.sub]\nx = 1\n", "t", "sub", "1", error.InvalidToml);
}

test "a table under an array of tables is refused, not only the array itself" {
    // Catches: turning the prefix check into an equality check.
    try expectSetError("[[t]]\na = 1\n", "t.sub", "k", "1", error.UnsupportedEdit);
    try expectRemoveError("[[t]]\na = 1\n", "t.sub", "k", error.UnsupportedEdit);
}

test "setKey parses its result, removeKey does not" {
    // Pins: an `[[x]]` section elsewhere makes setKey fail, while removeKey still edits.
    try expectSetError("[[x]]\na = 1\n", "t", "k", "1", error.InvalidToml);
    try expectRemove("[[x]]\na = 1\n[t]\nk = 1\n", "t", "k", "[[x]]\na = 1\n[t]\n");
}
