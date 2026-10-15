//! zip_check: reads a Lambda deployment package back and fails unless it is what
//! the provided runtimes need, byte for byte as zip_pack promises:
//!
//!   zip_check <package.zip> <bootstrap file> <stamp>
//!
//! exactly one entry; its name exactly `bootstrap` (not `./bootstrap`, not
//! `bootstrap/`, not another case); stored, the fixed DOS time and date; the
//! central directory's version-made-by host byte Unix and the external attributes
//! a regular file with mode 0755 (a FAT host or 0644 and Lambda cannot run it);
//! no extra field, no comment, no bytes outside the entry and the directory; and the
//! data is the file given, with its CRC-32. It shares no code with the writer:
//! the fields are read at their offsets from the format's definition (APPNOTE 4.3).
//!
//! The stamp, a passing Buck2 validation result, is written only when everything held. Zig's std.zip arrived after the
//! pinned compiler (0.12), and its entries do not carry the host byte or the
//! attributes this checks, so the reader is here.

const std = @import("std");

pub const Error = error{
    TooShort,
    EndRecord,
    EntryCount,
    DirectoryBounds,
    CentralHeader,
    Host,
    Mode,
    Name,
    Method,
    Flags,
    Time,
    Extra,
    LocalHeader,
    Data,
    Crc,
    Trailing,
};

fn r16(z: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, z[at..][0..2], .little);
}
fn r32(z: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, z[at..][0..4], .little);
}

/// `zip` is a package whose only entry must be `name` holding `data`, mode 0755.
pub fn verify(zip: []const u8, name: []const u8, data: []const u8) Error!void {
    if (zip.len < 22) return error.TooShort;
    const e = zip.len - 22; // no archive comment is allowed, so the end record is the last 22 bytes
    if (r32(zip, e) != 0x06054b50) return error.EndRecord;
    if (r16(zip, e + 4) != 0 or r16(zip, e + 6) != 0 or r16(zip, e + 20) != 0) return error.EndRecord;
    if (r16(zip, e + 8) != 1 or r16(zip, e + 10) != 1) return error.EntryCount;
    const cd_size = r32(zip, e + 12);
    const cd = r32(zip, e + 16);
    if (@as(u64, cd) + cd_size != e) return error.DirectoryBounds;
    if (cd_size < 46 + name.len) return error.DirectoryBounds;

    // Central directory header.
    if (r32(zip, cd) != 0x02014b50) return error.CentralHeader;
    if (zip[cd + 5] != 3) return error.Host; // high byte of version made by: 3 = Unix
    if (r16(zip, cd + 8) != 0) return error.Flags;
    if (r16(zip, cd + 10) != 0) return error.Method; // stored
    if (r16(zip, cd + 12) != 0 or r16(zip, cd + 14) != 0x0021) return error.Time; // 1980-01-01 00:00:00
    const crc = std.hash.Crc32.hash(data);
    if (r32(zip, cd + 16) != crc) return error.Crc;
    if (r32(zip, cd + 20) != data.len or r32(zip, cd + 24) != data.len) return error.Data;
    if (r16(zip, cd + 28) != name.len) return error.Name;
    if (r16(zip, cd + 30) != 0 or r16(zip, cd + 32) != 0) return error.Extra; // extra field, comment
    if (r16(zip, cd + 34) != 0 or r16(zip, cd + 36) != 0) return error.CentralHeader; // disk, internal attributes
    if (r32(zip, cd + 38) != (@as(u32, 0o100755) << 16)) return error.Mode;
    if (r32(zip, cd + 42) != 0) return error.LocalHeader; // the local header is first
    if (!std.mem.eql(u8, zip[cd + 46 ..][0..name.len], name)) return error.Name;
    if (cd_size != 46 + name.len) return error.DirectoryBounds; // nothing else in the directory

    // Local header, then the data, then straight into the directory.
    if (zip.len < 30 + name.len + data.len) return error.LocalHeader;
    if (r32(zip, 0) != 0x04034b50) return error.LocalHeader;
    if (r16(zip, 6) != 0) return error.Flags;
    if (r16(zip, 8) != 0) return error.Method;
    if (r16(zip, 10) != 0 or r16(zip, 12) != 0x0021) return error.Time;
    if (r32(zip, 14) != crc) return error.Crc;
    if (r32(zip, 18) != data.len or r32(zip, 22) != data.len) return error.Data;
    if (r16(zip, 26) != name.len) return error.Name;
    if (r16(zip, 28) != 0) return error.Extra;
    if (!std.mem.eql(u8, zip[30..][0..name.len], name)) return error.Name;
    const body = 30 + name.len;
    if (body + data.len != cd) return error.Trailing;
    if (!std.mem.eql(u8, zip[body..][0..data.len], data)) return error.Data;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4) {
        std.debug.print("usage: zip_check <package.zip> <bootstrap file> <stamp>\n", .{});
        std.process.exit(2);
    }
    const zip = try std.fs.cwd().readFileAlloc(a, args[1], 1 << 30);
    const data = try std.fs.cwd().readFileAlloc(a, args[2], 1 << 30);
    verify(zip, "bootstrap", data) catch |err| {
        std.debug.print("zip_check: {s} is not a Lambda package for a `bootstrap` of mode 0755: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    // A passing Buck2 validation result (lambda.bzl attaches it to the package).
    try std.fs.cwd().writeFile(args[3], "{\"version\": 1, \"data\": {\"status\": \"success\", \"message\": \"zip_check: one stored entry named bootstrap, mode 0755, host Unix\"}}\n");
}

// ---- Tests: a zip built here, not by zip_pack, with one field wrong at a time ----

const Opts = struct {
    name: []const u8 = "bootstrap",
    data: []const u8 = "\x7fELF-bootstrap",
    host: u8 = 3,
    mode: u32 = 0o100755,
    method: u16 = 0,
    flags: u16 = 0,
    time: u16 = 0,
    date: u16 = 0x0021,
    crc_delta: u32 = 0,
    extra_len: u16 = 0,
    comment_len: u16 = 0,
    local_name: ?[]const u8 = null,
    trailing: usize = 0,
    second_entry: bool = false,
};

fn put16(l: *std.ArrayList(u8), v: u16) !void {
    try l.writer().writeInt(u16, v, .little);
}
fn put32(l: *std.ArrayList(u8), v: u32) !void {
    try l.writer().writeInt(u32, v, .little);
}

fn build(a: std.mem.Allocator, o: Opts) ![]u8 {
    var l = std.ArrayList(u8).init(a);
    const crc = std.hash.Crc32.hash(o.data) +% o.crc_delta;
    const lname = o.local_name orelse o.name;
    try put32(&l, 0x04034b50);
    try put16(&l, 20);
    try put16(&l, o.flags);
    try put16(&l, o.method);
    try put16(&l, o.time);
    try put16(&l, o.date);
    try put32(&l, crc);
    try put32(&l, @intCast(o.data.len));
    try put32(&l, @intCast(o.data.len));
    try put16(&l, @intCast(lname.len));
    try put16(&l, 0);
    try l.appendSlice(lname);
    try l.appendSlice(o.data);
    const cd = l.items.len;
    const n: u16 = if (o.second_entry) 2 else 1;
    var i: u16 = 0;
    while (i < n) : (i += 1) {
        try put32(&l, 0x02014b50);
        try put16(&l, (@as(u16, o.host) << 8) | 20);
        try put16(&l, 20);
        try put16(&l, o.flags);
        try put16(&l, o.method);
        try put16(&l, o.time);
        try put16(&l, o.date);
        try put32(&l, crc);
        try put32(&l, @intCast(o.data.len));
        try put32(&l, @intCast(o.data.len));
        try put16(&l, @intCast(o.name.len));
        try put16(&l, o.extra_len);
        try put16(&l, o.comment_len);
        try put16(&l, 0);
        try put16(&l, 0);
        try put32(&l, o.mode << 16);
        try put32(&l, 0);
        try l.appendSlice(o.name);
        try l.appendNTimes('x', o.extra_len + o.comment_len);
    }
    const cd_size = l.items.len - cd;
    try put32(&l, 0x06054b50);
    try put16(&l, 0);
    try put16(&l, 0);
    try put16(&l, n);
    try put16(&l, n);
    try put32(&l, @intCast(cd_size));
    try put32(&l, @intCast(cd));
    try put16(&l, 0);
    try l.appendNTimes(0, o.trailing);
    return l.toOwnedSlice();
}

fn expectVerdict(want: ?Error, o: Opts) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const z = try build(arena.allocator(), o);
    const got = verify(z, "bootstrap", "\x7fELF-bootstrap");
    if (want) |w| {
        try std.testing.expectError(w, got);
    } else {
        try got;
    }
}

test "a package as zip_pack promises is accepted" {
    try expectVerdict(null, .{});
}

test "mode 0644 is refused" {
    try expectVerdict(error.Mode, .{ .mode = 0o100644 });
}

test "a mode without the regular-file type bits is refused" {
    try expectVerdict(error.Mode, .{ .mode = 0o755 });
}

test "a FAT host byte is refused" {
    try expectVerdict(error.Host, .{ .host = 0 });
}

test "an NTFS or macOS host byte is refused" {
    try expectVerdict(error.Host, .{ .host = 10 });
    try expectVerdict(error.Host, .{ .host = 19 });
}

test "./bootstrap is refused" {
    try expectVerdict(error.Name, .{ .name = "./bootstrap" });
}

test "bootstrap/ (a directory entry) is refused" {
    try expectVerdict(error.Name, .{ .name = "bootstrap/" });
}

test "another name or case is refused" {
    try expectVerdict(error.Name, .{ .name = "Bootstrap" });
    try expectVerdict(error.Name, .{ .name = "bin/bootstrap" });
}

test "a name that differs only in the local header is refused" {
    try expectVerdict(error.Name, .{ .local_name = "Bootstrap" });
}

test "a timestamp that is not the fixed one is refused" {
    try expectVerdict(error.Time, .{ .time = 0x6000 });
    try expectVerdict(error.Time, .{ .date = 0x5a21 });
}

test "a compressed entry is refused" {
    try expectVerdict(error.Method, .{ .method = 8 });
}

test "general purpose flags are refused" {
    try expectVerdict(error.Flags, .{ .flags = 0x0008 });
}

test "a wrong CRC is refused" {
    try expectVerdict(error.Crc, .{ .crc_delta = 1 });
}

test "data that is not the file given is refused" {
    try expectVerdict(error.Crc, .{ .data = "\x7fELF-bootstrap2" });
}

test "a second entry is refused" {
    try expectVerdict(error.EntryCount, .{ .second_entry = true });
}

test "an extra field or a comment is refused" {
    try expectVerdict(error.Extra, .{ .extra_len = 4 });
    try expectVerdict(error.Extra, .{ .comment_len = 4 });
}

test "bytes after the end record are refused" {
    try expectVerdict(error.EndRecord, .{ .trailing = 3 });
}

test "a truncated package is refused" {
    try std.testing.expectError(error.TooShort, verify("PK", "bootstrap", ""));
}
