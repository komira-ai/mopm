//! mopm command line. `--version`, `link-plan`, `metadata`, and `build`/`run`/`repl`,
//! which run the stock `mojo` with the environment's native libraries linked
//! or preloaded (or print that command with `--print-cmd`).

const std = @import("std");
const core = @import("mopm_core");
const mojo_cmd = core.mojo_cmd;
const test_cmd = @import("test_cmd.zig");

pub const version = "0.0.1";

const planned = [_][]const u8{
    "new",  "init",  "add",   "remove",  "lock",   "sync",
    "cov",  "tree",  "check", "publish", "export",  "launch",
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
    \\  build <file.mojo> [-o <out>]
    \\  run <file.mojo>
    \\  repl                    run the stock mojo of the environment, with its
    \\                          native libraries linked or preloaded; the exit
    \\                          status is mojo's
    \\  test [<path>...]        run the tests of tests/**/test_*.mojo and
    \\                          src/**/tests/test_*.mojo, one process per test
    \\                          (--timeout <s>, --memory <MiB>, --format json,
    \\                          --junit <file>; see docs/mopm-test.md)
    \\  test --list [<path>...] list them; --check also builds each file and
    \\                          compares the list with the binary's `--skip-all`
    \\                          listing (--strict-discovery, --prefix <dir>)
    \\
    \\  options for build, run and repl:
    \\    --prefix <dir>        the environment (default: CONDA_PREFIX, then
    \\                          MODULAR_HOME without /share/max)
    \\    --print-cmd           print the command instead of running it
    \\    --os <linux|macos>    with --print-cmd: the spelling to print
    \\                          (default: this host)
    \\
    \\planned (not implemented yet):
    \\  new init add remove lock sync cov tree check publish export launch
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

pub const Opts = struct {
    prefix: ?[]const u8 = null,
    os: mojo_cmd.Os,
    /// Whether `--os` was given; it only applies to `--print-cmd`.
    os_given: bool = false,
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
            o.os_given = true;
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
    if (o.os_given and !o.print_cmd) return .{ .usage = "--os applies only with --print-cmd: a command that runs uses this host's spelling" };
    return .{ .ok = o };
}

fn getEnv(arena: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(arena, key) catch null;
}

/// Replace this process with mojo: `argv`, and the caller's environment with
/// `cmd.env` applied on top. Exec rather than spawn-and-wait: the terminal,
/// stdin (the REPL reads it), signals such as Ctrl-C, and the exit status all
/// belong to mojo with nothing in between. Returns only if the exec failed:
/// 127 when the program does not exist, 126 otherwise (the shell's codes).
fn execMojo(arena: std.mem.Allocator, name: []const u8, cmd: mojo_cmd.Command) u8 {
    const err = std.io.getStdErr().writer();
    var env_map = std.process.getEnvMap(arena) catch |e| {
        err.print("mopm {s}: reading the environment: {s}\n", .{ name, @errorName(e) }) catch {};
        return 1;
    };
    mojo_cmd.applyEnv(&env_map, cmd.env) catch return 1;
    const e = std.process.execve(arena, cmd.argv, &env_map);
    err.print("mopm {s}: cannot run {s}: {s}\n", .{ name, cmd.argv[0], @errorName(e) }) catch {};
    return if (e == error.FileNotFound) 127 else 126;
}

/// `mopm build|run|repl`: discover the environment, plan, refuse, then run
/// mojo or print its command. Diagnostics go to stderr; a printed command
/// line to stdout.
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
    const prefix = std.fs.cwd().realpathAlloc(arena, chosen.path) catch {
        err.print("mopm {s}: environment {s} (from {s}) does not exist\n", .{ name, chosen.path, chosen.source.describe() }) catch {};
        return 1;
    };

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
    if (!o.print_cmd) return execMojo(arena, name, cmd);
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
    if (std.mem.eql(u8, cmd, "metadata")) return metadataCmd(arena, args[2..]);
    if (std.mem.eql(u8, cmd, "test")) return test_cmd.main(arena, args[2..]);
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
    try std.testing.expect(!isPlanned("metadata"));
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
    const r = try parseOk(a, .repl, &.{ "--prefix", "/e", "--os=linux", "--print-cmd" });
    try std.testing.expectEqualStrings("/e", r.prefix.?);
    try std.testing.expectEqual(mojo_cmd.Os.linux, r.os);
    const x = try parseOk(a, .run, &.{ "m.mojo", "--prefix", "/e" });
    try std.testing.expect(!x.print_cmd);
    try std.testing.expect(!x.os_given);
    try std.testing.expectEqual(mojo_cmd.Os.host(), x.os);
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
    try parseUsage(a, .run, &.{ "a.mojo", "--os", "linux" }); // --os without --print-cmd
    try parseUsage(a, .repl, &.{"--os=macos"});
}
