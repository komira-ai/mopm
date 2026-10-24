//! The files of a member's native library (`[native.<id>]` with `srcs`/`hdrs`, spec/mopm-toml.md): globs relative to
//! the member's directory, expanded to the files they name, sorted by path.
//!
//! A pattern is a path of `/`-separated segments. In a segment `*` stands for any run of characters, `?` for one, and
//! `[abc]` for one of a set (as `mopm test` filters do); a segment of `**` stands for any number of directories
//! (none included). A pattern with no wildcard names one file. Files and directories whose name starts with `.` are
//! never matched, and a pattern that matches no file is an error: a typo must not drop a source.

const std = @import("std");
const Allocator = std.mem.Allocator;
const test_filter = @import("test_filter.zig");

/// Whether `pattern` matches the whole of `path` (both relative, `/`-separated).
pub fn matches(pattern: []const u8, path: []const u8) bool {
    return matchSegments(pattern, path);
}

fn matchSegments(pattern: []const u8, path: []const u8) bool {
    const p_cut = std.mem.indexOfScalar(u8, pattern, '/');
    const p_seg = if (p_cut) |i| pattern[0..i] else pattern;
    const p_rest = if (p_cut) |i| pattern[i + 1 ..] else "";
    if (std.mem.eql(u8, p_seg, "**")) {
        // `**` takes zero directories, or one more and tries again.
        if (p_cut == null) return true;
        if (matchSegments(p_rest, path)) return true;
        const s_cut = std.mem.indexOfScalar(u8, path, '/') orelse return false;
        return matchSegments(pattern, path[s_cut + 1 ..]);
    }
    const s_cut = std.mem.indexOfScalar(u8, path, '/');
    const s_seg = if (s_cut) |i| path[0..i] else path;
    const s_rest = if (s_cut) |i| path[i + 1 ..] else "";
    if (!test_filter.glob(p_seg, s_seg)) return false;
    if (p_cut == null or s_cut == null) return p_cut == null and s_cut == null;
    return matchSegments(p_rest, s_rest);
}

fn isWild(seg: []const u8) bool {
    return std.mem.indexOfAny(u8, seg, "*?[") != null;
}

fn hidden(path: []const u8) bool {
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len > 0 and seg[0] == '.') return true;
    }
    return false;
}

/// The directory of `pattern` before its first wildcard segment ("" for none), and whether the pattern is one literal path.
fn literalPrefix(pattern: []const u8) struct { dir: []const u8, literal: bool } {
    var end: usize = 0;
    var it = std.mem.splitScalar(u8, pattern, '/');
    while (it.next()) |seg| {
        if (isWild(seg)) return .{ .dir = if (end == 0) "" else pattern[0 .. end - 1], .literal = false };
        end += seg.len + 1;
    }
    return .{ .dir = pattern, .literal = true };
}

pub const Expanded = union(enum) {
    /// The matched files, relative to the member directory, sorted, each once.
    files: []const []const u8,
    /// The first pattern that matched no file.
    unmatched: []const u8,
    /// The first pattern whose literal path is a symbolic link or passes through one: a link can lead out of the
    /// member, and a glob never follows one.
    link: []const u8,
};

/// Whether `rel` (relative to `root`), or a directory on the way to it, is a symbolic link.
fn throughLink(arena: Allocator, root: []const u8, rel: []const u8) !bool {
    var end: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        end += seg.len;
        const full = try std.fs.path.join(arena, &.{ root, rel[0..end] });
        var buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        if (std.fs.cwd().readLink(full, &buf)) |_| return true else |_| {}
        end += 1;
    }
    return false;
}

/// The files `patterns` name below `root` (the member's directory).
pub fn expand(arena: Allocator, root: []const u8, patterns: []const []const u8) !Expanded {
    var out = std.ArrayList([]const u8).init(arena);
    for (patterns) |pat| {
        const lp = literalPrefix(pat);
        if (lp.dir.len > 0 and try throughLink(arena, root, lp.dir)) return .{ .link = pat };
        if (lp.literal) {
            const full = try std.fs.path.join(arena, &.{ root, pat });
            const st = std.fs.cwd().statFile(full) catch return .{ .unmatched = pat };
            if (st.kind != .file or hidden(pat)) return .{ .unmatched = pat };
            try add(&out, pat);
            continue;
        }
        const base = if (lp.dir.len == 0) root else try std.fs.path.join(arena, &.{ root, lp.dir });
        var dir = std.fs.cwd().openDir(base, .{ .iterate = true }) catch return .{ .unmatched = pat };
        defer dir.close();
        var walker = try dir.walk(arena);
        defer walker.deinit();
        // A pattern matches if it names a file at all, whether or not an earlier pattern named it too.
        var matched = false;
        while (try walker.next()) |entry| {
            if (entry.kind != .file or hidden(entry.path)) continue;
            const rel = if (lp.dir.len == 0) try arena.dupe(u8, entry.path) else try std.fmt.allocPrint(arena, "{s}/{s}", .{ lp.dir, entry.path });
            if (matches(pat, rel)) {
                matched = true;
                try add(&out, rel);
            }
        }
        if (!matched) return .{ .unmatched = pat };
    }
    std.mem.sort([]const u8, out.items, {}, lessPath);
    return .{ .files = out.items };
}

fn add(out: *std.ArrayList([]const u8), path: []const u8) !void {
    for (out.items) |have| {
        if (std.mem.eql(u8, have, path)) return;
    }
    try out.append(path);
}

fn lessPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// The directories that hold `files`, sorted, each once ("." for the member directory itself).
pub fn dirsOf(arena: Allocator, files: []const []const u8) Allocator.Error![]const []const u8 {
    var out = std.ArrayList([]const u8).init(arena);
    for (files) |f| {
        const d = std.fs.path.dirname(f) orelse ".";
        var have = false;
        for (out.items) |x| have = have or std.mem.eql(u8, x, d);
        if (!have) try out.append(d);
    }
    std.mem.sort([]const u8, out.items, {}, lessPath);
    return out.items;
}

// ---------------------------------------------------------------------- tests

fn putFile(dir: std.fs.Dir, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| try dir.makePath(d);
    try dir.writeFile(path, "x\n");
}

fn joined(a: Allocator, items: []const []const u8) ![]const u8 {
    return std.mem.join(a, " ", items);
}

test "a pattern matches whole paths: * stays in a segment, ** crosses directories, [] and ? match one character" {
    const yes = [_][2][]const u8{
        .{ "native/*.c", "native/a.c" },
        .{ "native/*.c", "native/.c" },
        .{ "native/**/*.c", "native/a.c" },
        .{ "native/**/*.c", "native/x/y/a.c" },
        .{ "**/*.h", "a.h" },
        .{ "**/*.h", "inc/deep/a.h" },
        .{ "native/**", "native/x/a.c" },
        .{ "a?.c", "ab.c" },
        .{ "a[bc].c", "ac.c" },
        .{ "zlib.h", "zlib.h" },
    };
    for (yes) |c| {
        if (!matches(c[0], c[1])) {
            std.debug.print("{s} should match {s}\n", .{ c[0], c[1] });
            return error.TestUnexpectedResult;
        }
    }
    const no = [_][2][]const u8{
        .{ "native/*.c", "native/x/a.c" },
        .{ "native/*.c", "native/a.h" },
        .{ "native/*.c", "other/a.c" },
        .{ "native/*.c", "native" },
        .{ "native", "native/a.c" },
        .{ "native/a.c", "native" },
        .{ "native/**/*.c", "native/a.h" },
        .{ "a?.c", "a.c" },
        .{ "a[bc].c", "ad.c" },
        .{ "zlib.h", "zlib.hh" },
    };
    for (no) |c| {
        if (matches(c[0], c[1])) {
            std.debug.print("{s} should not match {s}\n", .{ c[0], c[1] });
            return error.TestUnexpectedResult;
        }
    }
}

test "expand finds the files patterns name, sorted and once each, and skips hidden files" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try putFile(tmp.dir, "native/b.c");
    try putFile(tmp.dir, "native/a.c");
    try putFile(tmp.dir, "native/a.h");
    try putFile(tmp.dir, "native/sub/c.c");
    try putFile(tmp.dir, "native/.hidden.c");
    try putFile(tmp.dir, "native/.d/e.c");
    try putFile(tmp.dir, "top.h");
    const root = try tmp.dir.realpathAlloc(a, ".");

    const one = try expand(a, root, &.{"native/*.c"});
    try std.testing.expectEqualStrings("native/a.c native/b.c", try joined(a, one.files));
    const all = try expand(a, root, &.{ "native/**/*.c", "native/a.c", "native/*.h" });
    try std.testing.expectEqualStrings("native/a.c native/a.h native/b.c native/sub/c.c", try joined(a, all.files));
    // A wildcard in the first segment walks the member directory.
    const top = try expand(a, root, &.{"*.h"});
    try std.testing.expectEqualStrings("top.h", try joined(a, top.files));
    const deep = try expand(a, root, &.{"**/*.h"});
    try std.testing.expectEqualStrings("native/a.h top.h", try joined(a, deep.files));
    // A hidden file is never named, even literally.
    const hid = try expand(a, root, &.{"native/.hidden.c"});
    try std.testing.expectEqualStrings("native/.hidden.c", hid.unmatched);
}

test "expand names the first pattern that matches nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try putFile(tmp.dir, "native/a.c");
    try putFile(tmp.dir, "dir/x.c");
    const root = try tmp.dir.realpathAlloc(a, ".");
    try std.testing.expectEqualStrings("native/*.cc", (try expand(a, root, &.{ "native/*.c", "native/*.cc" })).unmatched);
    try std.testing.expectEqualStrings("nodir/*.c", (try expand(a, root, &.{"nodir/*.c"})).unmatched);
    try std.testing.expectEqualStrings("native/missing.c", (try expand(a, root, &.{"native/missing.c"})).unmatched);
    // A directory is not a file.
    try std.testing.expectEqualStrings("dir", (try expand(a, root, &.{"dir"})).unmatched);
    // No patterns, no files.
    try std.testing.expectEqual(@as(usize, 0), (try expand(a, root, &.{})).files.len);
}

test "a pattern whose files an earlier pattern already named still matches" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try putFile(tmp.dir, "n/real.c");
    const root = try tmp.dir.realpathAlloc(a, ".");
    const both = try expand(a, root, &.{ "n/real.c", "n/*.c" });
    try std.testing.expectEqualStrings("n/real.c", try joined(a, both.files));
    const again = try expand(a, root, &.{ "n/*.c", "n/*.c", "n/real.c" });
    try std.testing.expectEqualStrings("n/real.c", try joined(a, again.files));
    // A pattern that names nothing is still refused, whatever came before it.
    try std.testing.expectEqualStrings("n/*.cc", (try expand(a, root, &.{ "n/real.c", "n/*.cc" })).unmatched);
}

test "a literal path that is a symbolic link, or passes through one, is refused; a glob does not follow links" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try putFile(tmp.dir, "outside/x.c");
    try putFile(tmp.dir, "member/n/real.c");
    try tmp.dir.symLink("../../outside/x.c", "member/n/link.c", .{});
    try tmp.dir.symLink("../outside", "member/ldir", .{ .is_directory = true });
    const root = try tmp.dir.realpathAlloc(a, "member");

    // The file link, the directory link, and a path through the directory link.
    try std.testing.expectEqualStrings("n/link.c", (try expand(a, root, &.{ "n/real.c", "n/link.c" })).link);
    try std.testing.expectEqualStrings("ldir", (try expand(a, root, &.{"ldir"})).link);
    try std.testing.expectEqualStrings("ldir/x.c", (try expand(a, root, &.{"ldir/x.c"})).link);
    // A glob below a directory link starts inside the link, so it is refused too.
    try std.testing.expectEqualStrings("ldir/*.c", (try expand(a, root, &.{"ldir/*.c"})).link);
    // A glob never follows a link: neither the file link nor the directory link is a match.
    const globbed = try expand(a, root, &.{"**/*.c"});
    try std.testing.expectEqualStrings("n/real.c", try joined(a, globbed.files));
    const in_dir = try expand(a, root, &.{"n/*.c"});
    try std.testing.expectEqualStrings("n/real.c", try joined(a, in_dir.files));
    // A plain file is not a link.
    try std.testing.expectEqualStrings("n/real.c", try joined(a, (try expand(a, root, &.{"n/real.c"})).files));
}

test "dirsOf lists each directory holding a file once, sorted, and . for the member directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dirs = try dirsOf(a, &.{ "z.h", "inc/b.h", "inc/a.h", "inc/deep/c.h" });
    try std.testing.expectEqualStrings(". inc inc/deep", try joined(a, dirs));
}
