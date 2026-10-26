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
    /// The system libraries the package opens at run time (`[native-dependencies]` with `mode = "load"`), by conda
    /// package name (`nativeDepsOf`): they follow the Mojo dependencies in `depends` of `info/index.json`.
    native_deps: []const Dep = &.{},
    /// The bytes of the `.mojoc`.
    mojoc: []const u8,
    /// The static native libraries of this subdir: each one's archive goes to `lib/<soname>`.
    natives: []const Native = &.{},
};

/// A static native library a package ships (`[native.<id>] kind = "static"`), as it is packed for one subdir.
pub const Native = struct {
    id: []const u8,
    /// `lib<name>.a`: the archive's file name, which is also the soname consumers' `needs` name.
    soname: []const u8,
    /// Sonames of other packages' native libraries this one needs.
    needs: []const []const u8 = &.{},
    /// An exclusivity group, or "".
    exclusive: []const u8 = "",
    /// The bytes of the archive built for the subdir.
    archive: []const u8,
};

/// The first four bytes of a Unix archive (`ar`) are `!<arch>`; the whole magic is eight.
pub const ar_magic = "!<arch>\n";

/// Why `n` cannot be packed as a static native library, or null. The registry holds the same names to the
/// same rules (`lib/lib<stem>.a`, `static_file` resolved from `lib/mojo/`), so a refusal here is one the
/// registry would make later.
pub fn nativeProblem(arena: Allocator, n: Native) Allocator.Error!?[]const u8 {
    if (!staticSoname(n.soname)) {
        return try std.fmt.allocPrint(arena, "native '{s}': '{s}' is not a static archive name; it must be lib<name>.a with no other dot", .{ n.id, n.soname });
    }
    if (n.archive.len <= ar_magic.len or !std.mem.eql(u8, n.archive[0..ar_magic.len], ar_magic)) {
        return try std.fmt.allocPrint(arena, "native '{s}': {s} is not a static archive (it does not start with {s})", .{ n.id, n.soname, "!<arch>" });
    }
    for (n.needs) |need| {
        if (!validNeed(need)) return try std.fmt.allocPrint(arena, "native '{s}': '{s}' is not a library name (lib<name>.<suffix>)", .{ n.id, need });
        if (std.mem.eql(u8, need, n.soname)) return try std.fmt.allocPrint(arena, "native '{s}' needs itself", .{n.id});
    }
    return null;
}

/// `lib<name>.a`: the registry's `SONAME_PATTERN` and its rule that a static file is `<soname up to the first dot>.a`.
fn staticSoname(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "lib") or !std.mem.endsWith(u8, s, ".a")) return false;
    const stem = s[3 .. s.len - 2];
    if (stem.len == 0) return false;
    for (stem) |c| {
        if (c == '.' or c == '/') return false;
    }
    return true;
}

/// `lib<name>.<suffix>`: any library file name (a `needs` entry may name a shared library of another package).
fn validNeed(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "lib")) return false;
    const dot = std.mem.indexOfScalar(u8, s[3..], '.') orelse return false;
    if (dot == 0 or 3 + dot + 1 >= s.len) return false;
    return std.mem.indexOfScalar(u8, s, '/') == null;
}

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
    /// The archives packed, by id: what `mopm pack` prints, to compare with the sha256 `mopm lock` pins.
    natives: []const NativeDigest = &.{},
};

pub const NativeDigest = struct { soname: []const u8, sha256: [64]u8, size: u64 };

pub const PackError = error{ BadCompiler, BadSubdir, BadVersion, BadNative, PathTooLong, TooLarge, OutOfMemory };

/// MAJOR.MINOR.PATCH: three numbers of digits, no leading zero except "0",
/// and nothing else (no pre-release, no build metadata, no missing part).
pub fn exactVersion(v: []const u8) bool {
    return semver.isPackageVersion(v);
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
    for (in.native_deps) |d| {
        try w.writeByte(',');
        const dep = if (d.range.len == 0)
            try arena.dupe(u8, d.name)
        else
            try std.fmt.allocPrint(arena, "{s} {s}", .{ d.name, d.range });
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
    if (in.natives.len > 0) {
        // By id, so that the order of the tables in mopm.toml does not change the bytes.
        const sorted = try arena.dupe(Native, in.natives);
        std.mem.sort(Native, sorted, {}, lessNative);
        try w.writeAll(",\"native\":[");
        for (sorted, 0..) |n, i| {
            if (i > 0) try w.writeByte(',');
            try w.writeByte('{');
            if (n.exclusive.len > 0) {
                try w.writeAll("\"exclusive\":");
                try jsonStr(w, n.exclusive);
                try w.writeByte(',');
            }
            try w.writeAll("\"id\":");
            try jsonStr(w, n.id);
            try w.writeAll(",\"kind\":\"static\",\"mode\":\"link\",\"needs\":[");
            const needs = try arena.dupe([]const u8, n.needs);
            std.mem.sort([]const u8, needs, {}, lessStr);
            for (needs, 0..) |need, k| {
                if (k > 0) try w.writeByte(',');
                try jsonStr(w, need);
            }
            try w.writeAll("],\"soname\":");
            try jsonStr(w, n.soname);
            // The registry resolves a file named in this metadata against lib/mojo/, and wants it directly under lib/.
            try w.writeAll(",\"static_file\":");
            try jsonStr(w, try std.fmt.allocPrint(arena, "../{s}", .{n.soname}));
            try w.writeByte('}');
        }
        try w.writeByte(']');
    }
    try w.writeAll(",\"schema\":1,\"version\":");
    try jsonStr(w, in.version);
    try w.writeByte('}');
    return out.items;
}

fn lessNative(_: void, a: Native, b: Native) bool {
    return std.mem.lessThan(u8, a.id, b.id);
}

fn lessStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
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

/// `info/about.json`: the facts about the archives of this one subdir's file, under `mopm_native` (the archive's file
/// name, sha256 and size). `.mopm.json` is the same bytes in every subdir's file (the registry compares its hash
/// with the version's), so what differs from one platform to the next is kept here, which no registry rule reads:
/// it is informational. The consumer's anchor is the sha256 `mopm lock` takes of the archive itself.
pub fn aboutJson(arena: Allocator, natives: []const Native) Allocator.Error![]u8 {
    var out = std.ArrayList(u8).init(arena);
    const w = out.writer();
    const sorted = try arena.dupe(Native, natives);
    std.mem.sort(Native, sorted, {}, lessNative);
    try w.writeAll("{\"mopm_native\":[");
    for (sorted, 0..) |n, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"id\":");
        try jsonStr(w, n.id);
        try w.print(",\"sha256\":\"{s}\",\"size\":{d},\"soname\":", .{ hex(n.archive), n.archive.len });
        try jsonStr(w, n.soname);
        try w.writeByte('}');
    }
    try w.writeAll("]}");
    return out.items;
}

/// Builds the `.conda` for `in`.
pub fn pack(arena: Allocator, in: Input) PackError!Packed {
    if (!exactVersion(in.version)) return error.BadVersion;
    if (!validCompiler(in.compiler)) return error.BadCompiler;
    if (!isSubdir(in.subdir)) return error.BadSubdir;

    for (in.natives) |n| {
        if ((try nativeProblem(arena, n)) != null) return error.BadNative;
    }

    const stem = try std.fmt.allocPrint(arena, "mojo-{s}-{s}-mojo{s}_0", .{ in.name, in.version, in.compiler });
    const mopm = try mopmJson(arena, in);
    const index = try indexJson(arena, in);

    var pkg_files = std.ArrayList(File).init(arena);
    try pkg_files.append(.{ .path = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mojoc", .{in.name}), .data = in.mojoc });
    try pkg_files.append(.{ .path = try std.fmt.allocPrint(arena, "lib/mojo/{s}.mopm.json", .{in.name}), .data = mopm });
    for (in.natives) |n| try pkg_files.append(.{ .path = try std.fmt.allocPrint(arena, "lib/{s}", .{n.soname}), .data = n.archive });
    std.mem.sort(File, pkg_files.items, {}, lessFile);
    var info_files = std.ArrayList(File).init(arena);
    try info_files.append(.{ .path = "info/index.json", .data = index });
    try info_files.append(.{ .path = "info/paths.json", .data = try pathsJson(arena, pkg_files.items) });
    // about.json goes into the info tar: the registry refuses an `info/` file in the package tar (conda_layout).
    if (in.natives.len > 0) try info_files.append(.{ .path = "info/about.json", .data = try aboutJson(arena, in.natives) });
    const info_tar = try tar(arena, info_files.items);
    const pkg_tar = try tar(arena, pkg_files.items);
    const digests = try arena.alloc(NativeDigest, in.natives.len);
    for (in.natives, digests) |n, *d| d.* = .{ .soname = n.soname, .sha256 = hex(n.archive), .size = n.archive.len };
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
        .natives = digests,
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

/// The conda package that provides a system library, from the name a manifest gives it (`lz4`, `liblz4`,
/// `liblz4.so.1`): the packages of conda-forge whose names are not the library's. Any other name is the conda
/// package name as written (`openssl`).
pub fn condaPackageFor(name: []const u8) []const u8 {
    const known = [_][2][]const u8{
        .{ "lz4", "lz4-c" },
        .{ "z", "libzlib" },
        .{ "zlib", "libzlib" },
        .{ "bz2", "bzip2" },
        .{ "lzma", "xz" },
        .{ "xz", "xz" },
        .{ "zstd", "zstd" },
    };
    var stem = if (std.mem.startsWith(u8, name, "lib")) name[3..] else name;
    if (std.mem.indexOfScalar(u8, stem, '.')) |dot| stem = stem[0..dot];
    for (known) |k| {
        if (std.mem.eql(u8, k[0], stem)) return k[1];
    }
    return name;
}

/// The system libraries `m` opens at run time as `Dep`s (conda package and conda constraint) sorted by package, or
/// `Unpackable` with `why`: only `mode = "load"` shared libraries are packed, each as an entry of `depends`, so
/// that installing the package installs the library; a library to link is not packed yet.
pub fn nativeDepsOf(arena: Allocator, m: manifest.Manifest, why: *[]const u8) error{ Unpackable, OutOfMemory }![]const Dep {
    var out = std.ArrayList(Dep).init(arena);
    for (m.native_dependencies) |d| {
        if (d.mode != .load) {
            why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' is mode = \"link\"; only mode = \"load\" is packed", .{d.name});
            return error.Unpackable;
        }
        if ((d.kind orelse manifest.NativeDepKind.shared) != .shared) {
            why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' is kind = \"static\"; a library to load is kind = \"shared\"", .{d.name});
            return error.Unpackable;
        }
        const pkg = condaPackageFor(d.name);
        for (pkg) |c| {
            if (std.ascii.isUpper(c)) {
                why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' names the conda package '{s}', which has an upper case letter", .{ d.name, pkg });
                return error.Unpackable;
            }
        }
        if (std.mem.startsWith(u8, pkg, "mojo-")) {
            why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' names the conda package '{s}'; a Mojo package belongs in [dependencies]", .{ d.name, pkg });
            return error.Unpackable;
        }
        for (out.items) |o| {
            if (std.mem.eql(u8, o.name, pkg)) {
                why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' names the conda package '{s}' a second time", .{ d.name, pkg });
                return error.Unpackable;
            }
        }
        var range: []const u8 = "";
        if (d.version) |v| {
            var reason: []const u8 = "";
            range = condaRange(arena, v, &reason) catch |e| switch (e) {
                error.Unpackable => {
                    why.* = try std.fmt.allocPrint(arena, "native dependency '{s}' = \"{s}\": {s}", .{ d.name, v, reason });
                    return error.Unpackable;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        try out.append(.{ .name = pkg, .range = range });
    }
    std.mem.sort(Dep, out.items, {}, lessDep);
    return out.items;
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
/// a native library that is not a linked static archive, or a native dependency `nativeDepsOf` refuses.
/// A path dependency with a version is published as that version alone: the path is never written.
pub fn depsOf(arena: Allocator, m: manifest.Manifest, path_versions: []const PathVersion, why: *[]const u8) error{ Unpackable, OutOfMemory }![]const Dep {
    for (m.native) |n| {
        if (n.kind != .static) {
            why.* = try std.fmt.allocPrint(arena, "native library '{s}' is kind = \"{s}\"; only static archives are packed (kind = \"static\")", .{ n.id, @tagName(n.kind) });
            return error.Unpackable;
        }
        if (n.mode != .link) {
            why.* = try std.fmt.allocPrint(arena, "native library '{s}' is mode = \"load\"; only mode = \"link\" is packed", .{n.id});
            return error.Unpackable;
        }
    }
    _ = try nativeDepsOf(arena, m, why);
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
    try std.testing.expectEqualStrings("native library 'zlib' is kind = \"shared\"; only static archives are packed (kind = \"static\")", why);
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

// ---------------------------------------------------------------------------
// Static native libraries
// ---------------------------------------------------------------------------

const ar_x = ar_magic ++ "members of x\n";
const ar_y = ar_magic ++ "members of y\n";

fn nativeInput(a: Allocator, subdir: []const u8, archive: []const u8) !Input {
    return .{
        .name = "tls_sys",
        .version = "2.4.0",
        .compiler = "1.0.0",
        .subdir = subdir,
        .mojoc = "MOJOC",
        .natives = try a.dupe(Native, &.{.{ .id = "tls_sys", .soname = "libtls_sys.a", .needs = &.{ "libcrypto_sys.a", "libc_sys.a" }, .exclusive = "libtls", .archive = archive }}),
    };
}

// Defects it catches: an archive that is not in the package, or at another path than the registry requires
// (`lib/lib<stem>.a`, named by `static_file` from `lib/mojo/`); metadata that declares a library with the wrong key,
// kind or path; `about.json` in the package tar (the registry refuses an info/ file there); a native id written
// into `depends` (the registry refuses one that is not allow-listed); paths.json that omits the archive (pixi
// cannot link a package whose file it does not list). Defect caught: the archive left out of pkg_files; written
// to lib/mojo/; about.json appended to pkg_files; the id appended to `depends`.
test "a package with a static archive: where each file is, and what the metadata says" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const p = try pack(a, try nativeInput(a, "linux-64", ar_x));
    const entries = try readZip(a, p.bytes);
    const info = try readTar(a, try unzstd(a, entries[1].data));
    const pkg = try readTar(a, try unzstd(a, entries[2].data));

    try std.testing.expectEqual(@as(usize, 3), pkg.len);
    try std.testing.expectEqualStrings("lib/libtls_sys.a", pkg[0].path);
    try std.testing.expectEqualStrings(ar_x, pkg[0].data);
    try std.testing.expectEqualStrings("lib/mojo/tls_sys.mojoc", pkg[1].path);
    try std.testing.expectEqualStrings("lib/mojo/tls_sys.mopm.json", pkg[2].path);
    try std.testing.expectEqualStrings(
        "{\"deps\":[],\"name\":\"tls_sys\",\"native\":[{\"exclusive\":\"libtls\",\"id\":\"tls_sys\",\"kind\":\"static\",\"mode\":\"link\"," ++
            "\"needs\":[\"libc_sys.a\",\"libcrypto_sys.a\"],\"soname\":\"libtls_sys.a\",\"static_file\":\"../libtls_sys.a\"}],\"schema\":1,\"version\":\"2.4.0\"}",
        pkg[2].data,
    );
    try std.testing.expectEqualSlices(u8, &p.manifest_sha256, &hex(pkg[2].data));

    // info/: about.json is here and only here; depends names no native id.
    try std.testing.expectEqual(@as(usize, 3), info.len);
    try std.testing.expectEqualStrings("info/about.json", info[0].path);
    try std.testing.expectEqualStrings("info/index.json", info[1].path);
    try std.testing.expectEqualStrings("info/paths.json", info[2].path);
    const about = try std.fmt.allocPrint(a, "{{\"mopm_native\":[{{\"id\":\"tls_sys\",\"sha256\":\"{s}\",\"size\":{d},\"soname\":\"libtls_sys.a\"}}]}}", .{ &hex(ar_x), ar_x.len });
    try std.testing.expectEqualStrings(about, info[0].data);
    try std.testing.expectEqualStrings("{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\"],\"name\":\"mojo-tls_sys\",\"subdir\":\"linux-64\",\"version\":\"2.4.0\"}", info[1].data);

    // paths.json lists the archive, with its own sha256 and size.
    const pj = try std.json.parseFromSlice(std.json.Value, a, info[2].data, .{});
    const paths = pj.value.object.get("paths").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expectEqualStrings("lib/libtls_sys.a", paths[0].object.get("_path").?.string);
    try std.testing.expectEqualStrings(&hex(ar_x), paths[0].object.get("sha256").?.string);
    try std.testing.expectEqual(@as(i64, ar_x.len), paths[0].object.get("size_in_bytes").?.integer);

    // What `mopm pack` prints to compare with the lock.
    try std.testing.expectEqual(@as(usize, 1), p.natives.len);
    try std.testing.expectEqualStrings("libtls_sys.a", p.natives[0].soname);
    try std.testing.expectEqualSlices(u8, &hex(ar_x), &p.natives[0].sha256);
    try std.testing.expectEqual(@as(u64, ar_x.len), p.natives[0].size);
}

// Defect it catches: per-platform facts in `.mopm.json`, so that the files of one version carry different metadata and
// the registry (which compares each file's metadata hash with the version's one `manifest_sha256`) rejects the
// second platform. Defect caught: the archive's size written into `static_file`.
test "the metadata is the same bytes in every subdir; the archive, about.json and the file are not" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const linux = try pack(a, try nativeInput(a, "linux-64", ar_x));
    const osx = try pack(a, try nativeInput(a, "osx-arm64", ar_y));
    try std.testing.expectEqualSlices(u8, &linux.manifest_sha256, &osx.manifest_sha256);
    try std.testing.expect(!std.mem.eql(u8, &linux.sha256, &osx.sha256));
    const l_entries = try readZip(a, linux.bytes);
    const o_entries = try readZip(a, osx.bytes);
    const l_info = try readTar(a, try unzstd(a, l_entries[1].data));
    const o_info = try readTar(a, try unzstd(a, o_entries[1].data));
    try std.testing.expect(!std.mem.eql(u8, l_info[0].data, o_info[0].data)); // about.json
    const l_pkg = try readTar(a, try unzstd(a, l_entries[2].data));
    const o_pkg = try readTar(a, try unzstd(a, o_entries[2].data));
    try std.testing.expectEqualStrings(l_pkg[2].data, o_pkg[2].data); // .mopm.json
    try std.testing.expectEqualStrings(ar_x, l_pkg[0].data);
    try std.testing.expectEqualStrings(ar_y, o_pkg[0].data);
}

test "a package with static archives is the same bytes however the natives and their needs are listed, and twice" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const one = [_]Native{
        .{ .id = "a_sys", .soname = "liba_sys.a", .needs = &.{ "libz.so.1", "libb_sys.a" }, .archive = ar_x },
        .{ .id = "b_sys", .soname = "libb_sys.a", .archive = ar_y },
    };
    const two = [_]Native{
        .{ .id = "b_sys", .soname = "libb_sys.a", .archive = ar_y },
        .{ .id = "a_sys", .soname = "liba_sys.a", .needs = &.{ "libb_sys.a", "libz.so.1" }, .archive = ar_x },
    };
    const base = Input{ .name = "pair", .version = "1.0.0", .compiler = "1.0.0", .subdir = "linux-64", .mojoc = "M" };
    var in = base;
    in.natives = &one;
    const p1 = try pack(a, in);
    const p1b = try pack(a, in);
    in.natives = &two;
    const p2 = try pack(a, in);
    try std.testing.expectEqualSlices(u8, p1.bytes, p1b.bytes);
    try std.testing.expectEqualSlices(u8, p1.bytes, p2.bytes);
    // A package without natives is what it was: no native key, no about.json, no archive.
    const plain = try pack(a, base);
    const entries = try readZip(a, plain.bytes);
    try std.testing.expectEqual(@as(usize, 2), (try readTar(a, try unzstd(a, entries[1].data))).len);
    try std.testing.expectEqual(@as(usize, 2), (try readTar(a, try unzstd(a, entries[2].data))).len);
}

// Defects it catches: an archive the registry would refuse (or worse, would accept and a linker choke on) leaving
// the packer: a file that is not an `ar` archive, a name that is not `lib<name>.a`, a need that is not a library name.
// Defect caught: the magic check dropped; staticSoname accepts any name ending `.a`; validNeed accepts any text.
test "pack refuses a native library that is not a static archive named lib<name>.a, or a need that is not a library name" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const base = try nativeInput(a, "linux-64", ar_x);
    const good = base.natives[0];

    const Case = struct { n: Native, want: []const u8 };
    const cases = [_]Case{
        .{ .n = .{ .id = "t", .soname = "libt.a", .archive = "\x7fELF-not-an-archive" }, .want = "is not a static archive (it does not start with !<arch>)" },
        .{ .n = .{ .id = "t", .soname = "libt.a", .archive = ar_magic }, .want = "is not a static archive" },
        .{ .n = .{ .id = "t", .soname = "libt.so.1", .archive = ar_x }, .want = "is not a static archive name; it must be lib<name>.a with no other dot" },
        .{ .n = .{ .id = "t", .soname = "t.a", .archive = ar_x }, .want = "is not a static archive name" },
        .{ .n = .{ .id = "t", .soname = "lib.a", .archive = ar_x }, .want = "is not a static archive name" },
        .{ .n = .{ .id = "t", .soname = "libt.1.a", .archive = ar_x }, .want = "is not a static archive name" },
        .{ .n = .{ .id = "t", .soname = "libt/x.a", .archive = ar_x }, .want = "is not a static archive name" },
        .{ .n = .{ .id = "t", .soname = "libt.a", .needs = &.{"zlib"}, .archive = ar_x }, .want = "'zlib' is not a library name" },
        .{ .n = .{ .id = "t", .soname = "libt.a", .needs = &.{"libz."}, .archive = ar_x }, .want = "is not a library name" },
        .{ .n = .{ .id = "t", .soname = "libt.a", .needs = &.{"lib/z.a"}, .archive = ar_x }, .want = "is not a library name" },
        .{ .n = .{ .id = "t", .soname = "libt.a", .needs = &.{"libt.a"}, .archive = ar_x }, .want = "needs itself" },
    };
    for (cases) |c| {
        const why = (try nativeProblem(a, c.n)) orelse {
            std.debug.print("accepted, want: {s}\n", .{c.want});
            return error.TestUnexpectedResult;
        };
        std.testing.expect(std.mem.indexOf(u8, why, c.want) != null) catch |e| {
            std.debug.print("said '{s}', want '{s}'\n", .{ why, c.want });
            return e;
        };
        var in = base;
        in.natives = &.{c.n};
        try std.testing.expectError(error.BadNative, pack(a, in));
    }
    try std.testing.expect((try nativeProblem(a, good)) == null);
    // A shared library named in `needs` is a library name too.
    try std.testing.expect((try nativeProblem(a, .{ .id = "t", .soname = "libt.a", .needs = &.{"libz.so.1"}, .archive = ar_x })) == null);
}

test "a manifest's native libraries: static, link mode packs; shared, both or load mode does not, and says why" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var diag: manifest.Diagnostic = .{};
    var why: []const u8 = "";
    const head = "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"1.0.0\"\n\n";
    const ok = try manifest.parse(a, head ++ "[native.tls_sys]\nkind = \"static\"\nneeds = [\"libz.a\"]\nexclusive = \"libtls\"\n", &diag);
    _ = try depsOf(a, ok, &.{}, &why);
    try std.testing.expectEqualStrings("libz.a", ok.native[0].needs[0]);
    try std.testing.expectEqualStrings("libtls", ok.native[0].exclusive);

    for ([_][2][]const u8{
        .{ "[native.s]\nkind = \"both\"\n", "native library 's' is kind = \"both\"; only static archives are packed (kind = \"static\")" },
        .{ "[native.s]\n", "native library 's' is kind = \"shared\"; only static archives are packed (kind = \"static\")" },
        .{ "[native.s]\nkind = \"static\"\nmode = \"load\"\n", "native library 's' is mode = \"load\"; only mode = \"link\" is packed" },
    }) |c| {
        const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ head, c[0] }), &diag);
        try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{}, &why));
        try std.testing.expectEqualStrings(c[1], why);
    }
    // A native dependency to link (the default mode) is not packed yet.
    const dep = try manifest.parse(a, head ++ "[native-dependencies]\nzlib = \">=1.2\"\n", &diag);
    try std.testing.expectError(error.Unpackable, depsOf(a, dep, &.{}, &why));
    try std.testing.expectEqualStrings("native dependency 'zlib' is mode = \"link\"; only mode = \"load\" is packed", why);
}

test "native dependencies to load are conda dependencies, in the order of their packages" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var diag: manifest.Diagnostic = .{};
    const head =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[dependencies]
        \\alpha = "^1.0"
        \\
        \\[native-dependencies]
        \\
    ;
    var why: []const u8 = "";
    const m = try manifest.parse(a, head ++
        \\lz4 = { version = ">=1.9.3", kind = "shared", mode = "load" }
        \\zlib = { mode = "load" }
        \\libzstd = { version = "1.5.2", mode = "load" }
        \\openssl = { version = ">=3", kind = "shared", mode = "load" }
        \\
    , &diag);
    // The Mojo dependencies are unchanged by them.
    const deps = try depsOf(a, m, &.{}, &why);
    try std.testing.expectEqual(@as(usize, 1), deps.len);
    const native = try nativeDepsOf(a, m, &why);
    try std.testing.expectEqual(@as(usize, 4), native.len);
    for ([_][2][]const u8{ .{ "libzlib", "" }, .{ "lz4-c", ">=1.9.3" }, .{ "openssl", ">=3" }, .{ "zstd", ">=1.5.2,<2" } }, native) |want, got| {
        try std.testing.expectEqualStrings(want[0], got.name);
        try std.testing.expectEqualStrings(want[1], got.range);
    }

    // They reach info/index.json, after the compiler and the Mojo dependencies, and nothing else of the package changes.
    const idx = try indexJson(a, .{ .name = "demo", .version = "0.1.0", .compiler = "1.0.0", .subdir = "linux-64", .deps = deps, .native_deps = native, .mojoc = "x" });
    try std.testing.expectEqualStrings(
        "{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-alpha >=1.0,<2\"," ++
            "\"libzlib\",\"lz4-c >=1.9.3\",\"openssl >=3\",\"zstd >=1.5.2,<2\"],\"name\":\"mojo-demo\",\"subdir\":\"linux-64\",\"version\":\"0.1.0\"}",
        idx,
    );
    // ... and into the file mopm pack writes.
    const p = try pack(a, .{ .name = "demo", .version = "0.1.0", .compiler = "1.0.0", .subdir = "linux-64", .native_deps = native, .mojoc = "x" });
    const entries = try readZip(a, p.bytes);
    const info = try readTar(a, try unzstd(a, entries[1].data));
    try std.testing.expectEqualStrings("info/index.json", info[0].path);
    try std.testing.expect(std.mem.indexOf(u8, info[0].data, "\"lz4-c >=1.9.3\"") != null);
}

test "native dependencies that cannot be packed are refused with their reason" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var diag: manifest.Diagnostic = .{};
    const head =
        \\[package]
        \\name = "demo"
        \\version = "0.1.0"
        \\
        \\[toolchain]
        \\mojo = "1.0.0"
        \\
        \\[native-dependencies]
        \\
    ;
    for ([_][2][]const u8{
        .{ "lz4 = { mode = \"link\", kind = \"shared\" }\n", "native dependency 'lz4' is mode = \"link\"; only mode = \"load\" is packed" },
        .{ "lz4 = { mode = \"load\", kind = \"static\" }\n", "native dependency 'lz4' is kind = \"static\"; a library to load is kind = \"shared\"" },
        .{ "OpenSSL = { mode = \"load\" }\n", "native dependency 'OpenSSL' names the conda package 'OpenSSL', which has an upper case letter" },
        .{ "mojo-json = { mode = \"load\" }\n", "native dependency 'mojo-json' names the conda package 'mojo-json'; a Mojo package belongs in [dependencies]" },
        .{ "lz4 = { mode = \"load\" }\nliblz4 = { mode = \"load\" }\n", "native dependency 'liblz4' names the conda package 'lz4-c' a second time" },
        .{ "lz4 = { version = \"^1.0.0-rc.1\", mode = \"load\" }\n", "native dependency 'lz4' = \"^1.0.0-rc.1\": a pre-release in a requirement has no conda spelling" },
    }) |c| {
        const m = try manifest.parse(a, try std.mem.concat(a, u8, &.{ head, c[0] }), &diag);
        var why: []const u8 = "";
        try std.testing.expectError(error.Unpackable, nativeDepsOf(a, m, &why));
        try std.testing.expectEqualStrings(c[1], why);
        try std.testing.expectError(error.Unpackable, depsOf(a, m, &.{}, &why));
    }
}

test "the conda package of a system library: by name, library name or file name" {
    for ([_][2][]const u8{
        .{ "lz4", "lz4-c" },
        .{ "liblz4", "lz4-c" },
        .{ "liblz4.so.1", "lz4-c" },
        .{ "libz.so.1", "libzlib" },
        .{ "zlib", "libzlib" },
        .{ "libbz2.so.1.0", "bzip2" },
        .{ "liblzma.so.5", "xz" },
        .{ "libzstd.so.1", "zstd" },
        .{ "openssl", "openssl" },
        .{ "libffi", "libffi" },
        .{ "lz4-c", "lz4-c" },
    }) |c| try std.testing.expectEqualStrings(c[1], condaPackageFor(c[0]));
}
