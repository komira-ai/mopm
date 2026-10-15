//! zip_pack: writes a deterministic .zip, the package format of an AWS Lambda function.
//!
//!   zip_pack <out.zip> <name>=<file>:<octal mode> ...
//!
//! Entries are stored (not compressed), in the order given, with a fixed
//! timestamp (1980-01-01) and Unix permission bits in the external attributes,
//! so the same inputs give the same bytes. Lambda unpacks stored entries.

const std = @import("std");

pub const Entry = struct { name: []const u8, data: []const u8, mode: u16 };

fn le16(w: anytype, v: u16) !void {
    try w.writeInt(u16, v, .little);
}
fn le32(w: anytype, v: u32) !void {
    try w.writeInt(u32, v, .little);
}

pub fn write(w: anytype, a: std.mem.Allocator, entries: []const Entry) !void {
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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 3) {
        std.debug.print("usage: zip_pack <out.zip> <name>=<file>:<octal mode> ...\n", .{});
        std.process.exit(2);
    }
    var entries = std.ArrayList(Entry).init(a);
    for (args[2..]) |spec| {
        const eq = std.mem.indexOfScalar(u8, spec, '=') orelse std.process.exit(2);
        const colon = std.mem.lastIndexOfScalar(u8, spec, ':') orelse std.process.exit(2);
        const data = try std.fs.cwd().readFileAlloc(a, spec[eq + 1 .. colon], 1 << 30);
        try entries.append(.{ .name = spec[0..eq], .data = data, .mode = try std.fmt.parseInt(u16, spec[colon + 1 ..], 8) });
    }
    var out = std.ArrayList(u8).init(a);
    try write(out.writer(), a, entries.items);
    try std.fs.cwd().writeFile(args[1], out.items);
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
