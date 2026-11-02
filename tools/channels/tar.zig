//! A byte-deterministic ustar writer, a reader for what it writes, and gzip.
//!
//! The same entries give the same bytes: entries are sorted by path, owner is root (uid and gid 0, names "root"),
//! the modification time is the one given for every entry, and gzip's header holds no time and no file name. A path
//! must fit the 100-byte name field; nothing here writes extended headers, so a longer path is refused.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum { file, dir };

pub const Entry = struct {
    /// A directory's path ends with `/`.
    path: []const u8,
    kind: Kind = .file,
    mode: u32,
    data: []const u8 = "",
};

pub const WriteError = error{ PathTooLong, DuplicatePath, BadDirPath };

fn lessThan(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Writes `entries` as one tar archive (no compression).
pub fn write(a: Allocator, entries: []const Entry, mtime: u64) ![]u8 {
    const sorted = try a.dupe(Entry, entries);
    defer a.free(sorted);
    std.mem.sort(Entry, sorted, {}, lessThan);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    for (sorted, 0..) |e, i| {
        if (i > 0 and std.mem.eql(u8, sorted[i - 1].path, e.path)) return error.DuplicatePath;
        const is_dir_path = e.path.len > 0 and e.path[e.path.len - 1] == '/';
        if ((e.kind == .dir) != is_dir_path) return error.BadDirPath;
        try header(&out, e, mtime);
        if (e.kind == .file) {
            try out.appendSlice(e.data);
            try out.appendNTimes(0, (512 - e.data.len % 512) % 512);
        }
    }
    try out.appendNTimes(0, 1024);
    return out.toOwnedSlice();
}

/// `dst.len - 1` octal digits, zero padded, then NUL.
fn octal(dst: []u8, v: u64) void {
    const n = dst.len - 1;
    var x = v;
    var i = n;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
    }
    dst[n] = 0;
}

fn header(out: *std.ArrayList(u8), e: Entry, mtime: u64) !void {
    if (e.path.len > 100) return error.PathTooLong;
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..e.path.len], e.path);
    octal(h[100..108], e.mode & 0o7777);
    octal(h[108..116], 0);
    octal(h[116..124], 0);
    octal(h[124..136], if (e.kind == .file) e.data.len else 0);
    octal(h[136..148], mtime);
    @memset(h[148..156], ' ');
    h[156] = if (e.kind == .dir) '5' else '0';
    @memcpy(h[257..263], "ustar\x00");
    h[263] = '0';
    h[264] = '0';
    @memcpy(h[265..269], "root");
    @memcpy(h[297..301], "root");
    octal(h[329..337], 0);
    octal(h[337..345], 0);
    var sum: u64 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[154] = 0;
    h[155] = ' ';
    try out.appendSlice(&h);
}

pub const Member = struct {
    path: []const u8,
    kind: Kind,
    mode: u32,
    uid: u32,
    gid: u32,
    mtime: u64,
    data: []const u8,
};

pub const ReadError = error{ BadChecksum, Truncated, BadNumber };

fn parseOctal(field: []const u8) ReadError!u64 {
    var end = field.len;
    while (end > 0 and (field[end - 1] == 0 or field[end - 1] == ' ')) end -= 1;
    var start: usize = 0;
    while (start < end and field[start] == ' ') start += 1;
    if (start == end) return 0;
    return std.fmt.parseInt(u64, field[start..end], 8) catch error.BadNumber;
}

/// Reads an archive made by `write`. The slices point into `tar`. Checks every header's checksum.
pub fn read(a: Allocator, tar: []const u8) ![]Member {
    var out = std.ArrayList(Member).init(a);
    errdefer out.deinit();
    var off: usize = 0;
    while (true) {
        if (off + 512 > tar.len) return error.Truncated;
        const h = tar[off .. off + 512];
        if (std.mem.allEqual(u8, h, 0)) break;
        var copy: [512]u8 = undefined;
        @memcpy(&copy, h);
        @memset(copy[148..156], ' ');
        var sum: u64 = 0;
        for (copy) |b| sum += b;
        if (sum != try parseOctal(h[148..156])) return error.BadChecksum;
        const name_end = std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100;
        const size: usize = @intCast(try parseOctal(h[124..136]));
        const kind: Kind = if (h[156] == '5') .dir else .file;
        off += 512;
        if (off + size > tar.len) return error.Truncated;
        try out.append(.{
            .path = h[0..name_end],
            .kind = kind,
            .mode = @intCast(try parseOctal(h[100..108])),
            .uid = @intCast(try parseOctal(h[108..116])),
            .gid = @intCast(try parseOctal(h[116..124])),
            .mtime = try parseOctal(h[136..148]),
            .data = tar[off .. off + size],
        });
        off += (size + 511) / 512 * 512;
    }
    return out.toOwnedSlice();
}

/// gzip with the library's own deflate: the header holds no time and no name, so the same bytes give the same output.
pub fn gzip(a: Allocator, bytes: []const u8) ![]u8 {
    var in = std.io.fixedBufferStream(bytes);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try std.compress.gzip.compress(in.reader(), out.writer(), .{});
    return out.toOwnedSlice();
}

pub fn gunzip(a: Allocator, bytes: []const u8) ![]u8 {
    var in = std.io.fixedBufferStream(bytes);
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    try std.compress.gzip.decompress(in.reader(), out.writer());
    return out.toOwnedSlice();
}

// ---- tests -------------------------------------------------------------------------------

const t = std.testing;

test "a tar reads back: paths, kinds, modes, owner root, the one time, the data" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try write(a, &.{
        .{ .path = "./usr/", .kind = .dir, .mode = 0o755 },
        .{ .path = "./usr/bin", .mode = 0o755, .data = "x" ** 700 },
        .{ .path = "./usr/readme", .mode = 0o644, .data = "hi" },
    }, 1700000000);
    try t.expectEqual(@as(usize, 0), bytes.len % 512);
    const got = try read(a, bytes);
    try t.expectEqual(@as(usize, 3), got.len);
    try t.expectEqualStrings("./usr/", got[0].path);
    try t.expectEqual(Kind.dir, got[0].kind);
    try t.expectEqual(@as(u32, 0o755), got[0].mode);
    try t.expectEqualStrings("./usr/bin", got[1].path);
    try t.expectEqual(@as(usize, 700), got[1].data.len);
    try t.expectEqualStrings("hi", got[2].data);
    for (got) |m| {
        try t.expectEqual(@as(u32, 0), m.uid);
        try t.expectEqual(@as(u32, 0), m.gid);
        try t.expectEqual(@as(u64, 1700000000), m.mtime);
    }
    // The owner names are root in the raw header too (dpkg and tar print them).
    try t.expectEqualStrings("root", bytes[265..269]);
    try t.expectEqualStrings("root", bytes[297..301]);
}

test "a damaged header is refused by its checksum" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const bytes = try write(a, &.{.{ .path = "./f", .mode = 0o644, .data = "data" }}, 1);
    const bad = try a.dupe(u8, bytes);
    bad[10] ^= 1; // a byte of the name
    try t.expectError(error.BadChecksum, read(a, bad));
}

test "the order of the entries does not change the bytes; the order in the archive is by path" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x: Entry = .{ .path = "./b", .mode = 0o644, .data = "1" };
    const y: Entry = .{ .path = "./a", .mode = 0o644, .data = "2" };
    const one = try write(a, &.{ x, y }, 5);
    const two = try write(a, &.{ y, x }, 5);
    try t.expectEqualSlices(u8, one, two);
    const got = try read(a, one);
    try t.expectEqualStrings("./a", got[0].path);
    try t.expectEqualStrings("./b", got[1].path);
}

test "a path over 100 bytes, a duplicate and a directory without its slash are refused" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const long = "./" ++ "d" ** 99;
    try t.expectError(error.PathTooLong, write(a, &.{.{ .path = long, .mode = 0o644 }}, 0));
    try t.expectError(error.DuplicatePath, write(a, &.{ .{ .path = "./a", .mode = 0o644 }, .{ .path = "./a", .mode = 0o644 } }, 0));
    try t.expectError(error.BadDirPath, write(a, &.{.{ .path = "./d", .kind = .dir, .mode = 0o755 }}, 0));
    try t.expectError(error.BadDirPath, write(a, &.{.{ .path = "./d/", .mode = 0o644 }}, 0));
}

test "gzip round-trips, is deterministic, and its header holds no time" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "the same bytes in, the same bytes out\n" ** 50;
    const one = try gzip(a, src);
    const two = try gzip(a, src);
    try t.expectEqualSlices(u8, one, two);
    try t.expectEqual(@as(u8, 0x1f), one[0]);
    try t.expectEqual(@as(u8, 0x8b), one[1]);
    try t.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, one[4..8]); // MTIME
    try t.expectEqual(@as(u8, 0), one[3]); // FLG: no name, no comment
    try t.expect(one.len < src.len);
    const back = try gunzip(a, one);
    try t.expectEqualStrings(src, back);
}

test "a file whose size is a whole number of blocks gets no padding block; one byte more gets a whole one" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // header (512) + data rounded up to 512 + the two zero blocks that end the archive (1024).
    const cases = [_]struct { len: usize, total: usize }{
        .{ .len = 0, .total = 512 + 0 + 1024 },
        .{ .len = 1, .total = 512 + 512 + 1024 },
        .{ .len = 511, .total = 512 + 512 + 1024 },
        .{ .len = 512, .total = 512 + 512 + 1024 },
        .{ .len = 513, .total = 512 + 1024 + 1024 },
        .{ .len = 1024, .total = 512 + 1024 + 1024 },
        .{ .len = 1025, .total = 512 + 1536 + 1024 },
    };
    for (cases) |c| {
        const data = try a.alloc(u8, c.len);
        @memset(data, 'x');
        const bytes = try write(a, &.{.{ .path = "./f", .mode = 0o644, .data = data }}, 1);
        try t.expectEqual(c.total, bytes.len);
        const got = try read(a, bytes);
        try t.expectEqual(@as(usize, 1), got.len);
        try t.expectEqualSlices(u8, data, got[0].data);
    }
    // And a second entry after an aligned one starts on its own header, not 512 bytes later.
    const data = try a.alloc(u8, 512);
    @memset(data, 'y');
    const two = try write(a, &.{ .{ .path = "./a", .mode = 0o644, .data = data }, .{ .path = "./b", .mode = 0o644, .data = "z" } }, 1);
    const members = try read(a, two);
    try t.expectEqual(@as(usize, 2), members.len);
    try t.expectEqualStrings("./b", members[1].path);
    try t.expectEqualStrings("z", members[1].data);
}
