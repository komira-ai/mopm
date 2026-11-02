//! The CPU level of a unit build (`mopm unit build|test --target-cpu <level>`;
//! spec/unit-graph.md, "Target CPU"). A level is a name a build system knows a
//! machine by; this file is the one place that says what `mojo build` is told
//! for it. A level with no verified Mojo spelling is refused, never guessed.

const std = @import("std");

pub const Error = error{ UnknownLevel, NoMojoSpelling };

const Entry = struct {
    level: []const u8,
    /// The value of `mojo build --target-cpu`; null when no spelling has been
    /// verified against `mojo build`.
    mojo: ?[]const u8,
};

/// Every level mopm accepts on the command line, in the order the usage lists
/// them. The x86-64 spellings are accepted by `mojo build` (they change the
/// binary). The Arm levels need `--target-cpu generic` plus a feature option
/// that has not been shown to exist in `mojo build`, so they have no entry
/// value: they are named, so the refusal can say so, and refused.
pub const levels = [_]Entry{
    .{ .level = "x86-64", .mojo = "x86-64" },
    .{ .level = "x86-64-v2", .mojo = "x86-64-v2" },
    .{ .level = "x86-64-v3", .mojo = "x86-64-v3" },
    .{ .level = "x86-64-v4", .mojo = "x86-64-v4" },
    .{ .level = "armv8.0-a", .mojo = null },
    .{ .level = "armv8.1-a", .mojo = null },
    .{ .level = "armv8.2-a", .mojo = null },
    .{ .level = "armv8.3-a", .mojo = null },
    .{ .level = "armv8.4-a", .mojo = null },
};

/// The `--target-cpu` value for `level`.
pub fn mojoValue(level: []const u8) Error![]const u8 {
    for (levels) |e| {
        if (std.mem.eql(u8, e.level, level)) return e.mojo orelse error.NoMojoSpelling;
    }
    return error.UnknownLevel;
}

/// The one-line reason `mojoValue` failed, for standard error.
pub fn explain(arena: std.mem.Allocator, level: []const u8, e: Error) ![]const u8 {
    return switch (e) {
        error.UnknownLevel => std.fmt.allocPrint(arena, "unknown --target-cpu '{s}'; the levels are x86-64, x86-64-v2, x86-64-v3, x86-64-v4 and armv8.0-a..armv8.4-a", .{level}),
        error.NoMojoSpelling => std.fmt.allocPrint(arena, "--target-cpu {s} is a known level, but this mopm has no verified Mojo spelling for it and does not guess; the levels it builds are x86-64, x86-64-v2, x86-64-v3, x86-64-v4", .{level}),
    };
}

test "each x86-64 level is the compiler's --target-cpu value, one by one" {
    try std.testing.expectEqualStrings("x86-64", try mojoValue("x86-64"));
    try std.testing.expectEqualStrings("x86-64-v2", try mojoValue("x86-64-v2"));
    try std.testing.expectEqualStrings("x86-64-v3", try mojoValue("x86-64-v3"));
    try std.testing.expectEqualStrings("x86-64-v4", try mojoValue("x86-64-v4"));
}

test "the levels are distinct: no two map to one value" {
    var seen: [levels.len][]const u8 = undefined;
    var n: usize = 0;
    for (levels) |e| {
        const v = e.mojo orelse continue;
        for (seen[0..n]) |s| try std.testing.expect(!std.mem.eql(u8, s, v));
        seen[n] = v;
        n += 1;
    }
    try std.testing.expectEqual(@as(usize, 4), n);
}

test "an Arm level is named and refused, an unknown one is refused differently" {
    for ([_][]const u8{ "armv8.0-a", "armv8.1-a", "armv8.2-a", "armv8.3-a", "armv8.4-a" }) |l| {
        try std.testing.expectError(error.NoMojoSpelling, mojoValue(l));
    }
    for ([_][]const u8{ "", "x86-64-v1", "x86_64_v3", "X86-64", "x86-64-v5", "armv9-a", "armv8.5-a", "native", "haswell" }) |l| {
        try std.testing.expectError(error.UnknownLevel, mojoValue(l));
    }
}

test "the refusal names the level and says what is accepted" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const u = try explain(a, "haswell", error.UnknownLevel);
    try std.testing.expect(std.mem.indexOf(u8, u, "'haswell'") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "x86-64-v3") != null);
    const n = try explain(a, "armv8.2-a", error.NoMojoSpelling);
    try std.testing.expect(std.mem.indexOf(u8, n, "armv8.2-a") != null);
    try std.testing.expect(std.mem.indexOf(u8, n, "does not guess") != null);
}
