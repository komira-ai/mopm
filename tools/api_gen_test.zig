//! The checked-in outputs of the registry API's protos are what tools/api_gen.zig makes of them (tools/api_gen/gen.zig),
//! and the check goes red when one is not, or when a proto does not parse. Run from the repository root: `zig build test`,
//! `zig test tools/api_gen_test.zig` (lint.yml) and the Buck2 target //:api_gen_test.

const std = @import("std");
const gen = @import("api_gen/gen.zig");

test {
    _ = @import("api_gen/model.zig");
    _ = @import("api_gen/proto.zig");
    _ = @import("api_gen/openapi.zig");
    _ = @import("api_gen/typescript.zig");
    _ = @import("api_gen/zig_client.zig");
}

test "the checked-in outputs are what the protos make" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const files = switch (try gen.generate(a, std.fs.cwd())) {
        .ok => |f| f,
        .bad => |why| {
            std.debug.print("{s}\n", .{why});
            return error.TestUnexpectedResult;
        },
    };
    var stale = false;
    for (files) |f| {
        const have = std.fs.cwd().readFileAlloc(a, f.path, 16 << 20) catch |e| {
            std.debug.print("{s}: cannot be read ({s}); run 'zig build gen-api'\n", .{ f.path, @errorName(e) });
            stale = true;
            continue;
        };
        if (try gen.drift(a, f.path, f.text, have)) |why| {
            std.debug.print("{s}\n", .{why});
            stale = true;
        }
    }
    if (stale) return error.TestUnexpectedResult;
}

test "an output that differs is named with its first differing line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expect((try gen.drift(a, "x.yaml", "a\nb\n", "a\nb\n")) == null);
    try std.testing.expectEqualStrings(
        "x.yaml:2: is not what tools/api_gen.zig makes of spec/api/mopm/registry/v2/*.proto; run 'zig build gen-api'\n  generated: b\n  checked in: c",
        (try gen.drift(a, "x.yaml", "a\nb\n", "a\nc\n")).?,
    );
    try std.testing.expectEqualStrings(
        "x.yaml:3: is not what tools/api_gen.zig makes of spec/api/mopm/registry/v2/*.proto; run 'zig build gen-api'\n  generated: (end of file)\n  checked in: extra",
        (try gen.drift(a, "x.yaml", "a\nb", "a\nb\nextra")).?,
    );
}

test "the protos are read in import order, and a missing or circular import is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("spec/api/mopm/registry/v2");
    const dir = "spec/api/mopm/registry/v2/";
    try tmp.dir.writeFile(dir ++ "registry.proto",
        \\syntax = "proto3";
        \\import "google/api/annotations.proto";
        \\import "mopm/registry/v2/options.proto";
        \\import "mopm/registry/v2/b.proto";
        \\import "mopm/registry/v2/a.proto";
    );
    try tmp.dir.writeFile(dir ++ "a.proto", "syntax = \"proto3\";\nimport \"mopm/registry/v2/b.proto\";\n");
    try tmp.dir.writeFile(dir ++ "b.proto", "syntax = \"proto3\";\n");
    const got = (try gen.sources(a, tmp.dir)).ok;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("mopm/registry/v2/b.proto", got[0].path);
    try std.testing.expectEqualStrings("mopm/registry/v2/a.proto", got[1].path);
    try std.testing.expectEqualStrings("mopm/registry/v2/registry.proto", got[2].path);

    try tmp.dir.writeFile(dir ++ "b.proto", "syntax = \"proto3\";\nimport \"mopm/registry/v2/a.proto\";\n");
    try std.testing.expectEqualStrings("mopm/registry/v2/b.proto: imports itself, through its imports", (try gen.sources(a, tmp.dir)).bad);

    try tmp.dir.writeFile(dir ++ "b.proto", "syntax = \"proto3\";\nimport \"mopm/registry/v2/c.proto\";\n");
    try std.testing.expectEqualStrings("spec/api/mopm/registry/v2/c.proto: cannot be read: FileNotFound", (try gen.sources(a, tmp.dir)).bad);
}

test "a proto that does not parse fails the generation, naming the file and line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("spec/api/mopm/registry/v2");
    try tmp.dir.writeFile("spec/api/mopm/registry/v2/registry.proto", "syntax = \"proto3\";\npackage mopm.registry.v2;\nmessage A { string n = ; }\n");
    const why = (try gen.generate(a, tmp.dir)).bad;
    try std.testing.expectEqualStrings("mopm/registry/v2/registry.proto:3: expected a number but found ';'", why);
}
