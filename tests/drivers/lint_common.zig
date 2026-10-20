//! What hygiene.zig and workflow_lint.zig share (they began as ports of Ruby scripts, now removed):
//! the reading of the files they check, a few Ruby behaviours the ports keep
//! (truthiness, `to_s`, `inspect`), and the small text matchers that stand in
//! for the Ruby regular expressions.
//!
//! The matchers are hand-written, not a regex engine: each one is the exact
//! meaning of one Ruby pattern (the comment above it says which). Two Ruby
//! details are NOT reproduced: `\b` and `/i` are Unicode-aware in Ruby, and
//! here they are ASCII only, so a non-ASCII letter next to a token counts as a
//! boundary and never folds to an ASCII letter.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const yaml = @import("yaml.zig");

/// The problems a lint found, one printed line each (`hygiene: <file>: ...`).
pub const Out = std.ArrayList([]const u8);

pub fn problem(a: Allocator, out: *Out, comptime fmt: []const u8, args: anytype) !void {
    try out.append(try std.fmt.allocPrint(a, fmt, args));
}

// ---- the files -----------------------------------------------------------

pub const Tree = struct {
    root: []const u8,
    /// Paths relative to `root`, sorted.
    files: []const []const u8,

    pub fn read(self: Tree, a: Allocator, rel: []const u8) ![]u8 {
        const path = try std.fs.path.join(a, &.{ self.root, rel });
        return std.fs.cwd().readFileAlloc(a, path, 64 * 1024 * 1024);
    }
};

/// The files the Buck2 rule staged for the test (BUILDRULES_TEST_WORK: exactly the
/// `data` of the target, so exactly the files the lint is to check).
///
/// Without BUILDRULES_TEST_WORK (a run by `zig test tests/drivers/<lint>_test.zig` from the
/// repository root, as .github/workflows/lint.yml does) the files are the ones git tracks
/// in the current directory (`git ls-files`): the same checkout the pull request holds.
pub fn loadTree(a: Allocator) !Tree {
    const root = std.process.getEnvVarOwned(a, "BUILDRULES_TEST_WORK") catch return trackedTree(a);
    var dir = try std.fs.cwd().openDir(root, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(a);
    defer walker.deinit();
    var files = std.ArrayList([]const u8).init(a);
    while (try walker.next()) |e| {
        if (e.kind == .file) try files.append(try a.dupe(u8, e.path));
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return .{ .root = root, .files = files.items };
}

/// The files git tracks under the current directory, which must be the repository root.
fn trackedTree(a: Allocator) !Tree {
    const r = std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "git", "ls-files", "-z", "--cached" },
        .max_output_bytes = 64 * 1024 * 1024,
    }) catch |err| {
        std.debug.print("BUILDRULES_TEST_WORK is not set and `git ls-files` did not run ({s}): run this from the repository root\n", .{@errorName(err)});
        return error.NoTestWork;
    };
    if (r.term != .Exited or r.term.Exited != 0) {
        std.debug.print("BUILDRULES_TEST_WORK is not set and `git ls-files` failed: {s}\n", .{r.stderr});
        return error.NoTestWork;
    }
    var files = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitScalar(u8, r.stdout, 0);
    while (it.next()) |p| {
        if (p.len == 0) continue;
        // A path git lists but the checkout lacks (a submodule, a deletion) has nothing to scan.
        const st = std.fs.cwd().statFile(p) catch continue;
        if (st.kind != .file) continue;
        try files.append(p);
    }
    std.mem.sort([]const u8, files.items, {}, lessThan);
    return .{ .root = ".", .files = files.items };
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

pub fn hasFile(t: Tree, rel: []const u8) bool {
    for (t.files) |f| if (std.mem.eql(u8, f, rel)) return true;
    return false;
}

pub fn basename(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

/// `.github/workflows/*.{yml,yaml}`, as Dir[] sorts them.
pub fn workflowFiles(a: Allocator, t: Tree) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (t.files) |f| {
        if (!std.mem.startsWith(u8, f, ".github/workflows/")) continue;
        const rest = f[".github/workflows/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
        if (std.mem.endsWith(u8, rest, ".yml") or std.mem.endsWith(u8, rest, ".yaml")) try out.append(f);
    }
    return out.items;
}

// ---- parsed YAML, read the way the Ruby does ---------------------------------

/// YAML.safe_load(text, aliases: false), or why not. (Ruby raises, which ends
/// the script with a backtrace; a port reports it as a problem.)
pub fn load(a: Allocator, text: []const u8) !Value {
    return yaml.parse(a, text);
}

/// `node[key]` for a mapping; nil for anything else or a missing key.
pub fn get(v: ?Value, key: []const u8) ?Value {
    const n = v orelse return null;
    if (n != .object) return null;
    return n.object.get(key);
}

/// Ruby truthiness: nil and false are false.
pub fn truthy(v: ?Value) bool {
    const n = v orelse return false;
    return switch (n) {
        .null => false,
        .bool => |b| b,
        else => true,
    };
}

pub fn isNil(v: ?Value) bool {
    const n = v orelse return true;
    return n == .null;
}

pub fn str(v: ?Value) ?[]const u8 {
    const n = v orelse return null;
    return if (n == .string) n.string else null;
}

/// `v == "text"`.
pub fn isStr(v: ?Value, text: []const u8) bool {
    const s = str(v) orelse return false;
    return std.mem.eql(u8, s, text);
}

pub fn keys(v: ?Value) []const []const u8 {
    const n = v orelse return &.{};
    if (n != .object) return &.{};
    return n.object.keys();
}

/// find_key.(node, key): some mapping anywhere under `node` has `key`.
pub fn findKey(node: Value, key: []const u8) bool {
    switch (node) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.eql(u8, e.key_ptr.*, key) or findKey(e.value_ptr.*, key)) return true;
            }
            return false;
        },
        .array => |arr| {
            for (arr.items) |v| if (findKey(v, key)) return true;
            return false;
        },
        else => return false,
    }
}

/// `doc["on"] || doc[true] || {}` read as the trigger names: a mapping's keys,
/// the name of a bare string, the entries of a list.
pub fn onKeys(a: Allocator, doc: Value) ![]const []const u8 {
    const on = get(doc, "on");
    if (!truthy(on)) return &.{};
    const n = on.?;
    switch (n) {
        .object => return n.object.keys(),
        .string => {
            const one = try a.alloc([]const u8, 1);
            one[0] = n.string;
            return one;
        },
        .array => {
            var out = std.ArrayList([]const u8).init(a);
            for (n.array.items) |v| if (v == .string) try out.append(v.string);
            return out.items;
        },
        else => return &.{},
    }
}

/// The `on` value itself (`doc["on"] || doc[true]`), nil when absent.
pub fn onValue(doc: Value) ?Value {
    const on = get(doc, "on");
    return if (truthy(on)) on else null;
}

pub fn containsStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

/// Array(v) as strings: nil is empty, a string is itself, a list its strings.
pub fn arrayOf(a: Allocator, v: ?Value) ![]const []const u8 {
    const n = v orelse return &.{};
    switch (n) {
        .null => return &.{},
        .string => {
            const one = try a.alloc([]const u8, 1);
            one[0] = n.string;
            return one;
        },
        .array => {
            var out = std.ArrayList([]const u8).init(a);
            for (n.array.items) |x| try out.append(if (x == .string) x.string else "");
            return out.items;
        },
        else => return &.{},
    }
}

pub fn eqlList(x: []const []const u8, y: []const []const u8) bool {
    if (x.len != y.len) return false;
    for (x, y) |p, q| if (!std.mem.eql(u8, p, q)) return false;
    return true;
}

/// Ruby's String#inspect for the strings these files hold.
pub fn inspectStr(a: Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.append('"');
    for (s, 0..) |ch, i| {
        switch (ch) {
            '"' => try out.appendSlice("\\\""),
            '\\' => try out.appendSlice("\\\\"),
            '\n' => try out.appendSlice("\\n"),
            '\t' => try out.appendSlice("\\t"),
            '\r' => try out.appendSlice("\\r"),
            0x1b => try out.appendSlice("\\e"),
            '#' => {
                if (i + 1 < s.len and (s[i + 1] == '{' or s[i + 1] == '$' or s[i + 1] == '@')) try out.append('\\');
                try out.append('#');
            },
            else => try out.append(ch),
        }
    }
    try out.append('"');
    return out.items;
}

/// Array#inspect of strings: `["a", "b"]`.
pub fn inspectList(a: Allocator, items: []const []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.append('[');
    for (items, 0..) |s, i| {
        if (i != 0) try out.appendSlice(", ");
        try out.appendSlice(try inspectStr(a, s));
    }
    try out.append(']');
    return out.items;
}

/// `value.inspect` of a parsed value (Ruby 3.2 spelling of a Hash).
pub fn inspect(a: Allocator, v: ?Value) ![]u8 {
    const n = v orelse return a.dupe(u8, "nil");
    switch (n) {
        .null => return a.dupe(u8, "nil"),
        .bool => |b| return a.dupe(u8, if (b) "true" else "false"),
        .integer => |i| return std.fmt.allocPrint(a, "{d}", .{i}),
        .float => |f| return std.fmt.allocPrint(a, "{d}", .{f}),
        .number_string => |s| return a.dupe(u8, s),
        .string => |s| return inspectStr(a, s),
        .array => |arr| {
            var out = std.ArrayList(u8).init(a);
            try out.append('[');
            for (arr.items, 0..) |x, i| {
                if (i != 0) try out.appendSlice(", ");
                try out.appendSlice(try inspect(a, x));
            }
            try out.append(']');
            return out.items;
        },
        .object => |o| {
            var out = std.ArrayList(u8).init(a);
            try out.append('{');
            var i: usize = 0;
            var it = o.iterator();
            while (it.next()) |e| : (i += 1) {
                if (i != 0) try out.appendSlice(", ");
                try out.appendSlice(try inspectStr(a, e.key_ptr.*));
                try out.appendSlice("=>");
                try out.appendSlice(try inspect(a, e.value_ptr.*));
            }
            try out.append('}');
            return out.items;
        },
    }
}

/// `value.to_s`: nil is empty, a string itself.
pub fn toS(a: Allocator, v: ?Value) ![]const u8 {
    const n = v orelse return "";
    return switch (n) {
        .null => "",
        .string => |s| s,
        else => inspect(a, n),
    };
}

// ---- the text matchers --------------------------------------------------------

pub fn isWord(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '_';
}

/// Ruby's \s.
pub fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r' or ch == 0x0b or ch == 0x0c;
}

pub fn isAlnum(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9');
}

/// A word boundary before `s[i]`, where `s[i]` is a word character.
pub fn boundaryBefore(s: []const u8, i: usize) bool {
    return i == 0 or !isWord(s[i - 1]);
}

/// A word boundary after `s[j - 1]`, a word character.
pub fn boundaryAfter(s: []const u8, j: usize) bool {
    return j >= s.len or !isWord(s[j]);
}

pub fn lower(a: Allocator, s: []const u8) ![]u8 {
    const out = try a.alloc(u8, s.len);
    for (s, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
}

/// ASCII-lower-cased `needle` found in `hay` (both already lower case)
/// with `\b` before it.
pub fn hasWordStart(hay: []const u8, needle: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, hay, from, needle)) |i| : (from = i + 1) {
        if (boundaryBefore(hay, i)) return true;
    }
    return false;
}

/// /\b(?:w1|w2|...)\b/ : some listed word stands alone in `s`.
pub fn hasAnyWord(s: []const u8, words: []const []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (!isWord(s[i]) or !boundaryBefore(s, i)) continue;
        for (words) |w| {
            if (std.mem.startsWith(u8, s[i..], w) and boundaryAfter(s, i + w.len)) return true;
        }
    }
    return false;
}

/// /\bsecrets\.\w+/ (`secrets.` then at least one word character).
pub fn refsSecrets(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "secrets.")) |i| : (from = i + 1) {
        if (!boundaryBefore(s, i)) continue;
        const j = i + "secrets.".len;
        if (j < s.len and isWord(s[j])) return true;
    }
    return false;
}

/// /\bsecrets\./ (case sensitive).
pub fn mentionsSecretsDot(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "secrets.")) |i| : (from = i + 1) {
        if (boundaryBefore(s, i)) return true;
    }
    return false;
}

/// /secrets:\s*inherit/
pub fn hasSecretsInherit(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "secrets:")) |i| : (from = i + 1) {
        var j = i + "secrets:".len;
        while (j < s.len and isSpace(s[j])) j += 1;
        if (std.mem.startsWith(u8, s[j..], "inherit")) return true;
    }
    return false;
}

/// The lines of `text` that do not start (after stripping) with `#`, joined as
/// File.readlines(f).reject { ... }.join does.
pub fn nonCommentLines(a: Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var start: usize = 0;
    while (start < text.len) {
        const end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |n| n + 1 else text.len;
        const line = text[start..end];
        const stripped = std.mem.trim(u8, line, " \t\r\n\x0b\x0c\x00");
        if (!std.mem.startsWith(u8, stripped, "#")) try out.appendSlice(line);
        start = end;
    }
    return out.items;
}

// ---- for the tests ------------------------------------------------------------------

/// `got` has exactly one line per entry of `want`, and each entry of `want`
/// is a substring of some line: the self-test's comparison.
pub fn expectLines(what: []const u8, got: []const []const u8, want: []const []const u8) !void {
    var ok = got.len == want.len;
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.indexOf(u8, g, w) != null) found = true;
        }
        if (!found) ok = false;
    }
    if (ok) return;
    std.debug.print("{s}: expected {d} line(s) containing:\n", .{ what, want.len });
    for (want) |w| std.debug.print("  | {s}\n", .{w});
    std.debug.print("got {d}:\n", .{got.len});
    for (got) |g| std.debug.print("  > {s}\n", .{g});
    return error.TestUnexpectedResult;
}
