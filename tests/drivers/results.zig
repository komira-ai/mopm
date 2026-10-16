//! What the supervisor and retry drivers check `mopm test` results with: a
//! checker that counts failed checks (and can be quiet, so a driver can show
//! that it rejects a doctored result), JSON accessors, and a small XML tree
//! for the JUnit file. Standard library only. The Zig port of the checkers
//! tests/e2e/check_supervisor.py and tests/e2e/check_flaky.py use.

const std = @import("std");
const Allocator = std.mem.Allocator;
pub const J = std.json.Value;

/// Counts checks and failures; prints `FAIL <what>` for each failed check
/// (a driver reports the count of the passed ones).
pub const Chk = struct {
    a: Allocator,
    failures: usize = 0,
    checks: usize = 0,
    /// Print nothing (the self-tests of a checker).
    quiet: bool = false,

    pub fn that(self: *Chk, ok: bool, comptime f: []const u8, args: anytype) void {
        self.checks += 1;
        if (ok) return;
        self.failures += 1;
        if (!self.quiet) {
            const text = std.fmt.allocPrint(self.a, f, args) catch "(out of memory)";
            std.debug.print("FAIL {s}\n", .{text});
        }
    }
};

// ------------------------------------------------------------------ JSON

pub fn field(v: J, key: []const u8) ?J {
    if (v != .object) return null;
    return v.object.get(key);
}

pub fn str(v: ?J) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

pub fn int(v: ?J) ?i64 {
    const x = v orelse return null;
    return if (x == .integer) x.integer else null;
}

pub fn isNull(v: ?J) bool {
    const x = v orelse return true;
    return x == .null;
}

pub fn array(v: ?J) []const J {
    const x = v orelse return &.{};
    return if (x == .array) x.array.items else &.{};
}

/// Whether the object has exactly the keys `keys`.
pub fn hasExactKeys(v: J, keys: []const []const u8) bool {
    if (v != .object or v.object.count() != keys.len) return false;
    for (keys) |k| if (!v.object.contains(k)) return false;
    return true;
}

pub fn parse(a: Allocator, text: []const u8) !J {
    return (try std.json.parseFromSlice(J, a, text, .{})).value;
}

/// The test of `tests` whose `id` is `id`.
pub fn testById(tests: []const J, id: []const u8) ?J {
    for (tests) |t| if (std.mem.eql(u8, str(field(t, "id")) orelse "", id)) return t;
    return null;
}

/// The text of the files `stdout` and `stderr` name (relative to `pkg`).
pub fn outputOf(a: Allocator, pkg: []const u8, t: J) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for ([_][]const u8{ "stdout", "stderr" }) |k| {
        if (str(field(t, k))) |p| {
            const full = try std.fs.path.join(a, &.{ pkg, p });
            const bytes = std.fs.cwd().readFileAlloc(a, full, 64 << 20) catch continue;
            try out.appendSlice(bytes);
        }
    }
    return out.items;
}

pub fn fileExists(a: Allocator, pkg: []const u8, rel: ?[]const u8) bool {
    const p = rel orelse return false;
    const full = std.fs.path.join(a, &.{ pkg, p }) catch return false;
    const st = std.fs.cwd().statFile(full) catch return false;
    return st.kind == .file;
}

// --------------------------------------------------------- doctoring text

/// `text` with `from` replaced by `to`, once, on every line that contains
/// `marker` (sed "/marker/s/from/to/"); null when nothing changed.
pub fn editLines(a: Allocator, text: []const u8, marker: []const u8, from: []const u8, to: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).init(a);
    var changed = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        if (std.mem.indexOf(u8, line, marker) != null) {
            if (std.mem.indexOf(u8, line, from)) |at| {
                try out.appendSlice(line[0..at]);
                try out.appendSlice(to);
                try out.appendSlice(line[at + from.len ..]);
                changed = true;
                continue;
            }
        }
        try out.appendSlice(line);
    }
    return if (changed) out.items else null;
}

/// `text` with the first `from` replaced by `to` (a sed s/// over the file
/// without a marker); null when nothing changed.
pub fn editAll(a: Allocator, text: []const u8, from: []const u8, to: []const u8) !?[]u8 {
    const at = std.mem.indexOf(u8, text, from) orelse return null;
    const out = try std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
    return out;
}

/// `text` with every `from` replaced by `to` (sed s///g); null when none.
pub fn editEvery(a: Allocator, text: []const u8, from: []const u8, to: []const u8) !?[]u8 {
    if (std.mem.indexOf(u8, text, from) == null) return null;
    return try std.mem.replaceOwned(u8, a, text, from, to);
}

// ------------------------------------------------------------------- XML

pub const Node = struct {
    name: []const u8,
    attrs: []const [2][]const u8,
    kids: []const *Node,

    pub fn attr(self: *const Node, key: []const u8) ?[]const u8 {
        for (self.attrs) |kv| if (std.mem.eql(u8, kv[0], key)) return kv[1];
        return null;
    }
};

/// The root element of `text`. Elements, attributes, text, comments, CDATA
/// and the XML declaration; no entities are decoded (attribute values are
/// compared as written).
pub fn parseXml(a: Allocator, text: []const u8) !*Node {
    var stack = std.ArrayList(*std.ArrayList(*Node)).init(a);
    var names = std.ArrayList(*Node).init(a);
    var root: ?*Node = null;
    var i: usize = 0;
    const top = try a.create(std.ArrayList(*Node));
    top.* = std.ArrayList(*Node).init(a);
    try stack.append(top);
    while (i < text.len) {
        const lt = std.mem.indexOfScalarPos(u8, text, i, '<') orelse break;
        i = lt;
        if (std.mem.startsWith(u8, text[i..], "<?")) {
            i = (std.mem.indexOfPos(u8, text, i, "?>") orelse return error.BadXml) + 2;
        } else if (std.mem.startsWith(u8, text[i..], "<!--")) {
            i = (std.mem.indexOfPos(u8, text, i, "-->") orelse return error.BadXml) + 3;
        } else if (std.mem.startsWith(u8, text[i..], "<![CDATA[")) {
            i = (std.mem.indexOfPos(u8, text, i, "]]>") orelse return error.BadXml) + 3;
        } else if (std.mem.startsWith(u8, text[i..], "</")) {
            const gt = std.mem.indexOfScalarPos(u8, text, i, '>') orelse return error.BadXml;
            const kids = stack.pop();
            const node = names.pop();
            node.kids = kids.items;
            i = gt + 1;
        } else {
            // A start tag: name, attributes, "/>" or ">". Quoted values may
            // hold '>' so the tag is scanned, not searched.
            var j = i + 1;
            const name_start = j;
            while (j < text.len and !std.ascii.isWhitespace(text[j]) and text[j] != '>' and text[j] != '/') j += 1;
            const node = try a.create(Node);
            var attrs = std.ArrayList([2][]const u8).init(a);
            var self_closing = false;
            while (true) {
                while (j < text.len and std.ascii.isWhitespace(text[j])) j += 1;
                if (j >= text.len) return error.BadXml;
                if (text[j] == '>') {
                    j += 1;
                    break;
                }
                if (text[j] == '/') {
                    self_closing = true;
                    j += 2;
                    break;
                }
                const k0 = j;
                while (j < text.len and text[j] != '=' and !std.ascii.isWhitespace(text[j])) j += 1;
                const key = text[k0..j];
                while (j < text.len and (text[j] == '=' or std.ascii.isWhitespace(text[j]))) j += 1;
                const q = text[j];
                if (q != '"' and q != '\'') return error.BadXml;
                const v0 = j + 1;
                const v1 = std.mem.indexOfScalarPos(u8, text, v0, q) orelse return error.BadXml;
                try attrs.append(.{ key, text[v0..v1] });
                j = v1 + 1;
            }
            node.* = .{ .name = text[name_start .. name_start + (std.mem.indexOfAny(u8, text[name_start..], " \t\r\n/>") orelse 0)], .attrs = attrs.items, .kids = &.{} };
            try stack.items[stack.items.len - 1].append(node);
            if (stack.items.len == 1 and root == null) root = node;
            if (!self_closing) {
                const kids = try a.create(std.ArrayList(*Node));
                kids.* = std.ArrayList(*Node).init(a);
                try stack.append(kids);
                try names.append(node);
            }
            i = j;
        }
    }
    return root orelse error.BadXml;
}

pub fn children(a: Allocator, n: *const Node, name: []const u8) ![]*Node {
    var out = std.ArrayList(*Node).init(a);
    for (n.kids) |k| if (std.mem.eql(u8, k.name, name)) try out.append(k);
    return out.items;
}

test "xml: nesting, attributes and self-closing tags" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const root = try parseXml(a, "<?xml version=\"1.0\"?>\n<r a=\"1\" b='x>y'><s n=\"2\"><c/><d k=\"v\">text</d></s><s n=\"3\"/></r>\n");
    try std.testing.expectEqualStrings("r", root.name);
    try std.testing.expectEqualStrings("x>y", root.attr("b").?);
    const ss = try children(a, root, "s");
    try std.testing.expectEqual(@as(usize, 2), ss.len);
    try std.testing.expectEqual(@as(usize, 2), ss[0].kids.len);
    try std.testing.expectEqualStrings("c", ss[0].kids[0].name);
    try std.testing.expectEqualStrings("v", ss[0].kids[1].attr("k").?);
    try std.testing.expectEqual(@as(usize, 0), ss[1].kids.len);
}

/// `text` with the span from the first `start` to the end of the first
/// `end` after it, on every line holding `marker`, replaced by `to`
/// (sed "/marker/s/start[^}]*end/to/" shaped); null when nothing changed.
pub fn editSpan(a: Allocator, text: []const u8, marker: []const u8, start: []const u8, end: []const u8, to: []const u8) !?[]u8 {
    var out = std.ArrayList(u8).init(a);
    var changed = false;
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first) try out.append('\n');
        first = false;
        if (std.mem.indexOf(u8, line, marker) != null) {
            if (std.mem.indexOf(u8, line, start)) |s0| {
                if (std.mem.indexOfPos(u8, line, s0 + start.len, end)) |e0| {
                    try out.appendSlice(line[0..s0]);
                    try out.appendSlice(to);
                    try out.appendSlice(line[e0 + end.len ..]);
                    changed = true;
                    continue;
                }
            }
        }
        try out.appendSlice(line);
    }
    return if (changed) out.items else null;
}
