//! mopm-api-gen: writes what the registry API's protos (spec/api/mopm/registry/v2/*.proto) make: spec/api/openapi-v2.yaml,
//! service/api/src/gen/registry-v2.ts and src/core/registry_v2.zig (tools/api_gen/gen.zig says how the files are read).
//!
//!   zig build gen-api                 (the repository root is build.zig's directory)
//!   mopm-api-gen [<repository root>]  (default: the working directory)
//!
//! It reads nothing but the protos and needs no network. tools/api_gen_test.zig fails when a checked-in output is not what
//! this writes, so a change to a proto lands with its outputs. The command itself is tools/api_gen/cli.zig.

const std = @import("std");
const cli = @import("api_gen/cli.zig");

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const args = try std.process.argsAlloc(arena);
    return cli.run(arena, args[1..], std.io.getStdOut().writer(), std.io.getStdErr().writer());
}
