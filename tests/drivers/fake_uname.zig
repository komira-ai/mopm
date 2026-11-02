//! A `uname` for install_script_test.zig to put first on the installer's PATH: `-s` prints
//! $FAKE_OS and `-m` prints $FAKE_ARCH; anything else runs the real /usr/bin/uname.

const std = @import("std");

pub fn main() !void {
    const a = std.heap.page_allocator;
    const argv = try std.process.argsAlloc(a);
    const out = std.io.getStdOut().writer();
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "-s")) {
        try out.print("{s}\n", .{std.posix.getenv("FAKE_OS") orelse ""});
        return;
    }
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "-m")) {
        try out.print("{s}\n", .{std.posix.getenv("FAKE_ARCH") orelse ""});
        return;
    }
    var real = std.ArrayList([]const u8).init(a);
    try real.append("/usr/bin/uname");
    try real.appendSlice(argv[1..]);
    return std.process.execv(a, real.items);
}
