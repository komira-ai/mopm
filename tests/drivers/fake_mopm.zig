//! A stand-in for a released mopm, for install_script_test.zig: `--version` prints
//! `mopm $FAKE_MOPM_VERSION`. The installer runs the binary it unpacked with the environment it
//! was started with, so the test picks what the "release" reports.

const std = @import("std");

pub fn main() !void {
    var args = std.process.args();
    _ = args.skip();
    const first = args.next() orelse std.process.exit(2);
    if (!std.mem.eql(u8, first, "--version")) std.process.exit(2);
    const v = std.posix.getenv("FAKE_MOPM_VERSION") orelse "0.0.0";
    try std.io.getStdOut().writer().print("mopm {s}\n", .{v});
}
