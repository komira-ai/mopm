//! macho_minos: the lowest macOS a Mach-O file says it runs on, and a refusal when that is above a limit.
//!
//! Usage: macho_minos --max <major.minor[.patch]> <file>...
//!
//! It reads the file's own load commands (LC_BUILD_VERSION, or LC_VERSION_MIN_MACOSX in an older linker's output), the same field
//! `otool -l` and `vtool -show` print as `minos`, so it runs on any host and needs no Apple tool. A universal file is checked
//! slice by slice and counts as its highest slice. A file that is not a Mach-O, or that names no macOS version, fails: a binary
//! the check cannot read is not a binary it has cleared. Exit status 0 when every file is at or below the limit, 1 otherwise.
//!
//! The version words are the Mach-O encoding, major in the high 16 bits, minor in the next 8, patch in the last 8, so
//! comparing two words as integers compares the versions.

const std = @import("std");

const mh_magic_64: u32 = 0xfeedfacf;
const fat_magic: u32 = 0xcafebabe;
const lc_version_min_macosx: u32 = 0x24;
const lc_build_version: u32 = 0x32;
const platform_macos: u32 = 1;

pub const Error = error{ NotMachO, Truncated, NoMacosVersion, BadVersion };

/// "14", "14.0" or "14.0.1" as a Mach-O version word.
pub fn parseVersion(s: []const u8) Error!u32 {
    var word: u32 = 0;
    var parts: u32 = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| : (parts += 1) {
        if (parts == 3 or p.len == 0) return error.BadVersion;
        const n = std.fmt.parseInt(u32, p, 10) catch return error.BadVersion;
        if (parts == 0) {
            if (n > 0xffff) return error.BadVersion;
            word = n << 16;
        } else {
            if (n > 0xff) return error.BadVersion;
            const shift: u5 = if (parts == 1) 8 else 0;
            word |= n << shift;
        }
    }
    return word;
}

pub fn format(buf: []u8, word: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}", .{ word >> 16, (word >> 8) & 0xff, word & 0xff }) catch buf[0..0];
}

fn rd(bytes: []const u8, at: usize, comptime endian: std.builtin.Endian) Error!u32 {
    if (at > bytes.len or bytes.len - at < 4) return error.Truncated;
    return std.mem.readInt(u32, bytes[at..][0..4], endian);
}

fn thin(bytes: []const u8) Error!u32 {
    if ((try rd(bytes, 0, .little)) != mh_magic_64) return error.NotMachO;
    const ncmds = try rd(bytes, 16, .little);
    var at: usize = 32;
    var found: ?u32 = null;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        const cmd = try rd(bytes, at, .little);
        const size = try rd(bytes, at + 4, .little);
        if (size < 8) return error.Truncated;
        if (cmd == lc_build_version) {
            if ((try rd(bytes, at + 8, .little)) == platform_macos) {
                const v = try rd(bytes, at + 12, .little);
                if (found == null or v > found.?) found = v;
            }
        } else if (cmd == lc_version_min_macosx) {
            const v = try rd(bytes, at + 8, .little);
            if (found == null or v > found.?) found = v;
        }
        at += size;
    }
    return found orelse error.NoMacosVersion;
}

/// The minimum macOS of a Mach-O file, thin or universal (the highest of its slices).
pub fn minosOf(bytes: []const u8) Error!u32 {
    if ((try rd(bytes, 0, .big)) != fat_magic) return thin(bytes);
    const n = try rd(bytes, 4, .big);
    if (n == 0) return error.NotMachO;
    var best: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const entry = 8 + @as(usize, i) * 20;
        const off = try rd(bytes, entry + 8, .big);
        const len = try rd(bytes, entry + 12, .big);
        if (off > bytes.len or bytes.len - off < len) return error.Truncated;
        const v = try thin(bytes[off..][0..len]);
        if (v > best) best = v;
    }
    return best;
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 4 or !std.mem.eql(u8, args[1], "--max")) {
        std.debug.print("usage: macho_minos --max <major.minor[.patch]> <file>...\n", .{});
        std.process.exit(2);
    }
    const max = parseVersion(args[2]) catch {
        std.debug.print("macho_minos: '{s}' is not a version (major.minor[.patch])\n", .{args[2]});
        std.process.exit(2);
    };
    var vbuf: [32]u8 = undefined;
    var mbuf: [32]u8 = undefined;
    var red = false;
    for (args[3..]) |path| {
        const bytes = std.fs.cwd().readFileAlloc(a, path, 1 << 30) catch |e| {
            std.debug.print("macho_minos: {s}: cannot read it: {s}\n", .{ path, @errorName(e) });
            red = true;
            continue;
        };
        const got = minosOf(bytes) catch |e| {
            std.debug.print("macho_minos: {s}: {s} (not a Mach-O that names a macOS version)\n", .{ path, @errorName(e) });
            red = true;
            continue;
        };
        const ok = got <= max;
        std.debug.print("macho_minos: {s}: minos {s}, limit {s}: {s}\n", .{ path, format(&vbuf, got), format(&mbuf, max), if (ok) "ok" else "ABOVE THE LIMIT" });
        if (!ok) red = true;
    }
    if (red) std.process.exit(1);
}

// ---- tests: Mach-O files made byte by byte ------------------------------------------------------------------------------

const le = std.builtin.Endian.little;
const be = std.builtin.Endian.big;

/// A thin arm64 Mach-O with the given load commands (each already encoded), into `out`; returns its length.
fn makeThin(out: []u8, cmds: []const []const u8) usize {
    @memset(out, 0);
    std.mem.writeInt(u32, out[0..4], mh_magic_64, le);
    std.mem.writeInt(u32, out[16..20], @intCast(cmds.len), le);
    var at: usize = 32;
    for (cmds) |c| {
        @memcpy(out[at..][0..c.len], c);
        at += c.len;
    }
    std.mem.writeInt(u32, out[20..24], @intCast(at - 32), le);
    return at;
}

fn buildVersion(out: *[24]u8, platform: u32, minos: u32) []const u8 {
    std.mem.writeInt(u32, out[0..4], lc_build_version, le);
    std.mem.writeInt(u32, out[4..8], 24, le);
    std.mem.writeInt(u32, out[8..12], platform, le);
    std.mem.writeInt(u32, out[12..16], minos, le);
    std.mem.writeInt(u32, out[16..20], 0, le);
    std.mem.writeInt(u32, out[20..24], 0, le);
    return out[0..];
}

test "parseVersion reads major, major.minor and major.minor.patch, and refuses the rest" {
    try std.testing.expectEqual(@as(u32, 14 << 16), try parseVersion("14"));
    try std.testing.expectEqual(@as(u32, (14 << 16) | (2 << 8)), try parseVersion("14.2"));
    try std.testing.expectEqual(@as(u32, (11 << 16) | (7 << 8) | 1), try parseVersion("11.7.1"));
    // "13.0" and "13.0.0" are one version, and 11.7.10 is above 11.7.1 (a version is numbers, not text).
    try std.testing.expectEqual(try parseVersion("13.0"), try parseVersion("13.0.0"));
    try std.testing.expect((try parseVersion("11.7.10")) > (try parseVersion("11.7.1")));
    for ([_][]const u8{ "", ".", "14.", ".5", "14.0" ++ ".0.0", "x", "14.x", "14.256", "70000.0" }) |bad| {
        try std.testing.expectError(error.BadVersion, parseVersion(bad));
    }
}

test "LC_BUILD_VERSION: the minos is read, and 14.0 is below 15.0" {
    var f: [128]u8 = undefined;
    var c: [24]u8 = undefined;
    const n = makeThin(&f, &.{buildVersion(&c, platform_macos, 15 << 16)});
    try std.testing.expectEqual(@as(u32, 15 << 16), try minosOf(f[0..n]));
    try std.testing.expect((try minosOf(f[0..n])) > (try parseVersion("14.0")));
    const m = makeThin(&f, &.{buildVersion(&c, platform_macos, 14 << 16)});
    try std.testing.expect((try minosOf(f[0..m])) <= (try parseVersion("14.0")));
    // 11.7.10 is above 11.7.1.
    const q = makeThin(&f, &.{buildVersion(&c, platform_macos, (11 << 16) | (7 << 8) | 10)});
    try std.testing.expect((try minosOf(f[0..q])) > (try parseVersion("11.7.1")));
    // One patch level above the limit is above it.
    const p = makeThin(&f, &.{buildVersion(&c, platform_macos, (14 << 16) | 1)});
    try std.testing.expect((try minosOf(f[0..p])) > (try parseVersion("14.0")));
}

test "LC_VERSION_MIN_MACOSX is read when there is no LC_BUILD_VERSION" {
    var f: [128]u8 = undefined;
    var c: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u32, c[0..4], lc_version_min_macosx, le);
    std.mem.writeInt(u32, c[4..8], 16, le);
    std.mem.writeInt(u32, c[8..12], (11 << 16), le);
    const n = makeThin(&f, &.{c[0..]});
    try std.testing.expectEqual(@as(u32, 11 << 16), try minosOf(f[0..n]));
}

test "a command that is not a version is stepped over; another platform's version is not the macOS one" {
    var f: [160]u8 = undefined;
    var other: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u32, other[0..4], 0x19, le); // LC_SEGMENT_64's number, any other command will do
    std.mem.writeInt(u32, other[4..8], 16, le);
    var ios: [24]u8 = undefined;
    var mac: [24]u8 = undefined;
    const n = makeThin(&f, &.{ other[0..], buildVersion(&ios, 2, 99 << 16), buildVersion(&mac, platform_macos, 13 << 16) });
    try std.testing.expectEqual(@as(u32, 13 << 16), try minosOf(f[0..n]));
}

test "a Mach-O without a macOS version, a truncated one and a file of another kind are refused" {
    var f: [128]u8 = undefined;
    const n = makeThin(&f, &.{});
    try std.testing.expectError(error.NoMacosVersion, minosOf(f[0..n]));
    var c: [24]u8 = undefined;
    const m = makeThin(&f, &.{buildVersion(&c, 2, 17 << 16)});
    try std.testing.expectError(error.NoMacosVersion, minosOf(f[0..m]));
    const k = makeThin(&f, &.{buildVersion(&c, platform_macos, 14 << 16)});
    try std.testing.expectError(error.Truncated, minosOf(f[0 .. k - 16]));
    try std.testing.expectError(error.NotMachO, minosOf("\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00"));
    try std.testing.expectError(error.Truncated, minosOf("ab"));
}

test "a universal file counts as its highest slice" {
    var a_: [96]u8 = undefined;
    var b_: [96]u8 = undefined;
    var c: [24]u8 = undefined;
    const na = makeThin(&a_, &.{buildVersion(&c, platform_macos, 11 << 16)});
    const nb = makeThin(&b_, &.{buildVersion(&c, platform_macos, 15 << 16)});
    var u: [8 + 40 + 96 + 96]u8 = .{0} ** (8 + 40 + 96 + 96);
    std.mem.writeInt(u32, u[0..4], fat_magic, be);
    std.mem.writeInt(u32, u[4..8], 2, be);
    std.mem.writeInt(u32, u[8 + 8 ..][0..4], 48, be);
    std.mem.writeInt(u32, u[8 + 12 ..][0..4], @intCast(na), be);
    std.mem.writeInt(u32, u[28 + 8 ..][0..4], 48 + 96, be);
    std.mem.writeInt(u32, u[28 + 12 ..][0..4], @intCast(nb), be);
    @memcpy(u[48..][0..na], a_[0..na]);
    @memcpy(u[48 + 96 ..][0..nb], b_[0..nb]);
    try std.testing.expectEqual(@as(u32, 15 << 16), try minosOf(&u));
    // A universal header that lists no slice is not a Mach-O.
    var empty: [8]u8 = .{0} ** 8;
    std.mem.writeInt(u32, empty[0..4], fat_magic, be);
    try std.testing.expectError(error.NotMachO, minosOf(&empty));
    // A slice that runs past the end of the file is refused.
    std.mem.writeInt(u32, u[28 + 12 ..][0..4], 4096, be);
    try std.testing.expectError(error.Truncated, minosOf(&u));
}

test "format spells the three fields" {
    var b: [32]u8 = undefined;
    try std.testing.expectEqualStrings("14.2.1", format(&b, (14 << 16) | (2 << 8) | 1));
}
