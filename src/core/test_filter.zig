//! Which tests `mopm test` runs: the name filters and the ignored tests.
//! Nothing here touches files or processes.
//!
//! A test's id is `<file>::<name>`. A pattern selects a test when:
//!   * with --exact: the pattern equals the id;
//!   * a pattern holding `*`, `?` or `[` is a glob, matched against the
//!     whole id and against the bare name (either is enough): `*` is any
//!     run of characters (`/` and `:` included), `?` one character,
//!     `[abc]`, `[a-z]`, `[!a]` one character of a set;
//!   * any other pattern is a substring of the id.
//! No pattern selects every test. A test is filtered out when no pattern
//! selects it, or when a `--skip` pattern (same rules) selects it.
//!
//! Of the tests the patterns keep, a test marked `# mopm: ignore` is SKIP
//! (reported, not run) by default; --ignored runs only the ignored tests
//! (the others are filtered out) and --include-ignored runs both.

const std = @import("std");

pub const Ignored = enum { skip, only, include };

pub const Filter = struct {
    patterns: []const []const u8 = &.{},
    skips: []const []const u8 = &.{},
    exact: bool = false,
    ignored: Ignored = .skip,
};

pub const Choice = enum {
    /// Run it.
    run,
    /// Report it as SKIP without running it (an ignored test).
    skip,
    /// Leave it out of the run and the report (counted as filtered out).
    out,
};

pub fn choose(f: Filter, id: []const u8, name: []const u8, is_ignored: bool) Choice {
    var kept = f.patterns.len == 0;
    for (f.patterns) |p| kept = kept or matches(f.exact, p, id, name);
    for (f.skips) |p| kept = kept and !matches(f.exact, p, id, name);
    if (!kept) return .out;
    return switch (f.ignored) {
        .skip => if (is_ignored) .skip else .run,
        .only => if (is_ignored) .run else .out,
        .include => .run,
    };
}

pub fn matches(exact: bool, pattern: []const u8, id: []const u8, name: []const u8) bool {
    if (exact) return std.mem.eql(u8, pattern, id);
    if (std.mem.indexOfAny(u8, pattern, "*?[") != null) return glob(pattern, id) or glob(pattern, name);
    return std.mem.indexOf(u8, id, pattern) != null;
}

/// `[...]` at `p[i]`: whether `c` is in the set, and the index after `]`;
/// null when the bracket never closes (then `[` is an ordinary character).
fn class(p: []const u8, i: usize, c: u8) ?struct { in: bool, next: usize } {
    var j = i + 1;
    var negate = false;
    if (j < p.len and (p[j] == '!' or p[j] == '^')) {
        negate = true;
        j += 1;
    }
    var in = false;
    var first = true;
    while (j < p.len and (first or p[j] != ']')) {
        first = false;
        if (j + 2 < p.len and p[j + 1] == '-' and p[j + 2] != ']') {
            if (p[j] <= c and c <= p[j + 2]) in = true;
            j += 3;
        } else {
            if (p[j] == c) in = true;
            j += 1;
        }
    }
    if (j >= p.len) return null;
    return .{ .in = in != negate, .next = j + 1 };
}

/// Whether glob `p` matches all of `s`.
pub fn glob(p: []const u8, s: []const u8) bool {
    var pi: usize = 0;
    var si: usize = 0;
    // The last `*` seen, and where in `s` it is tried to end next.
    var star_p: ?usize = null;
    var star_s: usize = 0;
    while (si < s.len) {
        if (pi < p.len) {
            switch (p[pi]) {
                '*' => {
                    star_p = pi;
                    star_s = si;
                    pi += 1;
                    continue;
                },
                '?' => {
                    pi += 1;
                    si += 1;
                    continue;
                },
                '[' => if (class(p, pi, s[si])) |cl| {
                    if (cl.in) {
                        pi = cl.next;
                        si += 1;
                        continue;
                    }
                } else if (s[si] == '[') {
                    pi += 1;
                    si += 1;
                    continue;
                },
                else => if (p[pi] == s[si]) {
                    pi += 1;
                    si += 1;
                    continue;
                },
            }
        }
        // Mismatch: let the last `*` take one more character.
        const sp = star_p orelse return false;
        pi = sp + 1;
        star_s += 1;
        si = star_s;
    }
    while (pi < p.len and p[pi] == '*') pi += 1;
    return pi == p.len;
}

// ---------------------------------------------------------------- tests

test "glob" {
    const yes = [_][2][]const u8{
        .{ "*", "" },
        .{ "*", "tests/a.mojo::test_x" },
        .{ "test_*", "test_alpha_one" },
        .{ "*alpha*", "tests/t.mojo::test_alpha_two" },
        .{ "tests/*.mojo::test_?eta", "tests/t.mojo::test_beta" },
        .{ "test_[ab]*", "test_beta" },
        .{ "test_[a-c]x", "test_bx" },
        .{ "test_[!a]x", "test_bx" },
        .{ "a*b*c", "aXXbYYc" },
        .{ "a[", "a[" },
        .{ "[]]x", "]x" },
    };
    for (yes) |c| {
        if (!glob(c[0], c[1])) {
            std.debug.print("glob {s} should match {s}\n", .{ c[0], c[1] });
            return error.TestUnexpectedResult;
        }
    }
    const no = [_][2][]const u8{
        .{ "test_*", "tests/a.mojo::test_x" },
        .{ "test_?", "test_ab" },
        .{ "test_[ab]*", "test_cab" },
        .{ "test_[!a]x", "test_ax" },
        .{ "a*b*c", "aXXbYY" },
        .{ "", "x" },
        .{ "abc", "ab" },
    };
    for (no) |c| {
        if (glob(c[0], c[1])) {
            std.debug.print("glob {s} should not match {s}\n", .{ c[0], c[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "choose: substring, glob on id or name, exact, skip, ignored" {
    const id = "tests/test_names.mojo::test_alpha_one";
    const name = "test_alpha_one";
    try std.testing.expectEqual(Choice.run, choose(.{}, id, name, false));
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{"alpha"} }, id, name, false));
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{"names.mojo::test_a"} }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{"beta"} }, id, name, false));
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{ "beta", "one" } }, id, name, false));
    // A glob matches the name alone or the whole id, never a part.
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{"test_alpha_*"} }, id, name, false));
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{"tests/*::test_alpha_one"} }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{"alpha_*"} }, id, name, false));
    // --exact: the whole id, nothing less.
    try std.testing.expectEqual(Choice.run, choose(.{ .patterns = &.{id}, .exact = true }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{name}, .exact = true }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{"test_alpha_*"}, .exact = true }, id, name, false));
    // --skip wins over a pattern.
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{"alpha"}, .skips = &.{"one"} }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .skips = &.{"test_alpha_*"} }, id, name, false));
    // Ignored tests.
    try std.testing.expectEqual(Choice.skip, choose(.{}, id, name, true));
    try std.testing.expectEqual(Choice.run, choose(.{ .ignored = .only }, id, name, true));
    try std.testing.expectEqual(Choice.out, choose(.{ .ignored = .only }, id, name, false));
    try std.testing.expectEqual(Choice.run, choose(.{ .ignored = .include }, id, name, true));
    try std.testing.expectEqual(Choice.run, choose(.{ .ignored = .include }, id, name, false));
    try std.testing.expectEqual(Choice.out, choose(.{ .patterns = &.{"beta"}, .ignored = .include }, id, name, true));
}
