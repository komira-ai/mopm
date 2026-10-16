//! The toolchain closures built into mopm: one file per supported Mojo
//! version and platform, src/core/toolchain/mojo-<version>-<subdir>.json
//! (core/closure.zig says what they are). A new version is a line in
//! `embedded` and in toolchain/versions.txt; the test below fails if the two
//! disagree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const closure = @import("closure.zig");
const testroot = @import("testroot.zig");

const Embedded = struct { mojo: []const u8, subdir: []const u8, text: []const u8 };

const embedded = [_]Embedded{
    .{ .mojo = "1.0.0", .subdir = "linux-64", .text = @embedFile("toolchain/mojo-1.0.0-linux-64.json") },
    .{ .mojo = "1.0.0", .subdir = "linux-aarch64", .text = @embedFile("toolchain/mojo-1.0.0-linux-aarch64.json") },
    .{ .mojo = "1.0.0", .subdir = "osx-arm64", .text = @embedFile("toolchain/mojo-1.0.0-osx-arm64.json") },
};

/// The built-in closure for Mojo `mojo` on `subdir`, or null.
pub fn find(arena: Allocator, mojo: []const u8, subdir: []const u8) !?closure.Closure {
    for (embedded) |e| {
        if (std.mem.eql(u8, e.mojo, mojo) and std.mem.eql(u8, e.subdir, subdir)) return try closure.parse(arena, e.text);
    }
    return null;
}

/// The Mojo versions mopm has a closure for, as "1.0.0, 1.1.0".
pub fn versions(arena: Allocator) ![]const u8 {
    var out = std.ArrayList(u8).init(arena);
    var last: []const u8 = "";
    for (embedded) |e| {
        if (std.mem.eql(u8, e.mojo, last)) continue;
        if (out.items.len > 0) try out.appendSlice(", ");
        try out.appendSlice(e.mojo);
        last = e.mojo;
    }
    return out.items;
}

test "every built-in closure is usable and is for what its name says" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    for (embedded) |e| {
        const c = try closure.parse(a, e.text);
        try std.testing.expectEqualStrings(e.mojo, c.mojo);
        try std.testing.expectEqualStrings(e.subdir, c.subdir);
        try std.testing.expectEqual(@as(?[]const u8, null), try closure.problem(a, c));
    }
}

test "toolchain/versions.txt and the built-in closures list the same versions and platforms" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const text = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/versions.txt"), 1 << 16);
    var listed: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text, '\n');
    while (it.next()) |line| {
        const ver = std.mem.trim(u8, line, " \t\r");
        if (ver.len == 0 or ver[0] == '#') continue;
        for (closure.subdirs) |subdir| {
            try std.testing.expect((try find(a, ver, subdir)) != null);
            listed += 1;
        }
    }
    try std.testing.expectEqual(embedded.len, listed);
}
