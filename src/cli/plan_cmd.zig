//! `mopm plan --unit-graph --locked`: the unit graph of the project in the
//! current directory, as JSON (spec/unit-graph.md), made from mopm.toml,
//! mopm.lock and the member sources. It never resolves and never touches the
//! network: a lock that does not match mopm.toml is refused, not repaired.
//!
//! Exit status: 0 the graph was printed; 1 any other failure; 2 a usage
//! error; 3 there is no usable lock, or it is out of date with mopm.toml
//! (`mopm lock` makes a new one); 4 the graph cannot be made from this
//! project and lock (a toolchain mopm does not pin, a native library without
//! sha256, a member outside the workspace, a missing source, a --workspace-root
//! that does not exist or does not contain this directory).
//!
//! `--workspace-root DIR` makes DIR, not this directory, the workspace: every
//! path in the graph is relative to DIR, and the path dependencies (siblings of
//! this directory included) must be below DIR.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const install_cmd = @import("install_cmd.zig");

pub const exit_usage: u8 = 2;
pub const exit_stale: u8 = 3;
pub const exit_refused: u8 = 4;

pub const usage =
    \\usage: mopm plan --unit-graph --locked [--mojo <version>] [--subdir <linux-64|linux-aarch64|osx-arm64>] [--workspace-root <dir>] [-o <file>]
    \\
    \\  print the unit graph (spec/unit-graph.md) of the project in this directory,
    \\  for one consumer Mojo version: --mojo, or the only one mopm.toml lists;
    \\  --locked is required: plan reads mopm.lock and never resolves or fetches;
    \\  --workspace-root makes <dir> (an existing directory that holds this one)
    \\  the workspace: graph paths are relative to it and path dependencies,
    \\  siblings of this directory included, may be anywhere below it
    \\
;

pub const Args = struct {
    unit_graph: bool = false,
    locked: bool = false,
    subdir: []const u8 = "linux-64",
    out: ?[]const u8 = null,
    mojo: ?[]const u8 = null,
    workspace_root: ?[]const u8 = null,
};

/// True when `args` give --workspace-root without --unit-graph: the one usage error that gets a message of its own.
fn rootWithoutGraph(args: []const []const u8) bool {
    var root = false;
    var graph = false;
    for (args) |arg| {
        root = root or std.mem.eql(u8, arg, "--workspace-root");
        graph = graph or std.mem.eql(u8, arg, "--unit-graph");
    }
    return root and !graph;
}

/// The directory of `cwd` relative to `root`, both absolute and real ("" when they are the same); null when `cwd` is
/// not `root` or below it. Compared by whole path components: /ab is not below /a.
fn belowRoot(root: []const u8, cwd: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, cwd)) return "";
    const prefix = if (std.mem.eql(u8, root, "/")) "" else root;
    if (cwd.len > prefix.len + 1 and std.mem.startsWith(u8, cwd, prefix) and cwd[prefix.len] == '/') return cwd[prefix.len + 1 ..];
    return null;
}

/// The directory of this project relative to the workspace root `root` (as the user wrote it); null when it is
/// refused (reported).
fn packageBelow(arena: Allocator, root: []const u8) !?[]const u8 {
    const cwd = try std.fs.cwd().realpathAlloc(arena, ".");
    const real = blk: {
        var d = std.fs.cwd().openDir(root, .{}) catch |e| {
            say("--workspace-root {s}: {s}; it must be an existing directory that contains the package directory {s}\n", .{ root, @errorName(e), cwd });
            return null;
        };
        d.close();
        break :blk try std.fs.cwd().realpathAlloc(arena, root);
    };
    return belowRoot(real, cwd) orelse {
        say("the package directory {s} is not below --workspace-root {s} ({s}); the workspace root must contain the package\n", .{ cwd, root, real });
        return null;
    };
}

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
        } else if (std.mem.eql(u8, arg, "--subdir") or std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--mojo") or std.mem.eql(u8, arg, "--workspace-root")) {
            if (i + 1 >= args.len or args[i + 1].len == 0) return null;
            i += 1;
            if (std.mem.eql(u8, arg, "-o")) {
                a.out = args[i];
            } else if (std.mem.eql(u8, arg, "--mojo")) {
                a.mojo = args[i];
            } else if (std.mem.eql(u8, arg, "--workspace-root")) {
                a.workspace_root = args[i];
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
        if (rootWithoutGraph(args)) say("--workspace-root belongs to --unit-graph: it sets the directory the graph's paths are relative to\n", .{});
        std.io.getStdErr().writeAll(usage) catch {};
        return exit_usage;
    };
    return run(arena, a) catch |e| {
        say("{s}\n", .{@errorName(e)});
        return 1;
    };
}

fn run(arena: Allocator, a: Args) !u8 {
    const pkg: []const u8 = if (a.workspace_root) |root| (try packageBelow(arena, root)) orelse return exit_refused else "";
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
        .dir = a.workspace_root orelse ".",
        .pkg = pkg,
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

test "--workspace-root takes a directory, needs --unit-graph, and is unset by default" {
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked" }).?.workspace_root == null);
    const a = parseArgs(&.{ "--unit-graph", "--locked", "--workspace-root", "../.." }).?;
    try std.testing.expectEqualStrings("../..", a.workspace_root.?);
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked", "--workspace-root" }) == null);
    try std.testing.expect(parseArgs(&.{ "--unit-graph", "--locked", "--workspace-root", "" }) == null);
    // Without --unit-graph it is a usage error, and the usage error says why.
    try std.testing.expect(parseArgs(&.{ "--locked", "--workspace-root", ".." }) == null);
    try std.testing.expect(rootWithoutGraph(&.{ "--locked", "--workspace-root", ".." }));
    try std.testing.expect(!rootWithoutGraph(&.{ "--unit-graph", "--locked", "--workspace-root", ".." }));
    try std.testing.expect(!rootWithoutGraph(&.{"--locked"}));
}

test "the package directory is found below the workspace root by whole path components" {
    try std.testing.expectEqualStrings("", belowRoot("/w/repo", "/w/repo").?);
    try std.testing.expectEqualStrings("src/a", belowRoot("/w/repo", "/w/repo/src/a").?);
    try std.testing.expectEqualStrings("w/repo", belowRoot("/", "/w/repo").?);
    try std.testing.expect(belowRoot("/w/repo", "/w/repo2") == null);
    try std.testing.expect(belowRoot("/w/repo", "/w") == null);
    try std.testing.expect(belowRoot("/w/repo/src/a", "/w/repo") == null);
    try std.testing.expect(belowRoot("/w/repo", "/other/repo/src") == null);
}
