//! Stands in for `mojo` in tests/drivers/group_publish_test.zig: prints what the registry token and one other variable
//! look like in the environment mopm handed to it, so the test can see that a program mopm starts never gets the token.

const std = @import("std");

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const out = std.io.getStdOut().writer();
    for ([_][]const u8{ "MOPM_TOKEN", "MOPM_PROBE_MARK" }) |name| {
        const v = std.process.getEnvVarOwned(a, name) catch |e| switch (e) {
            error.EnvironmentVariableNotFound => null,
            else => return e,
        };
        try out.print("{s}={s}\n", .{ name, v orelse "<unset>" });
    }
}
