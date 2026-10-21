//! What the shared index consists of, and what was read of it. Pure functions over text: no file, no process.
//!
//! The repository is one tree of object keys under `apt/`. The index of the suite `stable` is a handful of objects under
//! `apt/dists/stable/`: for each architecture a `Packages` and a `Packages.gz`, and `Release`, `InRelease`, `Release.gpg`.
//! Every write to one of them is conditional on the version that was read (its ETag), so the ETag of each object is kept
//! beside the copy of it in a text file, `etags.txt`, one `<path><TAB><etag>` line per object, `-` for an object that did
//! not exist.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The key prefix of everything the repository serves.
pub const key_root = "apt/";
/// The index of the suite, relative to the repository root.
pub const suite_dir = "dists/stable/";
/// The architectures that are read and written even when no Release lists them yet (the architectures mopm ships).
pub const default_archs = [_][]const u8{ "amd64", "arm64" };
/// The file of ETags next to the copy of the index.
pub const etags_file = "etags.txt";
/// The ETag of an object that did not exist when it was read.
pub const absent = "-";
/// The objects that sign the index, in the order they are written (after every Packages file).
pub const release_files = [_][]const u8{ "Release", "InRelease", "Release.gpg" };

pub const Error = error{ BadEtagLine, BadPoolDir, BadFileName };

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn validArch(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-')) return false;
    }
    return true;
}

/// The architectures a Release lists (the `main/binary-<arch>/Packages` lines of its checksums) together with the
/// defaults, each once, sorted. A word that is not a clean architecture name is ignored: it is never used as a path.
pub fn archsOfRelease(a: Allocator, release: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (default_archs) |d| try out.append(d);
    const head = "main/binary-";
    const tail = "/Packages";
    var words = std.mem.tokenizeAny(u8, release, " \t\r\n");
    while (words.next()) |w| {
        if (!std.mem.startsWith(u8, w, head) or !std.mem.endsWith(u8, w, tail) or w.len <= head.len + tail.len) continue;
        const arch = w[head.len .. w.len - tail.len];
        if (!validArch(arch)) continue;
        var seen = false;
        for (out.items) |x| {
            if (std.mem.eql(u8, x, arch)) seen = true;
        }
        if (!seen) try out.append(try a.dupe(u8, arch));
    }
    std.mem.sort([]const u8, out.items, {}, lessThan);
    return out.items;
}

/// The objects of the index of `archs`, relative to `dists/stable/`, in the order they are written: every Packages and
/// Packages.gz first, then Release, InRelease and Release.gpg. A reader sees a Release only after the files it lists.
pub fn indexFiles(a: Allocator, archs: []const []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    for (archs) |arch| {
        try out.append(try std.fmt.allocPrint(a, "main/binary-{s}/Packages", .{arch}));
        try out.append(try std.fmt.allocPrint(a, "main/binary-{s}/Packages.gz", .{arch}));
    }
    for (release_files) |f| try out.append(f);
    return out.items;
}

/// The object key of a file of the index.
pub fn indexKey(a: Allocator, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ key_root, suite_dir, rel });
}

/// The object key of a .deb in the pool directory `pool_dir` (`pool/<product>`, nothing else is accepted), by the file's
/// base name. A name with a separator or a leading dot is refused: it would leave the directory.
pub fn poolKey(a: Allocator, pool_dir: []const u8, file: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, pool_dir, "pool/") or pool_dir.len == "pool/".len or std.mem.endsWith(u8, pool_dir, "/") or std.mem.indexOf(u8, pool_dir, "..") != null or std.mem.indexOf(u8, pool_dir, "//") != null) return error.BadPoolDir;
    if (file.len == 0 or file[0] == '.' or std.mem.indexOfScalar(u8, file, '/') != null or !std.mem.endsWith(u8, file, ".deb")) return error.BadFileName;
    return std.fmt.allocPrint(a, "{s}{s}/{s}", .{ key_root, pool_dir, file });
}

pub const Entry = struct { path: []const u8, etag: []const u8 };

pub fn renderEtags(a: Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (entries) |e| try out.writer().print("{s}\t{s}\n", .{ e.path, e.etag });
    return out.toOwnedSlice();
}

pub fn parseEtags(a: Allocator, text: []const u8) ![]Entry {
    var out = std.ArrayList(Entry).init(a);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        const tab = std.mem.indexOfScalar(u8, l, '\t') orelse return error.BadEtagLine;
        if (tab == 0 or tab + 1 >= l.len or std.mem.indexOfScalarPos(u8, l, tab + 1, '\t') != null) return error.BadEtagLine;
        try out.append(.{ .path = l[0..tab], .etag = l[tab + 1 ..] });
    }
    return out.items;
}

/// The ETag read for `path`, or null when the file was never read.
pub fn etagOf(entries: []const Entry, path: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.etag;
    }
    return null;
}

const t = std.testing;

test "archsOfRelease: the defaults and every architecture the Release lists, once, sorted" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rel = "Origin: x\nSHA256:\n aa 10 main/binary-amd64/Packages\n bb 5 main/binary-amd64/Packages.gz\n cc 7 main/binary-s390x/Packages\n dd 7 main/binary-s390x/Packages\n";
    const got = try archsOfRelease(a, rel);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("amd64", got[0]);
    try t.expectEqualStrings("arm64", got[1]);
    try t.expectEqualStrings("s390x", got[2]);
    // No Release: the defaults alone.
    try t.expectEqual(@as(usize, 2), (try archsOfRelease(a, "")).len);
}

test "archsOfRelease ignores a word that is not a clean architecture, so it is never a path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try archsOfRelease(a, " aa 1 main/binary-../../x/Packages\n bb 1 main/binary-A_B/Packages\n cc 1 main/binary-/Packages\n");
    try t.expectEqual(@as(usize, 2), got.len);
}

test "indexFiles: every Packages and Packages.gz, then Release, InRelease, Release.gpg last" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = try indexFiles(a, &.{ "amd64", "arm64" });
    try t.expectEqual(@as(usize, 7), files.len);
    try t.expectEqualStrings("main/binary-amd64/Packages", files[0]);
    try t.expectEqualStrings("main/binary-arm64/Packages.gz", files[3]);
    try t.expectEqualStrings("Release", files[4]);
    try t.expectEqualStrings("InRelease", files[5]);
    try t.expectEqualStrings("Release.gpg", files[6]);
    try t.expectEqualStrings("apt/dists/stable/Release", try indexKey(a, "Release"));
}

test "poolKey: below the product's pool directory only" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings("apt/pool/mopm/mopm_1.2.3_amd64.deb", try poolKey(a, "pool/mopm", "mopm_1.2.3_amd64.deb"));
    for ([_][]const u8{ "", "pool", "pool/", "mopm", "pool/mopm/", "pool/../x", "pool//x" }) |d| {
        try t.expectError(error.BadPoolDir, poolKey(a, d, "x.deb"));
    }
    for ([_][]const u8{ "", ".hidden.deb", "a/b.deb", "../x.deb", "x.txt" }) |f| {
        try t.expectError(error.BadFileName, poolKey(a, "pool/mopm", f));
    }
}

test "the etag file round-trips, an absent object is a dash, and a bad line is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try renderEtags(a, &.{ .{ .path = "Release", .etag = "\"abc\"" }, .{ .path = "InRelease", .etag = absent } });
    try t.expectEqualStrings("Release\t\"abc\"\nInRelease\t-\n", text);
    const back = try parseEtags(a, text);
    try t.expectEqual(@as(usize, 2), back.len);
    try t.expectEqualStrings("\"abc\"", etagOf(back, "Release").?);
    try t.expectEqualStrings(absent, etagOf(back, "InRelease").?);
    try t.expect(etagOf(back, "Release.gpg") == null);
    for ([_][]const u8{ "no tab\n", "\tetag\n", "path\t\n", "a\tb\tc\n" }) |bad| {
        try t.expectError(error.BadEtagLine, parseEtags(a, bad));
    }
}
