//! A streaming tar reader for the archives inside a `.conda` package.
//!
//! Reads ustar, with the GNU long-name/long-link records ('L', 'K') and pax
//! extended headers ('x': `path`, `linkpath`, `size`; 'g' is skipped). Entries
//! it returns: regular files, directories, symbolic links and hard links.
//! Anything else (devices, FIFOs, sparse files) is an error, never skipped.
//!
//! `next` returns the header of the next entry; the entry's bytes are then
//! read with `read` until it returns 0. The name and link slices are valid
//! until the next call of `next`. The checksum of every header is verified.

const std = @import("std");

pub const Kind = enum { file, dir, symlink, hardlink };

pub const Entry = struct {
    name: []const u8,
    /// The target of a symbolic or hard link, else "".
    link: []const u8,
    size: u64,
    /// The permission bits (the low 12 bits of the tar mode).
    mode: u32,
    kind: Kind,
};

pub const max_name = 4096;
const pax_max = 64 * 1024;

pub fn TarReader(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        reader: ReaderType,
        /// Bytes of the current entry not yet read.
        remaining: u64 = 0,
        /// Zero bytes between the end of the current entry and the next header.
        padding: u64 = 0,
        name_buf: [max_name]u8 = undefined,
        link_buf: [max_name]u8 = undefined,
        pax_buf: [pax_max]u8 = undefined,

        pub fn init(reader: ReaderType) Self {
            return .{ .reader = reader };
        }

        fn skip(self: *Self, n: u64) !void {
            var left = n;
            var buf: [4096]u8 = undefined;
            while (left > 0) {
                const want: usize = @intCast(@min(left, buf.len));
                try self.reader.readNoEof(buf[0..want]);
                left -= want;
            }
        }

        /// Reads the data of the current entry into `dest`; 0 at its end.
        pub fn read(self: *Self, dest: []u8) !usize {
            const want: usize = @intCast(@min(@as(u64, dest.len), self.remaining));
            if (want == 0) return 0;
            const n = try self.reader.read(dest[0..want]);
            if (n == 0) return error.UnexpectedEndOfStream;
            self.remaining -= n;
            return n;
        }

        fn parseOctal(field: []const u8) !u64 {
            // GNU base-256: the high bit of the first byte is set.
            if (field.len > 0 and field[0] & 0x80 != 0) {
                var v: u64 = field[0] & 0x7f;
                for (field[1..]) |b| {
                    if (v > (std.math.maxInt(u64) >> 8)) return error.BadTarHeader;
                    v = (v << 8) | b;
                }
                return v;
            }
            var v: u64 = 0;
            var seen = false;
            for (field) |c| {
                if (c == 0 or c == ' ') {
                    if (seen) break;
                    continue;
                }
                if (c < '0' or c > '7') return error.BadTarHeader;
                if (v > (std.math.maxInt(u64) >> 3)) return error.BadTarHeader;
                v = (v << 3) | (c - '0');
                seen = true;
            }
            return v;
        }

        fn cstr(field: []const u8) []const u8 {
            return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
        }

        /// Reads `size` bytes of a name record into `buf`; the NUL, if any, is cut.
        fn readText(self: *Self, size: u64, buf: []u8) ![]const u8 {
            if (size > buf.len) return error.TarNameTooLong;
            const n: usize = @intCast(size);
            try self.reader.readNoEof(buf[0..n]);
            return cstr(buf[0..n]);
        }

        pub fn next(self: *Self) !?Entry {
            try self.skip(self.remaining + self.padding);
            self.remaining = 0;
            self.padding = 0;

            var name_override: ?[]const u8 = null;
            var link_override: ?[]const u8 = null;
            var size_override: ?u64 = null;
            while (true) {
                var h: [512]u8 = undefined;
                const got = try self.reader.readAll(&h);
                if (got == 0) return null;
                if (got < 512) return error.UnexpectedEndOfStream;
                if (std.mem.allEqual(u8, &h, 0)) return null;

                const stored = try parseOctal(h[148..156]);
                var sum: u64 = 0;
                for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
                if (sum != stored) return error.BadTarChecksum;

                const size = try parseOctal(h[124..136]);
                const padding = (512 - size % 512) % 512;
                const typeflag = h[156];
                switch (typeflag) {
                    'L' => {
                        name_override = try self.readText(size, &self.name_buf);
                        try self.skip(padding);
                    },
                    'K' => {
                        link_override = try self.readText(size, &self.link_buf);
                        try self.skip(padding);
                    },
                    'g' => try self.skip(size + padding),
                    'x' => {
                        if (size > pax_max) return error.TarNameTooLong;
                        const n: usize = @intCast(size);
                        try self.reader.readNoEof(self.pax_buf[0..n]);
                        try self.skip(padding);
                        var rest: []const u8 = self.pax_buf[0..n];
                        while (rest.len > 0) {
                            const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return error.BadPaxRecord;
                            const len = std.fmt.parseInt(usize, rest[0..sp], 10) catch return error.BadPaxRecord;
                            if (len <= sp + 1 or len > rest.len or rest[len - 1] != '\n') return error.BadPaxRecord;
                            const kv = rest[sp + 1 .. len - 1];
                            rest = rest[len..];
                            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.BadPaxRecord;
                            const key = kv[0..eq];
                            const val = kv[eq + 1 ..];
                            if (std.mem.eql(u8, key, "path")) {
                                if (val.len > self.name_buf.len) return error.TarNameTooLong;
                                @memcpy(self.name_buf[0..val.len], val);
                                name_override = self.name_buf[0..val.len];
                            } else if (std.mem.eql(u8, key, "linkpath")) {
                                if (val.len > self.link_buf.len) return error.TarNameTooLong;
                                @memcpy(self.link_buf[0..val.len], val);
                                link_override = self.link_buf[0..val.len];
                            } else if (std.mem.eql(u8, key, "size")) {
                                size_override = std.fmt.parseInt(u64, val, 10) catch return error.BadPaxRecord;
                            }
                        }
                    },
                    '0', 0, '7', '1', '2', '5' => {
                        const kind: Kind = switch (typeflag) {
                            '1' => .hardlink,
                            '2' => .symlink,
                            '5' => .dir,
                            else => .file,
                        };
                        const name: []const u8 = if (name_override) |n| n else blk: {
                            const base = cstr(h[0..100]);
                            const ustar = std.mem.eql(u8, h[257..262], "ustar");
                            const prefix = if (ustar) cstr(h[345..500]) else "";
                            if (prefix.len == 0) {
                                @memcpy(self.name_buf[0..base.len], base);
                                break :blk self.name_buf[0..base.len];
                            }
                            if (prefix.len + 1 + base.len > self.name_buf.len) return error.TarNameTooLong;
                            @memcpy(self.name_buf[0..prefix.len], prefix);
                            self.name_buf[prefix.len] = '/';
                            @memcpy(self.name_buf[prefix.len + 1 ..][0..base.len], base);
                            break :blk self.name_buf[0 .. prefix.len + 1 + base.len];
                        };
                        const link = link_override orelse blk: {
                            const l = cstr(h[157..257]);
                            @memcpy(self.link_buf[0..l.len], l);
                            break :blk self.link_buf[0..l.len];
                        };
                        const data: u64 = size_override orelse size;
                        self.remaining = data;
                        self.padding = (512 - data % 512) % 512;
                        const mode: u32 = @intCast((try parseOctal(h[100..108])) & 0o7777);
                        return .{ .name = name, .link = link, .size = data, .mode = mode, .kind = kind };
                    },
                    else => return error.UnsupportedTarEntry,
                }
            }
        }
    };
}

pub fn tarReader(reader: anytype) TarReader(@TypeOf(reader)) {
    return TarReader(@TypeOf(reader)).init(reader);
}

// ---------------------------------------------------------------- tests

/// A ustar header for the tests: `typeflag`, `name`, `size`, `link`.
fn header(typeflag: u8, name: []const u8, size: u64, link: []const u8, mode: u32) [512]u8 {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..name.len], name);
    _ = std.fmt.bufPrint(h[100..107], "{o:0>7}", .{mode}) catch unreachable;
    _ = std.fmt.bufPrint(h[124..135], "{o:0>11}", .{size}) catch unreachable;
    h[156] = typeflag;
    @memcpy(h[157..][0..link.len], link);
    @memcpy(h[257..262], "ustar");
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..154], "{o:0>6}", .{sum}) catch unreachable;
    h[154] = 0;
    h[155] = ' ';
    return h;
}

fn put(out: *std.ArrayList(u8), h: [512]u8, data: []const u8) !void {
    try out.appendSlice(&h);
    try out.appendSlice(data);
    try out.appendNTimes(0, (512 - data.len % 512) % 512);
}

test "files, directories and links; data, modes and padding" {
    const a = std.testing.allocator;
    var t = std.ArrayList(u8).init(a);
    defer t.deinit();
    try put(&t, header('5', "d/", 0, "", 0o755), "");
    try put(&t, header('0', "d/run", 5, "", 0o755), "hello");
    try put(&t, header('2', "d/ln", 0, "run", 0o777), "");
    try put(&t, header('1', "d/hard", 0, "d/run", 0o755), "");
    try put(&t, header('0', "big", 700, "", 0o644), "x" ** 700);
    try t.appendNTimes(0, 1024);

    var fbs = std.io.fixedBufferStream(t.items);
    var r = tarReader(fbs.reader());
    var e = (try r.next()).?;
    try std.testing.expectEqual(Kind.dir, e.kind);
    try std.testing.expectEqualStrings("d/", e.name);
    e = (try r.next()).?;
    try std.testing.expectEqualStrings("d/run", e.name);
    try std.testing.expectEqual(@as(u32, 0o755), e.mode);
    var buf: [16]u8 = undefined;
    // Read only part of the entry: next() must skip the rest and the padding.
    try std.testing.expectEqual(@as(usize, 3), try r.read(buf[0..3]));
    try std.testing.expectEqualStrings("hel", buf[0..3]);
    e = (try r.next()).?;
    try std.testing.expectEqual(Kind.symlink, e.kind);
    try std.testing.expectEqualStrings("run", e.link);
    e = (try r.next()).?;
    try std.testing.expectEqual(Kind.hardlink, e.kind);
    try std.testing.expectEqualStrings("d/run", e.link);
    e = (try r.next()).?;
    try std.testing.expectEqualStrings("big", e.name);
    var total: usize = 0;
    while (true) {
        const n = try r.read(&buf);
        if (n == 0) break;
        total += n;
    }
    try std.testing.expectEqual(@as(usize, 700), total);
    try std.testing.expect((try r.next()) == null);
}

test "a GNU long name and a pax path both replace the header's name" {
    const a = std.testing.allocator;
    var t = std.ArrayList(u8).init(a);
    defer t.deinit();
    const long = "lib/" ++ "d" ** 150 ++ "/file.txt";
    try put(&t, header('L', "././@LongLink", long.len + 1, "", 0), long ++ "\x00");
    try put(&t, header('0', "truncated", 2, "", 0o644), "ok");
    const rec = "31 path=pax/dir/name/of/a/file\n";
    try std.testing.expectEqual(@as(usize, 31), rec.len);
    try put(&t, header('x', "PaxHeader", rec.len, "", 0), rec);
    try put(&t, header('0', "ignored", 1, "", 0o600), "z");
    try t.appendNTimes(0, 1024);
    var fbs = std.io.fixedBufferStream(t.items);
    var r = tarReader(fbs.reader());
    var e = (try r.next()).?;
    try std.testing.expectEqualStrings(long, e.name);
    e = (try r.next()).?;
    try std.testing.expectEqualStrings("pax/dir/name/of/a/file", e.name);
    try std.testing.expectEqual(@as(u32, 0o600), e.mode);
}

test "a bad checksum, a device and a truncated archive are errors" {
    const a = std.testing.allocator;
    var t = std.ArrayList(u8).init(a);
    defer t.deinit();
    var h = header('0', "f", 1, "", 0o644);
    h[0] = 'g';
    try put(&t, h, "x");
    var fbs = std.io.fixedBufferStream(t.items);
    var r = tarReader(fbs.reader());
    try std.testing.expectError(error.BadTarChecksum, r.next());

    t.clearRetainingCapacity();
    try put(&t, header('3', "dev", 0, "", 0o644), "");
    var fbs2 = std.io.fixedBufferStream(t.items);
    var r2 = tarReader(fbs2.reader());
    try std.testing.expectError(error.UnsupportedTarEntry, r2.next());

    t.clearRetainingCapacity();
    try put(&t, header('0', "f", 600, "", 0o644), "y" ** 600);
    var fbs3 = std.io.fixedBufferStream(t.items[0..700]);
    var r3 = tarReader(fbs3.reader());
    _ = (try r3.next()).?;
    var buf: [1024]u8 = undefined;
    var failed: ?anyerror = null;
    while (true) {
        const n = r3.read(&buf) catch |e| {
            failed = e;
            break;
        };
        if (n == 0) break;
    }
    try std.testing.expect(failed != null and failed.? == error.UnexpectedEndOfStream);
}
