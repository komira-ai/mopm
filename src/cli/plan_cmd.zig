//! `mopm plan --unit-graph --locked`: the unit graph of the project in the
//! current directory, as JSON (spec/unit-graph.md), made from mopm.toml,
//! mopm.lock and the member sources. It never resolves and never touches the
//! network: a lock that does not match mopm.toml is refused, not repaired.
//!
//! Exit status: 0 the graph was printed; 1 any other failure; 2 a usage
//! error; 3 there is no usable lock, or it is out of date with mopm.toml
//! (`mopm lock` makes a new one); 4 the graph cannot be made from this
//! project and lock (a toolchain mopm does not pin, a native library without
//! sha256, a member outside the workspace, a missing source).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const install_cmd = @import("install_cmd.zig");

pub const exit_usage: u8 = 2;
pub const exit_stale: u8 = 3;
pub const exit_refused: u8 = 4;

pub const usage =
    \\usage: mopm plan --unit-graph --locked [--mojo <version>] [--subdir <linux-64>] [-o <file>]
    \\
    \\  print the unit graph (spec/unit-graph.md) of the project in this directory,
    \\  for one consumer Mojo version: --mojo, or the only one mopm.toml lists;
    \\  --locked is required: plan reads mopm.lock and never resolves or fetches
    \\
;

pub const Args = struct {
    unit_graph: bool = false,
    locked: bool = false,
    subdir: []const u8 = "linux-64",
    out: ?[]const u8 = null,
    mojo: ?[]const u8 = null,
};

/// The options of `plan`; null on a usage error.
pub fn parseArgs(args: []const []const u8) ?Args {
    var a = Args{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--unit-graph")) {
            a.unit_graph = true;
        } else if (std.mem.eql(u8, arg, "--locked")) {
            a.locked = true;
        } else if (std.mem.eql(u8, arg, "--subdir") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--mojo")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return null;
            i += 1;
            if (std.mem.eql(u8, arg, "-o")) {
                a.out = args[i];
            } else if (std.mem.eql(u8, arg, "--mojo")) {
                a.mojo = args[i];
            } else a.subdir = args[i];
        } else return null;
    }
    if (!a.unit_graph or !a.locked) return null;
    return a;
}

fn say(comptime fmt: []const u8, args: anytype) void {
    const w = std.io.getStdErr().writer();
    w.print("mopm plan: " ++ fmt, args) catch {};
}

pub fn main(arena: Allocator, args: []const []const u8) u8 {
    const a = parseArgs(args) orelse {
        std.io.getStdErr().writeAll(usage) catch {};
        return exit_usage;
    };
    return run(arena, a) catch |e| {
        say("{s}\n", .{@errorName(e)});
        return 1;
    };
}

fn run(arena: Allocator, a: Args) !u8 {
    const project = (try install_cmd.readProject(arena, .plan)) orelse return 1;
    if (project.m.mojo.len == 0) {
        say("mopm.toml has no mojo versions ([package] mojo); a unit graph is made for one compiler\n", .{});
        return 1;
    }
    const old = install_cmd.readLock(arena, .plan) catch |e| {
        if (e == error.Invalid) return exit_stale;
        return e;
    };
    const l = old orelse {
        say("there is no mopm.lock; run 'mopm lock' (plan never resolves)\n", .{});
        return exit_stale;
    };
    if (project.m.mojo_all and l.mojos.len == 0) {
        say("mopm.lock is a version 1 lock, and mopm.toml lists [package] mojo; run 'mopm lock'\n", .{});
        return exit_stale;
    }
    if (try core.install.staleness(arena, project.m.mojo, project.roots, project.paths, l)) |why| {
        say("mopm.lock is out of date with mopm.toml: {s}; run 'mopm lock'\n", .{why});
        return exit_stale;
    }
    const mojo = a.mojo orelse blk: {
        if (project.m.mojo.len == 1) break :blk project.m.mojo[0];
        const all = try std.mem.join(arena, ", ", project.m.mojo);
        say("mopm.toml lists several mojo versions ({s}); pass --mojo <version>\n", .{all});
        return exit_usage;
    };
    var why: []const u8 = "";
    const graph = core.unit_graph.build(arena, .{
        .dir = ".",
        .m = project.m,
        .members = project.paths,
        .l = l,
        .subdir = a.subdir,
        .mojo = mojo,
    }, &why) catch |e| {
        if (e == error.Refused) {
            std.io.getStdErr().writer().print("error: {s}\n", .{why}) catch {};
            return exit_refused;
        }
        return e;
    };
    const text = try core.unit_graph.render(arena, graph);
    if (a.out) |path| {
        try std.fs.cwd().writeFile(path, text);
    } else {
        try std.io.getStdOut().writeAll(text);
    }
    return 0;
}

test "plan needs --unit-graph and --locked" {
    try std.testing.expect(parseArgs(&.{}) == null);
    try std.testing.expect(parseArgs(&.{"--unit-graph"}) == null);
    try std.testing.expect(parseArgs(&.{"--locked"}) == null);
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked", "--frob" }) == null);
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked", "-o" }) == null);
    const a = parseArgs(&.{ "--locked", "--unit-graph", "--subdir", "linux-aarch64", "-o", "g.json", "--mojo", "1.0.0" }).?;
    try std.testing.expectEqualStrings("1.0.0", a.mojo.?);
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked", "--mojo" }) == null);
    try std.testing.expectEqualStrings("linux-aarch64", a.subdir);
    try std.testing.expectEqualStrings("g.json", a.out.?);
    try std.testing.expectEqualStrings("linux-64", parseArgs(&.{ "--unit-graph", "--locked" }).?.subdir);
}
