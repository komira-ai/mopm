//! mopm command line. `--version`, `link-plan`, and `build`/`run`/`repl` with
//! `--print-cmd` work; running mojo is not implemented yet.

const std = @import("std");
const core = @import("mopm_core");
const mojo_cmd = core.mojo_cmd;

pub const version = "0.0.1";

const planned = [_][]const u8{
    "new",  "init",  "add",   "remove",  "lock",   "sync",
    "test", "cov",   "tree",  "check",   "publish", "export",
    "launch",
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
    \\  build <file.mojo> [-o <out>] --print-cmd
    \\  run <file.mojo> --print-cmd
    \\  repl --print-cmd        print the stock mojo command, with the native
    \\                          libraries of the environment linked or preloaded
    \\
    \\  options for build, run and repl:
    \\    --prefix <dir>        the environment (default: CONDA_PREFIX, then
    \\                          MODULAR_HOME without /share/max)
    \\    --os <linux|macos>    the spelling to print (default: this host)
    \\    --print-cmd           print the command instead of running it
    \\
    \\planned (not implemented yet):
    \\  new init add remove lock sync test cov tree check publish export launch
    \\  running mojo from build, run and repl
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

pub const Opts = struct {
    prefix: ?[]const u8 = null,
    os: mojo_cmd.Os,
    print_cmd: bool = false,
    out: ?[]const u8 = null,
    file: ?[]const u8 = null,
};

pub const Parsed = union(enum) {
    ok: Opts,
    /// A usage error, already worded.
    usage: []const u8,
};

/// `--name value` or `--name=value`. Returns the value and advances `i`, or
/// null if `arg` is not this option.
fn optValue(args: []const []const u8, i: *usize, name: []const u8) ?[]const u8 {
    const arg = args[i.*];
    if (std.mem.eql(u8, arg, name)) {
        if (i.* + 1 >= args.len) return "";
        i.* += 1;
        return args[i.*];
    }
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') return arg[name.len + 1 ..];
    return null;
}

pub fn parseOpts(arena: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) std.mem.Allocator.Error!Parsed {
    var o = Opts{ .os = mojo_cmd.Os.host() };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--print-cmd")) {
            o.print_cmd = true;
        } else if (optValue(args, &i, "--prefix")) |v| {
            if (v.len == 0) return .{ .usage = "--prefix needs a directory" };
            o.prefix = v;
        } else if (optValue(args, &i, "--os")) |v| {
            o.os = std.meta.stringToEnum(mojo_cmd.Os, v) orelse
                return .{ .usage = try std.fmt.allocPrint(arena, "--os must be linux or macos, not '{s}'", .{v}) };
        } else if (tool == .build and std.mem.eql(u8, arg, "-o")) {
            if (i + 1 >= args.len) return .{ .usage = "-o needs a file name" };
            i += 1;
            o.out = args[i];
        } else if (arg.len > 1 and arg[0] == '-') {
            return .{ .usage = try std.fmt.allocPrint(arena, "unknown option '{s}'", .{arg}) };
        } else if (tool == .repl) {
            return .{ .usage = try std.fmt.allocPrint(arena, "repl takes no program, got '{s}'", .{arg}) };
        } else if (o.file != null) {
            return .{ .usage = try std.fmt.allocPrint(arena, "one program only, got '{s}' and '{s}'", .{ o.file.?, arg }) };
        } else {
            o.file = arg;
        }
    }
    if (tool != .repl and o.file == null) return .{ .usage = "a program is required: <file.mojo>" };
    return .{ .ok = o };
}

fn getEnv(arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(arena, key) catch null;
}

/// `mopm build|run|repl`: discover the environment, plan, refuse or print.
/// Diagnostics go to stderr; the command line to stdout.
fn autolink(arena: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) u8 {
    const name = @tagName(tool);
    const err = std.io.getStdErr().writer();
    const parsed = parseOpts(arena, tool, args) catch return 1;
    const o = switch (parsed) {
        .ok => |v| v,
        .usage => |msg| {
            err.print("mopm {s}: {s}\n\n{s}", .{ name, msg, usage }) catch {};
            return 2;
        },
    };

    const chosen = core.env.choosePrefix(o.prefix, getEnv(arena, "CONDA_PREFIX"), getEnv(arena, "MODULAR_HOME")) catch |e| {
        switch (e) {
            error.NoPrefix => err.print("mopm {s}: no environment: pass --prefix <dir>, or run in an activated environment (CONDA_PREFIX or MODULAR_HOME)\n", .{name}) catch {},
            error.BadModularHome => err.print("mopm {s}: MODULAR_HOME does not end in /share/max, so the environment prefix cannot be derived from it; pass --prefix <dir>\n", .{name}) catch {},
        }
        return 1;
    };
    _ = std.fs.cwd().realpathAlloc(arena, chosen.path) catch {
        err.print("mopm {s}: environment {s} (from {s}) does not exist\n", .{ name, chosen.path, chosen.source.describe() }) catch {};
        return 1;
    };

    const prefix = chosen.path;
    const paths = core.env.listMetadata(arena, prefix) catch |e| {
        switch (e) {
            error.NotAMojoEnv => err.print("mopm {s}: {s} (from {s}) has no lib/mojo: not a Mojo environment\n", .{ name, prefix, chosen.source.describe() }) catch {},
            else => err.print("mopm {s}: reading {s}/lib/mojo: {s}\n", .{ name, prefix, @errorName(e) }) catch {},
        }
        return 1;
    };
    const loaded = core.env.loadAll(arena, paths) catch return 1;
    const inputs = switch (loaded) {
        .ok => |v| v,
        .failed => |f| {
            err.print("mopm {s}: {s}: {s}\n", .{ name, f.path, @errorName(f.err) }) catch {};
            return 1;
        },
    };

    const plan = core.link_planner.plan(arena, inputs) catch return 1;
    const refused = mojo_cmd.refusals(arena, tool, plan) catch return 1;
    if (refused.len > 0) {
        for (refused) |d| err.print("mopm {s}: refused ({s}): {s}\n", .{ name, @tagName(d.code), d.message }) catch {};
        return 1;
    }
    const missing = core.env.missingFiles(arena, plan) catch return 1;
    if (missing.len > 0) {
        for (missing) |m| err.print("mopm {s}: refused (missing_file): {s} is named by the installed metadata but is not on disk\n", .{ name, m }) catch {};
        return 1;
    }

    const cmd = mojo_cmd.construct(arena, .{
        .tool = tool,
        .prefix = prefix,
        .os = o.os,
        .file = o.file orelse "",
        .out = o.out,
    }, plan) catch return 1;
    if (!o.print_cmd) {
        err.print("mopm {s}: running mojo is not implemented yet; --print-cmd prints the command\n", .{name}) catch {};
        return 1;
    }
    var buf = std.ArrayList(u8).init(arena);
    mojo_cmd.render(cmd, buf.writer()) catch return 1;
    std.io.getStdOut().writeAll(buf.items) catch return 1;
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
    if (std.meta.stringToEnum(mojo_cmd.Tool, cmd)) |tool| return autolink(arena, tool, args[2..]);
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
    try std.testing.expect(isPlanned("add"));
    try std.testing.expect(isPlanned("check"));
    try std.testing.expect(!isPlanned("build"));
    try std.testing.expect(!isPlanned("run"));
    try std.testing.expect(!isPlanned("repl"));
    try std.testing.expect(!isPlanned("link-plan"));
    try std.testing.expect(!isPlanned("--version"));
    try std.testing.expect(!isPlanned("frobnicate"));
}

fn parseOk(a: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) !Opts {
    return switch (try parseOpts(a, tool, args)) {
        .ok => |o| o,
        .usage => |m| {
            std.debug.print("unexpected usage error: {s}\n", .{m});
            return error.TestUnexpectedResult;
        },
    };
}

fn parseUsage(a: std.mem.Allocator, tool: mojo_cmd.Tool, args: []const []const u8) !void {
    switch (try parseOpts(a, tool, args)) {
        .ok => return error.TestUnexpectedResult,
        .usage => {},
    }
}

test "options: both spellings, any order" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    const o = try parseOk(a, .build, &.{ "--print-cmd", "m.mojo", "--prefix=/e", "-o", "out", "--os", "macos" });
    try std.testing.expect(o.print_cmd);
    try std.testing.expectEqualStrings("m.mojo", o.file.?);
    try std.testing.expectEqualStrings("/e", o.prefix.?);
    try std.testing.expectEqualStrings("out", o.out.?);
    try std.testing.expectEqual(mojo_cmd.Os.macos, o.os);
    const r = try parseOk(a, .repl, &.{ "--prefix", "/e", "--os=linux" });
    try std.testing.expectEqualStrings("/e", r.prefix.?);
    try std.testing.expectEqual(mojo_cmd.Os.linux, r.os);
    try std.testing.expect(!r.print_cmd);
}

test "options: usage errors" {
    var t = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer t.deinit();
    const a = t.allocator();
    try parseUsage(a, .build, &.{"--print-cmd"}); // no program
    try parseUsage(a, .run, &.{ "a.mojo", "b.mojo" }); // two programs
    try parseUsage(a, .run, &.{ "a.mojo", "-o", "x" }); // -o is build only
    try parseUsage(a, .repl, &.{"a.mojo"}); // repl takes no program
    try parseUsage(a, .build, &.{ "a.mojo", "--prefix" }); // flag without value
    try parseUsage(a, .build, &.{ "a.mojo", "--os", "windows" });
    try parseUsage(a, .build, &.{ "a.mojo", "--frobnicate" });
}
