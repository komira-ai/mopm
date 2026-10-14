//! The child processes of the supervisor tests in src/core/test_proc.zig, as a
//! program, for hosts with no /bin/sh (the build farm's image). Each mode is
//! one of the shell scripts those tests otherwise run with `sh -c`:
//!
//!   out_err_exit3   to-out on stdout, to-err on stderr, exit 3
//!   segv, abrt      kill itself with that signal
//!   sleep <secs>    sleep (the shell's `exec sleep N`)
//!   spin            compute forever (`while :; do :; done`)
//!   bg_sleep_wait   start a `sleep 60` child in this process group, wait for it
//!   bg_sleep_exit0  start a `sleep 60` child, exit 0 without waiting
//!   exit0           exit 0

const std = @import("std");
const posix = std.posix;

// A signal must kill the process, not be caught by zig's crash handler.
pub const std_options: std.Options = .{ .enable_segfault_handler = false };

fn sleepSeconds(s: u64) void {
    std.time.sleep(s * std.time.ns_per_s);
}

/// Another copy of this program in `sleep 60` mode, same process group.
fn startSleeper(a: std.mem.Allocator) !std.process.Child {
    const me = try std.fs.selfExePathAlloc(a);
    var child = std.process.Child.init(&.{ me, "sleep", "60" }, a);
    try child.spawn();
    return child;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len < 2) std.process.exit(2);
    const mode = args[1];
    if (std.mem.eql(u8, mode, "out_err_exit3")) {
        try std.io.getStdOut().writeAll("to-out\n");
        try std.io.getStdErr().writeAll("to-err\n");
        std.process.exit(3);
    } else if (std.mem.eql(u8, mode, "segv")) {
        try posix.raise(posix.SIG.SEGV);
        sleepSeconds(60);
    } else if (std.mem.eql(u8, mode, "abrt")) {
        try posix.raise(posix.SIG.ABRT);
        sleepSeconds(60);
    } else if (std.mem.eql(u8, mode, "sleep")) {
        sleepSeconds(try std.fmt.parseInt(u64, args[2], 10));
    } else if (std.mem.eql(u8, mode, "spin")) {
        var n: u64 = 0;
        while (true) {
            n +%= 1;
            std.mem.doNotOptimizeAway(n);
        }
    } else if (std.mem.eql(u8, mode, "bg_sleep_wait")) {
        var child = try startSleeper(a);
        _ = try child.wait();
    } else if (std.mem.eql(u8, mode, "bg_sleep_exit0")) {
        _ = try startSleeper(a);
    } else if (std.mem.eql(u8, mode, "exit0")) {
        // nothing
    } else {
        std.process.exit(2);
    }
}
