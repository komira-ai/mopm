//! Test support: build a `.conda` package in memory (zip of stored entries,
//! zstd frames of raw blocks, ustar tars with modes, symbolic links and hard
//! links, which `mopm pack`'s writer in conda.zig does not need to make).
//! Only tests import this file.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");

pub const Kind = enum { file, dir, symlink, hardlink };

pub const Item = struct {
    name: []const u8,
    kind: Kind = .file,
    data: []const u8 = "",
    /// The target of a symbolic or hard link.
    link: []const u8 = "",
    mode: u32 = 0o644,
};

/// A prefix placeholder as long as conda-build's (255 bytes).
pub const placeholder = "/" ++ "p" ** 254;

fn header(item: Item) [512]u8 {
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..item.name.len], item.name);
    _ = std.fmt.bufPrint(h[100..107], "{o:0>7}", .{item.mode}) catch unreachable;
    const size: u64 = if (item.kind == .file) item.data.len else 0;
    _ = std.fmt.bufPrint(h[124..135], "{o:0>11}", .{size}) catch unreachable;
    h[156] = switch (item.kind) {
        .file => '0',
        .dir => '5',
        .symlink => '2',
        .hardlink => '1',
    };
    @memcpy(h[157..][0..item.link.len], item.link);
    @memcpy(h[257..262], "ustar");
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    _ = std.fmt.bufPrint(h[148..154], "{o:0>6}", .{sum}) catch unreachable;
    h[154] = 0;
    h[155] = ' ';
    return h;
}

/// An uncompressed tar of `items`, in the order given.
pub fn tar(a: Allocator, items: []const Item) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (items) |item| {
        try out.appendSlice(&header(item));
        if (item.kind == .file) {
            try out.appendSlice(item.data);
            try out.appendNTimes(0, (512 - item.data.len % 512) % 512);
        }
    }
    try out.appendNTimes(0, 1024);
    return out.items;
}

/// A `.conda` whose `info/` holds `info` and whose files are `files`.
pub fn conda2(a: Allocator, stem: []const u8, info: []const Item, files: []const Item) ![]u8 {
    return conda2With(a, stem, info, files, null);
}

/// As `conda2`, but `zip_method` (when not null) is patched into the
/// central directory, to make a zip whose entries claim to be compressed.
pub fn conda2With(a: Allocator, stem: []const u8, info: []const Item, files: []const Item, zip_method: ?u16) ![]u8 {
    const info_tar = try tar(a, info);
    const pkg_tar = try tar(a, files);
    const entries = [_]conda.File{
        .{ .path = "metadata.json", .data = "{\"conda_pkg_format_version\": 2}" },
        .{ .path = try std.fmt.allocPrint(a, "info-{s}.tar.zst", .{stem}), .data = try conda.zstdStore(a, info_tar) },
        .{ .path = try std.fmt.allocPrint(a, "pkg-{s}.tar.zst", .{stem}), .data = try conda.zstdStore(a, pkg_tar) },
    };
    const z = try conda.zip(a, &entries);
    if (zip_method) |m| {
        // Patch the method of the first central directory record.
        const cd = std.mem.readInt(u32, z[z.len - 6 ..][0..4], .little);
        std.mem.writeInt(u16, z[cd + 10 ..][0..2], m, .little);
    }
    return z;
}

fn put(out: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(&b);
}

/// As `conda2`, but every zip entry carries a zip64 extra field, as the
/// `.conda` files of large packages do: 0xFFFFFFFF in the size fields and the
/// real sizes in the extra field.
pub fn conda2Zip64(a: Allocator, stem: []const u8, info: []const Item, files: []const Item) ![]u8 {
    const entries = [_]conda.File{
        .{ .path = "metadata.json", .data = "{\"conda_pkg_format_version\": 2}" },
        .{ .path = try std.fmt.allocPrint(a, "pkg-{s}.tar.zst", .{stem}), .data = try conda.zstdStore(a, try tar(a, files)) },
        .{ .path = try std.fmt.allocPrint(a, "info-{s}.tar.zst", .{stem}), .data = try conda.zstdStore(a, try tar(a, info)) },
    };
    var out = std.ArrayList(u8).init(a);
    const offsets = try a.alloc(u32, entries.len);
    for (entries, 0..) |f, i| {
        offsets[i] = @intCast(out.items.len);
        try put(&out, u32, 0x04034b50);
        try put(&out, u16, 45);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0x0021);
        try put(&out, u32, std.hash.Crc32.hash(f.data));
        try put(&out, u32, 0xFFFFFFFF);
        try put(&out, u32, 0xFFFFFFFF);
        try put(&out, u16, @intCast(f.path.len));
        try put(&out, u16, 20);
        try out.appendSlice(f.path);
        try put(&out, u16, 1);
        try put(&out, u16, 16);
        try put(&out, u64, f.data.len);
        try put(&out, u64, f.data.len);
        try out.appendSlice(f.data);
    }
    const cd_start = out.items.len;
    for (entries, 0..) |f, i| {
        try put(&out, u32, 0x02014b50);
        try put(&out, u16, 45);
        try put(&out, u16, 45);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0x0021);
        try put(&out, u32, std.hash.Crc32.hash(f.data));
        try put(&out, u32, 0xFFFFFFFF);
        try put(&out, u32, 0xFFFFFFFF);
        try put(&out, u16, @intCast(f.path.len));
        try put(&out, u16, 20);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u32, 0);
        try put(&out, u32, offsets[i]);
        try out.appendSlice(f.path);
        try put(&out, u16, 1);
        try put(&out, u16, 16);
        try put(&out, u64, f.data.len);
        try put(&out, u64, f.data.len);
    }
    const cd_size = out.items.len - cd_start;
    try put(&out, u32, 0x06054b50);
    try put(&out, u16, 0);
    try put(&out, u16, 0);
    try put(&out, u16, entries.len);
    try put(&out, u16, entries.len);
    try put(&out, u32, @intCast(cd_size));
    try put(&out, u32, @intCast(cd_start));
    try put(&out, u16, 0);
    return out.items;
}

/// `info/index.json` text.
pub fn indexJson(a: Allocator, name: []const u8, version: []const u8, build: []const u8, depends: []const u8, extra: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"{s}\",\"build\":\"{s}\",\"build_number\":3,\"depends\":[{s}],\"subdir\":\"linux-64\",\"license\":\"MIT\"{s}}}", .{ name, version, build, depends, extra });
}

/// A package with `info/index.json` only (no paths.json), as `mopm pack` makes.
pub fn simple(a: Allocator, name: []const u8, version: []const u8, files: []const Item) ![]u8 {
    const stem = try std.fmt.allocPrint(a, "{s}-{s}-h0_0", .{ name, version });
    const idx = try indexJson(a, name, version, "h0_0", "", "");
    return conda2(a, stem, &.{.{ .name = "info/index.json", .data = idx }}, files);
}

pub fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return a.dupe(u8, &std.fmt.bytesToHex(d, .lower));
}
