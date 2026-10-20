//! A .deb written byte-deterministically, and its control file read back.
//!
//! A .deb is an `ar` archive of three members, in this order: `debian-binary` ("2.0\n"), `control.tar.gz` (the
//! control file and the md5sums) and `data.tar.gz` (the files, with their directories). Everything that could vary
//! is fixed: members and tar entries are sorted, owner is root, every time is the one `mtime` given, gzip's header
//! holds no time. The same package description and the same bytes in give the same .deb out, so a verifier can
//! rebuild a .deb from a release tarball and compare it with the one that was attested.
//!
//! Nothing here runs dpkg; `dpkg-deb --info/--contents` and lintian are run on the output by the CI that uses this.

const std = @import("std");
const Allocator = std.mem.Allocator;
const tar = @import("tar.zig");
const control = @import("control.zig");
const version_mod = @import("version.zig");

pub const File = struct {
    /// Relative to `/`, with no leading slash and no `.` or `..` component: `usr/bin/mopm`.
    path: []const u8,
    data: []const u8,
    mode: u32,
};

pub const Package = struct {
    name: []const u8,
    /// `X.Y.Z`. A native package: no Debian revision.
    version: []const u8,
    architecture: []const u8,
    maintainer: []const u8,
    homepage: []const u8,
    synopsis: []const u8,
    /// Extra paragraph lines after the synopsis; may be empty. An empty line is written as ` .`.
    long_description: []const u8 = "",
    section: []const u8 = "devel",
    priority: []const u8 = "optional",
    files: []const File,
    /// Seconds since the epoch, written to every member and entry.
    mtime: u64,
};

pub const Error = error{ BadName, BadArchitecture, BadPath, NoFiles, MemberTooBig, NotADeb, NoControl };

fn validName(s: []const u8) bool {
    if (s.len < 2) return false;
    if (!std.ascii.isLower(s[0]) and !std.ascii.isDigit(s[0])) return false;
    for (s) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '+' and ch != '-' and ch != '.') return false;
    }
    return true;
}

fn validArch(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| {
        if (!std.ascii.isLower(ch) and !std.ascii.isDigit(ch) and ch != '-') return false;
    }
    return true;
}

fn validPath(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/' or p[p.len - 1] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |c| {
        if (c.len == 0 or std.mem.eql(u8, c, ".") or std.mem.eql(u8, c, "..")) return false;
    }
    return true;
}

fn checkPackage(p: Package) !void {
    if (!validName(p.name)) return error.BadName;
    _ = try version_mod.Version.parse(p.version);
    if (!validArch(p.architecture)) return error.BadArchitecture;
    if (p.files.len == 0) return error.NoFiles;
    for (p.files) |f| {
        if (!validPath(f.path)) return error.BadPath;
    }
}

/// The fields of the control file, in the order dpkg tools print them, Description last. `a` owns the strings.
pub fn controlFields(a: Allocator, p: Package) ![]control.Field {
    try checkPackage(p);
    var total: usize = 0;
    for (p.files) |f| total += f.data.len;
    var desc = std.ArrayList(u8).init(a);
    try desc.appendSlice(p.synopsis);
    if (p.long_description.len > 0) {
        var it = std.mem.splitScalar(u8, p.long_description, '\n');
        while (it.next()) |line| {
            try desc.appendSlice("\n ");
            try desc.appendSlice(if (line.len == 0) "." else line);
        }
    }
    var out = std.ArrayList(control.Field).init(a);
    try out.append(.{ .name = "Package", .value = p.name });
    try out.append(.{ .name = "Version", .value = p.version });
    try out.append(.{ .name = "Architecture", .value = p.architecture });
    try out.append(.{ .name = "Maintainer", .value = p.maintainer });
    try out.append(.{ .name = "Installed-Size", .value = try std.fmt.allocPrint(a, "{d}", .{(total + 1023) / 1024}) });
    try out.append(.{ .name = "Section", .value = p.section });
    try out.append(.{ .name = "Priority", .value = p.priority });
    try out.append(.{ .name = "Homepage", .value = p.homepage });
    try out.append(.{ .name = "Description", .value = try desc.toOwnedSlice() });
    return out.toOwnedSlice();
}

/// The `control` file text.
pub fn controlText(a: Allocator, p: Package) ![]u8 {
    return control.render(a, try controlFields(a, p));
}

fn md5sums(a: Allocator, files: []const File) ![]u8 {
    const sorted = try a.dupe(File, files);
    defer a.free(sorted);
    std.mem.sort(File, sorted, {}, struct {
        fn lt(_: void, x: File, y: File) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.lt);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (sorted) |f| {
        var digest: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(f.data, &digest, .{});
        try out.writer().print("{s}  {s}\n", .{ std.fmt.bytesToHex(digest, .lower), f.path });
    }
    return out.toOwnedSlice();
}

/// The data.tar entries: every file, and every directory above a file, as `./a/b`.
fn dataEntries(a: Allocator, files: []const File) ![]tar.Entry {
    var out = std.ArrayList(tar.Entry).init(a);
    var dirs = std.StringHashMap(void).init(a);
    defer dirs.deinit();
    try out.append(.{ .path = "./", .kind = .dir, .mode = 0o755 });
    for (files) |f| {
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, f.path, i, '/')) |slash| {
            const dir = try std.fmt.allocPrint(a, "./{s}/", .{f.path[0..slash]});
            if (!dirs.contains(dir)) {
                try dirs.put(dir, {});
                try out.append(.{ .path = dir, .kind = .dir, .mode = 0o755 });
            }
            i = slash + 1;
        }
        try out.append(.{ .path = try std.fmt.allocPrint(a, "./{s}", .{f.path}), .mode = f.mode, .data = f.data });
    }
    return out.toOwnedSlice();
}

fn arMember(out: *std.ArrayList(u8), name: []const u8, mtime: u64, data: []const u8) !void {
    var h: [60]u8 = undefined;
    @memset(&h, ' ');
    @memcpy(h[0..name.len], name);
    _ = std.fmt.bufPrint(h[16..28], "{d}", .{mtime}) catch return error.MemberTooBig;
    h[28] = '0'; // uid
    h[34] = '0'; // gid
    @memcpy(h[40..46], "100644");
    _ = std.fmt.bufPrint(h[48..58], "{d}", .{data.len}) catch return error.MemberTooBig;
    h[58] = '`';
    h[59] = '\n';
    try out.appendSlice(&h);
    try out.appendSlice(data);
    if (data.len % 2 == 1) try out.append('\n');
}

/// The .deb file's bytes.
pub fn build(a: Allocator, p: Package) ![]u8 {
    const ctrl = try controlText(a, p);
    const sums = try md5sums(a, p.files);
    const control_tar = try tar.write(a, &.{
        .{ .path = "./", .kind = .dir, .mode = 0o755 },
        .{ .path = "./control", .mode = 0o644, .data = ctrl },
        .{ .path = "./md5sums", .mode = 0o644, .data = sums },
    }, p.mtime);
    const data_tar = try tar.write(a, try dataEntries(a, p.files), p.mtime);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try out.appendSlice("!<arch>\n");
    try arMember(&out, "debian-binary", p.mtime, "2.0\n");
    try arMember(&out, "control.tar.gz", p.mtime, try tar.gzip(a, control_tar));
    try arMember(&out, "data.tar.gz", p.mtime, try tar.gzip(a, data_tar));
    return out.toOwnedSlice();
}

pub const ArMember = struct { name: []const u8, data: []const u8 };

/// The members of an ar archive, in order. The slices point into `bytes`.
pub fn readAr(a: Allocator, bytes: []const u8) ![]ArMember {
    if (!std.mem.startsWith(u8, bytes, "!<arch>\n")) return error.NotADeb;
    var out = std.ArrayList(ArMember).init(a);
    errdefer out.deinit();
    var off: usize = 8;
    while (off < bytes.len) {
        if (off + 60 > bytes.len) return error.NotADeb;
        const h = bytes[off .. off + 60];
        if (h[58] != '`' or h[59] != '\n') return error.NotADeb;
        const name = std.mem.trimRight(u8, std.mem.trimRight(u8, h[0..16], " "), "/");
        const size = std.fmt.parseInt(usize, std.mem.trim(u8, h[48..58], " "), 10) catch return error.NotADeb;
        off += 60;
        if (off + size > bytes.len) return error.NotADeb;
        try out.append(.{ .name = name, .data = bytes[off .. off + size] });
        off += size + size % 2;
    }
    return out.toOwnedSlice();
}

/// The text of the `control` file of a .deb. Checks the member order too.
pub fn readControl(a: Allocator, deb: []const u8) ![]u8 {
    const members = try readAr(a, deb);
    if (members.len != 3) return error.NotADeb;
    if (!std.mem.eql(u8, members[0].name, "debian-binary") or !std.mem.eql(u8, members[0].data, "2.0\n")) return error.NotADeb;
    if (!std.mem.eql(u8, members[1].name, "control.tar.gz") or !std.mem.eql(u8, members[2].name, "data.tar.gz")) return error.NotADeb;
    const raw = try tar.gunzip(a, members[1].data);
    for (try tar.read(a, raw)) |m| {
        if (std.mem.eql(u8, m.path, "./control") or std.mem.eql(u8, m.path, "control")) return a.dupe(u8, m.data);
    }
    return error.NoControl;
}

/// The data tar of a .deb, decompressed and read.
pub fn readData(a: Allocator, deb: []const u8) ![]tar.Member {
    const members = try readAr(a, deb);
    if (members.len != 3) return error.NotADeb;
    return tar.read(a, try tar.gunzip(a, members[2].data));
}

// ---- tests -------------------------------------------------------------------------------

const t = std.testing;

const sample_files = [_]File{
    .{ .path = "usr/share/doc/mopm/copyright", .data = "Apache-2.0\n", .mode = 0o644 },
    .{ .path = "usr/bin/mopm", .data = "ELF-not-really", .mode = 0o755 },
};

fn sample() Package {
    return .{
        .name = "mopm",
        .version = "1.2.3",
        .architecture = "amd64",
        .maintainer = "mopm authors <apt@mopm.dev>",
        .homepage = "https://mopm.dev",
        .synopsis = "package manager for Mojo",
        .long_description = "Resolves, locks and builds Mojo packages.\n\nStatic binary.",
        .files = &sample_files,
        .mtime = 1700000000,
    };
}

test "the control file has the fields in order, Installed-Size rounded up, a folded description" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try controlText(a, sample());
    try t.expectEqualStrings(
        "Package: mopm\n" ++
            "Version: 1.2.3\n" ++
            "Architecture: amd64\n" ++
            "Maintainer: mopm authors <apt@mopm.dev>\n" ++
            "Installed-Size: 1\n" ++
            "Section: devel\n" ++
            "Priority: optional\n" ++
            "Homepage: https://mopm.dev\n" ++
            "Description: package manager for Mojo\n" ++
            " Resolves, locks and builds Mojo packages.\n" ++
            " .\n" ++
            " Static binary.\n",
        text,
    );
    var big = sample();
    const data = try a.alloc(u8, 2049);
    @memset(data, 'x');
    const big_files = [_]File{.{ .path = "usr/bin/mopm", .data = data, .mode = 0o755 }};
    big.files = &big_files;
    const bigfields = try controlFields(a, big);
    try t.expectEqualStrings("3", control.get(bigfields, "Installed-Size").?);
}

test "the deb is an ar archive of debian-binary, control.tar.gz, data.tar.gz, padded to even" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deb = try build(a, sample());
    try t.expect(std.mem.startsWith(u8, deb, "!<arch>\n"));
    const members = try readAr(a, deb);
    try t.expectEqual(@as(usize, 3), members.len);
    try t.expectEqualStrings("debian-binary", members[0].name);
    try t.expectEqualStrings("2.0\n", members[0].data);
    try t.expectEqualStrings("control.tar.gz", members[1].name);
    try t.expectEqualStrings("data.tar.gz", members[2].name);
    // The header of the first member, byte for byte: name(16) mtime(12) uid(6) gid(6) mode(8) size(10) magic(2).
    try t.expectEqualStrings("debian-binary   1700000000  0     0     100644  4         `\n", deb[8..68]);
    // "2.0\n" is even, so the next header follows at once; an odd member would be followed by a newline.
    try t.expectEqualStrings("control.tar.gz", std.mem.trimRight(u8, deb[72..88], " "));
    var odd = std.ArrayList(u8).init(a);
    try odd.appendSlice("!<arch>\n");
    try arMember(&odd, "x", 1, "abc");
    try t.expectEqual(@as(usize, 8 + 60 + 3 + 1), odd.items.len);
    try t.expectEqual(@as(u8, '\n'), odd.items[odd.items.len - 1]);
    const back = try readAr(a, odd.items);
    try t.expectEqualStrings("abc", back[0].data);
}

test "the control file reads back out of the deb" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deb = try build(a, sample());
    const want = try controlText(a, sample());
    const got = try readControl(a, deb);
    try t.expectEqualStrings(want, got);
}

test "data.tar holds every directory above a file once, files with their modes, all owned by root" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const members = try readData(a, try build(a, sample()));
    const want = [_]struct { path: []const u8, kind: tar.Kind, mode: u32 }{
        .{ .path = "./", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/bin/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/bin/mopm", .kind = .file, .mode = 0o755 },
        .{ .path = "./usr/share/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/share/doc/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/share/doc/mopm/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/share/doc/mopm/copyright", .kind = .file, .mode = 0o644 },
    };
    try t.expectEqual(want.len, members.len);
    for (want, members) |w, m| {
        try t.expectEqualStrings(w.path, m.path);
        try t.expectEqual(w.kind, m.kind);
        try t.expectEqual(w.mode, m.mode);
        try t.expectEqual(@as(u32, 0), m.uid);
        try t.expectEqual(@as(u32, 0), m.gid);
        try t.expectEqual(@as(u64, 1700000000), m.mtime);
    }
    try t.expectEqualStrings("ELF-not-really", members[3].data);
}

test "md5sums lists each file's md5 in path order" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The md5 of "abc" and of the empty string are the published test vectors (RFC 1321).
    const got = try md5sums(a, &.{
        .{ .path = "usr/share/b", .data = "", .mode = 0o644 },
        .{ .path = "usr/bin/a", .data = "abc", .mode = 0o755 },
    });
    try t.expectEqualStrings(
        "900150983cd24fb0d6963f7d28e17f72  usr/bin/a\nd41d8cd98f00b204e9800998ecf8427e  usr/share/b\n",
        got,
    );
}

test "the same package gives the same bytes; any input that matters changes them" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = try build(a, sample());
    const two = try build(a, sample());
    try t.expectEqualSlices(u8, one, two);
    // The order the files are listed in is not part of the output.
    var swapped = sample();
    const rev = [_]File{ sample_files[1], sample_files[0] };
    swapped.files = &rev;
    try t.expectEqualSlices(u8, one, try build(a, swapped));
    var later = sample();
    later.mtime += 1;
    try t.expect(!std.mem.eql(u8, one, try build(a, later)));
    var other = sample();
    const changed = [_]File{ sample_files[0], .{ .path = "usr/bin/mopm", .data = "ELF-not-reallY", .mode = 0o755 } };
    other.files = &changed;
    try t.expect(!std.mem.eql(u8, one, try build(a, other)));
    var arm = sample();
    arm.architecture = "arm64";
    try t.expect(!std.mem.eql(u8, one, try build(a, arm)));
}

test "a bad name, version, architecture, path or field is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = sample();
    p.name = "Mopm";
    try t.expectError(error.BadName, build(a, p));
    p = sample();
    p.version = "1.2";
    try t.expectError(error.BadVersion, build(a, p));
    p = sample();
    p.version = "1.2.3-1";
    try t.expectError(error.BadVersion, build(a, p));
    p = sample();
    p.architecture = "amd 64";
    try t.expectError(error.BadArchitecture, build(a, p));
    p = sample();
    p.files = &.{};
    try t.expectError(error.NoFiles, build(a, p));
    for ([_][]const u8{ "/usr/bin/mopm", "usr/../etc/passwd", "usr//bin", "usr/bin/", "./usr/bin/mopm", "" }) |bad| {
        p = sample();
        const one_file = [_]File{.{ .path = bad, .data = "x", .mode = 0o755 }};
        p.files = &one_file;
        try t.expectError(error.BadPath, build(a, p));
    }
    p = sample();
    p.maintainer = "x <x@y>\nDepends: evil";
    try t.expectError(error.BadField, build(a, p));
    p = sample();
    p.homepage = "";
    try t.expectError(error.BadField, build(a, p));
}

test "a file that is not a deb is refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectError(error.NotADeb, readControl(a, "hello"));
    const deb = try build(a, sample());
    try t.expectError(error.NotADeb, readControl(a, deb[0 .. deb.len - 3]));
    // Only the first byte of the magic is wrong: the rest is a good deb, so the magic check alone refuses it.
    const bad_magic = try a.dupe(u8, deb);
    bad_magic[0] = '?';
    try t.expectError(error.NotADeb, readControl(a, bad_magic));
}
