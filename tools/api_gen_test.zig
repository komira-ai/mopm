//! The checked-in outputs of the registry API's protos (the API files, the command table and the help goldens of
//! tests/golden/registry) are what tools/api_gen.zig makes of them (tools/api_gen/gen.zig), and the check goes red when one
//! is not, when a golden is there that no command writes, or when a proto does not parse. A stale file is printed whole, so a
//! run on CI shows what to check in. Run from the repository root: `zig build test`,
//! `zig test tools/api_gen_test.zig` (lint.yml) and the Buck2 target //:api_gen_test.

const std = @import("std");
const gen = @import("api_gen/gen.zig");
const cli = @import("api_gen/cli.zig");

test {
    _ = @import("api_gen/model.zig");
    _ = @import("api_gen/proto.zig");
    _ = @import("api_gen/proto_test.zig");
    _ = @import("api_gen/openapi.zig");
    _ = @import("api_gen/openapi_test.zig");
    _ = @import("api_gen/typescript.zig");
    _ = @import("api_gen/zig_client.zig");
    _ = @import("api_gen/cli_cmds.zig");
    _ = @import("api_gen/cli_cmds_test.zig");
}

/// What a run on CI shows of a stale file: the text the generator makes of it.
fn printGenerated(path: []const u8, text: []const u8) void {
    std.debug.print("----- generated {s} -----\n{s}\n----- end {s} -----\n", .{ path, text, path });
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
            printGenerated(f.path, f.text);
            stale = true;
            continue;
        };
        if (try gen.drift(a, f.path, f.text, have)) |why| {
            std.debug.print("{s}\n", .{why});
            printGenerated(f.path, f.text);
            stale = true;
        }
    }
    for (try gen.staleGoldens(a, std.fs.cwd(), files)) |path| {
        std.debug.print("{s}: is not written by tools/api_gen.zig (the command it was the help of was removed); run 'zig build gen-api'\n", .{path});
        stale = true;
    }
    if (stale) return error.TestUnexpectedResult;
}

test "goldens that no command writes are found, and only *.txt files below the golden directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const written = [_]gen.Output{
        .{ .path = "tests/golden/registry/commands.txt", .text = "" },
        .{ .path = "tests/golden/registry/org-add.txt", .text = "" },
    };
    try std.testing.expectEqual(@as(usize, 0), (try gen.staleGoldens(a, tmp.dir, &written)).len);
    try tmp.dir.makePath("tests/golden/registry/sub");
    for ([_][]const u8{ "commands.txt", "org-add.txt", "org-remove.txt", "a-old.txt", "notes.md" }) |name| {
        try tmp.dir.writeFile(try std.fs.path.join(a, &.{ "tests/golden/registry", name }), "x");
    }
    const stale = try gen.staleGoldens(a, tmp.dir, &written);
    try std.testing.expectEqual(@as(usize, 2), stale.len);
    try std.testing.expectEqualStrings("tests/golden/registry/a-old.txt", stale[0]);
    try std.testing.expectEqualStrings("tests/golden/registry/org-remove.txt", stale[1]);
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

/// A scratch repository holding a copy of the real protos.
fn scratchRepo(a: std.mem.Allocator, tmp: *std.testing.TmpDir) ![]const u8 {
    const dir = "spec/api/mopm/registry/v2";
    try tmp.dir.makePath(dir);
    var src = try std.fs.cwd().openDir(dir, .{ .iterate = true });
    defer src.close();
    var it = src.iterate();
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".proto")) continue;
        try tmp.dir.writeFile(try std.fs.path.join(a, &.{ dir, e.name }), try src.readFileAlloc(a, e.name, 1 << 20));
    }
    return tmp.dir.realpathAlloc(a, ".");
}

test "the command writes every output into the repository it is given and says so" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try scratchRepo(a, &tmp);
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try std.testing.expectEqual(@as(u8, 0), try cli.run(a, &.{root}, out.writer(), err.writer()));
    const files = (try gen.generate(a, tmp.dir)).ok;
    var said = std.ArrayList(u8).init(a);
    for (files) |f| try said.writer().print("wrote {s}\n", .{f.path});
    try std.testing.expectEqualStrings(said.items, out.items);
    try std.testing.expect(std.mem.startsWith(u8, out.items, "wrote spec/api/openapi-v2.yaml\nwrote service/api/src/gen/registry-v2.ts\nwrote src/core/registry_v2.zig\nwrote src/cli/registry_commands.zig\nwrote tests/golden/registry/commands.txt\n"));
    try std.testing.expectEqualStrings("", err.items);
    // Every output is on disk, the golden directory was made, and the API files are what is checked in (the protos are the same).
    for (files) |f| try std.testing.expectEqualStrings(f.text, try tmp.dir.readFileAlloc(a, f.path, 16 << 20));
    for (gen.outputs) |path| {
        const written = try tmp.dir.readFileAlloc(a, path, 16 << 20);
        const checked_in = try std.fs.cwd().readFileAlloc(a, path, 16 << 20);
        try std.testing.expectEqualStrings(checked_in, written);
    }
}

test "the command deletes the goldens of removed commands and nothing else" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try scratchRepo(a, &tmp);
    try tmp.dir.makePath(gen.golden_dir);
    try tmp.dir.writeFile(gen.golden_dir ++ "/removed-command.txt", "old help\n");
    try tmp.dir.writeFile(gen.golden_dir ++ "/README.md", "kept\n");
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try std.testing.expectEqual(@as(u8, 0), try cli.run(a, &.{root}, out.writer(), err.writer()));
    try std.testing.expect(std.mem.endsWith(u8, out.items, "deleted tests/golden/registry/removed-command.txt\n"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(gen.golden_dir ++ "/removed-command.txt", .{}));
    try tmp.dir.access(gen.golden_dir ++ "/README.md", .{});
    try tmp.dir.access(gen.golden_dir ++ "/commands.txt", .{});

    // A second run has nothing to delete.
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 0), try cli.run(a, &.{root}, out.writer(), err.writer()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "deleted") == null);
}

test "the command refuses extra arguments, a root it cannot open and protos that do not parse" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var out = std.ArrayList(u8).init(a);
    var err = std.ArrayList(u8).init(a);
    try std.testing.expectEqual(@as(u8, 2), try cli.run(a, &.{ "a", "b" }, out.writer(), err.writer()));
    try std.testing.expectEqualStrings(cli.usage, err.items);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try scratchRepo(a, &tmp);
    err.clearRetainingCapacity();
    const missing = try std.fs.path.join(a, &.{ root, "no-such-dir" });
    try std.testing.expectEqual(@as(u8, 1), try cli.run(a, &.{missing}, out.writer(), err.writer()));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm-api-gen: cannot open {s}: FileNotFound\n", .{missing}), err.items);

    try tmp.dir.writeFile("spec/api/mopm/registry/v2/registry.proto", "syntax = \"proto3\";\npackage mopm.registry.v2;\nmessage A { string n = ; }\n");
    err.clearRetainingCapacity();
    out.clearRetainingCapacity();
    try std.testing.expectEqual(@as(u8, 1), try cli.run(a, &.{root}, out.writer(), err.writer()));
    try std.testing.expectEqualStrings("mopm-api-gen: mopm/registry/v2/registry.proto:3: expected a number but found ';'\n", err.items);
    try std.testing.expectEqualStrings("", out.items);
    // Nothing was written.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(gen.outputs[0], .{}));
}
