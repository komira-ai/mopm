//! mopm command line. Only `--version`, `link-plan`, `metadata`, `new` and `init` do
//! anything yet.

const std = @import("std");
const core = @import("mopm_core");

pub const version = "0.0.1";

const planned = [_][]const u8{
    "add",   "remove",  "lock",    "sync", "build",
    "run",   "test",  "cov",   "repl",    "tree",    "check", "publish",
    "export", "launch",
};

pub fn isPlanned(cmd: []const u8) bool {
    for (planned) |p| {
        if (std.mem.eql(u8, p, cmd)) return true;
    }
    return false;
}

const usage =
    \\usage: mopm <command> [args]
    \\
    \\working today:
    \\  --version               print the version
    \\  link-plan <file>...     print the link plan for installed packages,
    \\                          given their <name>.mopm.json files
    \\  metadata [mopm.toml]    check a package manifest and print it as JSON
    \\  new <name> [--lib|--bin]
    \\                          make a package in a new directory <name>
    \\  init [--lib|--bin] [--name <name>]
    \\                          make a package in this directory
    \\
    \\planned (not implemented yet):
    \\  add remove lock sync build run test cov repl tree check
    \\  publish export launch
    \\
;

fn linkPlan(arena: std.mem.Allocator, paths: []const []const u8) u8 {
    if (paths.len == 0) {
        std.debug.print("usage: mopm link-plan <file.mopm.json>...\n", .{});
        return 2;
    }
    var inputs = std.ArrayList(core.link_planner.Input).init(arena);
    for (paths) |p| {
        const inp = core.link_planner.loadInput(arena, p) catch |e| {
            std.debug.print("mopm: {s}: {s}\n", .{ p, @errorName(e) });
            return 1;
        };
        inputs.append(inp) catch return 1;
    }
    const plan = core.link_planner.plan(arena, inputs.items) catch return 1;
    var buf = std.ArrayList(u8).init(arena);
    core.link_planner.render(plan, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
    return if (plan.ok()) 0 else 1;
}

fn metadataCmd(arena: std.mem.Allocator, args: []const []const u8) u8 {
    if (args.len > 1) {
        std.debug.print("usage: mopm metadata [path/to/mopm.toml]\n", .{});
        return 2;
    }
    const path = if (args.len == 1) args[0] else "mopm.toml";
    const src = std.fs.cwd().readFileAlloc(arena, path, 1 << 20) catch |e| {
        std.debug.print("mopm: {s}: {s}\n", .{ path, @errorName(e) });
        return 1;
    };
    var diag: core.manifest.Diagnostic = .{};
    const m = core.manifest.parse(arena, src, &diag) catch |e| {
        if (e == error.Invalid) {
            std.debug.print("mopm: {s}:{d}:{d}: {s}\n", .{ path, diag.pos.line, diag.pos.col, diag.message });
        } else {
            std.debug.print("mopm: {s}: {s}\n", .{ path, @errorName(e) });
        }
        return 1;
    };
    var buf = std.ArrayList(u8).init(arena);
    core.manifest.writeJson(m, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
    return 0;
}

const ScaffoldArgs = struct {
    name: ?[]const u8 = null,
    kind: core.scaffold.Kind = .lib,
};

/// `new <name> [--lib|--bin]` or `init [--lib|--bin] [--name <name>]`; null if
/// the arguments are neither.
fn scaffoldArgs(cmd: []const u8, args: []const []const u8) ?ScaffoldArgs {
    const is_new = std.mem.eql(u8, cmd, "new");
    var out = ScaffoldArgs{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--lib")) {
            out.kind = .lib;
        } else if (std.mem.eql(u8, a, "--bin")) {
            out.kind = .bin;
        } else if (!is_new and std.mem.eql(u8, a, "--name") and i + 1 < args.len and out.name == null) {
            i += 1;
            out.name = args[i];
        } else if (is_new and a.len > 0 and a[0] != '-' and out.name == null) {
            out.name = a;
        } else return null;
    }
    if (is_new and out.name == null) return null;
    return out;
}

/// `mopm new` (into a new directory) and `mopm init` (into this one).
fn scaffoldCmd(arena: std.mem.Allocator, cmd: []const u8, args: []const []const u8) u8 {
    const parsed = scaffoldArgs(cmd, args) orelse {
        std.debug.print("usage: mopm new <name> [--lib|--bin]\n       mopm init [--lib|--bin] [--name <name>]\n", .{});
        return 2;
    };
    const is_new = std.mem.eql(u8, cmd, "new");
    var hint: []const u8 = "";
    const name = parsed.name orelse blk: {
        const here = std.fs.cwd().realpathAlloc(arena, ".") catch |e| {
            std.debug.print("mopm init: {s}\n", .{@errorName(e)});
            return 1;
        };
        hint = " (the name comes from this directory; pass --name <name>)";
        break :blk std.fs.path.basename(here);
    };
    const problem = core.manifest.nameProblem(arena, "package name", name) catch return 1;
    if (problem) |message| {
        std.debug.print("mopm {s}: {s}{s}\n", .{ cmd, message, hint });
        return 1;
    }
    const files = core.scaffold.files(arena, name, parsed.kind) catch return 1;

    var dir = std.fs.cwd();
    var opened: ?std.fs.Dir = null;
    defer if (opened) |*d| d.close();
    if (is_new) {
        std.fs.cwd().makeDir(name) catch |e| {
            if (e == error.PathAlreadyExists) {
                std.debug.print("mopm new: '{s}' already exists\n", .{name});
            } else {
                std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            }
            return 1;
        };
        opened = std.fs.cwd().openDir(name, .{}) catch |e| {
            std.debug.print("mopm new: {s}: {s}\n", .{ name, @errorName(e) });
            return 1;
        };
        dir = opened.?;
    }
    if (core.scaffold.firstExisting(dir, files)) |path| {
        std.debug.print("mopm {s}: {s} already exists; nothing was written\n", .{ cmd, path });
        return 1;
    }
    core.scaffold.write(dir, files) catch |e| {
        std.debug.print("mopm {s}: {s}\n", .{ cmd, @errorName(e) });
        return 1;
    };
    const what = switch (parsed.kind) {
        .lib => "library",
        .bin => "binary",
    };
    const out = std.io.getStdOut().writer();
    if (is_new) {
        out.print("created {s} package '{s}' in {s}/\n", .{ what, name, name }) catch return 1;
    } else {
        out.print("created {s} package '{s}'\n", .{ what, name }) catch return 1;
    }
    return 0;
}

fn run(arena: std.mem.Allocator) u8 {
    const args = std.process.argsAlloc(arena) catch return 1;
    if (args.len < 2) {
        std.debug.print("{s}", .{usage});
        return 2;
    }
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-V")) {
        std.io.getStdOut().writeAll("mopm " ++ version ++ "\n") catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        std.io.getStdOut().writeAll(usage) catch return 1;
        return 0;
    }
    if (std.mem.eql(u8, cmd, "link-plan")) return linkPlan(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "metadata")) return metadataCmd(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "init")) return scaffoldCmd(arena, cmd, args[2..]);
    if (isPlanned(cmd)) {
        std.debug.print("mopm {s}: not implemented yet\n", .{cmd});
        return 1;
    }
    std.debug.print("mopm: unknown command '{s}'\n\n{s}", .{ cmd, usage });
    return 2;
}

pub fn main() void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const code = run(arena_state.allocator());
    std.process.exit(code);
}

test "planned commands are recognised, working ones are not planned" {
    try std.testing.expect(isPlanned("build"));
    try std.testing.expect(isPlanned("repl"));
    try std.testing.expect(!isPlanned("link-plan"));
    try std.testing.expect(!isPlanned("metadata"));
    try std.testing.expect(!isPlanned("new"));
    try std.testing.expect(!isPlanned("init"));
    try std.testing.expect(!isPlanned("--version"));
    try std.testing.expect(!isPlanned("frobnicate"));
}

test "new and init arguments" {
    try std.testing.expectEqualStrings("demo", scaffoldArgs("new", &.{ "demo", "--bin" }).?.name.?);
    try std.testing.expectEqual(core.scaffold.Kind.bin, scaffoldArgs("new", &.{ "--bin", "demo" }).?.kind);
    try std.testing.expectEqual(core.scaffold.Kind.lib, scaffoldArgs("new", &.{"demo"}).?.kind);
    try std.testing.expect(scaffoldArgs("new", &.{}) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "a", "b" }) == null);
    try std.testing.expect(scaffoldArgs("new", &.{ "--name", "a" }) == null);
    try std.testing.expectEqualStrings("x", scaffoldArgs("init", &.{ "--name", "x" }).?.name.?);
    try std.testing.expect(scaffoldArgs("init", &.{}).?.name == null);
    try std.testing.expect(scaffoldArgs("init", &.{"x"}) == null);
    try std.testing.expect(scaffoldArgs("init", &.{"--name"}) == null);
}
