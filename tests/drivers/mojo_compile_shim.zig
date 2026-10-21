//! `mojo_compile` for the drivers that run `mopm unit build` and `mopm unit test` against a real Mojo
//! (native_static_test.zig): the wrapper spec/unit-graph.md ("Running a unit") describes, cut down to what such a test
//! needs. The real wrapper is a buildrules program that owns the closure check, the environment, zig as `cc`, the
//! run path rules and the watchdog; this one only turns the command mopm gives into a compiler run.
//!
//! mopm starts `<toolchain>/mojo_compile` with an empty environment and the arguments
//!
//!     [--runpath=<value>] --source-root=<root> -- <mojo arguments>
//!
//! This program reads `mojo_compile.conf` beside itself (one `key=value` per line: `mojo=` the compiler to run,
//! `log=` a file that gets one line per run, `env.<NAME>=` the environment to give it), runs the compiler from
//! the parent of `<root>` with every argument that is `<root>` named by its base name (so a `.mojoc` records
//! `<package>/<file>.mojo`, never a staged path, as the real wrapper does), and returns its exit status. The
//! run path option is accepted and ignored: a test run by `mopm unit test` is given `LD_LIBRARY_PATH` for the
//! compiler's runtime.

const std = @import("std");

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const self_dir = try std.fs.selfExeDirPathAlloc(a);
    const conf_path = try std.fs.path.join(a, &.{ self_dir, "mojo_compile.conf" });
    const conf = std.fs.cwd().readFileAlloc(a, conf_path, 1 << 20) catch |e| {
        std.debug.print("mojo_compile: cannot read {s}: {s}\n", .{ conf_path, @errorName(e) });
        return 2;
    };
    var mojo: []const u8 = "";
    var log: []const u8 = "";
    var env = std.process.EnvMap.init(a);
    var lines = std.mem.splitScalar(u8, conf, '\n');
    while (lines.next()) |line| {
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        const value = line[eq + 1 ..];
        if (std.mem.eql(u8, key, "mojo")) {
            mojo = value;
        } else if (std.mem.eql(u8, key, "log")) {
            log = value;
        } else if (std.mem.startsWith(u8, key, "env.")) {
            try env.put(key["env.".len..], value);
        }
    }
    if (mojo.len == 0) {
        std.debug.print("mojo_compile: {s} has no mojo=\n", .{conf_path});
        return 2;
    }

    const args = try std.process.argsAlloc(a);
    var i: usize = 1;
    var root: []const u8 = "";
    while (i < args.len) : (i += 1) {
        const s = args[i];
        if (std.mem.eql(u8, s, "--")) {
            i += 1;
            break;
        }
        if (std.mem.startsWith(u8, s, "--source-root=")) {
            root = s["--source-root=".len..];
        } else if (!std.mem.startsWith(u8, s, "--runpath=")) {
            std.debug.print("mojo_compile: unexpected argument {s}\n", .{s});
            return 2;
        }
    }
    if (root.len == 0) {
        std.debug.print("mojo_compile: no --source-root=\n", .{});
        return 2;
    }
    const cwd = std.fs.path.dirname(root) orelse ".";
    var argv = std.ArrayList([]const u8).init(a);
    try argv.append(mojo);
    for (args[i..]) |s| try argv.append(if (std.mem.eql(u8, s, root)) std.fs.path.basename(root) else s);

    if (log.len > 0) {
        var f = try std.fs.cwd().createFile(log, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        const w = f.writer();
        for (argv.items, 0..) |s, k| try w.print("{s}{s}", .{ if (k == 0) "" else " ", s });
        try w.writeByte('\n');
    }

    var child = std.process.Child.init(argv.items, a);
    child.cwd = cwd;
    child.env_map = &env;
    const term = try child.spawnAndWait();
    return switch (term) {
        .Exited => |c| c,
        else => 1,
    };
}
