//! Ordering of the API's `Version` grammar: `MAJOR.MINOR.PATCH`, three numbers
//! (util.isVersion). They compare numerically, major first. There are no
//! pre-release or other suffixes, so a version has one spelling and two
//! versions are the same exactly when their text is.

const std = @import("std");
const Order = std.math.Order;

/// `v` must match the `Version` pattern (util.isVersion).
fn parse(v: []const u8) [3]u64 {
    var out = [3]u64{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    var i: usize = 0;
    while (it.next()) |p| : (i += 1) {
        if (i == out.len) break;
        out[i] = std.fmt.parseInt(u64, p, 10) catch std.math.maxInt(u64);
    }
    return out;
}

pub fn compare(a: []const u8, b: []const u8) Order {
    const x = parse(a);
    const y = parse(b);
    for (x, y) |p, q| {
        const o = std.math.order(p, q);
        if (o != .eq) return o;
    }
    return .eq;
}

pub fn same(a: []const u8, b: []const u8) bool {
    return compare(a, b) == .eq;
}

test "ordering of the API's versions" {
    try std.testing.expect(same("1.0.0", "1.0.0"));
    try std.testing.expect(!same("1.0.0", "1.0.1"));
    const chain = [_][]const u8{ "0.9.0", "1.0.0", "1.0.1", "1.2.0", "1.10.0", "2.0.0", "10.0.0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |lo, hi| {
        try std.testing.expectEqual(Order.lt, compare(lo, hi));
        try std.testing.expectEqual(Order.gt, compare(hi, lo));
    }
}
