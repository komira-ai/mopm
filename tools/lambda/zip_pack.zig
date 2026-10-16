//! zip_pack: writes a deterministic .zip, the package format of an AWS Lambda function.
//!
//!   zip_pack <out.zip> [--sha256 <out.sha256>] <name>=<file>:<octal mode> ...
//!
//! Entries are stored (not compressed), in the order given, with a fixed
//! timestamp (1980-01-01) and Unix permission bits in the external attributes
//! (version made by: host Unix), so the same inputs give the same bytes. Lambda
//! unpacks stored entries. A name Lambda would not find (empty, absolute, `./x`,
//! `..` or `.` components, a trailing `/`, a backslash, a NUL) is refused, and so
//! is a name given twice.
//!
//! With --sha256 the tool also writes `<sha256 of the zip>  <zip file name>` and
//! `<sha256 of that entry>  <name>` for each entry, in `sha256sum` form, so a
//! deploy can compare what it uploads with what the build made.

const std = @import("std");

pub const Entry = struct { name: []const u8, data: []const u8, mode: u16 };

pub const NameError = error{BadEntryName};

/// A name is valid when it is a relative path of plain components.
pub fn checkName(name: []const u8) NameError!void {
    if (name.len == 0 or name.len > 0xffff) return error.BadEntryName;
    if (name[0] == '/' or name[name.len - 1] == '/') return error.BadEntryName;
    if (std.mem.indexOfScalar(u8, name, '\\') != null or std.mem.indexOfScalar(u8, name, 0) != null) return error.BadEntryName;
    var parts = std.mem.splitScalar(u8, name, '/');
    while (parts.next()) |p| {
        if (p.len == 0 or std.mem.eql(u8, p, ".") or std.mem.eql(u8, p, "..")) return error.BadEntryName;
    }
}

fn le16(w: anytype, v: u16) !void {
    try w.writeInt(u16, v, .little);
}
fn le32(w: anytype, v: u32) !void {
    try w.writeInt(u32, v, .little);
}

pub fn write(w: anytype, a: std.mem.Allocator, entries: []const Entry) !void {
    for (entries, 0..) |e, i| {
        try checkName(e.name);
        for (entries[0..i]) |before| if (std.mem.eql(u8, before.name, e.name)) return error.BadEntryName;
    }
    var offsets = try a.alloc(u32, entries.len);
    defer a.free(offsets);
    var pos: u32 = 0;
    // MS-DOS date 1980-01-01 is 0x0021, time 0.
    for (entries, 0..) |e, i| {
        offsets[i] = pos;
        const crc = std.hash.Crc32.hash(e.data);
        try le32(w, 0x04034b50);
        try le16(w, 20); // version needed
        try le16(w, 0); // flags
        try le16(w, 0); // stored
        try le16(w, 0);
        try le16(w, 0x0021);
        try le32(w, crc);
        try le32(w, @intCast(e.data.len));
        try le32(w, @intCast(e.data.len));
        try le16(w, @intCast(e.name.len));
        try le16(w, 0);
        try w.writeAll(e.name);
        try w.writeAll(e.data);
        pos += @intCast(30 + e.name.len + e.data.len);
    }
    const cd_start = pos;
    for (entries, 0..) |e, i| {
        const crc = std.hash.Crc32.hash(e.data);
        try le32(w, 0x02014b50);
        try le16(w, (3 << 8) | 20); // made by Unix
        try le16(w, 20);
        try le16(w, 0);
        try le16(w, 0);
        try le16(w, 0);
        try le16(w, 0x0021);
        try le32(w, crc);
        try le32(w, @intCast(e.data.len));
        try le32(w, @intCast(e.data.len));
        try le16(w, @intCast(e.name.len));
        try le16(w, 0); // extra
        try le16(w, 0); // comment
        try le16(w, 0); // disk
        try le16(w, 0); // internal attributes
        try le32(w, (@as(u32, 0o100000 | e.mode)) << 16);
        try le32(w, offsets[i]);
        try w.writeAll(e.name);
        pos += @intCast(46 + e.name.len);
    }
    try le32(w, 0x06054b50);
    try le16(w, 0);
    try le16(w, 0);
    try le16(w, @intCast(entries.len));
    try le16(w, @intCast(entries.len));
    try le32(w, pos - cd_start);
    try le32(w, cd_start);
    try le16(w, 0);
}

/// `sha256sum` lines for the zip and each entry.
pub fn sums(a: std.mem.Allocator, zip_name: []const u8, zip: []const u8, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    errdefer out.deinit();
    const w = out.writer();
    var h: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(zip, &h, .{});
    try w.print("{s}  {s}\n", .{ std.fmt.fmtSliceHexLower(&h), zip_name });
    for (entries) |e| {
        std.crypto.hash.sha2.Sha256.hash(e.data, &h, .{});
        try w.print("{s}  {s}\n", .{ std.fmt.fmtSliceHexLower(&h), e.name });
    }
    return out.toOwnedSlice();
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    var sums_out: ?[]const u8 = null;
    var rest = args[1..];
    // zip_pack <out.zip> [--sha256 <file>] <name>=<file>:<mode>...
    if (rest.len < 2) usage();
    const out_path = rest[0];
    rest = rest[1..];
    if (rest.len >= 2 and std.mem.eql(u8, rest[0], "--sha256")) {
        sums_out = rest[1];
        rest = rest[2..];
    }
    if (rest.len == 0) usage();
    var entries = std.ArrayList(Entry).init(a);
    for (rest) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse usage();
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse usage();
        if (colon < eq) usage();
        const data = try std.fs.cwd().readFileAlloc(a, spec[eq + 1 .. colon], 1 << 30);
        const mode = std.fmt.parseInt(u16, spec[colon + 1 ..], 8) catch usage();
        try entries.append(.{ .name = spec[0..eq], .data = data, .mode = mode });
    }
    var out = std.ArrayList(u8).init(a);
    write(out.writer(), a, entries.items) catch |err| switch (err) {
        error.BadEntryName => {
            std.debug.print("zip_pack: an entry name is not a plain relative path, or is given twice\n", .{});
            std.process.exit(2);
        },
        else => return err,
    };
    try std.fs.cwd().writeFile(out_path, out.items);
    if (sums_out) |p| try std.fs.cwd().writeFile(p, try sums(a, std.fs.path.basename(out_path), out.items, entries.items));
}

fn usage() noreturn {
    std.debug.print("usage: zip_pack <out.zip> [--sha256 <out.sha256>] <name>=<file>:<octal mode> ...\n", .{});
    std.process.exit(2);
}

test "a stored zip reads back: signatures, crc, mode, offsets" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    try write(out.writer(), a, &.{
        .{ .name = "bootstrap", .data = "hello", .mode = 0o755 },
        .{ .name = "x", .data = "", .mode = 0o644 },
    });
    const z = out.items;
    // End of central directory.
    const eocd = z.len - 22;
    try std.testing.expectEqual(@as(u32, 0x06054b50), std.mem.readInt(u32, z[eocd..][0..4], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, z[eocd + 10 ..][0..2], .little));
    const cd = std.mem.readInt(u32, z[eocd + 16 ..][0..4], .little);
    // First central entry: crc of "hello", mode 0755 regular file, local header at 0.
    try std.testing.expectEqual(@as(u32, 0x02014b50), std.mem.readInt(u32, z[cd..][0..4], .little));
    // Version made by: host 3 (Unix), version 2.0.
    try std.testing.expectEqual(@as(u16, (3 << 8) | 20), std.mem.readInt(u16, z[cd + 4 ..][0..2], .little));
    // Stored, with the fixed DOS time and date.
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, z[cd + 10 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, z[cd + 12 ..][0..2], .little));
    try std.testing.expectEqual(@as(u16, 0x0021), std.mem.readInt(u16, z[cd + 14 ..][0..2], .little));
    try std.testing.expectEqual(std.hash.Crc32.hash("hello"), std.mem.readInt(u32, z[cd + 16 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0o100755 << 16), std.mem.readInt(u32, z[cd + 38 ..][0..4], .little));
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, z[cd + 42 ..][0..4], .little));
    // The local header: name, then the data.
    try std.testing.expectEqualStrings("bootstrap", z[30..39]);
    try std.testing.expectEqualStrings("hello", z[39..44]);
    // Second entry starts right after the first local entry.
    const cd2 = cd + 46 + "bootstrap".len;
    try std.testing.expectEqual(@as(u32, 44), std.mem.readInt(u32, z[cd2 + 42 ..][0..4], .little));
}

test "the same entries give the same bytes" {
    const a = std.testing.allocator;
    var one = std.ArrayList(u8).init(a);
    defer one.deinit();
    var two = std.ArrayList(u8).init(a);
    defer two.deinit();
    const entries = [_]Entry{.{ .name = "bootstrap", .data = "\x7fELF....", .mode = 0o755 }};
    try write(one.writer(), a, &entries);
    try write(two.writer(), a, &entries);
    try std.testing.expectEqualSlices(u8, one.items, two.items);
}

test "names Lambda would not find are refused" {
    const a = std.testing.allocator;
    const bad = [_][]const u8{ "", "./bootstrap", "/bootstrap", "bootstrap/", "a//b", "a/./b", "../bootstrap", "a/..", "a\\b", "boot\x00strap", "." };
    for (bad) |name| {
        var out = std.ArrayList(u8).init(a);
        defer out.deinit();
        try std.testing.expectError(error.BadEntryName, write(out.writer(), a, &.{.{ .name = name, .data = "x", .mode = 0o755 }}));
    }
    for ([_][]const u8{ "bootstrap", "lib/libfoo.so", "a.b/c-d" }) |name| {
        var out = std.ArrayList(u8).init(a);
        defer out.deinit();
        try write(out.writer(), a, &.{.{ .name = name, .data = "x", .mode = 0o755 }});
    }
}

test "a name given twice is refused" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).init(a);
    defer out.deinit();
    try std.testing.expectError(error.BadEntryName, write(out.writer(), a, &.{
        .{ .name = "bootstrap", .data = "a", .mode = 0o755 },
        .{ .name = "bootstrap", .data = "b", .mode = 0o755 },
    }));
}

test "sums are sha256sum lines of the zip and of each entry" {
    const a = std.testing.allocator;
    const got = try sums(a, "f.zip", "abc", &.{.{ .name = "bootstrap", .data = "abc", .mode = 0o755 }});
    defer a.free(got);
    // sha256("abc")
    const h = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    try std.testing.expectEqualStrings(h ++ "  f.zip\n" ++ h ++ "  bootstrap\n", got);
}
