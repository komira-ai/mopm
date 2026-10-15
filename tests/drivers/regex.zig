//! A small backtracking regular-expression matcher: the `pattern` keyword of
//! the JSON Schemas under spec/ needs one, and the build has no Python `re`.
//!
//! It implements the ECMA-262 subset those patterns use, and refuses the rest
//! with a message (`error.UnsupportedPattern`) instead of guessing:
//!
//!   literals, `.`, `^`, `$` (end of input only, as ECMA-262; not Python's
//!   "before a final newline"), `|`, groups `( )` and `(?: )` (no captures are
//!   kept), classes `[a-z_]` `[^/]` with ranges, the escapes `\s \S \d \D \w \W
//!   \n \t \r \f \v` and `\` before a punctuation character, and the
//!   quantifiers `* + ? {n} {n,} {n,m}`.
//!
//! Not supported (refused): lookahead and lookbehind, back-references, named
//! groups, lazy and possessive quantifiers, `\b`, `\p{..}`, flags, and any
//! `\` before a letter or digit not listed above. A pattern is matched as
//! `search` (anywhere in the string), as the JSON Schema `pattern` keyword
//! says, over the bytes of the string; none of the patterns matches by code
//! point, so UTF-8 needs no special case.
//!
//! A pattern is compiled to a small program (counted repeats are expanded
//! into copies) and run by backtracking with a step budget, so a pattern that
//! blows up fails the run instead of hanging it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Set = [256]bool;

const Node = union(enum) {
    char: u8,
    any,
    class: *const Set,
    start,
    end,
    cat: []const Node,
    alt: []const Node,
    rep: Rep,

    const Rep = struct { node: *const Node, min: u32, max: ?u32 };
};

const Inst = union(enum) {
    char: u8,
    any,
    class: *const Set,
    /// Try the first target, then the second.
    split: [2]usize,
    jmp: usize,
    start,
    end,
    match,
};

pub const Regex = struct {
    prog: []const Inst,

    /// Compiles `pattern`; prints why and returns `error.UnsupportedPattern`
    /// for anything outside the subset above.
    pub fn compile(a: Allocator, pattern: []const u8) !Regex {
        var p = Parser{ .a = a, .s = pattern };
        const node = try p.parseAlt();
        if (p.i != pattern.len) return p.fail("unbalanced ')'");
        var c = Compiler{ .a = a, .prog = std.ArrayList(Inst).init(a) };
        try c.emit(node);
        try c.prog.append(.match);
        if (c.prog.items.len > 200_000) {
            std.debug.print("pattern {s}: expands to more than 200000 instructions\n", .{pattern});
            return error.UnsupportedPattern;
        }
        return .{ .prog = c.prog.items };
    }

    /// Whether the pattern matches anywhere in `s`.
    pub fn search(self: Regex, s: []const u8) bool {
        var steps: usize = 0;
        var from: usize = 0;
        while (from <= s.len) : (from += 1) {
            if (self.run(0, from, s, &steps)) return true;
        }
        return false;
    }

    fn run(self: Regex, pc0: usize, pos0: usize, s: []const u8, steps: *usize) bool {
        var pc = pc0;
        var pos = pos0;
        while (true) {
            steps.* += 1;
            if (steps.* > 50_000_000) @panic("regex: step budget exceeded (a pattern that backtracks too much)");
            switch (self.prog[pc]) {
                .char => |c| {
                    if (pos < s.len and s[pos] == c) {
                        pos += 1;
                        pc += 1;
                    } else return false;
                },
                .any => {
                    if (pos < s.len and s[pos] != '\n') {
                        pos += 1;
                        pc += 1;
                    } else return false;
                },
                .class => |set| {
                    if (pos < s.len and set[s[pos]]) {
                        pos += 1;
                        pc += 1;
                    } else return false;
                },
                .split => |t| {
                    if (self.run(t[0], pos, s, steps)) return true;
                    pc = t[1];
                },
                .jmp => |t| pc = t,
                .start => {
                    if (pos != 0) return false;
                    pc += 1;
                },
                .end => {
                    if (pos != s.len) return false;
                    pc += 1;
                },
                .match => return true,
            }
        }
    }
};

const Esc = union(enum) { single: u8, set: *const Set };

const Parser = struct {
    a: Allocator,
    s: []const u8,
    i: usize = 0,

    fn fail(self: *Parser, why: []const u8) error{UnsupportedPattern} {
        std.debug.print("pattern {s}: unsupported at offset {d}: {s}\n", .{ self.s, self.i, why });
        return error.UnsupportedPattern;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn parseAlt(self: *Parser) anyerror!Node {
        var branches = std.ArrayList(Node).init(self.a);
        try branches.append(try self.parseCat());
        while (self.peek() == '|') {
            self.i += 1;
            try branches.append(try self.parseCat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alt = branches.items };
    }

    fn parseCat(self: *Parser) anyerror!Node {
        var items = std.ArrayList(Node).init(self.a);
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            var atom = try self.parseAtom();
            while (self.peek()) |q| {
                var min: u32 = 0;
                var max: ?u32 = null;
                switch (q) {
                    '*' => self.i += 1,
                    '+' => {
                        min = 1;
                        self.i += 1;
                    },
                    '?' => {
                        max = 1;
                        self.i += 1;
                    },
                    '{' => {
                        self.i += 1;
                        min = try self.number();
                        max = min;
                        if (self.peek() == ',') {
                            self.i += 1;
                            max = if (self.peek() == '}') null else try self.number();
                        }
                        if (self.peek() != '}') return self.fail("a '{' that is not a quantifier {n}, {n,} or {n,m}");
                        self.i += 1;
                        if (max != null and max.? < min) return self.fail("a quantifier whose maximum is below its minimum");
                    },
                    else => break,
                }
                if (self.peek()) |after| {
                    if (after == '?' or after == '+') return self.fail("lazy and possessive quantifiers");
                }
                const boxed = try self.a.create(Node);
                boxed.* = atom;
                atom = .{ .rep = .{ .node = boxed, .min = min, .max = max } };
            }
            try items.append(atom);
        }
        return .{ .cat = items.items };
    }

    fn number(self: *Parser) !u32 {
        const begin = self.i;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            self.i += 1;
        }
        if (self.i == begin) return self.fail("a quantifier without a number");
        return std.fmt.parseInt(u32, self.s[begin..self.i], 10) catch return self.fail("a quantifier number that is too large");
    }

    fn parseAtom(self: *Parser) anyerror!Node {
        const c = self.s[self.i];
        switch (c) {
            '(' => {
                self.i += 1;
                if (self.peek() == '?') {
                    if (self.i + 1 < self.s.len and self.s[self.i + 1] == ':') {
                        self.i += 2;
                    } else return self.fail("(?...) other than (?: ) (lookaround, named groups, flags)");
                }
                const inner = try self.parseAlt();
                if (self.peek() != ')') return self.fail("a group that is not closed");
                self.i += 1;
                return inner;
            },
            '[' => return self.parseClass(),
            '.' => {
                self.i += 1;
                return .any;
            },
            '^' => {
                self.i += 1;
                return .start;
            },
            '$' => {
                self.i += 1;
                return .end;
            },
            '*', '+', '?' => return self.fail("a quantifier with nothing before it"),
            '{' => return self.fail("a '{' that is not a quantifier"),
            '\\' => switch (try self.escape()) {
                .single => |b| return .{ .char = b },
                .set => |set| return .{ .class = set },
            },
            else => {
                self.i += 1;
                return .{ .char = c };
            },
        }
    }

    fn setOf(self: *Parser, comptime pred: fn (u8) bool, negate: bool) !*const Set {
        const set = try self.a.create(Set);
        for (0..256) |b| set[b] = pred(@intCast(b)) != negate;
        return set;
    }

    fn isSpace(b: u8) bool {
        return b == ' ' or (b >= 9 and b <= 13);
    }
    fn isDigit(b: u8) bool {
        return b >= '0' and b <= '9';
    }
    fn isWord(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }

    /// At a backslash: the byte or set it stands for.
    fn escape(self: *Parser) !Esc {
        self.i += 1;
        const e = self.peek() orelse return self.fail("a pattern that ends in a backslash");
        self.i += 1;
        return switch (e) {
            's' => .{ .set = try self.setOf(isSpace, false) },
            'S' => .{ .set = try self.setOf(isSpace, true) },
            'd' => .{ .set = try self.setOf(isDigit, false) },
            'D' => .{ .set = try self.setOf(isDigit, true) },
            'w' => .{ .set = try self.setOf(isWord, false) },
            'W' => .{ .set = try self.setOf(isWord, true) },
            'n' => .{ .single = '\n' },
            't' => .{ .single = '\t' },
            'r' => .{ .single = '\r' },
            'f' => .{ .single = 12 },
            'v' => .{ .single = 11 },
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/', '-' => .{ .single = e },
            else => return self.fail("an escape other than \\s \\S \\d \\D \\w \\W \\n \\t \\r \\f \\v or a punctuation character"),
        };
    }

    fn parseClass(self: *Parser) anyerror!Node {
        self.i += 1; // [
        const set = try self.a.create(Set);
        @memset(set, false);
        const negate = self.peek() == '^';
        if (negate) self.i += 1;
        while (true) {
            const c = self.peek() orelse return self.fail("a class that is not closed");
            if (c == ']') {
                self.i += 1;
                break;
            }
            const lo: u8 = blk: {
                if (c == '\\') switch (try self.escape()) {
                    .single => |b| break :blk b,
                    .set => |other| {
                        for (0..256) |b| {
                            if (other[b]) set[b] = true;
                        }
                        continue;
                    },
                };
                self.i += 1;
                break :blk c;
            };
            if (self.peek() == '-' and self.i + 1 < self.s.len and self.s[self.i + 1] != ']') {
                self.i += 1;
                const hc = self.s[self.i];
                const hi: u8 = blk: {
                    if (hc == '\\') switch (try self.escape()) {
                        .single => |b| break :blk b,
                        .set => return self.fail("a range that ends in a class escape"),
                    };
                    self.i += 1;
                    break :blk hc;
                };
                if (hi < lo) return self.fail("a range whose end is below its start");
                var x: usize = lo;
                while (x <= hi) : (x += 1) set[x] = true;
            } else {
                set[lo] = true;
            }
        }
        if (negate) {
            for (0..256) |b| set[b] = !set[b];
        }
        return .{ .class = set };
    }
};

const Compiler = struct {
    a: Allocator,
    prog: std.ArrayList(Inst),

    fn emit(self: *Compiler, n: Node) anyerror!void {
        if (self.prog.items.len > 200_000) return error.UnsupportedPattern;
        switch (n) {
            .char => |c| try self.prog.append(.{ .char = c }),
            .any => try self.prog.append(.any),
            .class => |set| try self.prog.append(.{ .class = set }),
            .start => try self.prog.append(.start),
            .end => try self.prog.append(.end),
            .cat => |items| for (items) |it| try self.emit(it),
            .alt => |branches| {
                var jumps = std.ArrayList(usize).init(self.a);
                for (branches, 0..) |b, k| {
                    if (k + 1 < branches.len) {
                        const at = self.prog.items.len;
                        try self.prog.append(.{ .split = .{ 0, 0 } });
                        try self.emit(b);
                        try jumps.append(self.prog.items.len);
                        try self.prog.append(.{ .jmp = 0 });
                        self.prog.items[at] = .{ .split = .{ at + 1, self.prog.items.len } };
                    } else {
                        try self.emit(b);
                    }
                }
                for (jumps.items) |j| self.prog.items[j] = .{ .jmp = self.prog.items.len };
            },
            .rep => |r| {
                var k: u32 = 0;
                while (k < r.min) : (k += 1) try self.emit(r.node.*);
                if (r.max) |mx| {
                    var splits = std.ArrayList(usize).init(self.a);
                    var m: u32 = r.min;
                    while (m < mx) : (m += 1) {
                        try splits.append(self.prog.items.len);
                        try self.prog.append(.{ .split = .{ 0, 0 } });
                        try self.emit(r.node.*);
                    }
                    for (splits.items) |at| self.prog.items[at] = .{ .split = .{ at + 1, self.prog.items.len } };
                } else {
                    const at = self.prog.items.len;
                    try self.prog.append(.{ .split = .{ 0, 0 } });
                    try self.emit(r.node.*);
                    try self.prog.append(.{ .jmp = at });
                    self.prog.items[at] = .{ .split = .{ at + 1, self.prog.items.len } };
                }
            },
        }
    }
};

// ------------------------------------------------------------------ tests

fn expectMatch(a: Allocator, pattern: []const u8, s: []const u8, want: bool) !void {
    const re = try Regex.compile(a, pattern);
    if (re.search(s) != want) {
        std.debug.print("pattern {s} on \"{s}\": want {}\n", .{ pattern, s, want });
        return error.TestUnexpectedResult;
    }
}

test "regex: the subset the specs use, accepting and refusing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const semver = "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)$";
    try expectMatch(a, semver, "1.20.3", true);
    try expectMatch(a, semver, "01.2.3", false);
    try expectMatch(a, semver, "1.2", false);
    try expectMatch(a, semver, "1.2.3\n", false);
    const name = "^[a-z][a-z0-9_]{1,63}$";
    try expectMatch(a, name, "http_client", true);
    try expectMatch(a, name, "a", false);
    try expectMatch(a, name, "Http", false);
    const sha = "^[0-9a-f]{64}$";
    try expectMatch(a, sha, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", true);
    try expectMatch(a, sha, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg", false);
    const loop = "^http://(127\\.0\\.0\\.1|\\[::1\\]|localhost):([1-9][0-9]{0,3}|[1-5][0-9]{4}|6553[0-5])/([^?#\\s]*/)?$";
    try expectMatch(a, loop, "http://127.0.0.1:8080/channel/", true);
    try expectMatch(a, loop, "http://[::1]:1/", true);
    try expectMatch(a, loop, "http://127.0.0.1:0/", false);
    try expectMatch(a, loop, "http://127.0.0.1:65536/", false);
    try expectMatch(a, loop, "http://127.0.0.1/", false);
    try expectMatch(a, loop, "http://localhostx:80/", false);
    try expectMatch(a, loop, "http://localhost:80/a b/", false);
    try expectMatch(a, "^lib[^./]+\\..+$", "libcrypto.so.1", true);
    try expectMatch(a, "^lib[^./]+\\..+$", "libc", false);
    try expectMatch(a, "^mopm_[a-z2-7]{32,64}$", "mopm_" ++ "a" ** 32, true);
    try expectMatch(a, "^mopm_[a-z2-7]{32,64}$", "mopm_" ++ "a" ** 31, false);
    try expectMatch(a, "^mopm_[a-z2-7]{32,64}$", "mopm_" ++ "a" ** 65, false);
    try expectMatch(a, "abc", "xxabcxx", true);
    try expectMatch(a, "^abc", "xxabc", false);
}

test "regex: what is not implemented is refused, not guessed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ "(?=a)", "(?<n>a)", "a*?", "a++", "\\bfoo", "\\p{L}", "(a", "a)", "a{x}", "[a", "*a", "\\1", "a\\" }) |bad| {
        if (Regex.compile(a, bad)) |_| {
            std.debug.print("pattern {s} was accepted\n", .{bad});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}
