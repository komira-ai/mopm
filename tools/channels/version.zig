//! Release versions and the rule that a channel only moves up.
//!
//! A release version is `X.Y.Z`: three decimal numbers, no leading zeros, no `v`, no suffix. The compare is numeric
//! (1.10.0 is newer than 1.9.0). `checkMove` is the monotonic check every channel stage runs before it writes: a
//! channel that holds 1.2.3 is never moved to 1.2.2, and moving it to 1.2.3 again is a no-op, not an error.

const std = @import("std");

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub const Error = error{BadVersion};

    pub fn parse(s: []const u8) Error!Version {
        var parts: [3]u32 = undefined;
        var it = std.mem.splitScalar(u8, s, '.');
        var n: usize = 0;
        while (it.next()) |p| : (n += 1) {
            if (n == 3) return error.BadVersion;
            if (p.len == 0 or p.len > 9) return error.BadVersion;
            if (p.len > 1 and p[0] == '0') return error.BadVersion;
            for (p) |ch| {
                if (ch < '0' or ch > '9') return error.BadVersion;
            }
            parts[n] = std.fmt.parseInt(u32, p, 10) catch return error.BadVersion;
        }
        if (n != 3) return error.BadVersion;
        return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
    }

    pub fn order(a: Version, b: Version) std.math.Order {
        const am = [3]u32{ a.major, a.minor, a.patch };
        const bm = [3]u32{ b.major, b.minor, b.patch };
        for (am, bm) |x, y| {
            if (x < y) return .lt;
            if (x > y) return .gt;
        }
        return .eq;
    }

    pub fn format(v: Version, comptime _: []const u8, _: std.fmt.FormatOptions, w: anytype) !void {
        try w.print("{d}.{d}.{d}", .{ v.major, v.minor, v.patch });
    }
};

pub const Move = enum { advance, same };

pub const MoveError = error{ChannelWouldMoveDown};

/// What moving a channel that holds `current` (null: empty) to `next` is. Down is refused.
pub fn checkMove(current: ?Version, next: Version) MoveError!Move {
    const cur = current orelse return .advance;
    return switch (next.order(cur)) {
        .gt => .advance,
        .eq => .same,
        .lt => error.ChannelWouldMoveDown,
    };
}

test "parse accepts X.Y.Z and nothing else" {
    const v = try Version.parse("1.20.3");
    try std.testing.expectEqual(@as(u32, 1), v.major);
    try std.testing.expectEqual(@as(u32, 20), v.minor);
    try std.testing.expectEqual(@as(u32, 3), v.patch);
    _ = try Version.parse("0.0.0");
    for ([_][]const u8{ "", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-rc1", "1.2.3+dev", "01.2.3", "1.02.3", "1.2.03", "1..3", "1.2.-3", " 1.2.3", "1.2.3 ", "1.2.x", "9999999999.0.0" }) |bad| {
        try std.testing.expectError(error.BadVersion, Version.parse(bad));
    }
}

test "the compare is numeric, not lexical" {
    const old = try Version.parse("1.9.0");
    const new = try Version.parse("1.10.0");
    try std.testing.expectEqual(std.math.Order.gt, new.order(old));
    try std.testing.expectEqual(std.math.Order.lt, old.order(new));
    try std.testing.expectEqual(std.math.Order.eq, new.order(new));
    try std.testing.expectEqual(std.math.Order.gt, (try Version.parse("2.0.0")).order(try Version.parse("1.99.99")));
    try std.testing.expectEqual(std.math.Order.lt, (try Version.parse("1.2.3")).order(try Version.parse("1.2.4")));
}

test "a channel moves up, stays, and never moves down" {
    const v123 = try Version.parse("1.2.3");
    try std.testing.expectEqual(Move.advance, try checkMove(null, v123));
    try std.testing.expectEqual(Move.advance, try checkMove(v123, try Version.parse("1.2.4")));
    try std.testing.expectEqual(Move.advance, try checkMove(v123, try Version.parse("1.10.0")));
    try std.testing.expectEqual(Move.same, try checkMove(v123, v123));
    try std.testing.expectError(error.ChannelWouldMoveDown, checkMove(v123, try Version.parse("1.2.2")));
    try std.testing.expectError(error.ChannelWouldMoveDown, checkMove(try Version.parse("1.10.0"), try Version.parse("1.9.9")));
}

test "format prints X.Y.Z" {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{}", .{try Version.parse("3.14.15")});
    try std.testing.expectEqualStrings("3.14.15", s);
}
