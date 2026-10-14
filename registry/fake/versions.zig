//! Conda version ordering for the API's `Version` grammar (dot-separated
//! numbers and an optional `dev`, `a`, `b` or `rc` suffix with a number).
//! Missing trailing parts count as zero, so `1.0` and `1.0.0` are the same
//! version; a suffix sorts below the release: dev < a < b < rc < release.

const std = @import("std");
const Order = std.math.Order;

const max_parts = 16;

const Parsed = struct {
    parts: [max_parts]u64 = [_]u64{0} ** max_parts,
    len: usize = 0,
    /// 0 dev, 1 a, 2 b, 3 rc, 4 release.
    kind: u8 = 4,
    suffix: u64 = 0,
};

/// `v` must match the `Version` pattern (util.isVersion).
fn parse(v: []const u8) Parsed {
    var out = Parsed{};
    var end = v.len;
    while (end > 0 and std.ascii.isDigit(v[end - 1])) end -= 1;
    var core = v;
    const suffixes = [_]struct { []const u8, u8 }{ .{ "dev", 0 }, .{ "rc", 3 }, .{ "a", 1 }, .{ "b", 2 } };
    for (suffixes) |s| {
        if (end > s[0].len and end < v.len and std.mem.eql(u8, v[end - s[0].len .. end], s[0])) {
            out.kind = s[1];
            out.suffix = std.fmt.parseInt(u64, v[end..], 10) catch std.math.maxInt(u64);
            core = v[0 .. end - s[0].len];
            break;
        }
    }
    var it = std.mem.splitScalar(u8, core, '.');
    while (it.next()) |part| {
        if (out.len == max_parts) break;
        out.parts[out.len] = std.fmt.parseInt(u64, part, 10) catch std.math.maxInt(u64);
        out.len += 1;
    }
    return out;
}

pub fn compare(a: []const u8, b: []const u8) Order {
    const x = parse(a);
    const y = parse(b);
    for (0..max_parts) |i| {
        const o = std.math.order(x.parts[i], y.parts[i]);
        if (o != .eq) return o;
    }
    if (x.kind != y.kind) return std.math.order(x.kind, y.kind);
    return std.math.order(x.suffix, y.suffix);
}

/// Equal under conda ordering: `1.0` and `1.0.0` are the same version.
pub fn same(a: []const u8, b: []const u8) bool {
    return compare(a, b) == .eq;
}

pub fn isPrerelease(v: []const u8) bool {
    return parse(v).kind != 4;
}

test "conda ordering of the API's versions" {
    try std.testing.expect(same("1.0", "1.0.0"));
    try std.testing.expect(same("1", "1.0.0.0"));
    try std.testing.expect(!same("1.0", "1.0.1"));
    const chain = [_][]const u8{ "0.9", "1.0dev1", "1.0a1", "1.0a2", "1.0b1", "1.0rc1", "1.0", "1.0.1", "1.2", "1.10", "2.0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |lo, hi| {
        try std.testing.expectEqual(Order.lt, compare(lo, hi));
        try std.testing.expectEqual(Order.gt, compare(hi, lo));
    }
    try std.testing.expect(isPrerelease("1.0rc1") and !isPrerelease("1.0"));
}
