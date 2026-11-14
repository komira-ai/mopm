//! mopm-api-gen: writes what the registry API's protos (spec/api/mopm/registry/v2/*.proto) make: spec/api/openapi-v2.yaml,
//! service/api/src/gen/registry-v2.ts and src/core/registry_v2.zig (tools/api_gen/gen.zig says how the files are read).
//!
//!   zig build gen-api                 (the repository root is build.zig's directory)
//!   mopm-api-gen [<repository root>]  (default: the working directory)
//!
//! It reads nothing but the protos and needs no network. tools/api_gen_test.zig fails when a checked-in output is not what
//! this writes, so a change to a proto lands with its outputs.

const std = @import("std");
const gen = @import("api_gen/gen.zig");

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    const stderr = std.io.getStdErr().writer();
    if (args.len > 2) {
        try stderr.writeAll("usage: mopm-api-gen [<repository root>]\n");
        return 2;
    }
    var root = try std.fs.cwd().openDir(if (args.len == 2) args[1] else ".", .{});
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
        try std.io.getStdOut().writer().print("wrote {s}\n", .{f.path});
    }
    return 0;
}
