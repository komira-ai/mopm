//! A stand-in for pixi, for install_e2e_test.zig: the build farm has no pixi
//! and no network. `mopm sync` runs `pixi install --manifest-path
//! .mopm/pixi.toml`; this program does what mopm relies on pixi for, for the
//! packages mopm pins (the `mojo-<name> = { version, build, sha256 }` lines):
//!
//!   * finds <name>-<version>-<build>.conda in the first channel of the
//!     manifest (the local file channel mopm wrote), under the platform's
//!     directory;
//!   * refuses the file unless its sha256 is the pinned one (pixi refuses a
//!     file that differs from its repodata entry; mopm writes the pin there);
//!   * unpacks the conda archive (a zip holding info-*.tar.zst and
//!     pkg-*.tar.zst) into <manifest dir>/.pixi/envs/default, and writes
//!     conda-meta/<name>-<version>-<build>.json with the file's sha256, as pixi
//!     does.
//!
//! The `mojo` and `mojo-compiler` dependencies are not installed: the driver
//! lays the Mojo toolchain into the environment itself. The zstd it reads is
//! raw blocks (RFC 8878), in the frame header form install_e2e_test.zig writes or
//! the one `mopm pack` writes, nothing else. Exit status 0 on success, 1 with a
//! message if a pin is not met.

const std = @import("std");
const Allocator = std.mem.Allocator;

fn die(comptime f: []const u8, args: anytype) noreturn {
    std.debug.print("fake pixi: " ++ f ++ "\n", args);
    std.process.exit(1);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 4 or !std.mem.eql(u8, args[1], "install") or !std.mem.eql(u8, args[2], "--manifest-path")) {
        die("usage: pixi install --manifest-path <pixi.toml>", .{});
    }
    const manifest_path = args[3];
    const cwd = std.fs.cwd();
    const text = cwd.readFileAlloc(a, manifest_path, 1 << 20) catch |e| die("cannot read {s}: {s}", .{ manifest_path, @errorName(e) });
    const dir = std.fs.path.dirname(manifest_path) orelse ".";
    const env = try std.fmt.allocPrint(a, "{s}/.pixi/envs/default", .{dir});
    try cwd.makePath(env);

    const channel = try firstChannel(a, text);
    const platform = try firstString(a, text, "platforms = [");
    var lines = std.mem.splitScalar(u8, text, '\n');
    var installed: usize = 0;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "mojo-") or std.mem.startsWith(u8, line, "mojo-compiler")) continue;
        const eq = std.mem.indexOf(u8, line, " = {") orelse continue;
        const name = line[0..eq];
        const version = std.mem.trimLeft(u8, try fieldOf(a, line, "version"), "=");
        const build = try fieldOf(a, line, "build");
        const pin = try fieldOf(a, line, "sha256");
        const stem = try std.fmt.allocPrint(a, "{s}-{s}-{s}", .{ name, version, build });
        const file = try std.fmt.allocPrint(a, "{s}/{s}/{s}.conda", .{ channel, platform, stem });
        const bytes = cwd.readFileAlloc(a, file, 1 << 30) catch |e| die("{s}: cannot read {s}: {s}", .{ name, file, @errorName(e) });
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        const got = try std.fmt.allocPrint(a, "{s}", .{std.fmt.fmtSliceHexLower(&digest)});
        if (!std.mem.eql(u8, got, pin)) die("{s}: sha256 of {s} is {s}, the manifest pins {s}", .{ name, file, got, pin });
        try unpack(a, bytes, env, stem);
        const record = try std.fmt.allocPrint(a, "{{\"name\":\"{s}\",\"version\":\"{s}\",\"build\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}\n", .{ name, version, build, got, bytes.len });
        try cwd.makePath(try std.fmt.allocPrint(a, "{s}/conda-meta", .{env}));
        try cwd.writeFile(try std.fmt.allocPrint(a, "{s}/conda-meta/{s}.json", .{ env, stem }), record);
        installed += 1;
    }
    std.debug.print("fake pixi: installed {d} packages into {s}\n", .{ installed, env });
}

/// The first quoted string of the line that starts with `prefix`.
fn firstString(a: Allocator, text: []const u8, prefix: []const u8) ![]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |l| {
        if (!std.mem.startsWith(u8, l, prefix)) continue;
        const open = std.mem.indexOfScalarPos(u8, l, prefix.len, '"') orelse continue;
        const close = std.mem.indexOfScalarPos(u8, l, open + 1, '"') orelse continue;
        return a.dupe(u8, l[open + 1 .. close]);
    }
    die("no `{s}` line in the manifest", .{prefix});
}

/// The local channel's directory: the first channel is a file URL.
fn firstChannel(a: Allocator, text: []const u8) ![]const u8 {
    const url = try firstString(a, text, "channels = [");
    const scheme = "file://";
    if (!std.mem.startsWith(u8, url, scheme)) die("the first channel {s} is not a file URL", .{url});
    var out = std.ArrayList(u8).init(a);
    var i: usize = scheme.len;
    while (i < url.len) : (i += 1) {
        if (url[i] == '%' and i + 2 < url.len) {
            try out.append(try std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16));
            i += 2;
        } else try out.append(url[i]);
    }
    while (out.items.len > 1 and out.items[out.items.len - 1] == '/') _ = out.pop();
    return out.items;
}

/// The value of `key = "..."` inside the inline table on `line`.
fn fieldOf(a: Allocator, line: []const u8, key: []const u8) ![]const u8 {
    const needle = try std.fmt.allocPrint(a, "{s} = \"", .{key});
    const at = std.mem.indexOf(u8, line, needle) orelse die("no {s} in `{s}`", .{ key, line });
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, line, start, '"') orelse die("unterminated {s} in `{s}`", .{ key, line });
    return line[start..end];
}

// ------------------------------------------------------------- the archive

fn le(comptime T: type, b: []const u8) T {
    return std.mem.readInt(T, b[0..@sizeOf(T)], .little);
}

/// Unpacks the pkg-*.tar.zst member of the conda zip `zip` into `env`.
fn unpack(a: Allocator, zip: []const u8, env: []const u8, stem: []const u8) !void {
    // End of central directory: the last 22 bytes (no comment).
    if (zip.len < 22 or le(u32, zip[zip.len - 22 ..]) != 0x06054b50) die("{s}: not a zip (no end of central directory)", .{stem});
    const entries = le(u16, zip[zip.len - 22 + 10 ..]);
    var cd: usize = le(u32, zip[zip.len - 22 + 16 ..]);
    var found = false;
    var n: usize = 0;
    while (n < entries) : (n += 1) {
        if (le(u32, zip[cd..]) != 0x02014b50) die("{s}: bad central directory", .{stem});
        const method = le(u16, zip[cd + 10 ..]);
        const csize = le(u32, zip[cd + 20 ..]);
        const name_len = le(u16, zip[cd + 28 ..]);
        const extra_len = le(u16, zip[cd + 30 ..]);
        const comment_len = le(u16, zip[cd + 32 ..]);
        const local = le(u32, zip[cd + 42 ..]);
        const name = zip[cd + 46 ..][0..name_len];
        cd += 46 + name_len + extra_len + comment_len;
        if (!std.mem.startsWith(u8, name, "pkg-") or !std.mem.endsWith(u8, name, ".tar.zst")) continue;
        if (method != 0) die("{s}: {s} is compressed (method {d}); only stored members are read", .{ stem, name, method });
        const lname = le(u16, zip[local + 26 ..]);
        const lextra = le(u16, zip[local + 28 ..]);
        const body = zip[local + 30 + lname + lextra ..][0..csize];
        const tar = try unzstd(a, body);
        try untar(a, tar, env);
        found = true;
    }
    if (!found) die("{s}: no pkg-*.tar.zst member", .{stem});
}

/// A zstd frame of raw blocks, decoded.
fn unzstd(a: Allocator, f: []const u8) ![]u8 {
    if (f.len < 6 or le(u32, f) != 0xFD2FB528) die("not a zstd frame", .{});
    const fhd = f[4];
    // Two header forms, both of raw blocks: the plain one (no size, checksum or dictionary; a window descriptor),
    // which install_e2e_test.zig writes, and the single-segment one with an 8-byte content size, which `mopm pack` writes.
    var i: usize = switch (fhd) {
        0x00 => 6, // magic, descriptor, window descriptor
        0xE0 => 13, // magic, descriptor, the content size
        else => die("zstd frame header {x}: only the plain and the single-segment, 8-byte-size forms are read", .{fhd}),
    };
    var out = std.ArrayList(u8).init(a);
    while (true) {
        const hdr = @as(u32, f[i]) | @as(u32, f[i + 1]) << 8 | @as(u32, f[i + 2]) << 16;
        i += 3;
        const last = hdr & 1 == 1;
        const kind = (hdr >> 1) & 3;
        const size = hdr >> 3;
        if (kind != 0) die("zstd block type {d}: only raw blocks are read", .{kind});
        try out.appendSlice(f[i..][0..size]);
        i += size;
        if (last) break;
    }
    return out.items;
}

fn octal(field: []const u8) !usize {
    const t = std.mem.trim(u8, field, " \x00");
    if (t.len == 0) return 0;
    return std.fmt.parseInt(usize, t, 8);
}

/// Extracts the regular files of a ustar archive under `env`.
fn untar(a: Allocator, tar: []const u8, env: []const u8) !void {
    const cwd = std.fs.cwd();
    var i: usize = 0;
    while (i + 512 <= tar.len) {
        const h = tar[i..][0..512];
        if (std.mem.allEqual(u8, h, 0)) break;
        const name = h[0 .. std.mem.indexOfScalar(u8, h[0..100], 0) orelse 100];
        const mode = try octal(h[100..108]);
        const size = try octal(h[124..136]);
        const kind = h[156];
        i += 512;
        if (kind == '0' or kind == 0) {
            if (std.mem.startsWith(u8, name, "/") or std.mem.indexOf(u8, name, "..") != null) die("unsafe path {s} in the archive", .{name});
            const dest = try std.fmt.allocPrint(a, "{s}/{s}", .{ env, name });
            try cwd.makePath(std.fs.path.dirname(dest).?);
            const f = try cwd.createFile(dest, .{ .truncate = true, .mode = @intCast(mode & 0o777) });
            defer f.close();
            try f.writeAll(tar[i..][0..size]);
        }
        i += (size + 511) / 512 * 512;
    }
}
