//! Stands in for the programs mopm starts in tests/drivers/group_publish_test.zig (`mojo`, the test binary `mojo build`
//! writes, and `pixi`): prints what the registry token and one other variable look like in the environment mopm handed
//! to it, so the test can see that a program mopm starts never gets the token.
//!
//! Which program it stands in for is its first argument (`run`, `build`, `--skip-all` for a test binary, `install` for
//! pixi). When MOPM_PROBE_OUT names a file, one line `<first argument>: MOPM_TOKEN=<value> MOPM_PROBE_MARK=<value>` is
//! appended to it, so one run of mopm that starts several programs leaves a line for each. `build` also writes the
//! output file it is asked for (`-o <path>`): a copy of this program, which is then the test binary mopm lists.

const std = @import("std");

fn variable(a: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(a, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => return e,
    };
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const out = std.io.getStdOut().writer();
    for ([_][]const u8{ "MOPM_TOKEN", "MOPM_PROBE_MARK" }) |name| {
        try out.print("{s}={s}\n", .{ name, (try variable(a, name)) orelse "<unset>" });
    }
    const args = try std.process.argsAlloc(a);
    const role = if (args.len > 1) args[1] else "";
    if (try variable(a, "MOPM_PROBE_OUT")) |path| {
        const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
        defer f.close();
        try f.seekFromEnd(0);
        try f.writer().print("{s}: MOPM_TOKEN={s} MOPM_PROBE_MARK={s}\n", .{
            role,
            (try variable(a, "MOPM_TOKEN")) orelse "<unset>",
            (try variable(a, "MOPM_PROBE_MARK")) orelse "<unset>",
        });
    }
    if (std.mem.eql(u8, role, "build")) {
        for (args, 0..) |arg, i| {
            if (!std.mem.eql(u8, arg, "-o") or i + 1 >= args.len) continue;
            const me = try std.fs.selfExePathAlloc(a);
            try std.fs.cwd().copyFile(me, std.fs.cwd(), args[i + 1], .{});
        }
    }
}
