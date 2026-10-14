//! Test discovery for `mopm test`: which functions of one Mojo test file are
//! tests, read from the source. Nothing here compiles or runs Mojo, and
//! nothing relies on the compiler's `__functions_in_module()` reflection.
//!
//! A file is one of two kinds:
//!   * bare: no top-level `def main`. Its tests are the top-level functions
//!     named `test_*`; mopm appends a `main` that registers each of them with
//!     `std.testing.TestSuite` (test_harness.zig). Every top-level `test_*`
//!     must have exactly the signature TestSuite runs, `def test_x() raises`
//!     (optionally `-> None`); any other is an error naming the function,
//!     unless the comment line `# mopm: not-a-test` stands directly above
//!     it (or above its decorators), which makes it a helper.
//!   * self-hosted: the file has its own `main`. Its tests are what that main
//!     registers: each explicit registration `<suite>.test[<function>]()`, in
//!     source order, and, if the file calls `TestSuite.discover_tests[...]`,
//!     every top-level `test_*` (which then must all conform: discover_tests
//!     stops at the first that does not, and `not-a-test` cannot exclude one).
//!
//! The lexer skips comments and strings (single, triple-quoted, with any
//! r/b/f/t/u prefix), joins lines inside brackets and after a backslash, and
//! treats only a logical line starting in column 0 as top level, so nested
//! functions, methods and definitions under `comptime if` are never tests.
//! A file the lexer cannot read (an unterminated string, unbalanced brackets,
//! a `def` without a name or parameter list) is an error, never a guess.
//!
//! A test marked `# mopm: ignore "<reason>" <issue>` on the line above it
//! (or above its decorators) is still listed and built, but `mopm test`
//! runs it only with --ignored or --include-ignored. The reason (in double
//! quotes, not empty) and the issue reference (`#<n>`, `<owner>/<repo>#<n>`
//! or an https URL) are both required, so an ignored test is traceable.
//!
//! Errors and warnings carry the 1-based source line. Tests are reported in
//! source line order.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { bare, self_hosted };

pub const Ignore = struct {
    reason: []const u8,
    issue: []const u8,
};

pub const Item = struct {
    name: []const u8,
    line: u32,
    /// Set by `# mopm: ignore`: run only with --ignored/--include-ignored.
    ignore: ?Ignore = null,
};

pub const Diag = struct {
    line: u32,
    message: []const u8,
};

pub const Scan = struct {
    kind: Kind,
    /// The tests, in source line order. With errors, the tests read so far
    /// (none after a lexing error); a caller must not list them.
    tests: []const Item,
    /// `test_*` functions marked `# mopm: not-a-test`.
    helpers: []const Item,
    /// Any error means the file's tests cannot be listed.
    errors: []const Diag,
    warnings: []const Diag,

    pub fn ok(self: Scan) bool {
        return self.errors.len == 0;
    }
};

/// The known directive words. `not-a-test` and `ignore` are implemented; the
/// others are part of the design and refused until the runner implements
/// them, so a file never silently loses one.
const later_directives = [_][]const u8{ "should-abort", "timeout", "serial" };

const TokKind = enum { ident, punct, string, number };

const Tok = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
};

const Def = struct {
    name: []const u8,
    line: u32,
    /// Why the signature is not `() raises`; null when it is.
    bad: ?[]const u8,
    /// The def could not be read at all.
    malformed: bool,
    not_a_test: bool,
    ignore: ?Ignore,
    ignore_line: u32,
};

const DirectiveKind = enum {
    not_a_test,
    ignore,

    fn word(k: DirectiveKind) []const u8 {
        return switch (k) {
            .not_a_test => "not-a-test",
            .ignore => "ignore",
        };
    }
};

const Directive = struct {
    line: u32,
    kind: DirectiveKind,
    ignore: ?Ignore = null,
};

/// Whether `s` is an issue reference: `#<n>`, `<owner>/<repo>#<n>`, or an
/// https URL.
fn isIssueRef(s: []const u8) bool {
    if (std.mem.startsWith(u8, s, "https://")) {
        if (s.len == "https://".len) return false;
        for (s) |c| if (c <= ' ' or c == 0x7f) return false;
        return true;
    }
    const hash = std.mem.lastIndexOfScalar(u8, s, '#') orelse return false;
    const num = s[hash + 1 ..];
    if (num.len == 0) return false;
    for (num) |c| if (!std.ascii.isDigit(c)) return false;
    const repo = s[0..hash];
    if (repo.len == 0) return true;
    const slash = std.mem.indexOfScalar(u8, repo, '/') orelse return false;
    const owner = repo[0..slash];
    const name = repo[slash + 1 ..];
    if (owner.len == 0 or name.len == 0) return false;
    for (repo) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '/')) return false;
    return std.mem.indexOfScalar(u8, name, '/') == null;
}

/// `"<reason>" <issue>`, the text after `ignore`.
fn parseIgnore(text: []const u8) ?Ignore {
    const t = std.mem.trim(u8, text, " \t");
    if (t.len < 2 or t[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, t, 1, '"') orelse return null;
    const reason = std.mem.trim(u8, t[1..close], " \t");
    if (reason.len == 0) return null;
    const issue = std.mem.trim(u8, t[close + 1 ..], " \t");
    if (!isIssueRef(issue)) return null;
    return .{ .reason = reason, .issue = issue };
}

const Scanner = struct {
    arena: Allocator,
    defs: std.ArrayList(Def),
    registrations: std.ArrayList(Item),
    unreadable: std.ArrayList(u32),
    pending: std.ArrayList(Directive),
    errors: std.ArrayList(Diag),
    warnings: std.ArrayList(Diag),
    discovers: bool = false,
    main_line: ?u32 = null,
    /// Set by a lexing error: the rest of the file is not interpreted.
    stopped: bool = false,

    fn init(arena: Allocator) Scanner {
        return .{
            .arena = arena,
            .defs = std.ArrayList(Def).init(arena),
            .registrations = std.ArrayList(Item).init(arena),
            .unreadable = std.ArrayList(u32).init(arena),
            .pending = std.ArrayList(Directive).init(arena),
            .errors = std.ArrayList(Diag).init(arena),
            .warnings = std.ArrayList(Diag).init(arena),
        };
    }

    fn err(self: *Scanner, line: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.errors.append(.{ .line = line, .message = try std.fmt.allocPrint(self.arena, fmt, args) });
    }

    fn warn(self: *Scanner, line: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try self.warnings.append(.{ .line = line, .message = try std.fmt.allocPrint(self.arena, fmt, args) });
    }

    /// Pending directives that no def followed.
    fn dangling(self: *Scanner) Allocator.Error!void {
        for (self.pending.items) |d| {
            try self.err(d.line, "`# mopm: {s}` must stand directly above a top-level def or its decorators", .{d.kind.word()});
        }
        self.pending.clearRetainingCapacity();
    }

    /// A comment that is the whole line, starting in column 0.
    fn comment(self: *Scanner, line: u32, text: []const u8) Allocator.Error!void {
        const body = std.mem.trim(u8, text, " \t\r");
        if (!std.mem.startsWith(u8, body, "mopm:")) return;
        const rest = std.mem.trim(u8, body["mopm:".len..], " \t");
        if (std.mem.eql(u8, rest, "not-a-test")) {
            try self.pending.append(.{ .line = line, .kind = .not_a_test });
            return;
        }
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        const word = rest[0..end];
        if (std.mem.eql(u8, word, "ignore")) {
            const ig = parseIgnore(rest[end..]) orelse {
                try self.err(line, "`# mopm: ignore` needs a reason in double quotes and an issue reference: `# mopm: ignore \"<reason>\" #<n>` (or <owner>/<repo>#<n>, or an https URL)", .{});
                return;
            };
            try self.pending.append(.{ .line = line, .kind = .ignore, .ignore = ig });
            return;
        }
        for (later_directives) |w| {
            if (std.mem.eql(u8, w, word)) {
                try self.err(line, "`# mopm: {s}` is not implemented yet", .{word});
                return;
            }
        }
        try self.err(line, "unknown directive `# mopm: {s}`", .{rest});
    }

    fn logical(self: *Scanner, indent: usize, toks: []const Tok) Allocator.Error!void {
        try self.findRegistrations(toks);
        if (indent != 0) return;
        const t0 = toks[0];
        // A decorator: directives above it stay pending for the def below.
        if (isPunct(t0, "@")) return;
        var k: usize = 0;
        var is_async = false;
        if (isIdent(t0, "async") and toks.len > 1 and isIdent(toks[1], "def")) {
            is_async = true;
            k = 1;
        }
        if (isIdent(toks[k], "def")) return self.def(toks[k..], is_async);
        try self.dangling();
    }

    fn findRegistrations(self: *Scanner, toks: []const Tok) Allocator.Error!void {
        var j: usize = 0;
        while (j < toks.len) : (j += 1) {
            const t = toks[j];
            if (isIdent(t, "discover_tests")) self.discovers = true;
            if (!(isPunct(t, ".") and j + 2 < toks.len and isIdent(toks[j + 1], "test") and isPunct(toks[j + 2], "["))) continue;
            // `.test[a.b.name]`: the function's own name is the last identifier.
            var k = j + 3;
            var last: ?Tok = null;
            var readable = true;
            while (k < toks.len and !isPunct(toks[k], "]")) : (k += 1) {
                if (toks[k].kind == .ident) {
                    last = toks[k];
                } else if (!isPunct(toks[k], ".")) {
                    readable = false;
                }
            }
            if (k >= toks.len or !readable or last == null) {
                try self.unreadable.append(t.line);
            } else {
                try self.registrations.append(.{ .name = last.?.text, .line = last.?.line });
            }
        }
    }

    fn def(self: *Scanner, toks: []const Tok, is_async: bool) Allocator.Error!void {
        const line = toks[0].line;
        var not_a_test = false;
        var directive_line: u32 = 0;
        var ignore: ?Ignore = null;
        var ignore_line: u32 = 0;
        for (self.pending.items) |d| switch (d.kind) {
            .not_a_test => if (!not_a_test) {
                not_a_test = true;
                directive_line = d.line;
            },
            .ignore => if (ignore == null) {
                ignore = d.ignore;
                ignore_line = d.line;
            } else {
                try self.err(d.line, "a second `# mopm: ignore` above the same def (the first is at line {d})", .{ignore_line});
            },
        };
        if (not_a_test and ignore != null) {
            try self.err(ignore_line, "`# mopm: ignore` and `# mopm: not-a-test` above the same def: a helper is never run, so it cannot be ignored", .{});
            ignore = null;
        }
        self.pending.clearRetainingCapacity();
        if (toks.len < 2 or toks[1].kind != .ident) {
            try self.err(line, "malformed def: no function name", .{});
            return;
        }
        const name = toks[1].text;
        const sig = signature(toks[2..], is_async);
        if (std.mem.eql(u8, name, "main")) {
            self.main_line = line;
            if (not_a_test) try self.err(directive_line, "`# mopm: not-a-test` is above main, not above a test_ function", .{});
            if (ignore != null) try self.err(ignore_line, "`# mopm: ignore` is above main, not above a test_ function", .{});
            return;
        }
        if (!std.mem.startsWith(u8, name, "test_")) {
            if (not_a_test) try self.err(directive_line, "`# mopm: not-a-test` is above '{s}', which is not a test_ function", .{name});
            if (ignore != null) try self.err(ignore_line, "`# mopm: ignore` is above '{s}', which is not a test_ function", .{name});
            return;
        }
        for (self.defs.items) |d| {
            if (std.mem.eql(u8, d.name, name)) {
                try self.err(line, "'{s}' is defined twice (first at line {d}); test names in a file must be unique", .{ name, d.line });
                return;
            }
        }
        try self.defs.append(.{
            .name = name,
            .line = line,
            .bad = switch (sig) {
                .conforming => null,
                .nonconforming, .malformed => |why| why,
            },
            .malformed = sig == .malformed,
            .not_a_test = not_a_test,
            .ignore = ignore,
            .ignore_line = ignore_line,
        });
    }

    fn finish(self: *Scanner) Allocator.Error!Scan {
        var tests = std.ArrayList(Item).init(self.arena);
        var helpers = std.ArrayList(Item).init(self.arena);
        const kind: Kind = if (self.main_line == null) .bare else .self_hosted;
        if (!self.stopped) {
            for (self.defs.items) |d| {
                if (d.malformed) {
                    try self.err(d.line, "malformed def of '{s}': {s}", .{ d.name, d.bad.? });
                    continue;
                }
                const registers_all = kind == .bare or self.discovers;
                if (!registers_all) {
                    if (d.not_a_test) try helpers.append(.{ .name = d.name, .line = d.line });
                    continue;
                }
                if (kind == .self_hosted and d.not_a_test) {
                    try self.err(d.line, "'{s}' is marked not-a-test, but discover_tests registers every test_ function; rename it", .{d.name});
                } else if (d.not_a_test) {
                    try helpers.append(.{ .name = d.name, .line = d.line });
                } else if (d.bad) |why| {
                    if (kind == .bare) {
                        try self.err(d.line, "'{s}' {s}; a test is `def {s}() raises:` (mark a helper with `# mopm: not-a-test` above it)", .{ d.name, why, d.name });
                    } else {
                        try self.err(d.line, "'{s}' {s}, and discover_tests stops at a test_ function it cannot run; rename it", .{ d.name, why });
                    }
                } else {
                    try tests.append(.{ .name = d.name, .line = d.line, .ignore = d.ignore });
                }
            }
            if (kind == .self_hosted) {
                for (self.registrations.items) |r| {
                    var item = r;
                    for (self.defs.items) |d| {
                        if (std.mem.eql(u8, d.name, r.name)) item.ignore = d.ignore;
                    }
                    try tests.append(item);
                }
                for (self.defs.items) |d| {
                    if (d.ignore == null or self.discovers) continue;
                    var registered = false;
                    for (self.registrations.items) |r| registered = registered or std.mem.eql(u8, r.name, d.name);
                    if (!registered) try self.err(d.ignore_line, "`# mopm: ignore` is above '{s}', which the file's main does not register", .{d.name});
                }
                for (self.unreadable.items) |l| try self.warn(l, "cannot read the function this `.test[...]` registers; it is not listed", .{});
                if (!self.discovers and self.registrations.items.len == 0) {
                    try self.warn(self.main_line.?, "the file has its own main but no registration mopm can read (`suite.test[f]()` or `TestSuite.discover_tests[...]`); no tests are listed", .{});
                }
            }
            std.sort.insertion(Item, tests.items, {}, itemBefore);
            for (tests.items, 0..) |t, n| {
                for (tests.items[0..n]) |u| {
                    if (std.mem.eql(u8, t.name, u.name)) {
                        try self.err(t.line, "'{s}' is registered twice (also at line {d})", .{ t.name, u.line });
                        break;
                    }
                }
            }
        }
        std.sort.insertion(Diag, self.errors.items, {}, diagBefore);
        std.sort.insertion(Diag, self.warnings.items, {}, diagBefore);
        return .{
            .kind = kind,
            .tests = try tests.toOwnedSlice(),
            .helpers = try helpers.toOwnedSlice(),
            .errors = try self.errors.toOwnedSlice(),
            .warnings = try self.warnings.toOwnedSlice(),
        };
    }
};

fn itemBefore(_: void, a: Item, b: Item) bool {
    return a.line < b.line;
}

fn diagBefore(_: void, a: Diag, b: Diag) bool {
    return a.line < b.line;
}

fn isIdent(t: Tok, s: []const u8) bool {
    return t.kind == .ident and std.mem.eql(u8, t.text, s);
}

fn isPunct(t: Tok, s: []const u8) bool {
    return t.kind == .punct and std.mem.eql(u8, t.text, s);
}

fn isOpen(t: Tok) bool {
    return isPunct(t, "(") or isPunct(t, "[") or isPunct(t, "{");
}

fn isClose(t: Tok) bool {
    return isPunct(t, ")") or isPunct(t, "]") or isPunct(t, "}");
}

/// `toks[k]` opens a group; the index just past its matching close.
fn skipGroup(toks: []const Tok, k: usize) ?usize {
    var depth: usize = 0;
    var j = k;
    while (j < toks.len) : (j += 1) {
        if (isOpen(toks[j])) {
            depth += 1;
        } else if (isClose(toks[j])) {
            depth -= 1;
            if (depth == 0) return j + 1;
        }
    }
    return null;
}

const Sig = union(enum) {
    conforming,
    nonconforming: []const u8,
    malformed: []const u8,
};

/// The signature after the function name, up to the `:` that ends it.
fn signature(toks: []const Tok, is_async: bool) Sig {
    var k: usize = 0;
    var generic = false;
    if (k < toks.len and isPunct(toks[k], "[")) {
        generic = true;
        k = skipGroup(toks, k) orelse return .{ .malformed = "unclosed '['" };
    }
    if (k >= toks.len or !isPunct(toks[k], "(")) return .{ .malformed = "no parameter list after the name" };
    const close = skipGroup(toks, k) orelse return .{ .malformed = "unclosed '('" };
    const has_args = close > k + 2;
    k = close;
    const after_start = k;
    var depth: usize = 0;
    while (k < toks.len) : (k += 1) {
        const t = toks[k];
        if (isOpen(t)) {
            depth += 1;
        } else if (isClose(t)) {
            depth -|= 1;
        } else if (depth == 0 and isPunct(t, ":")) {
            break;
        }
    }
    if (k >= toks.len) return .{ .malformed = "no ':' ends the signature" };
    const after = toks[after_start..k];
    if (is_async) return .{ .nonconforming = "is async" };
    if (generic) return .{ .nonconforming = "has compile-time parameters" };
    if (has_args) return .{ .nonconforming = "takes arguments" };
    if (after.len == 0) return .{ .nonconforming = "does not raise" };
    if (!isIdent(after[0], "raises")) return .{ .nonconforming = "has a signature other than `() raises`" };
    const rest = after[1..];
    if (rest.len == 0) return .conforming;
    if (isPunct(rest[0], "->")) {
        if (rest.len == 2 and isIdent(rest[1], "None")) return .conforming;
        return .{ .nonconforming = "returns a value" };
    }
    return .{ .nonconforming = "raises a typed error" };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or std.ascii.isDigit(c);
}

fn isStringPrefix(s: []const u8) bool {
    if (s.len == 0 or s.len > 2) return false;
    for (s) |c| switch (std.ascii.toLower(c)) {
        'r', 'b', 'f', 't', 'u' => {},
        else => return false,
    };
    return true;
}

/// Where the string literal whose opening quote is at `q` ends (one past the
/// closing quote), or null if it never closes. Advances `line` and
/// `line_start` over the newlines inside it.
fn stringEnd(src: []const u8, q: usize, line: *u32, line_start: *usize) ?usize {
    const quote = src[q];
    const triple = q + 2 < src.len and src[q + 1] == quote and src[q + 2] == quote;
    var j = q + @as(usize, if (triple) 3 else 1);
    while (j < src.len) {
        const d = src[j];
        if (d == '\\') {
            if (j + 1 < src.len and src[j + 1] == '\n') {
                line.* += 1;
                line_start.* = j + 2;
            }
            j += 2;
            continue;
        }
        if (d == '\n') {
            if (!triple) return null;
            line.* += 1;
            j += 1;
            line_start.* = j;
            continue;
        }
        if (d == quote) {
            if (!triple) return j + 1;
            if (j + 2 < src.len and src[j + 1] == quote and src[j + 2] == quote) return j + 3;
        }
        j += 1;
    }
    return null;
}

const Open = struct { ch: u8, line: u32 };

fn closerOf(c: u8) u8 {
    return switch (c) {
        '(' => ')',
        '[' => ']',
        else => '}',
    };
}

fn lex(s: *Scanner, src: []const u8) Allocator.Error!void {
    var toks = std.ArrayList(Tok).init(s.arena);
    var opens = std.ArrayList(Open).init(s.arena);
    var i: usize = 0;
    var line: u32 = 1;
    var line_start: usize = 0;
    // Column of the current logical line's first token.
    var indent: usize = 0;
    // The current physical line holds nothing but white space so far.
    var blank = true;
    while (i < src.len) {
        const c = src[i];
        if (c == '\n') {
            if (opens.items.len == 0) {
                if (toks.items.len > 0) {
                    try s.logical(indent, toks.items);
                    toks.clearRetainingCapacity();
                } else if (blank) {
                    try s.dangling();
                }
            }
            i += 1;
            line += 1;
            line_start = i;
            blank = true;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == 0x0c) {
            i += 1;
            continue;
        }
        if (c == '\\' and i + 1 < src.len and src[i + 1] == '\n') {
            // An explicit line continuation: the logical line goes on.
            i += 2;
            line += 1;
            line_start = i;
            continue;
        }
        if (c == '\\' and i + 2 < src.len and src[i + 1] == '\r' and src[i + 2] == '\n') {
            i += 3;
            line += 1;
            line_start = i;
            continue;
        }
        if (c == '#') {
            const end = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            if (toks.items.len == 0 and opens.items.len == 0 and i == line_start) try s.comment(line, src[i + 1 .. end]);
            blank = false;
            i = end;
            continue;
        }
        blank = false;
        if (toks.items.len == 0) indent = i - line_start;
        const tok_line = line;
        if (c == '"' or c == '\'') {
            const end = stringEnd(src, i, &line, &line_start) orelse {
                try s.err(tok_line, "unterminated string", .{});
                s.stopped = true;
                return;
            };
            try toks.append(.{ .kind = .string, .text = src[i..end], .line = tok_line });
            i = end;
            continue;
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < src.len and isIdentChar(src[j])) j += 1;
            if (j < src.len and (src[j] == '"' or src[j] == '\'') and isStringPrefix(src[i..j])) {
                const end = stringEnd(src, j, &line, &line_start) orelse {
                    try s.err(tok_line, "unterminated string", .{});
                    s.stopped = true;
                    return;
                };
                try toks.append(.{ .kind = .string, .text = src[i..end], .line = tok_line });
                i = end;
                continue;
            }
            try toks.append(.{ .kind = .ident, .text = src[i..j], .line = tok_line });
            i = j;
            continue;
        }
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < src.len and (isIdentChar(src[j]) or src[j] == '.')) j += 1;
            try toks.append(.{ .kind = .number, .text = src[i..j], .line = tok_line });
            i = j;
            continue;
        }
        switch (c) {
            '(', '[', '{' => try opens.append(.{ .ch = c, .line = line }),
            ')', ']', '}' => {
                if (opens.items.len == 0 or closerOf(opens.items[opens.items.len - 1].ch) != c) {
                    try s.err(line, "unmatched '{c}'", .{c});
                    s.stopped = true;
                    return;
                }
                _ = opens.pop();
            },
            else => {},
        }
        const len: usize = if (c == '-' and i + 1 < src.len and src[i + 1] == '>') 2 else 1;
        try toks.append(.{ .kind = .punct, .text = src[i .. i + len], .line = tok_line });
        i += len;
    }
    if (opens.items.len > 0) {
        const o = opens.items[opens.items.len - 1];
        try s.err(o.line, "'{c}' is never closed", .{o.ch});
        s.stopped = true;
        return;
    }
    if (toks.items.len > 0) try s.logical(indent, toks.items);
    try s.dangling();
}

/// Scan one test file's source.
pub fn scan(arena: Allocator, src: []const u8) Allocator.Error!Scan {
    var s = Scanner.init(arena);
    try lex(&s, src);
    return s.finish();
}

/// The scan as text, one fact per line: the golden form under
/// tests/discovery/*.scan.
pub fn render(sc: Scan, w: anytype) !void {
    try w.print("kind {s}\n", .{@tagName(sc.kind)});
    for (sc.tests) |t| {
        try w.print("test {d} {s}", .{ t.line, t.name });
        if (t.ignore) |ig| try w.print(" ignored \"{s}\" {s}", .{ ig.reason, ig.issue });
        try w.writeByte('\n');
    }
    for (sc.helpers) |t| try w.print("helper {d} {s}\n", .{ t.line, t.name });
    for (sc.errors) |d| try w.print("error {d}: {s}\n", .{ d.line, d.message });
    for (sc.warnings) |d| try w.print("warning {d}: {s}\n", .{ d.line, d.message });
}

// ---------------------------------------------------------------- tests

fn scanText(a: Allocator, src: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(a);
    try render(try scan(a, src), buf.writer());
    return buf.items;
}

test "a bare file: top-level test_ functions in line order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try std.testing.expectEqualStrings(
        \\kind bare
        \\test 3 test_b
        \\test 6 test_a
        \\
    , try scanText(a,
        \\def helper() raises:
        \\    pass
        \\def test_b() raises:
        \\    helper()
        \\
        \\def test_a() raises -> None:
        \\    pass
        \\
    ));
}

test "the same text indented, in a comment or in a string is not a test" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try std.testing.expectEqualStrings("kind bare\n", try scanText(a,
        \\# def test_c() raises:
        \\x = "def test_s() raises:"
        \\y = """
        \\def test_t() raises:
        \\"""
        \\struct S:
        \\    def test_m(self) raises:
        \\        pass
        \\
    ));
}

test "an unterminated string stops the scan with an error and no tests" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const sc = try scan(a, "def test_a() raises:\n    pass\nx = '''\n");
    try std.testing.expect(!sc.ok());
    try std.testing.expectEqual(@as(usize, 0), sc.tests.len);
    try std.testing.expectEqual(@as(u32, 3), sc.errors[0].line);
}

// The golden cases: tests/discovery/<case>.mojo is scanned and rendered,
// and must equal tests/discovery/<case>.scan. Every .mojo in that directory
// must be listed here, so a fixture cannot be added and silently skipped.
// Read relative to the working directory: run from the repository root.
pub const golden_cases = [_][]const u8{
    "bare_basic",
    "lookalikes",
    "signatures",
    "nonconforming",
    "none",
    "malformed_string",
    "malformed_bracket",
    "malformed_def",
    "duplicate",
    "directives",
    "ignore",
    "self_hosted_explicit",
    "self_hosted_discover",
    "self_hosted_none",
};

test "golden scans of tests/discovery" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    var failed = false;
    for (golden_cases) |name| {
        const src = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "tests/discovery/{s}.mojo", .{name}), 1 << 20);
        const want = try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "tests/discovery/{s}.scan", .{name}), 1 << 20);
        const got = try scanText(a, src);
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("tests/discovery/{s}.scan differs.\n--- want\n{s}--- got\n{s}---\n", .{ name, want, got });
            failed = true;
        }
    }
    var dir = try std.fs.cwd().openDir("tests/discovery", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    var seen: usize = 0;
    while (try it.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".mojo")) continue;
        seen += 1;
        const stem = e.name[0 .. e.name.len - ".mojo".len];
        var listed = false;
        for (golden_cases) |n| listed = listed or std.mem.eql(u8, n, stem);
        if (!listed) {
            std.debug.print("tests/discovery/{s} is not in golden_cases\n", .{e.name});
            failed = true;
        }
    }
    try std.testing.expectEqual(@as(usize, golden_cases.len), seen);
    try std.testing.expect(!failed);
}

test "ignore in a self-hosted file: on a registered test, refused on one main does not register" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try std.testing.expectEqualStrings(
        \\kind self_hosted
        \\test 6 test_a ignored "slow" #4
        \\test 7 test_b
        \\error 9: `# mopm: ignore` is above 'test_c', which the file's main does not register
        \\
    , try scanText(a,
        \\# mopm: ignore "slow" #4
        \\def test_a() raises:
        \\    pass
        \\def main() raises:
        \\    var s = TestSuite()
        \\    s.test[test_a]()
        \\    s.test[test_b]()
        \\    s^.run()
        \\# mopm: ignore "unregistered" #5
        \\def test_c() raises:
        \\    pass
        \\
    ));
}

test "isIssueRef" {
    for ([_][]const u8{ "#1", "#123", "a/b#9", "komira-ai/mopm#7", "o.x/r_y#10", "https://example.com/i/1" }) |s| {
        if (!isIssueRef(s)) {
            std.debug.print("refused {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "", "#", "#x", "12", "a#1", "/b#1", "a/#1", "a/b/c#1", "a/b#", "https://", "http://example.com/1", "https://a b", "issue-15" }) |s| {
        if (isIssueRef(s)) {
            std.debug.print("accepted {s}\n", .{s});
            return error.TestUnexpectedResult;
        }
    }
}
