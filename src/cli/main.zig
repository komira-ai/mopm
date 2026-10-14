//! mopm command line. Only `--version`, `link-plan` and `metadata` do anything yet.

const std = @import("std");
const core = @import("mopm_core");

pub const version = "0.0.1";

const planned = [_][]const u8{
    "new",   "init",  "add",   "remove",  "lock",    "sync", "build",
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
    \\
    \\planned (not implemented yet):
    \\  new init add remove lock sync build run test cov repl tree check
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
    try std.testing.expect(!isPlanned("--version"));
    try std.testing.expect(!isPlanned("frobnicate"));
}
