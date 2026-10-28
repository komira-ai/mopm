//! toolchain/natives.libs: the shared libraries and links below `lib/` of every package of the native
//! catalog, read from the package files. The unit test in native_catalog.zig holds the catalog to it (every
//! package has a shared library, no link leaves its package), and `mopm-closure --natives-libs` keeps it
//! up to date with the catalog, so a weekly re-solve cannot leave it stale.
//!
//! A line is `<subdir> <package> <sha256 of the package file> <path>` for a regular file and
//! `<subdir> <package> <sha256> <path> -> <target>` for a link (target relative to its directory). `#` lines at
//! the top are kept as they are.
//!
//! `regenerate` keeps the lines of a package the file already holds for the same sha256, reads the others from
//! the package file (a `.conda`; a `.tar.bz2` is refused, the catalog holds none and the standard library has no
//! bzip2), and drops the lines of packages the catalog no longer pins. The package bytes come from a `source`, so
//! the tool downloads them and a test supplies them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const closure = @import("closure.zig");
const native_catalog = @import("native_catalog.zig");
const conda_unpack = @import("conda_unpack.zig");
const conda_fixture = @import("conda_fixture.zig");
const testroot = @import("testroot.zig");

pub const Diag = struct { message: []const u8 = "" };

pub const default_header =
    "# The shared libraries of every package of the native catalog (src/core/toolchain/natives-<subdir>.json), as the\n" ++
    "# package holds them: one line per file below lib/ that is a shared library or a link to one.\n" ++
    "# Made by `mopm-closure --natives-libs`; see toolchain/README.md.\n";

/// A file below `lib/` (not below a directory of it) named like a shared library: `.so`, `.so.<n>...` or `.dylib`.
pub fn isLibPath(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "lib/")) return false;
    if (std.mem.indexOfScalar(u8, path[4..], '/') != null) return false;
    if (std.mem.endsWith(u8, path, ".dylib")) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, path, from, ".so")) |at| {
        const next = at + 3;
        if (next == path.len or path[next] == '.') return true;
        from = at + 1;
    }
    return false;
}

fn linesOfPackage(arena: Allocator, subdir: []const u8, p: closure.Package, window: []u8, bytes: []const u8, out: *std.ArrayList(u8), diag: *Diag) !void {
    var d: conda_unpack.Diag = .{};
    const entries = conda_unpack.listEntries(arena, bytes, window, &d) catch |e| {
        diag.message = try std.fmt.allocPrint(arena, "{s} {s}: {s}: {s}", .{ subdir, p.name, @errorName(e), d.message });
        return error.BadPackage;
    };
    for (entries) |e| {
        if (!isLibPath(e.name)) continue;
        switch (e.kind) {
            .file => try out.writer().print("{s} {s} {s} {s}\n", .{ subdir, p.name, p.sha256, e.name }),
            .symlink => try out.writer().print("{s} {s} {s} {s} -> {s}\n", .{ subdir, p.name, p.sha256, e.name, e.link }),
            .hardlink, .dir => {
                diag.message = try std.fmt.allocPrint(arena, "{s} {s}: {s} is a {s}; natives.libs records files and symbolic links only", .{ subdir, p.name, e.name, @tagName(e.kind) });
                return error.BadPackage;
            },
        }
    }
}

/// The new text of natives.libs for `catalogs`, given the old text. `source.bytesOf(arena, subdir, package)` gives
/// the package file's bytes and is called only for a package the old text holds no lines for with the pinned
/// sha256. Errors: `HashMismatch` (the bytes are not the pinned sha256), `UnsupportedFormat` (not a `.conda`) and
/// `BadPackage`, each with `diag` set.
pub fn regenerate(arena: Allocator, old_text: []const u8, catalogs: []const native_catalog.Catalog, window: []u8, source: anytype, diag: *Diag) ![]u8 {
    var out = std.ArrayList(u8).init(arena);
    var old = std.ArrayList([]const u8).init(arena);
    var header_done = false;
    var header = std.ArrayList(u8).init(arena);
    var lines = std.mem.splitScalar(u8, old_text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') {
            if (!header_done) try header.writer().print("{s}\n", .{line});
            continue;
        }
        header_done = true;
        try old.append(line);
    }
    try out.appendSlice(if (header.items.len > 0) header.items else default_header);
    for (catalogs) |cat| {
        for (cat.packages) |p| {
            var held = false;
            for (old.items) |line| {
                var f = std.mem.tokenizeScalar(u8, line, ' ');
                const sd = f.next() orelse continue;
                const name = f.next() orelse continue;
                const sha = f.next() orelse continue;
                if (std.mem.eql(u8, sd, cat.subdir) and std.mem.eql(u8, name, p.name) and std.mem.eql(u8, sha, p.sha256)) {
                    held = true;
                    try out.writer().print("{s}\n", .{line});
                }
            }
            if (held) continue;
            if (!std.mem.endsWith(u8, p.path, ".conda")) {
                diag.message = try std.fmt.allocPrint(arena, "{s} {s}: {s} is not a .conda; only .conda packages are read (the standard library has no bzip2)", .{ cat.subdir, p.name, p.path });
                return error.UnsupportedFormat;
            }
            const bytes = try source.bytesOf(arena, cat.subdir, p);
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            if (!std.mem.eql(u8, &hex, p.sha256)) {
                diag.message = try std.fmt.allocPrint(arena, "{s} {s}: the package file has sha256 {s}, the catalog pins {s}", .{ cat.subdir, p.name, hex, p.sha256 });
                return error.HashMismatch;
            }
            try linesOfPackage(arena, cat.subdir, p, window, bytes, &out, diag);
        }
    }
    return out.items;
}

// ------------------------------------------------------------------ tests

const Fx = struct {
    /// The package file of the one package every test uses, and how many times it was asked for.
    bytes: []const u8,
    calls: usize = 0,

    fn bytesOf(self: *Fx, _: Allocator, _: []const u8, _: closure.Package) ![]const u8 {
        self.calls += 1;
        return self.bytes;
    }
};

const NoCalls = struct {
    fn bytesOf(_: *NoCalls, _: Allocator, _: []const u8, p: closure.Package) ![]const u8 {
        std.debug.print("the package file of {s} was asked for\n", .{p.name});
        return error.Unexpected;
    }
};

fn pk(name: []const u8, path: []const u8, sha: []const u8) closure.Package {
    return .{ .name = name, .version = "1", .build = "h0_0", .subdir = "linux-64", .channel = "conda-forge", .path = path, .sha256 = sha, .size = 1 };
}

fn catOf(packages: []const closure.Package) native_catalog.Catalog {
    return .{ .subdir = "linux-64", .channels = &.{}, .roots = &.{}, .provided = &.{}, .packages = packages };
}

fn libfoo(a: Allocator) ![]u8 {
    return conda_fixture.simple(a, "libfoo", "1", &.{
        .{ .name = "lib/libfoo.so.1.2", .data = "ELF" },
        .{ .name = "lib/libfoo.so.1", .kind = .symlink, .link = "libfoo.so.1.2" },
        .{ .name = "lib/libfoo.so", .kind = .symlink, .link = "libfoo.so.1" },
        .{ .name = "lib/libfoo.1.dylib", .data = "MACHO" },
        .{ .name = "lib/pkgconfig", .kind = .dir },
        .{ .name = "lib/pkgconfig/foo.pc", .data = "x" },
        .{ .name = "lib/python3/site/ext.so", .data = "x" },
        .{ .name = "lib/libfoo.a", .data = "!<arch>" },
        .{ .name = "lib/cmake.sox", .data = "x" },
        .{ .name = "include/foo.h", .data = "x" },
    });
}

test "isLibPath: shared libraries and links directly below lib/" {
    for ([_][]const u8{ "lib/libz.so", "lib/libz.so.1.3.2", "lib/libz.1.dylib", "lib/libc++.1.0.dylib" }) |p| try std.testing.expect(isLibPath(p));
    for ([_][]const u8{ "lib/libz.a", "lib/x.sox", "lib/py/ext.so", "include/z.so", "libz.so", "lib/pkgconfig", "lib/libz.so-gdb.py" }) |p| try std.testing.expect(!isLibPath(p));
}

test "regenerate: a new package is read from its .conda; the header is kept; nothing else of the package is listed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const bytes = try libfoo(a);
    const sha = try conda_fixture.sha256Hex(a, bytes);
    const window = try a.alloc(u8, conda_unpack.window_size);
    var fx = Fx{ .bytes = bytes };
    var diag = Diag{};
    const got = try regenerate(a, "# my header\n# second\n", &.{catOf(&.{pk("libfoo", "linux-64/libfoo-1-h0_0.conda", sha)})}, window, &fx, &diag);
    const want = try std.fmt.allocPrint(a,
        \\# my header
        \\# second
        \\linux-64 libfoo {0s} lib/libfoo.so.1.2
        \\linux-64 libfoo {0s} lib/libfoo.so.1 -> libfoo.so.1.2
        \\linux-64 libfoo {0s} lib/libfoo.so -> libfoo.so.1
        \\linux-64 libfoo {0s} lib/libfoo.1.dylib
        \\
    , .{sha});
    try std.testing.expectEqualStrings(want, got);
    try std.testing.expectEqual(@as(usize, 1), fx.calls);
}

test "regenerate: a package pinned with the sha256 the file holds is not read again; a moved pin is; an unpinned package is dropped" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const bytes = try libfoo(a);
    const sha = try conda_fixture.sha256Hex(a, bytes);
    const window = try a.alloc(u8, conda_unpack.window_size);
    const old = "# h\nlinux-64 kept aa lib/libkept.so.1\nlinux-64 kept aa lib/libkept.so -> libkept.so.1\nlinux-64 moved bb lib/libmoved.so.1\nlinux-64 gone cc lib/libgone.so.1\n";
    var diag = Diag{};
    var none = NoCalls{};
    const same = try regenerate(a, old, &.{catOf(&.{pk("kept", "linux-64/kept-1-h0_0.conda", "aa")})}, window, &none, &diag);
    try std.testing.expectEqualStrings("# h\nlinux-64 kept aa lib/libkept.so.1\nlinux-64 kept aa lib/libkept.so -> libkept.so.1\n", same);
    var fx = Fx{ .bytes = bytes };
    const moved = try regenerate(a, old, &.{catOf(&.{ pk("kept", "linux-64/kept-1-h0_0.conda", "aa"), pk("moved", "linux-64/moved-1-h0_0.conda", sha) })}, window, &fx, &diag);
    try std.testing.expect(std.mem.indexOf(u8, moved, "linux-64 moved bb") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "linux-64 gone") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "linux-64 kept aa lib/libkept.so.1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, try std.fmt.allocPrint(a, "linux-64 moved {s} lib/libfoo.so.1.2\n", .{sha})) != null);
    try std.testing.expectEqual(@as(usize, 1), fx.calls);
}

test "regenerate: bytes that are not the pinned sha256 are refused, naming both" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const bytes = try libfoo(a);
    const sha = try conda_fixture.sha256Hex(a, bytes);
    const window = try a.alloc(u8, conda_unpack.window_size);
    var fx = Fx{ .bytes = bytes };
    var diag = Diag{};
    const pinned = "0" ** 64;
    try std.testing.expectError(error.HashMismatch, regenerate(a, "", &.{catOf(&.{pk("libfoo", "linux-64/libfoo-1-h0_0.conda", pinned)})}, window, &fx, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, sha) != null);
    try std.testing.expect(std.mem.indexOf(u8, diag.message, pinned) != null);
}

test "regenerate: a .tar.bz2 is refused before anything is fetched; a hard link and a damaged package are errors" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const window = try a.alloc(u8, conda_unpack.window_size);
    var none = NoCalls{};
    var diag = Diag{};
    try std.testing.expectError(error.UnsupportedFormat, regenerate(a, "", &.{catOf(&.{pk("old", "linux-64/old-1-0.tar.bz2", "aa")})}, window, &none, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "old-1-0.tar.bz2") != null);

    const hard = try conda_fixture.simple(a, "h", "1", &.{.{ .name = "lib/libh.so.1", .kind = .hardlink, .link = "lib/libh.so.2" }});
    var fh = Fx{ .bytes = hard };
    try std.testing.expectError(error.BadPackage, regenerate(a, "", &.{catOf(&.{pk("h", "linux-64/h-1-h0_0.conda", try conda_fixture.sha256Hex(a, hard))})}, window, &fh, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.message, "hardlink") != null);

    const junk = "not a zip at all, but long enough to have a tail";
    var fj = Fx{ .bytes = junk };
    try std.testing.expectError(error.BadPackage, regenerate(a, "", &.{catOf(&.{pk("j", "linux-64/j-1-h0_0.conda", try conda_fixture.sha256Hex(a, junk))})}, window, &fj, &diag));
}

test "regenerate: the committed natives.libs is what the committed catalog and itself make, with no package read" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const committed = try std.fs.cwd().readFileAlloc(a, try testroot.path(a, "toolchain/natives.libs"), 1 << 20);
    var cats = std.ArrayList(native_catalog.Catalog).init(a);
    for (closure.subdirs) |sd| try cats.append((try native_catalog.forSubdir(a, sd)).?);
    const window = try a.alloc(u8, 1);
    var none = NoCalls{};
    var diag = Diag{};
    const got = try regenerate(a, committed, cats.items, window, &none, &diag);
    try std.testing.expectEqualStrings(committed, got);
}
