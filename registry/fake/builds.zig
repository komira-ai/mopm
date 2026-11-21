//! The builds of a version. A build is the files of a version built with one Mojo compiler: its build string is
//! `mojo<compiler>_0`, which is also the end of each of its file names, `mojo-<name>-<version>-<build>.conda`. The fake
//! stores no build apart from its files, so the build of a file is read off its name. A version holds one or more
//! builds; its primary build, the one with the lowest compiler (compared as numbers, part by part), is the first of `of`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Order = std.math.Order;
const st = @import("state.zig");

/// The build string of a file name `mojo-<name>-<version>-<build>.conda`.
pub fn buildOf(filename: []const u8) []const u8 {
    const stem = filename[0 .. filename.len - ".conda".len];
    const dash = std.mem.lastIndexOfScalar(u8, stem, '-') orelse return stem;
    return stem[dash + 1 ..];
}

/// The compiler of a build string `mojo<compiler>_<n>`, or null for any other build string.
pub fn compilerOf(build: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, build, "mojo")) return null;
    const under = std.mem.lastIndexOfScalar(u8, build, '_') orelse build.len;
    if (under <= 4) return null;
    return build[4..under];
}

/// The conda requirement on the compiler that a build states: `==<compiler>`, or `>=0` for a build string that names none.
pub fn requiresMojo(arena: Allocator, build: []const u8) Allocator.Error![]const u8 {
    const compiler = compilerOf(build) orelse return ">=0";
    return std.fmt.allocPrint(arena, "=={s}", .{compiler});
}

/// A part of a compiler that is not a number sorts after every number.
fn part(text: []const u8) u64 {
    return std.fmt.parseInt(u64, text, 10) catch std.math.maxInt(u64);
}

fn compareCompilers(a: []const u8, b: []const u8) Order {
    var x = std.mem.splitScalar(u8, a, '.');
    var y = std.mem.splitScalar(u8, b, '.');
    while (true) {
        const p = x.next();
        const q = y.next();
        if (p == null and q == null) return .eq;
        if (p == null) return .lt;
        if (q == null) return .gt;
        const o = std.math.order(part(p.?), part(q.?));
        if (o != .eq) return o;
    }
}

/// Order of two build strings: by compiler, numerically, part by part (`1.2.0` before `1.10.0`; a compiler that is a prefix of another
/// comes first). A build string that names no compiler sorts after the others, by text.
pub fn compareBuilds(a: []const u8, b: []const u8) Order {
    const x = compilerOf(a);
    const y = compilerOf(b);
    if (x != null and y != null) {
        const o = compareCompilers(x.?, y.?);
        if (o != .eq) return o;
    } else if (x != null) return .lt else if (y != null) return .gt;
    return std.mem.order(u8, a, b);
}

pub const Build = struct {
    build: []const u8,
    /// In the order the version holds them.
    files: []const st.File,
};

fn buildLess(_: void, a: Build, b: Build) bool {
    return compareBuilds(a.build, b.build) == .lt;
}

/// The builds of a version's files, sorted by compiler: each file under the build its name ends with.
pub fn of(arena: Allocator, files: []const st.File) Allocator.Error![]const Build {
    var names = std.ArrayList([]const u8).init(arena);
    var lists = std.ArrayList(std.ArrayList(st.File)).init(arena);
    for (files) |f| {
        const b = buildOf(f.filename);
        const at = for (names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, b)) break i;
        } else blk: {
            try names.append(b);
            try lists.append(std.ArrayList(st.File).init(arena));
            break :blk names.items.len - 1;
        };
        try lists.items[at].append(f);
    }
    const out = try arena.alloc(Build, names.items.len);
    for (out, names.items, lists.items) |*o, n, l| o.* = .{ .build = n, .files = l.items };
    std.mem.sort(Build, out, {}, buildLess);
    return out;
}

/// Whether one of `files` belongs to `build`.
pub fn has(files: []const st.File, build: []const u8) bool {
    for (files) |f| {
        if (std.mem.eql(u8, buildOf(f.filename), build)) return true;
    }
    return false;
}

test "the build of a file is the end of its name, and its compiler is in it" {
    try std.testing.expectEqualStrings("mojo1.0.0_0", buildOf("mojo-http_client-0.4.0-mojo1.0.0_0.conda"));
    try std.testing.expectEqualStrings("nodash", buildOf("nodash.conda"));
    try std.testing.expectEqualStrings("1.0.0", compilerOf("mojo1.0.0_0").?);
    try std.testing.expectEqualStrings("1.0.0", compilerOf("mojo1.0.0").?);
    try std.testing.expect(compilerOf("py_0") == null);
    try std.testing.expect(compilerOf("mojo_0") == null);
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("==1.2.0", try requiresMojo(a, "mojo1.2.0_0"));
    try std.testing.expectEqualStrings(">=0", try requiresMojo(a, "py_0"));
}

test "builds are ordered by compiler, numerically and part by part" {
    const chain = [_][]const u8{ "mojo1.0_0", "mojo1.0.0_0", "mojo1.2.0_0", "mojo1.10.0_0", "mojo2.0.0_0", "mojo10.0.0_0" };
    for (chain[0 .. chain.len - 1], chain[1..]) |lo, hi| {
        try std.testing.expectEqual(Order.lt, compareBuilds(lo, hi));
        try std.testing.expectEqual(Order.gt, compareBuilds(hi, lo));
    }
    try std.testing.expectEqual(Order.eq, compareBuilds("mojo1.0.0_0", "mojo1.0.0_0"));
    // A part that is not a number sorts after the numbers.
    try std.testing.expectEqual(Order.lt, compareBuilds("mojo1.10.0_0", "mojo1.x.0_0"));
    // The same compiler with another build number falls back to the text.
    try std.testing.expectEqual(Order.lt, compareBuilds("mojo1.0.0_0", "mojo1.0.0_1"));
    // A build string that names no compiler sorts after the others, by text between themselves.
    try std.testing.expectEqual(Order.lt, compareBuilds("mojo99.0.0_0", "py_0"));
    try std.testing.expectEqual(Order.gt, compareBuilds("py_0", "mojo99.0.0_0"));
    try std.testing.expectEqual(Order.lt, compareBuilds("a_0", "b_0"));
}

fn file(subdir: []const u8, filename: []const u8) st.File {
    return .{ .subdir = subdir, .filename = filename, .sha256 = "", .size = 1, .path = "" };
}

test "the files of a version fall under their builds, lowest compiler first, each file once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = [_]st.File{
        file("linux-64", "mojo-p-1.0.0-mojo1.2.0_0.conda"),
        file("osx-arm64", "mojo-p-1.0.0-mojo1.2.0_0.conda"),
        file("linux-64", "mojo-p-1.0.0-mojo1.0.0_0.conda"),
        file("linux-64", "mojo-p-1.0.0-mojo1.10.0_0.conda"),
    };
    const all = try of(a, &files);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", all[0].build);
    try std.testing.expectEqualStrings("mojo1.2.0_0", all[1].build);
    try std.testing.expectEqualStrings("mojo1.10.0_0", all[2].build);
    try std.testing.expectEqual(@as(usize, 1), all[0].files.len);
    try std.testing.expectEqual(@as(usize, 2), all[1].files.len);
    try std.testing.expectEqualStrings("linux-64", all[1].files[0].subdir);
    try std.testing.expectEqualStrings("osx-arm64", all[1].files[1].subdir);
    try std.testing.expect(has(&files, "mojo1.10.0_0"));
    try std.testing.expect(!has(&files, "mojo1.1.0_0"));
}
