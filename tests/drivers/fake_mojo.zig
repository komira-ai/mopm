//! Stands in for `mojo` in tests/drivers/golden_test.zig: shows what
//! mopm handed over (one argument per line, two environment variables, stdin
//! for the REPL) and exits with a status of its own, so the golden files can
//! check that mopm passes argv, environment, stdin and exit status through.

const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    const out = std.io.getStdOut().writer();
    for (args[1..]) |arg| try out.print("arg: {s}\n", .{arg});
    for ([_][]const u8{ "MODULAR_HOME", "MOPM_GOLDEN_MARK" }) |name| {
        const v = std.process.getEnvVarOwned(a, name) catch |e| switch (e) {
            error.EnvironmentVariableNotFound => null,
            else => return e,
        };
        try out.print("{s}={s}\n", .{ name, v orelse "<unset>" });
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "repl")) {
        const stdin = std.io.getStdIn().reader();
        while (try stdin.readUntilDelimiterOrEofAlloc(a, '\n', 1 << 20)) |line| {
            try out.print("stdin: {s}\n", .{line});
        }
    }
    std.process.exit(7);
}
