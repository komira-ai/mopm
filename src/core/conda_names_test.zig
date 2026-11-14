//! Tests of the names in a package `mopm pack` writes: the conda name `mojo-<namespace>.<name>`, the import name of
//! the files inside, and how the package installs. mopm_core.zig runs them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const conda = @import("conda.zig");
const unpack = @import("conda_unpack.zig");
const env_mod = @import("conda_env.zig");
const fx = @import("conda_fixture.zig");
const metadata = @import("metadata.zig");

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn input(name: []const u8, deps: []const conda.Dep) conda.Input {
    return .{ .name = name, .version = "0.1.0", .compiler = "1.0.0", .subdir = "noarch", .deps = deps, .mojoc = "MOJOC" };
}

// Behaviour: the package of komira-ai/json is the conda package mojo-komira-ai.json; its libraries are named by the
// import name, and the dependency on another namespace's package is written with that package's conda name.
test "pack: the conda name, the file name and index.json come from the full name; the files inside from the import name" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const deps = [_]conda.Dep{ .{ .name = "other-org/http_core", .range = ">=1.0,<2" }, .{ .name = "komira-ai/utf8", .range = "" } };
    const in = input("komira-ai/json", &deps);
    const p = try conda.pack(a, in);
    try std.testing.expectEqualStrings("mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda", p.file_name);
    try std.testing.expectEqualStrings(
        "{\"build\":\"mojo1.0.0_0\",\"build_number\":0,\"depends\":[\"mojo-compiler ==1.0.0\",\"mojo-other-org.http_core >=1.0,<2\",\"mojo-komira-ai.utf8\"]," ++
            "\"name\":\"mojo-komira-ai.json\",\"subdir\":\"noarch\",\"version\":\"0.1.0\"}",
        try conda.indexJson(a, in),
    );

    const window = try std.testing.allocator.alloc(u8, unpack.window_size);
    defer std.testing.allocator.free(window);
    var diag = unpack.Diag{};
    const got = try unpack.readFiles(a, p.bytes, window, &.{ "lib/mojo/json.mojoc", "lib/mojo/json.mopm.json", "lib/mojo/komira-ai/json.mojoc", "lib/mojo/mojo-komira-ai.json.mojoc" }, &diag);
    try std.testing.expectEqualStrings("MOJOC", got[0].?);
    try std.testing.expectEqualStrings(
        "{\"deps\":[{\"name\":\"other-org/http_core\",\"range\":\">=1.0,<2\"},{\"name\":\"komira-ai/utf8\"}],\"name\":\"komira-ai/json\",\"schema\":2,\"version\":\"0.1.0\"}",
        got[1].?,
    );
    try std.testing.expect(got[2] == null);
    try std.testing.expect(got[3] == null);
    try std.testing.expectEqualStrings(&p.manifest_sha256, try fx.sha256Hex(a, got[1].?));
}

// Behaviour: two namespaces may publish the same import name; their packages differ in name and file name, and the
// metadata each carries names its own package.
test "pack: one import name in two namespaces gives two conda packages" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const one = try conda.pack(a, input("komira-ai/json", &.{}));
    const two = try conda.pack(a, input("other-org/json", &.{}));
    try std.testing.expectEqualStrings("mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda", one.file_name);
    try std.testing.expectEqualStrings("mojo-other-org.json-0.1.0-mojo1.0.0_0.conda", two.file_name);
    try std.testing.expect(!std.mem.eql(u8, one.bytes, two.bytes));
    try std.testing.expect(!std.mem.eql(u8, &one.manifest_sha256, &two.manifest_sha256));
}

// Behaviour: the metadata `pack` writes is what the reader accepts, with full names kept as they are.
test "mopmJson is schema 2 and metadata.parse reads its names back" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    const json = try conda.mopmJson(a, input("komira-ai/json", &.{.{ .name = "other-org/http_core", .range = "" }}));
    const m = try metadata.parse(a, json);
    try std.testing.expectEqual(@as(u32, 2), m.schema);
    try std.testing.expectEqualStrings("komira-ai/json", m.name);
    try std.testing.expectEqualStrings("other-org/http_core", m.deps[0].name);
}

// Behaviour: a package named mojo-<namespace>.<name> installs; its conda-meta record is named by the conda name and
// its library lands at lib/mojo/<import name>.
test "install: a package of a namespace is recorded under its conda name and its files are under the import name" {
    var st = testArena();
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("pkgs");
    try tmp.dir.makeDir("m");
    var cache = try tmp.dir.openDir("pkgs", .{});
    defer cache.close();
    var parent = try tmp.dir.openDir("m", .{});
    defer parent.close();

    const p = try conda.pack(a, input("komira-ai/json", &.{}));
    try cache.writeFile(p.file_name, p.bytes);
    const pin = env_mod.Pkg{
        .name = "mojo-komira-ai.json",
        .version = "0.1.0",
        .dir = cache,
        .file_name = p.file_name,
        .sha256 = &p.sha256,
        .size = p.bytes.len,
        .url = "http://127.0.0.1:1/noarch/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.conda",
    };
    var diag = env_mod.Diag{};
    _ = try env_mod.recover(a, parent, "env");
    const cand = try env_mod.stage(a, parent, "env", "/opt/mopm/env", &.{pin}, "stamp", &diag);
    _ = try env_mod.commit(a, parent, "env", cand, &diag);

    var env = try parent.openDir("env", .{});
    defer env.close();
    try std.testing.expectEqualStrings("MOJOC", try env.readFileAlloc(a, "lib/mojo/json.mojoc", 100));
    const meta = try metadata.parse(a, try env.readFileAlloc(a, "lib/mojo/json.mopm.json", 1 << 20));
    try std.testing.expectEqualStrings("komira-ai/json", meta.name);
    const rec = try env.readFileAlloc(a, "conda-meta/mojo-komira-ai.json-0.1.0-mojo1.0.0_0.json", 1 << 20);
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a, rec, .{});
    try std.testing.expectEqualStrings("mojo-komira-ai.json", v.object.get("name").?.string);
}
