//! Semantic versions and cargo-style version requirements (spec/mopm-toml.md,
//! "Version requirements").
//!
//! A requirement is `*`, or comparators joined by commas, all of which must
//! hold: `^`, `~`, `=`, `>`, `>=`, `<`, `<=` before a version of one to three
//! parts, a bare version (meaning `^`), or a wildcard `I.*` / `I.J.*`.
//! `matches` follows cargo, including its pre-release rule: a version with a
//! pre-release matches only if some comparator names a pre-release of the same
//! MAJOR.MINOR.PATCH.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;

pub const Version = struct {
    major: u64,
    minor: u64,
    patch: u64,
    /// Dot-separated pre-release identifiers, without the `-`; "" for a release.
    pre: []const u8 = "",
    /// Build metadata, without the `+`; ignored by every comparison.
    build: []const u8 = "",
};

pub const Op = enum { exact, greater, greater_eq, less, less_eq, tilde, caret, wildcard };

/// One comparator. A missing minor or patch is a partial version (`>=1.2`).
pub const Comparator = struct {
    op: Op,
    major: u64,
    minor: ?u64 = null,
    patch: ?u64 = null,
    pre: []const u8 = "",
};

/// No comparators means `*`.
pub const Req = struct {
    comparators: []const Comparator,

    /// Whether `v` satisfies every comparator, under the pre-release rule.
    pub fn matches(self: Req, v: Version) bool {
        for (self.comparators) |c| {
            if (!matchesComparator(c, v)) return false;
        }
        if (v.pre.len == 0) return true;
        for (self.comparators) |c| {
            if (preIsCompatible(c, v)) return true;
        }
        return false;
    }
};

/// A MAJOR.MINOR.PATCH number: digits, no leading zero.
fn number(s: []const u8) ?u64 {
    if (s.len == 0 or (s.len > 1 and s[0] == '0')) return null;
    for (s) |d| {
        if (!std.ascii.isDigit(d)) return null;
    }
    return std.fmt.parseInt(u64, s, 10) catch null;
}

fn allDigits(s: []const u8) bool {
    for (s) |d| {
        if (!std.ascii.isDigit(d)) return false;
    }
    return true;
}

/// Dot-separated identifiers of letters, digits and `-`. In a pre-release a
/// numeric identifier may not have a leading zero.
fn identifiers(s: []const u8, pre: bool) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        for (part) |b| {
            if (!std.ascii.isAlphanumeric(b) and b != '-') return false;
        }
        if (pre and part.len > 1 and part[0] == '0' and allDigits(part)) return false;
    }
    return true;
}

/// MAJOR.MINOR.PATCH with an optional `-pre.release` and `+build`, as
/// semver.org; null if `text` is not one.
pub fn parseVersion(text: []const u8) ?Version {
    var v = Version{ .major = 0, .minor = 0, .patch = 0 };
    var rest = text;
    if (std.mem.indexOfScalar(u8, rest, '+')) |plus| {
        v.build = rest[plus + 1 ..];
        if (!identifiers(v.build, false)) return null;
        rest = rest[0..plus];
    }
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        v.pre = rest[dash + 1 ..];
        if (!identifiers(v.pre, true)) return null;
        rest = rest[0..dash];
    }
    var it = std.mem.splitScalar(u8, rest, '.');
    v.major = number(it.next() orelse return null) orelse return null;
    v.minor = number(it.next() orelse return null) orelse return null;
    v.patch = number(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return v;
}

pub const ParseError = error{ Invalid, OutOfMemory };

/// Parses a requirement. On `error.Invalid`, `why` says what is wrong.
pub fn parseReq(arena: Allocator, text: []const u8, why: *[]const u8) ParseError!Req {
    const whole = std.mem.trim(u8, text, " \t");
    if (whole.len == 0) {
        why.* = "it is empty";
        return error.Invalid;
    }
    if (std.mem.eql(u8, whole, "*")) return .{ .comparators = &.{} };
    var out = std.ArrayList(Comparator).init(arena);
    var it = std.mem.splitScalar(u8, whole, ',');
    while (it.next()) |raw| {
        const part = std.mem.trim(u8, raw, " \t");
        if (part.len == 0) {
            why.* = "a comparator between commas is empty";
            return error.Invalid;
        }
        try out.append(try comparator(part, why));
    }
    return .{ .comparators = try out.toOwnedSlice() };
}

fn comparator(text: []const u8, why: *[]const u8) ParseError!Comparator {
    const ops = [_]struct { []const u8, Op }{
        .{ ">=", .greater_eq }, .{ "<=", .less_eq }, .{ ">", .greater }, .{ "<", .less },
        .{ "=", .exact },       .{ "~", .tilde },    .{ "^", .caret },
    };
    var op: Op = .caret;
    var explicit = false;
    var rest = text;
    for (ops) |o| {
        if (std.mem.startsWith(u8, rest, o[0])) {
            op = o[1];
            explicit = true;
            rest = std.mem.trimLeft(u8, rest[o[0].len..], " \t");
            break;
        }
    }
    if (rest.len == 0) {
        why.* = "an operator has no version after it";
        return error.Invalid;
    }
    if (std.mem.indexOfScalar(u8, rest, '+') != null) {
        why.* = "build metadata (+...) has no place in a requirement";
        return error.Invalid;
    }
    var c = Comparator{ .op = op, .major = 0 };
    if (std.mem.indexOfScalar(u8, rest, '-')) |dash| {
        c.pre = rest[dash + 1 ..];
        if (!identifiers(c.pre, true)) {
            why.* = "the pre-release is not dot-separated identifiers of letters, digits and '-'";
            return error.Invalid;
        }
        rest = rest[0..dash];
    }
    var parts: [3]?u64 = .{ null, null, null };
    var n: usize = 0;
    var wildcard = false;
    var it = std.mem.splitScalar(u8, rest, '.');
    while (it.next()) |part| : (n += 1) {
        if (n == 3) {
            why.* = "a version has at most three parts (MAJOR.MINOR.PATCH)";
            return error.Invalid;
        }
        if (wildcard) {
            why.* = "a wildcard (*) must be the last part";
            return error.Invalid;
        }
        if (std.mem.eql(u8, part, "*") or std.mem.eql(u8, part, "x") or std.mem.eql(u8, part, "X")) {
            if (n == 0) {
                why.* = "'*' matches any version on its own; it cannot be joined with other comparators";
                return error.Invalid;
            }
            wildcard = true;
            continue;
        }
        parts[n] = number(part) orelse {
            why.* = "each part of a version is a number without leading zeros";
            return error.Invalid;
        };
    }
    if (wildcard) {
        if (explicit) {
            why.* = "a wildcard version (1.*) takes no operator";
            return error.Invalid;
        }
        c.op = .wildcard;
    }
    if (c.pre.len > 0 and (parts[2] == null or wildcard)) {
        why.* = "a pre-release needs a full MAJOR.MINOR.PATCH version";
        return error.Invalid;
    }
    c.major = parts[0].?;
    c.minor = parts[1];
    c.patch = parts[2];
    return c;
}

/// Pre-release precedence (semver.org, 11): a release is above its
/// pre-releases; numeric identifiers compare as numbers and sort before
/// alphanumeric ones; a longer list wins when one is a prefix of the other.
pub fn comparePre(a: []const u8, b: []const u8) Order {
    if (a.len == 0 and b.len == 0) return .eq;
    if (a.len == 0) return .gt;
    if (b.len == 0) return .lt;
    var ia = std.mem.splitScalar(u8, a, '.');
    var ib = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const x = ia.next() orelse return if (ib.next() == null) .eq else .lt;
        const y = ib.next() orelse return .gt;
        const xn = allDigits(x);
        const yn = allDigits(y);
        const o: Order = if (xn and yn)
            (if (x.len != y.len) std.math.order(x.len, y.len) else std.mem.order(u8, x, y))
        else if (xn)
            .lt
        else if (yn)
            .gt
        else
            std.mem.order(u8, x, y);
        if (o != .eq) return o;
    }
}

/// Version precedence; build metadata is ignored.
pub fn compare(a: Version, b: Version) Order {
    if (a.major != b.major) return std.math.order(a.major, b.major);
    if (a.minor != b.minor) return std.math.order(a.minor, b.minor);
    if (a.patch != b.patch) return std.math.order(a.patch, b.patch);
    return comparePre(a.pre, b.pre);
}

fn matchesComparator(c: Comparator, v: Version) bool {
    return switch (c.op) {
        .exact, .wildcard => matchesExact(c, v),
        .greater => matchesGreater(c, v),
        .greater_eq => matchesExact(c, v) or matchesGreater(c, v),
        .less => matchesLess(c, v),
        .less_eq => matchesExact(c, v) or matchesLess(c, v),
        .tilde => matchesTilde(c, v),
        .caret => matchesCaret(c, v),
    };
}

fn matchesExact(c: Comparator, v: Version) bool {
    if (v.major != c.major) return false;
    if (c.minor) |minor| {
        if (v.minor != minor) return false;
    }
    if (c.patch) |patch| {
        if (v.patch != patch) return false;
    }
    return std.mem.eql(u8, v.pre, c.pre);
}

fn matchesGreater(c: Comparator, v: Version) bool {
    if (v.major != c.major) return v.major > c.major;
    const minor = c.minor orelse return false;
    if (v.minor != minor) return v.minor > minor;
    const patch = c.patch orelse return false;
    if (v.patch != patch) return v.patch > patch;
    return comparePre(v.pre, c.pre) == .gt;
}

fn matchesLess(c: Comparator, v: Version) bool {
    if (v.major != c.major) return v.major < c.major;
    const minor = c.minor orelse return false;
    if (v.minor != minor) return v.minor < minor;
    const patch = c.patch orelse return false;
    if (v.patch != patch) return v.patch < patch;
    return comparePre(v.pre, c.pre) == .lt;
}

fn matchesTilde(c: Comparator, v: Version) bool {
    if (v.major != c.major) return false;
    if (c.minor) |minor| {
        if (v.minor != minor) return false;
    }
    if (c.patch) |patch| {
        if (v.patch != patch) return v.patch > patch;
    }
    return comparePre(v.pre, c.pre) != .lt;
}

fn matchesCaret(c: Comparator, v: Version) bool {
    if (v.major != c.major) return false;
    const minor = c.minor orelse return true;
    const patch = c.patch orelse {
        return if (c.major > 0) v.minor >= minor else v.minor == minor;
    };
    if (c.major > 0) {
        if (v.minor != minor) return v.minor > minor;
        if (v.patch != patch) return v.patch > patch;
    } else if (minor > 0) {
        if (v.minor != minor) return false;
        if (v.patch != patch) return v.patch > patch;
    } else if (v.minor != minor or v.patch != patch) {
        return false;
    }
    return comparePre(v.pre, c.pre) != .lt;
}

fn preIsCompatible(c: Comparator, v: Version) bool {
    return c.major == v.major and c.minor != null and c.minor.? == v.minor and
        c.patch != null and c.patch.? == v.patch and c.pre.len > 0;
}

test "versions: accepted and refused" {
    for ([_][]const u8{ "0.1.0", "1.2.3", "10.0.0-rc.1", "1.0.0+build.5", "1.0.0-alpha-1", "1.0.0+001" }) |v| {
        if (parseVersion(v) == null) {
            std.debug.print("refused {s}\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
    for ([_][]const u8{ "1.0", "1.0.0.0", "01.0.0", "1.0.0-", "1.0.0+", "v1.0.0", "1..0", "", "1.0.0-01", "1.0.0-a..b" }) |v| {
        if (parseVersion(v) != null) {
            std.debug.print("accepted {s}\n", .{v});
            return error.TestUnexpectedResult;
        }
    }
}

test "precedence follows semver.org" {
    const chain = [_][]const u8{
        "1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta",
        "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1",      "1.0.0",
        "1.0.1",       "1.1.0",         "2.0.0",
    };
    for (chain[0 .. chain.len - 1], chain[1..]) |lo, hi| {
        const a = parseVersion(lo).?;
        const b = parseVersion(hi).?;
        if (compare(a, b) != .lt or compare(b, a) != .gt) {
            std.debug.print("expected {s} < {s}\n", .{ lo, hi });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(Order.eq, compare(parseVersion("1.0.0+a").?, parseVersion("1.0.0+b").?));
}

test "requirements match as cargo's do" {
    const Case = struct { req: []const u8, version: []const u8, want: bool };
    const cases = [_]Case{
        // A bare version is a caret requirement.
        .{ .req = "1.2", .version = "1.2.0", .want = true },
        .{ .req = "1.2", .version = "1.9.9", .want = true },
        .{ .req = "1.2", .version = "2.0.0", .want = false },
        .{ .req = "1.2", .version = "1.1.9", .want = false },
        .{ .req = "0.4", .version = "0.4.9", .want = true },
        .{ .req = "0.4", .version = "0.5.0", .want = false },
        .{ .req = "0.0.3", .version = "0.0.3", .want = true },
        .{ .req = "0.0.3", .version = "0.0.4", .want = false },
        .{ .req = "^1.2.3", .version = "1.2.2", .want = false },
        .{ .req = "^1.2.3", .version = "1.8.0", .want = true },
        .{ .req = "^0.2.3", .version = "0.2.9", .want = true },
        .{ .req = "^0.2.3", .version = "0.3.0", .want = false },
        .{ .req = "^0.0", .version = "0.0.7", .want = true },
        .{ .req = "^0.0", .version = "0.1.0", .want = false },
        .{ .req = "^0", .version = "0.9.0", .want = true },
        .{ .req = "^0", .version = "1.0.0", .want = false },
        // Tilde.
        .{ .req = "~1.2", .version = "1.2.5", .want = true },
        .{ .req = "~1.2", .version = "1.3.0", .want = false },
        .{ .req = "~1.2.3", .version = "1.2.9", .want = true },
        .{ .req = "~1.2.3", .version = "1.2.2", .want = false },
        .{ .req = "~1", .version = "1.9.0", .want = true },
        .{ .req = "~1", .version = "2.0.0", .want = false },
        // Exact, greater, less.
        .{ .req = "=1.2.3", .version = "1.2.3", .want = true },
        .{ .req = "=1.2.3", .version = "1.2.4", .want = false },
        .{ .req = "=1.2", .version = "1.2.9", .want = true },
        .{ .req = "=1.2", .version = "1.3.0", .want = false },
        .{ .req = ">1.2.3", .version = "1.2.4", .want = true },
        .{ .req = ">1.2.3", .version = "1.2.3", .want = false },
        .{ .req = ">1.2", .version = "1.2.9", .want = false },
        .{ .req = ">1.2", .version = "1.3.0", .want = true },
        .{ .req = ">=1.2", .version = "1.2.0", .want = true },
        .{ .req = ">=1.2", .version = "1.1.9", .want = false },
        .{ .req = "<1.2.3", .version = "1.2.2", .want = true },
        .{ .req = "<1.2.3", .version = "1.2.3", .want = false },
        .{ .req = "<=1.2", .version = "1.2.9", .want = true },
        .{ .req = "<=1.2", .version = "1.3.0", .want = false },
        // Several comparators: all must hold.
        .{ .req = ">=1.2, <1.5", .version = "1.4.9", .want = true },
        .{ .req = ">=1.2, <1.5", .version = "1.5.0", .want = false },
        .{ .req = ">=1.2, <1.5", .version = "1.1.0", .want = false },
        .{ .req = " >= 1.2 ,<1.5 ", .version = "1.3.0", .want = true },
        // Wildcards.
        .{ .req = "*", .version = "0.0.1", .want = true },
        .{ .req = "*", .version = "99.0.0", .want = true },
        .{ .req = "1.*", .version = "1.5.0", .want = true },
        .{ .req = "1.*", .version = "2.0.0", .want = false },
        .{ .req = "1.2.*", .version = "1.2.7", .want = true },
        .{ .req = "1.2.*", .version = "1.3.0", .want = false },
        // Pre-releases match only a comparator naming a pre-release of the
        // same MAJOR.MINOR.PATCH.
        .{ .req = "*", .version = "1.0.0-alpha", .want = false },
        .{ .req = "1.2", .version = "1.3.0-beta.1", .want = false },
        .{ .req = "<1.2.3", .version = "1.2.3-alpha", .want = false },
        .{ .req = ">=1.2.3-alpha", .version = "1.2.3-beta", .want = true },
        .{ .req = ">=1.2.3-alpha", .version = "1.2.3", .want = true },
        .{ .req = ">=1.2.3-alpha", .version = "1.2.4-beta", .want = false },
        .{ .req = ">=1.2.3-alpha", .version = "1.2.4", .want = true },
        .{ .req = "^1.2.3-alpha.1", .version = "1.2.3-alpha.2", .want = true },
        .{ .req = "^1.2.3-alpha.1", .version = "1.2.3-alpha.0", .want = false },
        .{ .req = "~1.2.3-beta", .version = "1.2.3-beta.2", .want = true },
        .{ .req = "=1.2.3-rc.1", .version = "1.2.3-rc.1", .want = true },
        .{ .req = "=1.2.3-rc.1", .version = "1.2.3-rc.2", .want = false },
        // Build metadata is ignored.
        .{ .req = "=1.2.3", .version = "1.2.3+linux", .want = true },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var bad: usize = 0;
    for (cases) |case| {
        var why: []const u8 = "";
        const req = parseReq(arena_state.allocator(), case.req, &why) catch |e| {
            std.debug.print("'{s}' refused: {s} ({s})\n", .{ case.req, why, @errorName(e) });
            bad += 1;
            continue;
        };
        const v = parseVersion(case.version).?;
        if (req.matches(v) != case.want) {
            std.debug.print("'{s}' vs {s}: want {}\n", .{ case.req, case.version, case.want });
            bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "requirements outside the grammar are refused" {
    const Case = struct { req: []const u8, why: []const u8 };
    const cases = [_]Case{
        .{ .req = "", .why = "it is empty" },
        .{ .req = "1.2,", .why = "a comparator between commas is empty" },
        .{ .req = ">=", .why = "an operator has no version after it" },
        .{ .req = "=>1.0", .why = "each part of a version is a number without leading zeros" },
        .{ .req = "1.2.3.4", .why = "a version has at most three parts (MAJOR.MINOR.PATCH)" },
        .{ .req = "01.2", .why = "each part of a version is a number without leading zeros" },
        .{ .req = "1.0.0+build", .why = "build metadata (+...) has no place in a requirement" },
        .{ .req = "1.2-beta", .why = "a pre-release needs a full MAJOR.MINOR.PATCH version" },
        .{ .req = "1.*.3", .why = "a wildcard (*) must be the last part" },
        .{ .req = ">=1.*", .why = "a wildcard version (1.*) takes no operator" },
        .{ .req = "*, <2", .why = "'*' matches any version on its own; it cannot be joined with other comparators" },
        .{ .req = "1.0.0-be..ta", .why = "the pre-release is not dot-separated identifiers of letters, digits and '-'" },
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for (cases) |case| {
        var why: []const u8 = "";
        if (parseReq(arena_state.allocator(), case.req, &why)) |_| {
            std.debug.print("accepted '{s}'\n", .{case.req});
            return error.TestUnexpectedResult;
        } else |e| {
            if (e != error.Invalid) return e;
        }
        std.testing.expectEqualStrings(case.why, why) catch |e| {
            std.debug.print("for '{s}'\n", .{case.req});
            return e;
        };
    }
}
