//! Regenerates registry/fake/errors.zig from spec/api/openapi.yaml: the Zig
//! port of registry/fake/gen_errors.py. Run it after the error catalogue
//! (`x-mopm-errors`, `ErrorCode`) changes, from the repository root:
//!
//!     ./buck2 run //:gen_errors -- spec/api/openapi.yaml registry/fake/errors.zig
//!
//! //:gen_errors_current fails while the committed errors.zig is not what this
//! makes of the spec.

const std = @import("std");
const gen = @import("errors_gen.zig");

pub fn main() !u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const args = try std.process.argsAlloc(a);
    if (args.len != 3) {
        std.debug.print("usage: gen_errors <spec/api/openapi.yaml> <registry/fake/errors.zig>\n", .{});
        return 2;
    }
    const cwd = std.fs.cwd();
    const spec = try cwd.readFileAlloc(a, args[1], 16 << 20);
    var why: []const u8 = "";
    const text = gen.generate(a, spec, &why) catch |e| {
        std.debug.print("gen_errors: {s}: {s}\n", .{ @errorName(e), why });
        return 1;
    };
    try cwd.writeFile(args[2], text);
    std.debug.print("wrote {s}\n", .{args[2]});
    return 0;
}
