//! Conda packages and a stand-in toolchain closure for the drivers that run `mopm sync` against the fake registry.
//!
//! `package` writes a real `.conda` file (spec/channel.md): a zip of `metadata.json`, `info-<stem>.tar.zst` (index.json,
//! paths.json, files) and `pkg-<stem>.tar.zst`. The zstd frames hold raw blocks (RFC 8878), which any decoder reads, so
//! no compressor is needed.
//!
//! `fakeToolchain` is what `mopm sync --toolchain <file>` reads in place of the pinned Mojo closure: the farm has no
//! network, so the real closure (hundreds of MB from conda channels) cannot be downloaded there. It writes two small
//! packages, `mojo` and `mojo-compiler` at the Mojo version (the two a closure must hold, core/closure.zig `problem`),
//! under the fake registry's data directory, where the fake serves them at `/channel/...`, and a closure file whose
//! channel is that url. Each package holds one text file under `share/mopm-fake-toolchain/`, so a driver can see that
//! sync installed it. The real compiler is laid into the environment by the driver afterwards (mojo_env.zig `prefix`),
//! as before.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Entry = struct { path: []const u8, data: []const u8, mode: u32 = 0o644 };

pub fn sha256Hex(a: Allocator, bytes: []const u8) ![]u8 {
    var d: [32]u8 = undefined;
    Sha256.hash(bytes, &d, .{});
    return std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&d)});
}

/// A zstd frame holding `data` in raw (stored) blocks: valid zstd that any decoder reads, written without a compressor
/// (RFC 8878, section 3.1.1).
pub fn zstdRaw(a: Allocator, data: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(&.{ 0x28, 0xb5, 0x2f, 0xfd }); // magic number 0xFD2FB528
    try out.append(0x00); // frame header: no content size, no checksum, no dictionary
    try out.append(0x38); // window descriptor: 2^17 bytes, the largest block size
    const block: usize = 128 * 1024;
    var at: usize = 0;
    while (true) {
        const n = @min(block, data.len - at);
        const last: u32 = if (at + n >= data.len) 1 else 0;
        const hdr: u32 = last | (@as(u32, @intCast(n)) << 3); // block type 0: raw
        try out.appendSlice(&.{ @truncate(hdr), @truncate(hdr >> 8), @truncate(hdr >> 16) });
        try out.appendSlice(data[at..][0..n]);
        at += n;
        if (last == 1) break;
    }
    return out.items;
}

fn putOctal(dst: []u8, v: usize) void {
    @memset(dst, '0');
    var x = v;
    var i = dst.len - 1; // the last byte is the NUL
    dst[i] = 0;
    while (i > 0) {
        i -= 1;
        dst[i] = '0' + @as(u8, @intCast(x & 7));
        x >>= 3;
    }
}

/// A ustar archive of `entries`.
pub fn tar(a: Allocator, entries: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    for (entries) |e| {
        var hd = [_]u8{0} ** 512;
        @memcpy(hd[0..e.path.len], e.path);
        putOctal(hd[100..108], e.mode);
        putOctal(hd[108..116], 0);
        putOctal(hd[116..124], 0);
        putOctal(hd[124..136], e.data.len);
        putOctal(hd[136..148], 0); // mtime 0
        @memset(hd[148..156], ' ');
        hd[156] = '0';
        @memcpy(hd[257..263], "ustar\x00");
        @memcpy(hd[263..265], "00");
        var sum: usize = 0;
        for (hd) |b| sum += b;
        putOctal(hd[148..155], sum); // six digits, NUL, then the space
        hd[154] = 0;
        hd[155] = ' ';
        try out.appendSlice(&hd);
        try out.appendSlice(e.data);
        try out.appendNTimes(0, (512 - e.data.len % 512) % 512);
    }
    try out.appendNTimes(0, 1024);
    return out.items;
}

/// A zip of stored members, dated 1980-01-01.
pub fn zip(a: Allocator, members: []const Entry) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    var central = std.ArrayList(u8).init(a);
    const w = out.writer();
    const cw = central.writer();
    for (members) |m| {
        const crc = std.hash.Crc32.hash(m.data);
        const offset: u32 = @intCast(out.items.len);
        const n: u32 = @intCast(m.data.len);
        const name_len: u16 = @intCast(m.path.len);
        try w.writeInt(u32, 0x04034b50, .little);
        try w.writeInt(u16, 20, .little); // version needed
        try w.writeInt(u16, 0, .little); // flags
        try w.writeInt(u16, 0, .little); // stored
        try w.writeInt(u16, 0, .little); // time
        try w.writeInt(u16, 0x21, .little); // date: 1980-01-01
        try w.writeInt(u32, crc, .little);
        try w.writeInt(u32, n, .little);
        try w.writeInt(u32, n, .little);
        try w.writeInt(u16, name_len, .little);
        try w.writeInt(u16, 0, .little);
        try w.writeAll(m.path);
        try w.writeAll(m.data);

        try cw.writeInt(u32, 0x02014b50, .little);
        try cw.writeInt(u16, 20, .little); // version made by
        try cw.writeInt(u16, 20, .little); // version needed
        try cw.writeInt(u16, 0, .little);
        try cw.writeInt(u16, 0, .little);
        try cw.writeInt(u16, 0, .little);
        try cw.writeInt(u16, 0x21, .little);
        try cw.writeInt(u32, crc, .little);
        try cw.writeInt(u32, n, .little);
        try cw.writeInt(u32, n, .little);
        try cw.writeInt(u16, name_len, .little);
        try cw.writeInt(u16, 0, .little); // extra
        try cw.writeInt(u16, 0, .little); // comment
        try cw.writeInt(u16, 0, .little); // disk
        try cw.writeInt(u16, 0, .little); // internal attributes
        try cw.writeInt(u32, 0, .little); // external attributes
        try cw.writeInt(u32, offset, .little);
        try cw.writeAll(m.path);
    }
    const cd_offset: u32 = @intCast(out.items.len);
    try w.writeAll(central.items);
    try w.writeInt(u32, 0x06054b50, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, @intCast(members.len), .little);
    try w.writeInt(u16, @intCast(members.len), .little);
    try w.writeInt(u32, @intCast(central.items.len), .little);
    try w.writeInt(u32, cd_offset, .little);
    try w.writeInt(u16, 0, .little);
    return out.items;
}

/// The bytes of `<name>-<version>-<build>.conda` holding `files`, with `depends` in its index.
pub fn package(a: Allocator, name: []const u8, version: []const u8, build: []const u8, subdir: []const u8, depends: []const []const u8, files: []const Entry) ![]u8 {
    const stem = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ name, version, build });
    var index = std.ArrayList(u8).init(a);
    try std.json.stringify(.{ .build = build, .build_number = 0, .depends = depends, .name = name, .subdir = subdir, .version = version }, .{}, index.writer());
    var paths = std.ArrayList(u8).init(a);
    var list = std.ArrayList(u8).init(a);
    try paths.appendSlice("{\"paths\": [");
    for (files, 0..) |f, i| {
        if (i != 0) try paths.appendSlice(", ");
        try paths.writer().print("{{\"_path\": \"{s}\", \"path_type\": \"hardlink\", \"sha256\": \"{s}\", \"size_in_bytes\": {d}}}", .{ f.path, try sha256Hex(a, f.data), f.data.len });
        try list.writer().print("{s}\n", .{f.path});
    }
    try paths.appendSlice("], \"paths_version\": 1}");
    const info = try tar(a, &.{
        .{ .path = "info/index.json", .data = index.items },
        .{ .path = "info/paths.json", .data = paths.items },
        .{ .path = "info/files", .data = list.items },
    });
    return zip(a, &.{
        .{ .path = "metadata.json", .data = "{\"conda_pkg_format_version\": 2}", .mode = 0 },
        .{ .path = try std.fmt.allocPrint(a, "info-{s}.tar.zst", .{stem}), .data = try zstdRaw(a, info), .mode = 0 },
        .{ .path = try std.fmt.allocPrint(a, "pkg-{s}.tar.zst", .{stem}), .data = try zstdRaw(a, try tar(a, files)), .mode = 0 },
    });
}

/// One package of a stand-in toolchain: where the fake serves it from (below its data directory) and its bytes.
pub const ToolchainFile = struct {
    name: []const u8,
    /// The file name, `<name>-<mojo>-fake_0.conda`.
    file_name: []const u8,
    /// Below the fake's data directory: `<channel dir>/<subdir>/<file name>`.
    served: []const u8,
    bytes: []const u8,
    sha256: []const u8,
};

pub const Toolchain = struct {
    /// The closure file, for `mopm sync --toolchain`.
    closure: []const u8,
    files: [2]ToolchainFile,
};

/// The build string of the stand-in toolchain's packages.
pub const fake_build = "fake_0";

/// The names of the stand-in toolchain's packages.
pub const fake_names = [2][]const u8{ "mojo", "mojo-compiler" };

/// The text file each stand-in toolchain package installs: `share/mopm-fake-toolchain/<name>.txt`.
pub fn markerPath(a: Allocator, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "share/mopm-fake-toolchain/{s}.txt", .{name});
}

/// Writes the stand-in toolchain for Mojo `mojo` on `subdir`: its two packages under `<fake_dir>/<channel_dir>/<subdir>/`
/// (served by the fake registry at `<base>/<channel_dir>/...`) and its closure file at `closure_path`. `channel_dir`
/// must start with `channel/` (the fake serves that tree). `variant` is written into each package's text file, so
/// another variant is other bytes; two calls with the same variant and another `channel_dir` make a mirror: the same
/// bytes, another url.
pub fn fakeToolchain(a: Allocator, fake_dir: []const u8, base: []const u8, channel_dir: []const u8, subdir: []const u8, mojo: []const u8, closure_path: []const u8, variant: []const u8) !Toolchain {
    var files: [2]ToolchainFile = undefined;
    var pkgs = std.ArrayList(u8).init(a);
    for (fake_names, 0..) |name, i| {
        const marker = try markerPath(a, name);
        const bytes = try package(a, name, mojo, fake_build, subdir, &.{}, &.{.{ .path = marker, .data = try std.fmt.allocPrint(a, "{s} {s} ({s}), a stand-in of the toolchain for the tests\n", .{ name, mojo, variant }) }});
        const file_name = try std.fmt.allocPrint(a, "{s}-{s}-{s}.conda", .{ name, mojo, fake_build });
        const served = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ channel_dir, subdir, file_name });
        const full = try std.fs.path.join(a, &.{ fake_dir, served });
        try std.fs.cwd().makePath(std.fs.path.dirname(full).?);
        try std.fs.cwd().writeFile(full, bytes);
        const sha = try sha256Hex(a, bytes);
        files[i] = .{ .name = name, .file_name = file_name, .served = served, .bytes = bytes, .sha256 = sha };
        if (i != 0) try pkgs.appendSlice(",\n");
        try pkgs.writer().print(
            \\    {{"name": "{s}", "version": "{s}", "build": "{s}", "build_number": 0, "subdir": "{s}", "channel": "fake", "path": "{s}/{s}", "sha256": "{s}", "size": {d}}}
        , .{ name, mojo, fake_build, subdir, subdir, file_name, sha, bytes.len });
    }
    const text = try std.fmt.allocPrint(a,
        \\{{"format": 1, "mojo": "{s}", "subdir": "{s}",
        \\  "channels": [{{"name": "fake", "url": "{s}/{s}/"}}],
        \\  "packages": [
        \\{s}
        \\  ]}}
        \\
    , .{ mojo, subdir, base, channel_dir, pkgs.items });
    if (std.fs.path.dirname(closure_path)) |d| try std.fs.cwd().makePath(d);
    try std.fs.cwd().writeFile(closure_path, text);
    return .{ .closure = closure_path, .files = files };
}

/// The conda subdir of the machine the driver runs on.
pub fn hostSubdir() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => "osx-arm64",
        else => switch (builtin.cpu.arch) {
            .aarch64 => "linux-aarch64",
            else => "linux-64",
        },
    };
}
