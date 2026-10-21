//! Installs the pinned actionlint for the `lint` workflow: downloads the release tarball, REFUSES (unpacking
//! nothing) unless its sha256 is the one pinned here, unpacks it into <dir> and prints the path of the binary.
//!
//!   zig run tools/install_actionlint.zig -- <dir>
//!
//! The version and the sha256 are the ones buildrules pins (rules/pins/pins.bzl, "actionlint"), which the Buck2
//! target //:actionlint runs on the farm; keep the two in step. No third-party action and no shell are involved.

const std = @import("std");
const Allocator = std.mem.Allocator;

const version = "1.7.12";
const url = "https://github.com/rhysd/actionlint/releases/download/v" ++ version ++ "/actionlint_" ++ version ++ "_linux_amd64.tar.gz";
const sha256_hex = "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8";
/// The real tarball is 2.3 MB.
const max_bytes: usize = 16 << 20;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("install_actionlint: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn download(a: Allocator) ![]u8 {
    var client = std.http.Client{ .allocator = a };
    defer client.deinit();
    const uri = try std.Uri.parse(url);
    var header_buf: [16 * 1024]u8 = undefined;
    var req = try client.open(.GET, uri, .{
        .server_header_buffer = &header_buf,
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "mopm-lint" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = @intFromEnum(req.response.status);
    if (status < 200 or status >= 300) {
        std.debug.print("install_actionlint: {s} answered HTTP {d}\n", .{ url, status });
        return error.BadStatus;
    }
    return try req.reader().readAllAlloc(a, max_bytes);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 2) die("usage: install_actionlint <dir>", .{});

    const bytes = download(a) catch |e| die("cannot download {s}: {s}", .{ url, @errorName(e) });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, sha256_hex)) die("the download has sha256 {s}, not the pinned {s}; refusing to unpack it", .{ &hex, sha256_hex });

    const cwd = std.fs.cwd();
    try cwd.makePath(args[1]);
    var dir = try cwd.openDir(args[1], .{});
    defer dir.close();
    var fbs = std.io.fixedBufferStream(bytes);
    var gz = std.compress.gzip.decompressor(fbs.reader());
    try std.tar.pipeToFileSystem(dir, gz.reader(), .{});
    const bin = try std.fs.path.join(a, &.{ args[1], "actionlint" });
    const f = try cwd.openFile(bin, .{});
    defer f.close();
    try f.chmod(0o755);
    try std.io.getStdOut().writer().print("{s}\n", .{try cwd.realpathAlloc(a, bin)});
}
