//! The checked-in outputs of the registry API's protos (the API files, the command table and the help goldens of
//! tests/golden/registry) are what tools/api_gen.zig makes of them (tools/api_gen/gen.zig), and the check goes red when one
//! is not, when a golden is there that no command writes, or when a proto does not parse. A stale file is printed whole, so a
//! run on CI shows what to check in. Run from the repository root: `zig build test`,
//! `zig test tools/api_gen_test.zig` (lint.yml) and the Buck2 target //:api_gen_test.

const std = @import("std");
const gen = @import("api_gen/gen.zig");
const cli = @import("api_gen/cli.zig");
const model = @import("api_gen/model.zig");
const proto = @import("api_gen/proto.zig");
const openapi = @import("api_gen/openapi.zig");
const typescript = @import("api_gen/typescript.zig");

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

/// The scratch repository of `scratchRepo` with the first `from` of the proto `file` replaced by `to`.
fn editedRepo(a: std.mem.Allocator, tmp: *std.testing.TmpDir, file: []const u8, from: []const u8, to: []const u8) !void {
    _ = try scratchRepo(a, tmp);
    const path = try std.fs.path.join(a, &.{ "spec/api/mopm/registry/v2", file });
    const text = try tmp.dir.readFileAlloc(a, path, 1 << 20);
    const at = std.mem.indexOf(u8, text, from) orelse return error.TestUnexpectedResult;
    try tmp.dir.writeFile(path, try std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] }));
}

fn expectGenerateRefuses(file: []const u8, from: []const u8, to: []const u8, want: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try editedRepo(a, &tmp, file, from, to);
    try std.testing.expectEqualStrings(want, (try gen.generate(a, tmp.dir)).bad);
}

test "a proto that one generator cannot write fails the generation with that generator's reason" {
    // The sources: the entry file imports a file that is not there.
    try expectGenerateRefuses("registry.proto", "import \"mopm/registry/v2/auth.proto\";\n", "import \"mopm/registry/v2/gone.proto\";\n", "spec/api/mopm/registry/v2/gone.proto: cannot be read: FileNotFound");
    // The OpenAPI file: a doc with a tab cannot be a literal block.
    try expectGenerateRefuses("types.proto", "// A normalised package name; in a full name, the import name.\n", "// A normalised\n//\tname.\n", "the text \"A normalised\" cannot be written as a literal block: it holds a tab or a carriage return");
    // The TypeScript types: two declarations flatten to one name.
    try expectGenerateRefuses("types.proto", "message Name {\n", "message NameX {\n  message Y { string a = 1; }\n}\nmessage NameXY { string a = 1; }\nmessage Name {\n", "'NameX.Y' and 'NameXY' are both the TypeScript name 'NameXY'");
    // The Zig client: the enum value 'unknown' is the tag of a value the client does not know.
    try expectGenerateRefuses("namespaces.proto", "  MEMBER_ROLE_MEMBER = 2;\n", "  MEMBER_ROLE_MEMBER = 2;\n  MEMBER_ROLE_X = 3 [(json) = \"unknown\"];\n", "enum 'MemberRole' has the JSON value 'unknown', the tag of a value this client does not know");
    // The command table: an operation needs a command.
    try expectGenerateRefuses("registry.proto", "      commands { name: \"health\" summary: \"Show whether the registry is up and in which mode.\" }\n", "", "rpc GetHealth: has no `commands` in its (operation) option");
}

test "running out of memory is passed up by the parser and the generators, not reported as a refusal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const srcs = (try gen.sources(a, std.fs.cwd())).ok;
    const api = (try proto.parse(a, srcs)).ok;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, proto.parse(failing.allocator(), srcs));
    failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, proto.imports(failing.allocator(), srcs[0].text));
    failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, openapi.write(failing.allocator(), api));
    failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, typescript.generate(failing.allocator(), api));
}

test "a path is relative to the base path, and one outside it is whole" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var api = (try proto.parse(a, (try gen.sources(a, std.fs.cwd())).ok)).ok;
    const rpc = api.rpcs[0];
    try std.testing.expectEqualStrings(rpc.path[api.base_path.len..], model.relativePath(api, rpc));
    api.base_path = "/elsewhere";
    try std.testing.expectEqualStrings(rpc.path, model.relativePath(api, rpc));
}

test "stray semicolons are skipped wherever a declaration may start, and a file option is read and dropped" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const text =
        \\syntax = "proto3";
        \\package t.v2;
        \\;
        \\option java_package = "x";
        \\option optimize_for = SPEED;
        \\message A {
        \\  ;
        \\  string a = 1;
        \\  ;
        \\  oneof o { ; string b = 2; ; }
        \\  enum K { ; K_A = 0; ; }
        \\}
        \\enum E { ; E_A = 0; ; }
        \\service S {
        \\  ;
        \\  option (api) = { base_path: "/api/v2" };
        \\  ;
        \\  rpc R(A) returns (A) { ; option (google.api.http) = { get: "/api/v2/r" }; ; }
        \\}
        \\
    ;
    const api = (try proto.parse(a, &.{.{ .path = "t.proto", .text = text }})).ok;
    try std.testing.expectEqual(@as(usize, 1), api.messages.len);
    try std.testing.expectEqual(@as(usize, 2), api.enums.len);
    try std.testing.expectEqualStrings("A", api.messages[0].name);
    try std.testing.expectEqual(@as(usize, 2), api.messages[0].fields.len);
    try std.testing.expectEqualStrings("b", api.messages[0].fields[1].name);
    try std.testing.expectEqualStrings("R", api.rpcs[0].name);
}

test "a description replaces the one an entry has, and a list holds integers, empty mappings and nothing nested" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var w = openapi.Writer{ .arena = a, .api = undefined };
    var e = openapi.Entries.init(a);
    try openapi.Writer.add(&e, "description", .{ .str = "old" });
    try openapi.Writer.add(&e, "type", .{ .str = "string" });
    try w.describe(&e, "new");
    try std.testing.expectEqual(@as(usize, 2), e.items.len);
    try std.testing.expectEqualStrings("new", e.items[0].value.str);
    try w.describe(&e, "");
    try std.testing.expectEqualStrings("new", e.items[0].value.str);

    var out = std.ArrayList(u8).init(a);
    try w.renderSeq(&out, &.{ .{ .raw = "7" }, .{ .map = &.{} }, .{ .str = "s" } }, 2);
    try std.testing.expectEqualStrings("  - 7\n  - {}\n  - s\n", out.items);
    try std.testing.expectError(error.Invalid, w.renderSeq(&out, &.{.{ .seq = &.{} }}, 0));
    try std.testing.expectEqualStrings("a list inside a list", w.msg);
    try std.testing.expectError(error.Invalid, w.renderSeq(&out, &.{.{ .flow = &.{} }}, 0));
    try std.testing.expectEqualStrings("a flow mapping in a list", w.msg);
}
