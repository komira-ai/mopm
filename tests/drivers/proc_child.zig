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
//!   env_to_stdout   print the environment, NAME=value per line
//!   --source-root=<dir> ...   a stand-in for the `mojo_compile` wrapper (fakeMojoCompile)
//!   (no arguments)  as a test binary built by that stand-in: writes its environment to <argv0>.env

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

/// Stands in for `mojo_compile`, the toolchain wrapper `mopm unit build` runs
/// (src/core/unit_run.zig). It does what the real wrapper does to the line
/// (tools/build/mojo/tools/compile_args.zig, `compilerArgs`): the argument that
/// names the `--source-root` directory becomes that directory's basename, so a
/// `precompile` records `p`, not the staged path. For `precompile` it writes
/// what the compiler would have been given to the file after `-o`, one argument
/// per line, then `env=<number of environment variables>`; the `-I` and `-o`
/// arguments are left out, they are absolute staged paths the real `.mojoc`
/// does not record. For `build` it makes the output a copy of this program,
/// which, run with no arguments, writes its environment to `<its own path>.env`.
fn fakeMojoCompile(a: std.mem.Allocator, args: []const [:0]u8) !void {
    var out: ?[]const u8 = null;
    var root: []const u8 = "";
    var after_dashes = false;
    var is_build = false;
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "-o") and i + 1 < args.len) out = args[i + 1];
        if (std.mem.startsWith(u8, arg, "--source-root=")) root = arg["--source-root=".len..];
        if (after_dashes and std.mem.eql(u8, arg, "build")) is_build = true;
        if (std.mem.eql(u8, arg, "--")) after_dashes = true;
    }
    const path = out orelse std.process.exit(2);
    if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
    if (is_build) {
        const me = try std.fs.selfExePathAlloc(a);
        try std.fs.cwd().copyFile(me, std.fs.cwd(), path, .{});
        return;
    }
    var text = std.ArrayList(u8).init(a);
    var past = false;
    var skip_next = false;
    for (args[1..]) |arg| {
        if (!past) {
            past = std.mem.eql(u8, arg, "--");
            continue;
        }
        if (skip_next) {
            skip_next = false;
            continue;
        }
        if (std.mem.eql(u8, arg, "-o")) {
            skip_next = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-I")) continue;
        if (root.len > 0 and std.mem.eql(u8, arg, root)) {
            try text.writer().print("{s}\n", .{std.fs.path.basename(root)});
        } else try text.writer().print("{s}\n", .{arg});
    }
    var env = try std.process.getEnvMap(a);
    try text.writer().print("env={d}\n", .{env.count()});
    try std.fs.cwd().writeFile(path, text.items);
}

/// A test binary built by the fake wrapper, run: writes the environment it
/// got, `NAME=value` per line, to `<its own path>.env`.
fn fakeTestBinary(a: std.mem.Allocator, me: []const u8) !void {
    var env = try std.process.getEnvMap(a);
    var text = std.ArrayList(u8).init(a);
    var it = env.iterator();
    while (it.next()) |e| try text.writer().print("{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
    const dest = try std.fmt.allocPrint(a, "{s}.env", .{me});
    try std.fs.cwd().writeFile(dest, text.items);
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len == 1) return fakeTestBinary(a, args[0]);
    if (args.len < 2) std.process.exit(2);
    const mode = args[1];
    if (std.mem.startsWith(u8, mode, "--source-root=") or std.mem.startsWith(u8, mode, "--runpath=")) return fakeMojoCompile(a, args);
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
    } else if (std.mem.eql(u8, mode, "env_to_stdout")) {
        var env = try std.process.getEnvMap(a);
        var it = env.iterator();
        const out = std.io.getStdOut().writer();
        while (it.next()) |e| try out.print("{s}={s}\n", .{ e.key_ptr.*, e.value_ptr.* });
    } else if (std.mem.eql(u8, mode, "exit0")) {
        // nothing
    } else {
        std.process.exit(2);
    }
}
