//! A deterministic `.conda` writer (`mopm pack`), with no dependencies
//! beyond the standard library. The same inputs always give the same bytes.
//!
//! A `.conda` is a zip of exactly three stored (method 0) entries, in this
//! order: `metadata.json`, `info-<stem>.tar.zst` and `pkg-<stem>.tar.zst`,
//! where `<stem>` is `mojo-<name>-<version>-<build>` (spec/channel.md). The
//! zip has a fixed DOS timestamp (the DOS epoch, January 1st of year 1980, at 00:00), no zip64 and no data
//! descriptors. Each tar is ustar: regular files only, mode 0644, uid and gid
//! 0, mtime 0, no user or group names, paths sorted, two zero blocks at the
//! end.
//!
//! The zstd streams are stored: one frame of raw blocks (RFC 8878, block type
//! 0) with the content size in the frame header and no checksum. Zig 0.12's
//! standard library has no zstd compressor, so nothing is compressed; every
//! zstd reader accepts the frame all the same.

const std = @import("std");
const Allocator = std.mem.Allocator;
const manifest = @import("manifest.zig");
const semver = @import("semver.zig");

/// The conda subdirs the registry serves (spec/channel.md).
pub const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };

pub fn isSubdir(s: []const u8) bool {
    for (subdirs) |d| {
        if (std.mem.eql(u8, d, s)) return true;
    }
    return false;
}

/// A Mojo dependency as written to the package: `range` is a conda
/// constraint such as `>=1.2,<2`, or "" for any version.
pub const Dep = struct { name: []const u8, range: []const u8 };

pub const Input = struct {
    name: []const u8,
    /// Exactly MAJOR.MINOR.PATCH (`exactVersion`).
    version: []const u8,
    /// The exact Mojo version the `.mojoc` was built with, such as `1.0.0`.
    compiler: []const u8,
    subdir: []const u8,
    deps: []const Dep = &.{},
    /// The bytes of the `.mojoc`.
    mojoc: []const u8,
};

pub const Packed = struct {
    subdir: []const u8,
    /// `mojo-<name>-<version>-mojo<compiler>_0.conda`
    file_name: []const u8,
    bytes: []const u8,
    /// Lowercase hex sha256 of `bytes`.
    sha256: [64]u8,
    /// Lowercase hex sha256 of `lib/mojo/<name>.mopm.json` as packed: what
    /// the commit step declares as `manifest_sha256`.
    manifest_sha256: [64]u8,
};

pub const PackError = error{ BadCompiler, BadSubdir, BadVersion, PathTooLong, TooLarge, OutOfMemory };

/// MAJOR.MINOR.PATCH: three numbers of digits, no leading zero except "0",
/// and nothing else (no pre-release, no build metadata, no missing part).
pub fn exactVersion(v: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| : (parts += 1) {
        if (p.len == 0 or p.len > 18) return false;
        if (p.len > 1 and p[0] == '0') return false;
        for (p) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
    }
    return parts == 3;
}

/// A compiler version as the build string spells it: digits in dot-separated
/// groups (`mojo<compiler>_0` must match `^mojo(\d+(\.\d+)*)_0$`).
pub fn validCompiler(v: []const u8) bool {
    if (v.len == 0) return false;
    var it = std.mem.splitScalar(u8, v, '.');
    while (it.next()) |p| {
        if (p.len == 0) return false;
        for (p) |c| {
            if (!std.ascii.isDigit(c)) return false;
        }
    }
    return true;
}

fn put(out: *std.ArrayList(u8), comptime T: type, v: T) Allocator.Error!void {
    var b: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &b, v, .little);
    try out.appendSlice(&b);
}

// ---------------------------------------------------------------------------
// zstd
// ---------------------------------------------------------------------------

/// The largest raw block (RFC 8878, Block_Maximum_Size).
pub const zstd_block_max: usize = 128 * 1024;

/// One zstd frame holding `content` in raw blocks. Frame header descriptor
/// 0xE0: 8-byte content size, single segment, no checksum, no dictionary.
pub fn zstdStore(arena: Allocator, content: []const u8) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    try out.appendSlice(&.{ 0x28, 0xB5, 0x2F, 0xFD, 0xE0 });
    try put(&out, u64, content.len);
    var rest = content;
    while (true) {
        const n = @min(rest.len, zstd_block_max);
        const last = n == rest.len;
        // Block header: bit 0 last block, bits 1-2 type (0 = raw), bits 3-23 size.
        const header: u32 = (@as(u32, @intCast(n)) << 3) | @as(u32, @intFromBool(last));
        var h: [4]u8 = undefined;
        std.mem.writeInt(u32, &h, header, .little);
        try out.appendSlice(h[0..3]);
        try out.appendSlice(rest[0..n]);
        rest = rest[n..];
        if (last) break;
    }
    return out.items;
}

// ---------------------------------------------------------------------------
// tar
// ---------------------------------------------------------------------------

pub const File = struct { path: []const u8, data: []const u8 };

fn lessFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Writes `value` as zero-padded octal in all of `dst` but the last byte,
/// which is NUL.
fn octal(dst: []u8, value: u64) void {
    var v = value;
    var i = dst.len - 1;
    dst[i] = 0;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
}

/// The 512-byte ustar header of a regular file.
pub fn tarHeader(path: []const u8, size: u64) error{PathTooLong}![512]u8 {
    if (path.len == 0 or path.len > 100) return error.PathTooLong;
    var h = [_]u8{0} ** 512;
    @memcpy(h[0..path.len], path);
    octal(h[100..108], 0o644); // mode
    octal(h[108..116], 0); // uid
    octal(h[116..124], 0); // gid
    octal(h[124..136], size);
    octal(h[136..148], 0); // mtime
    h[156] = '0'; // a regular file
    @memcpy(h[257..263], "ustar\x00");
    @memcpy(h[263..265], "00");
    octal(h[329..337], 0); // devmajor
    octal(h[337..345], 0); // devminor
    // The checksum is the sum of every byte with the checksum field itself
    // taken as eight spaces; it is written as six octal digits, NUL, space.
    @memset(h[148..156], ' ');
    var sum: u64 = 0;
    for (h) |b| sum += b;
    octal(h[148..155], sum);
    h[155] = ' ';
    return h;
}

/// An uncompressed tar of `files`, sorted by path.
pub fn tar(arena: Allocator, files: []const File) PackError![]u8 {
    const sorted = try arena.dupe(File, files);
    std.mem.sort(File, sorted, {}, lessFile);
    var out = std.ArrayList(u8).init(arena);
    for (sorted) |f| {
        const h = try tarHeader(f.path, f.data.len);
        try out.appendSlice(&h);
        try out.appendSlice(f.data);
        const pad = (512 - f.data.len % 512) % 512;
        try out.appendNTimes(0, pad);
    }
    try out.appendNTimes(0, 1024);
    return out.items;
}

// ---------------------------------------------------------------------------
// zip
// ---------------------------------------------------------------------------

/// The DOS epoch (January 1st of year 1980) as a DOS date; the DOS time is 00:00:00, which is 0.
const dos_date: u16 = (0 << 9) | (1 << 5) | 1;

/// A zip of `files` in the given order, every entry stored.
pub fn zip(arena: Allocator, files: []const File) PackError![]u8 {
    var out = std.ArrayList(u8).init(arena);
    const offsets = try arena.alloc(u32, files.len);
    for (files, 0..) |f, i| {
        if (f.data.len >= 0xFFFFFFFF or out.items.len >= 0xFFFFFFFF) return error.TooLarge;
        offsets[i] = @intCast(out.items.len);
        try put(&out, u32, 0x04034b50);
        try put(&out, u16, 20); // version needed
        try put(&out, u16, 0); // flags
        try put(&out, u16, 0); // method: stored
        try put(&out, u16, 0); // time
        try put(&out, u16, dos_date);
        try put(&out, u32, std.hash.Crc32.hash(f.data));
        try put(&out, u32, @intCast(f.data.len));
        try put(&out, u32, @intCast(f.data.len));
        try put(&out, u16, @intCast(f.path.len));
        try put(&out, u16, 0); // extra length
        try out.appendSlice(f.path);
        try out.appendSlice(f.data);
    }
    const cd_start = out.items.len;
    for (files, 0..) |f, i| {
        try put(&out, u32, 0x02014b50);
        try put(&out, u16, 20); // version made by
        try put(&out, u16, 20); // version needed
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, 0);
        try put(&out, u16, dos_date);
        try put(&out, u32, std.hash.Crc32.hash(f.data));
        try put(&out, u32, @intCast(f.data.len));
        try put(&out, u32, @intCast(f.data.len));
        try put(&out, u16, @intCast(f.path.len));
        try put(&out, u16, 0); // extra length
        try put(&out, u16, 0); // comment length
        try put(&out, u16, 0); // disk number
        try put(&out, u16, 0); // internal attributes
        try put(&out, u32, 0); // external attributes
        try put(&out, u32, offsets[i]);
        try out.appendSlice(f.path);
    }
    const cd_size = out.items.len - cd_start;
    try put(&out, u32, 0x06054b50);
    try put(&out, u16, 0);
    try put(&out, u16, 0);
    try put(&out, u16, @intCast(files.len));
    try put(&out, u16, @intCast(files.len));
    try put(&out, u32, @intCast(cd_size));
    try put(&out, u32, @intCast(cd_start));
    try put(&out, u16, 0);
    return out.items;
}

// ---------------------------------------------------------------------------
// The package
// ---------------------------------------------------------------------------

fn jsonStr(w: anytype, s: []const u8) !void {
    try std.json.encodeJsonString(s, .{}, w);
}

/// `info/index.json`: keys sorted, `depends` the compiler first and then the
/// Mojo dependencies by name.
pub fn indexJson(arena: Allocator, in: Input) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.print("{{\"build\":\"mojo{s}_0\",\"build_number\":0,\"depends\":[", .{in.compiler});
    const compiler_dep = try std.fmt.allocPrint(arena, "mojo-compiler =={s}", .{in.compiler});
    try jsonStr(w, compiler_dep);
    for (in.deps) |d| {
        try w.writeByte(',');
        const dep = if (d.range.len == 0)
            try std.fmt.allocPrint(arena, "mojo-{s}", .{d.name})
        else
            try std.fmt.allocPrint(arena, "mojo-{s} {s}", .{ d.name, d.range });
        try jsonStr(w, dep);
    }
    try w.writeAll("],\"name\":");
    try jsonStr(w, try std.fmt.allocPrint(arena, "mojo-{s}", .{in.name}));
    try w.writeAll(",\"subdir\":");
    try jsonStr(w, in.subdir);
    try w.writeAll(",\"version\":");
    try jsonStr(w, in.version);
    try w.writeByte('}');
    return out.items;
}

/// `lib/mojo/<name>.mopm.json` (spec/package-metadata.schema.json): keys sorted.
pub fn mopmJson(arena: Allocator, in: Input) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.writeAll("{\"deps\":[");
    for (in.deps, 0..) |d, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try jsonStr(w, d.name);
        if (d.range.len > 0) {
            try w.writeAll(",\"range\":");
            try jsonStr(w, d.range);
        }
        try w.writeByte('}');
    }
    try w.writeAll("],\"name\":");
    try jsonStr(w, in.name);
    try w.writeAll(",\"schema\":1,\"version\":");
    try jsonStr(w, in.version);
    try w.writeByte('}');
    return out.items;
}

fn hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// `info/paths.json`: the files of the package with their sha256 and size. Without it (or the older
/// `info/files`) pixi's installer cannot link the package ("failed to read 'paths.json'"), so a package
/// `mopm pack` wrote would publish but never install. Keys sorted.
pub fn pathsJson(arena: Allocator, files: []const File) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    try w.writeAll("{\"paths\":[");
    for (files, 0..) |f, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"_path\":");
        try jsonStr(w, f.path);
        try w.print(",\"path_type\":\"hardlink\",\"sha256\":\"{s}\",\"size_in_bytes\":{d}}}", .{ hex(f.data), f.data.len });
    }
    try w.writeAll("],\"paths_version\":1}");
    return out.items;
}

/// Builds the `.conda` for `in`.
pub fn pack(arena: Allocator, in: Input) PackError!Packed {
    if (!exactVersion(in.version)) return error.BadVersion;
    if (!validCompiler(in.compiler)) return error.BadCompiler;
    if (!isSubdir(in.subdir)) return error.BadSubdir;

    const stem = try std.fmt.allocPrint(arena, "mojo-{s}-{s}-mojo{s}_0", .{ in.name, in.version, in.compiler });
    const mopm = try mopmJson(arena, in);
    const index = try indexJson(arena, in);

    const pkg_files = [_]File{
        .{ .path = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mojoc", .{in.name}), .data = in.mojoc },
        .{ .path = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mopm.json", .{in.name}), .data = mopm },
    };
    const info_tar = try tar(arena, &.{
        .{ .path = "info/index.json", .data = index },
        .{ .path = "info/paths.json", .data = try pathsJson(arena, &pkg_files) },
    });
    const pkg_tar = try tar(arena, &pkg_files);
    const bytes = try zip(arena, &.{
        .{ .path = "metadata.json", .data = "{\"conda_pkg_format_version\": 2}" },
        .{ .path = try std.fmt.allocPrint(arena, "info-{s}.tar.zst", .{stem}), .data = try zstdStore(arena, info_tar) },
        .{ .path = try std.fmt.allocPrint(arena, "pkg-{s}.tar.zst", .{stem}), .data = try zstdStore(arena, pkg_tar) },
    });
    return .{
        .subdir = in.subdir,
        .file_name = try std.fmt.allocPrint(arena, "{s}.conda", .{stem}),
        .bytes = bytes,
        .sha256 = hex(bytes),
        .manifest_sha256 = hex(mopm),
    };
}

// ---------------------------------------------------------------------------
// From a manifest
// ---------------------------------------------------------------------------

fn versionText(arena: Allocator, major: u64, minor: ?u64, patch: ?u64) Allocator.Error![]const u8 {
    if (patch) |p| return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ major, minor orelse 0, p });
    if (minor) |m| return std.fmt.allocPrint(arena, "{d}.{d}", .{ major, m });
    return std.fmt.allocPrint(arena, "{d}", .{major});
}

/// The conda constraint for one comparator: `>=1.2.3,<2` for `^1.2.3`.
fn comparatorText(arena: Allocator, c: semver.Comparator, w: anytype) !void {
    const v = try versionText(arena, c.major, c.minor, c.patch);
    switch (c.op) {
        .exact => {
            if (c.patch != null) {
                try w.print("=={s}", .{v});
            } else {
                try w.print(">={s},<{s}", .{ v, try versionText(arena, c.major + @intFromBool(c.minor == null), if (c.minor) |m| m + 1 else null, null) });
            }
        },
        .greater => {
            // `>1.2` in a requirement means at least 1.3.0.
            if (c.patch != null) {
                try w.print(">{s}", .{v});
            } else if (c.minor) |m| {
                try w.print(">={d}.{d}", .{ c.major, m + 1 });
            } else {
                try w.print(">={d}", .{c.major + 1});
            }
        },
        .greater_eq => try w.print(">={s}", .{v}),
        .less => try w.print("<{s}", .{v}),
        .less_eq => {
            // `<=1.2` in a requirement means below 1.3.0.
            if (c.patch != null) {
                try w.print("<={s}", .{v});
            } else if (c.minor) |m| {
                try w.print("<{d}.{d}", .{ c.major, m + 1 });
            } else {
                try w.print("<{d}", .{c.major + 1});
            }
        },
        .tilde, .wildcard => {
            if (c.minor) |m| {
                try w.print(">={s},<{d}.{d}", .{ v, c.major, m + 1 });
            } else {
                try w.print(">={s},<{d}", .{ v, c.major + 1 });
            }
        },
        .caret => {
            if (c.major > 0) {
                try w.print(">={s},<{d}", .{ v, c.major + 1 });
            } else if (c.minor == null) {
                try w.print(">={s},<1", .{v});
            } else if (c.minor.? > 0 or c.patch == null) {
                try w.print(">={s},<0.{d}", .{ v, c.minor.? + 1 });
            } else {
                try w.print(">={s},<0.0.{d}", .{ v, c.patch.? + 1 });
            }
        },
    }
}

/// The conda constraint equivalent to the cargo-style requirement `text`
/// ("" for `*`). `why` says what is wrong when this fails with `Unpackable`.
pub fn condaRange(arena: Allocator, text: []const u8, why: *[]const u8) error{ Unpackable, OutOfMemory }![]const u8 {
    const req = semver.parseReq(arena, text, why) catch |e| switch (e) {
        error.Invalid => return error.Unpackable,
        error.OutOfMemory => return error.OutOfMemory,
    };
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    for (req.comparators, 0..) |c, i| {
        if (c.pre.len > 0) {
            why.* = "a pre-release in a requirement has no conda spelling";
            return error.Unpackable;
        }
        if (i > 0) try w.writeByte(',');
        try comparatorText(arena, c, w);
    }
    return out.items;
}

fn lessDep(_: void, a: Dep, b: Dep) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// The version of the package a path dependency names, read by the caller from the dependency's own mopm.toml.
pub const PathVersion = struct { name: []const u8, version: []const u8 };

/// Refusal of a path dependency that has no `version`: it names no versions for a consumer to use.
pub const path_no_version_fmt = "dependency '{s}' is a path dependency with no version; add 'version' beside its 'path'";
/// Refusal of a path dependency whose package is not a version its own requirement accepts.
pub const path_unsatisfied_fmt = "dependency '{s}' requires version \"{s}\", but the package at '{s}' is version {s}; change the requirement or the version of that package";

/// The Mojo dependencies of `m` as `Dep`s sorted by name, or `Unpackable`
/// with `why` when `m` cannot be packed: a path dependency with no version,
/// one whose package (in `path_versions`) does not satisfy its version,
/// native libraries or native dependencies (a later change packs those).
/// A path dependency with a version is published as that version alone: the path is never written.
pub fn depsOf(arena: Allocator, m: manifest.Manifest, path_versions: []const PathVersion, why: *[]const u8) error{ Unpackable, OutOfMemory }![]const Dep {
    if (m.native.len > 0) {
        why.* = "native libraries are not packed yet";
        return error.Unpackable;
    }
    if (m.native_dependencies.len > 0) {
        why.* = "native dependencies are not packed yet";
        return error.Unpackable;
    }
    var out = std.ArrayList(Dep).init(arena);
    for (m.dependencies) |d| {
        const text: []const u8 = switch (d.source) {
            .path => |p| blk: {
                const v = d.requirement orelse {
                    why.* = try std.fmt.allocPrint(arena, path_no_version_fmt, .{d.name});
                    return error.Unpackable;
                };
                var found: ?[]const u8 = null;
                for (path_versions) |pv| {
                    if (std.mem.eql(u8, pv.name, d.name)) found = pv.version;
                }
                const have = found orelse {
                    why.* = try std.fmt.allocPrint(arena, "dependency '{s}': the package at '{s}' was not read", .{ d.name, p });
                    return error.Unpackable;
                };
                var bad: []const u8 = "";
                const req = semver.parseReq(arena, v, &bad) catch |e| switch (e) {
                    error.Invalid => {
                        why.* = try std.fmt.allocPrint(arena, "dependency '{s}' = \"{s}\": {s}", .{ d.name, v, bad });
                        return error.Unpackable;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                const ver = semver.parseVersion(have) orelse {
                    why.* = try std.fmt.allocPrint(arena, "dependency '{s}': the package at '{s}' has the version '{s}', which is not MAJOR.MINOR.PATCH", .{ d.name, p, have });
                    return error.Unpackable;
                };
                if (!req.matches(ver)) {
                    why.* = try std.fmt.allocPrint(arena, path_unsatisfied_fmt, .{ d.name, v, p, have });
                    return error.Unpackable;
                }
                break :blk v;
            },
            .version => |v| v,
        };
        var reason: []const u8 = "";
        const range = condaRange(arena, text, &reason) catch |e| switch (e) {
            error.Unpackable => {
                why.* = try std.fmt.allocPrint(arena, "dependency '{s}' = \"{s}\": {s}", .{ d.name, text, reason });
                return error.Unpackable;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        try out.append(.{ .name = d.name, .range = range });
    }
    std.mem.sort(Dep, out.items, {}, lessDep);
    return out.items;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "zstd frame: header bytes, block headers, round trip" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();

    // Empty content: the header, then one last raw block of size 0.
    const empty = try zstdStore(a, "");
    try std.testing.expectEqualSlices(u8, &.{
        0x28, 0xB5, 0x2F, 0xFD, 0xE0, 0, 0, 0, 0, 0, 0, 0, 0, // magic, descriptor, content size 0
        0x01, 0x00, 0x00, // last, raw, size 0
    }, empty);

    const small = try zstdStore(a, "hello");
    try std.testing.expectEqualSlices(u8, &.{ 0x28, 0xB5, 0x2F, 0xFD, 0xE0, 5, 0, 0, 0, 0, 0, 0, 0 }, small[0..13]);
    // size 5 << 3 | last = 0x29
    try std.testing.expectEqualSlices(u8, &.{ 0x29, 0x00, 0x00 }, small[13..16]);
    try std.testing.expectEqualStrings("hello", small[16..]);

    // 300 KiB + 1 byte: blocks of 128 KiB, 128 KiB, 44 KiB + 1, the last one flagged.
    const big_len = 300 * 1024 + 1;
    const big = try a.alloc(u8, big_len);
    for (big, 0..) |*b, i| b.* = @intCast((i * 31 + i / 7) % 251);
    const framed = try zstdStore(a, big);
    try std.testing.expectEqual(@as(usize, 13 + 3 * 3 + big_len), framed.len);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x10 }, framed[13..16]); // 131072 << 3, not last
    const second = 13 + 3 + zstd_block_max;
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x10 }, framed[second .. second + 3]);
    const third = second + 3 + zstd_block_max;
    const rest: u32 = big_len - 2 * zstd_block_max;
    try std.testing.expectEqualSlices(u8, &.{ @truncate((rest << 3) | 1), @truncate(((rest << 3) | 1) >> 8), @truncate(((rest << 3) | 1) >> 16) }, framed[third .. third + 3]);

    // The standard library's decompressor reads it back.
    const back = try std.compress.zstd.decompress.decodeAlloc(std.testing.allocator, framed, true, 8 << 20);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, big, back);
    const back_small = try std.compress.zstd.decompress.decodeAlloc(std.testing.allocator, small, true, 8 << 20);
    defer std.testing.allocator.free(back_small);
    try std.testing.expectEqualStrings("hello", back_small);
}

fn parseOctal(field: []const u8) !u64 {
    const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
    return std.fmt.parseInt(u64, std.mem.trim(u8, field[0..end], " "), 8);
}

test "tar header: fields and checksum" {
    const h = try tarHeader("info/index.json", 1234);
    try std.testing.expectEqualStrings("info/index.json", h[0.."info/index.json".len]);
    try std.testing.expectEqual(@as(u8, 0), h["info/index.json".len]);
    try std.testing.expectEqual(@as(u64, 0o644), try parseOctal(h[100..108]));
    try std.testing.expectEqual(@as(u64, 0), try parseOctal(h[108..116]));
    try std.testing.expectEqual(@as(u64, 0), try parseOctal(h[116..124]));
    try std.testing.expectEqual(@as(u64, 1234), try parseOctal(h[124..136]));
    try std.testing.expectEqual(@as(u64, 0), try parseOctal(h[136..148]));
    try std.testing.expectEqual(@as(u8, '0'), h[156]);
    try std.testing.expectEqualStrings("ustar\x00" ++ "00", h[257..265]);
    try std.testing.expect(std.mem.allEqual(u8, h[265..329], 0)); // no user or group name
    // Recompute: the checksum field counts as eight spaces.
    var sum: u64 = 0;
    for (h, 0..) |b, i| sum += if (i >= 148 and i < 156) ' ' else b;
    try std.testing.expectEqual(sum, try parseOctal(h[148..156]));
    try std.testing.expectEqual(@as(u8, ' '), h[155]);
    try std.testing.expectError(error.PathTooLong, tarHeader("a" ** 101, 0));
}

test "tar: sorted, padded, two zero blocks, deterministic" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const t = try tar(a, &.{ .{ .path = "b", .data = "22" }, .{ .path = "a", .data = "x" ** 512 } });
    // a: header + 1 block, b: header + 1 padded block, then 1024 zero bytes.
    try std.testing.expectEqual(@as(usize, 512 * 4 + 1024), t.len);
    try std.testing.expectEqual(@as(u8, 'a'), t[0]);
    try std.testing.expectEqual(@as(u8, 'b'), t[1024]);
    try std.testing.expectEqualStrings("22", t[1536..1538]);
    try std.testing.expect(std.mem.allEqual(u8, t[1538..], 0));
    const again = try tar(a, &.{ .{ .path = "a", .data = "x" ** 512 }, .{ .path = "b", .data = "22" } });
    try std.testing.expectEqualSlices(u8, t, again);
}

/// What a test reads back from the zip's central directory.
const Entry = struct { name: []const u8, data: []const u8, crc: u32 };

fn rd(comptime T: type, b: []const u8, at: usize) T {
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn readZip(a: Allocator, z: []const u8) ![]Entry {
    const eocd = z.len - 22;
    try std.testing.expectEqual(@as(u32, 0x06054b50), rd(u32, z, eocd));
    const n = rd(u16, z, eocd + 10);
    try std.testing.expectEqual(@as(u16, n), rd(u16, z, eocd + 8));
    try std.testing.expectEqual(@as(u16, 0), rd(u16, z, eocd + 20)); // no comment
    const cd_size = rd(u32, z, eocd + 12);
    const cd_off = rd(u32, z, eocd + 16);
    try std.testing.expectEqual(@as(usize, eocd), cd_off + cd_size);
    var out = std.ArrayList(Entry).init(a);
    var p: usize = cd_off;
    for (0..n) |_| {
        try std.testing.expectEqual(@as(u32, 0x02014b50), rd(u32, z, p));
        try std.testing.expectEqual(@as(u16, 0), rd(u16, z, p + 8)); // flags: no data descriptor
        try std.testing.expectEqual(@as(u16, 0), rd(u16, z, p + 10)); // stored
        try std.testing.expectEqual(@as(u16, 0), rd(u16, z, p + 12)); // 00:00
        try std.testing.expectEqual(@as(u16, 0x0021), rd(u16, z, p + 14)); // the DOS epoch
        const crc = rd(u32, z, p + 16);
        const csize = rd(u32, z, p + 20);
        try std.testing.expectEqual(csize, rd(u32, z, p + 24));
        const name_len = rd(u16, z, p + 28);
        try std.testing.expectEqual(@as(u16, 0), rd(u16, z, p + 30));
        const lho = rd(u32, z, p + 42);
        const name = z[p + 46 ..][0..name_len];
        // The local header agrees with the central one.
        try std.testing.expectEqual(@as(u32, 0x04034b50), rd(u32, z, lho));
        try std.testing.expectEqual(crc, rd(u32, z, lho + 14));
        try std.testing.expectEqual(name_len, rd(u16, z, lho + 26));
        try std.testing.expectEqualStrings(name, z[lho + 30 ..][0..name_len]);
        const data = z[lho + 30 + name_len ..][0..csize];
        try std.testing.expectEqual(crc, std.hash.Crc32.hash(data));
        try out.append(.{ .name = name, .data = data, .crc = crc });
        p += 46 + name_len;
    }
    return out.items;
}

/// Entries of an uncompressed tar, as (path, data).
fn readTar(a: Allocator, t: []const u8) ![]File {
    var out = std.ArrayList(File).init(a);
    var p: usize = 0;
    while (!std.mem.allEqual(u8, t[p..][0..512], 0)) {
        const h = t[p..][0..512];
        const name_end = std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100;
        const size: usize = @intCast(try parseOctal(h[124..136]));
        try out.append(.{ .path = h[0..name_end], .data = t[p + 512 ..][0..size] });
        p += 512 + (size + 511) / 512 * 512;
    }
    try std.testing.expect(std.mem.allEqual(u8, t[p..], 0));
    try std.testing.expectEqual(@as(usize, 1024), t.len - p);
    return out.items;
}

fn unzstd(a: Allocator, z: []const u8) ![]u8 {
    return std.compress.zstd.decompress.decodeAlloc(a, z, true, 8 << 20);
}

test "a package: zip structure, tars, index.json and mopm.json bytes" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const p = try pack(a, .{
        .name = "demo",
        .version = "1.2.3",
        .compiler = "1.0.0",
        .subdir = "linux-64",
        .deps = &.{ .{ .name = "alpha", .range = ">=1.2,<2" }, .{ .name = "beta", .range = "" } },
        .mojoc = "MOJOC-BYTES",
    });
    try std.testing.expectEqualStrings("mojo-demo-1.2.3-mojo1.0.0_0.conda", p.file_name);
    try std.testing.expectEqualSlices(u8, &p.sha256, &hex(p.bytes));

    const entries = try readZip(a, p.bytes);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("metadata.json", entries[0].name);
    try std.testing.expectEqualStrings("{\"conda_pkg_format_version\": 2}", entries[0].data);
    try std.testing.expectEqualStrings("info-mojo-demo-1.2.3-mojo1.0.0_0.tar.zst", entries[1].name);
    try std.testing.expectEqualStrings("pkg-mojo-demo-1.2.3-mojo1.0.0_0.tar.zst", entries[2].name);

    const info = try readTar(a, try unzstd(a, entries[1].data));
    try std.testing.expectEqual(@as(usize, 2), info.len);
    try std.testing.expectEqualStrings("info/index.json", info[0].path);
    try std.testing.expectEqualStrings(
        "{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-alpha >=1.2,<2\",\"mojo-beta\"]," ++
            "\"name\":\"mojo-demo\",\"subdir\":\"linux-64\",\"version\":\"1.2.3\"}",
        info[0].data,
    );
    // paths.json lists exactly the package's files, with the sha256 and size of each (pixi cannot link a
    // package without it: the user-level beta's `mopm sync` of a package `mopm pack` made failed on this).
    try std.testing.expectEqualStrings("info/paths.json", info[1].path);
    {
        const pj = try std.json.parseFromSlice(std.json.Value, a, info[1].data, .{});
        const paths = pj.value.object.get("paths").?.array.items;
        try std.testing.expectEqual(@as(i64, 1), pj.value.object.get("paths_version").?.integer);
        try std.testing.expectEqual(@as(usize, 2), paths.len);
        try std.testing.expectEqualStrings("lib/mojo/demo.mojoc", paths[0].object.get("_path").?.string);
        try std.testing.expectEqualStrings(&hex("MOJOC-BYTES"), paths[0].object.get("sha256").?.string);
        try std.testing.expectEqual(@as(i64, 11), paths[0].object.get("size_in_bytes").?.integer);
        try std.testing.expectEqualStrings("hardlink", paths[0].object.get("path_type").?.string);
        try std.testing.expectEqualStrings("lib/mojo/demo.mopm.json", paths[1].object.get("_path").?.string);
    }

    const pkg = try readTar(a, try unzstd(a, entries[2].data));
    try std.testing.expectEqual(@as(usize, 2), pkg.len);
    try std.testing.expectEqualStrings("lib/mojo/demo.mojoc", pkg[0].path);
    try std.testing.expectEqualStrings("MOJOC-BYTES", pkg[0].data);
    try std.testing.expectEqualStrings("lib/mojo/demo.mopm.json", pkg[1].path);
    try std.testing.expectEqualStrings(
        "{\"deps\":[{\"name\":\"alpha\",\"range\":\">=1.2,<2\"},{\"name\":\"beta\"}],\"name\":\"demo\",\"schema\":1,\"version\":\"1.2.3\"}",
        pkg[1].data,
    );
    try std.testing.expectEqualSlices(u8, &p.manifest_sha256, &hex(pkg[1].data));

    // Deterministic: the same input, the same bytes.
    const q = try pack(a, .{
        .name = "demo",
        .version = "1.2.3",
        .compiler = "1.0.0",
        .subdir = "linux-64",
        .deps = &.{ .{ .name = "alpha", .range = ">=1.2,<2" }, .{ .name = "beta", .range = "" } },
        .mojoc = "MOJOC-BYTES",
    });
    try std.testing.expectEqualSlices(u8, p.bytes, q.bytes);
}

test "pack refuses a bad version, compiler and subdir" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const base = Input{ .name = "demo", .version = "1.0.0", .compiler = "1.0.0", .subdir = "noarch", .mojoc = "x" };
    var in = base;
    in.version = "1.0";
    try std.testing.expectError(error.BadVersion, pack(a, in));
    in.version = "1.0.0-rc.1";
    try std.testing.expectError(error.BadVersion, pack(a, in));
    in = base;
    in.compiler = "1.0.0b1";
    try std.testing.expectError(error.BadCompiler, pack(a, in));
    in.compiler = "";
    try std.testing.expectError(error.BadCompiler, pack(a, in));
    in = base;
    in.subdir = "win-64";
    try std.testing.expectError(error.BadSubdir, pack(a, in));
}

test "exact versions" {
    try std.testing.expect(exactVersion("0.0.0"));
    try std.testing.expect(exactVersion("10.20.30"));
    for ([_][]const u8{ "1.0", "1", "1.0.0.0", "01.0.0", "1.00.0", "1.0.0-rc.1", "1.0.0+b", "1..0", "", "a.b.c", "1.0.0a1" }) |bad| {
        if (exactVersion(bad)) {
            std.debug.print("accepted {s}\n", .{bad});
            return error.TestUnexpectedResult;
        }
    }
}

test "requirements become conda constraints" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const cases = [_][2][]const u8{
        .{ "*", "" },
        .{ "1.2.3", ">=1.2.3,<2" },
        .{ "^1.2.3", ">=1.2.3,<2" },
        .{ "^1.2", ">=1.2,<2" },
        .{ "^0.2.3", ">=0.2.3,<0.3" },
        .{ "^0.0.3", ">=0.0.3,<0.0.4" },
        .{ "^0.0", ">=0.0,<0.1" },
        .{ "^0", ">=0,<1" },
        .{ "~1.2.3", ">=1.2.3,<1.3" },
        .{ "~1", ">=1,<2" },
        .{ "=1.2.3", "==1.2.3" },
        .{ "=1.2", ">=1.2,<1.3" },
        .{ "1.*", ">=1,<2" },
        .{ "1.2.*", ">=1.2,<1.3" },
        .{ ">=1.2, <2", ">=1.2,<2" },
        .{ ">1.2", ">=1.3" },
        .{ ">1.2.3", ">1.2.3" },
        .{ "<=1.2", "<1.3" },
        .{ "<=1.2.3", "<=1.2.3" },
        .{ "<2", "<2" },
    };
    for (cases) |c| {
        var why: []const u8 = "";
        const got = try condaRange(a, c[0], &why);
        std.testing.expectEqualStrings(c[1], got) catch |e| {
            std.debug.print("requirement {s}\n", .{c[0]});
            return e;
        };
    }
    var why: []const u8 = "";
    try std.testing.expectError(error.Unpackable, condaRange(a, "^1.0.0-rc.1", &why));
    try std.testing.expectError(error.Unpackable, condaRange(a, "", &why));
}

test "a manifest: dependencies, and what cannot be packed" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var diag: manifest.Diagnostic = .{};
    const ok = try manifest.parse(a,
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[dependencies]
        \\zeta = "^1.0"
        \\alpha = { version = ">=0.3" }
        \\
    , &diag);
    var why: []const u8 = "";
    const deps = try depsOf(a, ok, &.{}, &why);
    try std.testing.expectEqual(@as(usize, 2), deps.len);
    try std.testing.expectEqualStrings("alpha", deps[0].name);
    try std.testing.expectEqualStrings(">=0.3", deps[0].range);
    try std.testing.expectEqualStrings("zeta", deps[1].name);
    try std.testing.expectEqualStrings(">=1.0,<2", deps[1].range);

    const native = try manifest.parse(a,
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[native.zlib]
        \\kind = "shared"
        \\
    , &diag);
    try std.testing.expectError(error.Unpackable, depsOf(a, native, &.{}, &why));
    try std.testing.expectEqualStrings("native libraries are not packed yet", why);
}

const path_dep_head =
    \\[package]
    \\name = "demo"
    \\version = "0.1.0"
    \\
    \\[toolchain]
    \\mojo = "1.0.0"
    \\
    \\[dependencies]
    \\
;

fn pathDepManifest(a: Allocator, dep_line: []const u8) !manifest.Manifest {
    var diag: manifest.Diagnostic = .{};
    return manifest.parse(a, try std.fmt.allocPrint(a, "{s}{s}\n", .{ path_dep_head, dep_line }), &diag);
}

test "a path dependency with no version cannot be packed, and the message says to add one" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const m = try pathDepManifest(a, "local = { path = \"../local\" }");
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "local", .version = "0.3.0" }}, &why));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, path_no_version_fmt, .{"local"}), why);
    try std.testing.expect(std.mem.indexOf(u8, why, "add 'version' beside its 'path'") != null);
}

test "a path dependency with a version: the version is packed when the package satisfies it, never the path" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const m = try pathDepManifest(a, "local = { path = \"../local\", version = \"^0.3\" }");
    const deps = try depsOf(a, m, &.{.{ .name = "local", .version = "0.3.7" }}, &why);
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    try std.testing.expectEqualStrings("local", deps[0].name);
    try std.testing.expectEqualStrings(">=0.3,<0.4", deps[0].range);

    // The bytes of the package carry the requirement and nothing of the path.
    const p = try pack(a, .{ .name = "demo", .version = "0.1.0", .compiler = "1.0.0", .subdir = "linux-64", .deps = deps, .mojoc = "MOJOC" });
    const entries = try readZip(a, p.bytes);
    const pkg = try readTar(a, try unzstd(a, entries[2].data));
    try std.testing.expectEqualStrings(
        "{\"deps\":[{\"name\":\"local\",\"range\":\">=0.3,<0.4\"}],\"name\":\"demo\",\"schema\":1,\"version\":\"0.1.0\"}",
        pkg[1].data,
    );
    const info = try readTar(a, try unzstd(a, entries[1].data));
    try std.testing.expect(std.mem.indexOf(u8, info[0].data, "mojo-local >=0.3,<0.4") != null);
    for ([_][]const u8{ pkg[1].data, info[0].data, p.bytes }) |bytes| {
        try std.testing.expect(std.mem.indexOf(u8, bytes, "../local") == null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"path\"") == null);
    }
}

test "a path dependency whose package does not satisfy its version cannot be packed" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    const m = try pathDepManifest(a, "local = { path = \"../local\", version = \"^0.3\" }");
    // Below, above and exactly at the edges of ^0.3 (>=0.3.0, <0.4.0).
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "local", .version = "0.2.9" }}, &why));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, path_unsatisfied_fmt, .{ "local", "^0.3", "../local", "0.2.9" }), why);
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "local", .version = "0.4.0" }}, &why));
    _ = try depsOf(a, m, &.{.{ .name = "local", .version = "0.3.0" }}, &why);
    _ = try depsOf(a, m, &.{.{ .name = "local", .version = "0.3.99" }}, &why);
    // A package nobody read is not assumed to satisfy anything.
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{}, &why));
}

test "a path dependency that depsOf cannot judge is refused with the reason" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var why: []const u8 = "";
    var m = try pathDepManifest(a, "local = { path = \"../local\", version = \"^0.3\" }");

    // The package at the path has a version that is not MAJOR.MINOR.PATCH.
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "local", .version = "0.3" }}, &why));
    try std.testing.expectEqualStrings("dependency 'local': the package at '../local' has the version '0.3', which is not MAJOR.MINOR.PATCH", why);

    // The package was never read.
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "other", .version = "0.3.0" }}, &why));
    try std.testing.expectEqualStrings("dependency 'local': the package at '../local' was not read", why);

    // A requirement the parser would have refused (a hand-made manifest) is refused here too, and not read as `*`.
    const bad = try a.alloc(manifest.Dep, 1);
    bad[0] = .{ .name = "local", .source = .{ .path = "../local" }, .requirement = "=>1" };
    m.dependencies = bad;
    try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{.{ .name = "local", .version = "0.3.0" }}, &why));
    try std.testing.expect(std.mem.startsWith(u8, why, "dependency 'local' = \"=>1\": "));
}
