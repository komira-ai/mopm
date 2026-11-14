//! The command line of mopm-api-gen (tools/api_gen.zig only forwards to `run`): `mopm-api-gen [<repository root>]` writes
//! what the protos below the root make (gen.zig) and says each file it wrote. Exit 0 when they are written, 1 when the
//! protos cannot be read or written as the outputs (the reason on `stderr`), 2 for a usage error.

const std = @import("std");
const Allocator = std.mem.Allocator;
const gen = @import("gen.zig");

pub const usage = "usage: mopm-api-gen [<repository root>]\n";

/// `args` are the arguments after the program name.
pub fn run(arena: Allocator, args: []const []const u8, stdout: anytype, stderr: anytype) !u8 {
    if (args.len > 1) {
        try stderr.writeAll(usage);
        return 2;
    }
    const root_path = if (args.len == 1) args[0] else ".";
    var root = std.fs.cwd().openDir(root_path, .{}) catch |e| {
        try stderr.print("mopm-api-gen: cannot open {s}: {s}\n", .{ root_path, @errorName(e) });
        return 1;
    };
    defer root.close();
    const files = switch (try gen.generate(arena, root)) {
        .ok => |f| f,
        .bad => |why| {
            try stderr.print("mopm-api-gen: {s}\n", .{why});
            return 1;
        },
    };
    for (files) |f| {
        if (std.fs.path.dirname(f.path)) |dir| try root.makePath(dir);
        try root.writeFile(f.path, f.text);
        try stdout.print("wrote {s}\n", .{f.path});
    }
    return 0;
}
