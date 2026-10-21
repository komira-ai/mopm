//! Installs the pinned OSV-Scanner for the `advisories` workflow: downloads the release binary, REFUSES (writing
//! nothing) unless its sha256 is the one pinned here, writes it into <dir> as an executable and prints its path.
//!
//!   zig run tools/install_osv_scanner.zig -- <dir>
//!
//! The same shape as tools/install_actionlint.zig: the release is named by an exact version, the digest is a constant of
//! this file (the release's own osv-scanner_SHA256SUMS lists the same value), and no third-party action and no shell
//! are involved. A new release is taken by changing `version` and `sha256_hex` together in a reviewed change.
//! tests/drivers/workflow_lint.zig holds this file to that shape.

const std = @import("std");
const Allocator = std.mem.Allocator;

const version = "2.7.0";
const url = "https://github.com/google/osv-scanner/releases/download/v" ++ version ++ "/osv-scanner_linux_amd64";
const sha256_hex = "160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b";
/// The real binary is 58 MB.
const max_bytes: usize = 128 << 20;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("install_osv_scanner: " ++ fmt ++ "\n", args);
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
            .user_agent = .{ .override = "mopm-advisories" },
            .accept_encoding = .{ .override = "identity" },
        },
    });
    defer req.deinit();
    try req.send();
    try req.finish();
    try req.wait();
    const status = @intFromEnum(req.response.status);
    if (status < 200 or status >= 300) {
        std.debug.print("install_osv_scanner: {s} answered HTTP {d}\n", .{ url, status });
        return error.BadStatus;
    }
    return try req.reader().readAllAlloc(a, max_bytes);
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 2) die("usage: install_osv_scanner <dir>", .{});

    const bytes = download(a) catch |e| die("cannot download {s}: {s}", .{ url, @errorName(e) });
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, sha256_hex)) die("the download has sha256 {s}, not the pinned {s}; refusing to install it", .{ &hex, sha256_hex });

    const cwd = std.fs.cwd();
    try cwd.makePath(args[1]);
    var dir = try cwd.openDir(args[1], .{});
    defer dir.close();
    const f = try dir.createFile("osv-scanner", .{ .mode = 0o755 });
    defer f.close();
    try f.writeAll(bytes);
    const bin = try std.fs.path.join(a, &.{ args[1], "osv-scanner" });
    try std.io.getStdOut().writer().print("{s}\n", .{try cwd.realpathAlloc(a, bin)});
}
