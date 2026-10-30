//! `link` of a `[native.<id>]`: the system libraries the final link of any consumer of a static native adds
//! (`-l<name>`), for the symbols its archive leaves to the platform (a C++ archive leaves `std::__1::...` to libc++).
//! The names are a closed list: a package published by anyone puts them on its consumers' linker command lines, and a
//! name outside the list is refused when the package is packed, read from metadata, read from a lock, or planned.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The libraries a native may name, sorted. Each exists on the platforms mopm builds for (Linux through the
/// toolchain's zig, which ships libc++; macOS, where `-lm`, `-lpthread` and `-ldl` are the system library's stubs).
pub const allowed = [_][]const u8{ "c++", "dl", "m", "pthread" };

pub fn isAllowed(name: []const u8) bool {
    for (allowed) |a| {
        if (std.mem.eql(u8, a, name)) return true;
    }
    return false;
}

/// Whether every name is allowed and none is repeated (the answer of `problem` without its text).
pub fn allAllowed(names: []const []const u8) bool {
    for (names, 0..) |name, i| {
        if (!isAllowed(name)) return false;
        for (names[0..i]) |before| {
            if (std.mem.eql(u8, before, name)) return false;
        }
    }
    return true;
}

/// Why `names` cannot be a native's `link`, or null: a name outside `allowed`, or one given twice.
pub fn problem(arena: Allocator, names: []const []const u8) Allocator.Error!?[]const u8 {
    for (names, 0..) |name, i| {
        if (!isAllowed(name)) {
            return try std.fmt.allocPrint(arena, "'{s}' is not a system library a native may link; the allowed ones are c++, dl, m and pthread", .{name});
        }
        for (names[0..i]) |before| {
            if (std.mem.eql(u8, before, name)) return try std.fmt.allocPrint(arena, "'{s}' is named twice", .{name});
        }
    }
    return null;
}

fn rank(name: []const u8) usize {
    for (allowed, 0..) |a, i| {
        if (std.mem.eql(u8, a, name)) return i;
    }
    return allowed.len;
}

fn before(_: void, a: []const u8, b: []const u8) bool {
    const ra = rank(a);
    const rb = rank(b);
    if (ra != rb) return ra < rb;
    return std.mem.lessThan(u8, a, b);
}

/// Adds each of `names` that `out` does not hold yet, and leaves `out` in the order of `allowed` (libc++ first, as it
/// needs libm and libpthread behind it). The one place a closure's `link` lists are merged: the link plan and the unit
/// graph both use it, so a consumer gets one `-l<name>` per name, in one order, whatever order the natives are in.
pub fn merge(out: *std.ArrayList([]const u8), names: []const []const u8) Allocator.Error!void {
    outer: for (names) |name| {
        for (out.items) |have| {
            if (std.mem.eql(u8, have, name)) continue :outer;
        }
        try out.append(name);
    }
    std.mem.sort([]const u8, out.items, {}, before);
}

test "the allowed names are accepted, anything else is refused with the list" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect((try problem(a, &.{ "c++", "m", "pthread", "dl" })) == null);
    try std.testing.expect((try problem(a, &.{})) == null);
    for ([_][]const u8{ "", "C++", "stdc++", "c", "-lc++", "c++ ", "m,-v", "../x", "rt", "z" }) |bad| {
        const why = (try problem(a, &.{bad})) orelse return error.TestUnexpectedResult;
        try std.testing.expect(std.mem.indexOf(u8, why, "the allowed ones are c++, dl, m and pthread") != null);
    }
    try std.testing.expectEqualStrings("'m' is named twice", (try problem(a, &.{ "m", "c++", "m" })).?);
}

test "the allowed list is sorted and every entry is a plain library name" {
    for (allowed, 0..) |name, i| {
        if (i > 0) try std.testing.expect(std.mem.lessThan(u8, allowed[i - 1], name));
        for (name) |ch| try std.testing.expect(std.ascii.isAlphanumeric(ch) or ch == '+');
    }
}

test "merge adds a name once and leaves the names in the order of the allowed list, whatever order they came in" {
    var out = std.ArrayList([]const u8).init(std.testing.allocator);
    defer out.deinit();
    try merge(&out, &.{ "m", "pthread" });
    try merge(&out, &.{ "pthread", "c++" });
    try merge(&out, &.{});
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("c++", out.items[0]);
    try std.testing.expectEqualStrings("m", out.items[1]);
    try std.testing.expectEqualStrings("pthread", out.items[2]);
}
