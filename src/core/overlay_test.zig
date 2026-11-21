//! Tests of a staged set that only adds a build to a version the registry already holds (core/overlay.zig,
//! `mergedIndexText`): resolution through the set sees the registry's record of that version with the staged build
//! added, and the registry's other versions of the package.

const std = @import("std");
const Allocator = std.mem.Allocator;
const resolve = @import("resolve.zig");
const overlay = @import("overlay.zig");
const plan = @import("install_plan.zig");

const sha256Hex = overlay.sha256Hex;
const test_sha = overlay.test_sha;
const sha_a = "a" ** 64;
const sha_b = "b" ** 64;
const sha_c = "c" ** 64;

const libbase_meta = "{\"schema\":2,\"name\":\"acme/libbase\",\"version\":\"0.1.0\",\"deps\":[{\"name\":\"acme/regdep\"}]}";

/// An index file line of a registry package, in the registry's layout with `builds`.
fn line(a: Allocator, name: []const u8, version: []const u8, deps: []const u8, builds: []const []const u8) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    const w = out.writer();
    try w.print("{{\"v\":2,\"name\":\"{s}\",\"version\":\"{s}\",\"state\":\"published\",\"deps\":[{s}],", .{ name, version, deps });
    try w.print("{s},\"builds\":[", .{try trio(a, builds[0])});
    for (builds, 0..) |b, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(b);
    }
    try w.writeAll("]}\n");
    return out.items;
}

/// `build` as the top-level trio of an index line, and as an entry of `builds`; for the registry's lines.
fn build(a: Allocator, name: []const u8, version: []const u8, compiler: []const u8, subdir: []const u8, sha: []const u8, size: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"build\":\"mojo{s}_0\",\"requires_mojo\":\"=={s}\",\"files\":[{{\"subdir\":\"{s}\",\"filename\":\"mojo-{s}-{s}-mojo{s}_0.conda\",\"sha256\":\"{s}\",\"size\":{d}}}]}}", .{ compiler, compiler, subdir, name, version, compiler, sha, size });
}

/// `build` as the top-level keys of a line, without its braces: `"build":...,"requires_mojo":...,"files":[...]`.
fn trio(a: Allocator, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{s}", .{b[1 .. b.len - 1]});
}

/// A line the way the registry wrote it before `builds`: the top-level trio alone.
fn oldLine(a: Allocator, name: []const u8, version: []const u8, deps: []const u8, b: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"v\":2,\"name\":\"{s}\",\"version\":\"{s}\",\"state\":\"published\",\"deps\":[{s}],{s}}}\n", .{ name, version, deps, try trio(a, b) });
}

/// The registry of the add: acme/libbase 0.0.9 and 0.1.0 (old lines, built for 1.0.0 only), and acme/regdep, which
/// libbase 0.1.0 depends on, built for 1.0.0 (linux-64) and 1.1.0 (osx-arm64).
const Registry = struct {
    libbase: []const u8,
    regdep: []const u8,

    pub fn fetch(self: Registry, _: Allocator, name: []const u8, _: *resolve.Diagnostic) resolve.Error!?[]const u8 {
        if (std.mem.eql(u8, name, "acme/libbase")) return self.libbase;
        if (std.mem.eql(u8, name, "acme/regdep")) return self.regdep;
        return null;
    }
};

fn registry(a: Allocator) !Registry {
    const old = try oldLine(a, "acme/libbase", "0.0.9", "", try build(a, "acme.libbase", "0.0.9", "1.0.0", "linux-64", test_sha, 10));
    const cur = try oldLine(a, "acme/libbase", "0.1.0", "{\"name\":\"acme/regdep\"}", try build(a, "acme.libbase", "0.1.0", "1.0.0", "linux-64", sha_a, 20));
    return .{
        .libbase = try std.mem.concat(a, u8, &.{ old, cur }),
        .regdep = try line(a, "acme/regdep", "1.0.0", "", &.{
            try build(a, "acme.regdep", "1.0.0", "1.0.0", "linux-64", sha_b, 30),
            try build(a, "acme.regdep", "1.0.0", "1.1.0", "osx-arm64", sha_c, 40),
        }),
    };
}

/// The staged set of the add: acme/libbase 0.1.0 with the Mojo 1.1.0 build alone.
fn addSet(a: Allocator, tmp: *std.testing.TmpDir, bytes: []const u8) !overlay.Overlay {
    const dir = try overlay.testSet(a, tmp, &.{.{ .name = "acme/libbase", .version = "0.1.0", .files = &.{.{ .build = "mojo1.1.0_0", .bytes = bytes }} }});
    var why: []const u8 = "";
    return overlay.load(a, dir, &why);
}

const RegistryChannel = struct {
    linux: []const u8,
    osx: []const u8,

    pub fn fetch(self: RegistryChannel, _: Allocator, namespace: []const u8, subdir: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
        std.testing.expectEqualStrings("acme", namespace) catch return error.ResolveFailed;
        return if (std.mem.eql(u8, subdir, "linux-64")) self.linux else self.osx;
    }

    pub fn fetchConda(_: RegistryChannel, _: Allocator, _: []const u8, _: []const u8, _: []const u8, _: *resolve.Diagnostic) resolve.Error![]const u8 {
        return error.ResolveFailed;
    }
};

fn entry(a: Allocator, filename: []const u8, sha: []const u8, size: usize) ![]const u8 {
    return std.fmt.allocPrint(a, "\"{s}\":{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ filename, sha, size });
}

test "a set that adds a build to a version the registry holds resolves for the added Mojo to the staged file and for the registry's Mojo to the registry's file of the same version" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged_bytes = try overlay.testCondaStamped(a, "acme/libbase", "0.1.0", libbase_meta, "1.1.0 linux");
    const ov = try addSet(a, &tmp, staged_bytes);
    const reg = try registry(a);
    var asked = false;
    var diag: resolve.Diagnostic = .{};
    const roots = [_]resolve.Root{.{ .name = "acme/libbase", .requirement = "0.1" }};
    const source = overlay.Index(Registry){ .overlay = &ov, .inner = reg, .asked = &asked };

    // Mojo 1.0.0: the staged set has no such build; the registry's record of 0.1.0 has, and its dependency follows.
    const res10 = try resolve.resolve(a, source, .{ .mojo = "1.0.0", .roots = &roots }, &diag);
    try std.testing.expect(asked);
    try std.testing.expectEqual(@as(usize, 2), res10.packages.len);
    try std.testing.expectEqualStrings("acme/libbase", res10.packages[0].record.name);
    try std.testing.expectEqualStrings("0.1.0", res10.packages[0].record.version);
    const held = res10.packages[0].record.buildFor("1.0.0").?;
    try std.testing.expectEqualStrings("mojo1.0.0_0", held.build);
    try std.testing.expectEqualStrings("mojo-acme.libbase-0.1.0-mojo1.0.0_0.conda", held.files[0].filename);
    try std.testing.expectEqualStrings(sha_a, held.files[0].sha256);
    try std.testing.expectEqualStrings("acme/regdep", res10.packages[1].record.name);

    // Mojo 1.1.0: the staged build of the same version, with the registry's dependencies.
    const res11 = try resolve.resolve(a, source, .{ .mojo = "1.1.0", .roots = &roots }, &diag);
    try std.testing.expectEqual(@as(usize, 2), res11.packages.len);
    try std.testing.expectEqualStrings("0.1.0", res11.packages[0].record.version);
    const added = res11.packages[0].record.buildFor("1.1.0").?;
    try std.testing.expectEqualStrings("mojo-acme.libbase-0.1.0-mojo1.1.0_0.conda", added.files[0].filename);
    try std.testing.expectEqualStrings(&sha256Hex(staged_bytes), added.files[0].sha256);
    try std.testing.expectEqual(@as(u64, staged_bytes.len), added.files[0].size);
    try std.testing.expectEqualStrings("acme/regdep", res11.packages[1].record.name);

    // The channels to ask the registry for: the registry's build of libbase and of regdep for 1.0.0, regdep's alone for 1.1.0.
    const subs10 = try overlay.registrySubdirs(a, ov, res10);
    try std.testing.expectEqual(@as(usize, 1), subs10.len);
    try std.testing.expectEqualStrings("acme/linux-64", subs10[0]);
    const subs11 = try overlay.registrySubdirs(a, ov, res11);
    try std.testing.expectEqual(@as(usize, 1), subs11.len);
    try std.testing.expectEqualStrings("acme/osx-arm64", subs11[0]);

    // The locks: each Mojo's file of libbase 0.1.0, the registry's from its repodata, the staged one from the set.
    const linux = try std.fmt.allocPrint(a, "{{\"packages.conda\":{{{s},{s}}}}}", .{
        try entry(a, "mojo-acme.libbase-0.1.0-mojo1.0.0_0.conda", sha_a, 20),
        try entry(a, "mojo-acme.regdep-1.0.0-mojo1.0.0_0.conda", sha_b, 30),
    });
    const osx = try std.fmt.allocPrint(a, "{{\"packages.conda\":{{{s}}}}}", .{try entry(a, "mojo-acme.regdep-1.0.0-mojo1.1.0_0.conda", sha_c, 40)});
    const inner = RegistryChannel{ .linux = linux, .osx = osx };
    const l10 = try plan.buildLock(a, res10, "https://conda.example/", overlay.Channel(RegistryChannel){ .overlay = &ov, .inner = inner, .registry_subdirs = subs10 }, null, &diag);
    try std.testing.expectEqual(@as(usize, 2), l10.packages.len);
    try std.testing.expectEqualStrings("acme/libbase", l10.packages[0].name);
    try std.testing.expectEqualStrings("mojo1.0.0_0", l10.packages[0].build);
    try std.testing.expectEqualStrings("https://conda.example/acme/linux-64/mojo-acme.libbase-0.1.0-mojo1.0.0_0.conda", l10.packages[0].url);
    try std.testing.expectEqualStrings(sha_a, l10.packages[0].sha256);
    const l11 = try plan.buildLock(a, res11, "https://conda.example/", overlay.Channel(RegistryChannel){ .overlay = &ov, .inner = inner, .registry_subdirs = subs11 }, null, &diag);
    try std.testing.expectEqual(@as(usize, 2), l11.packages.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", l11.packages[0].build);
    try std.testing.expectEqualStrings("https://conda.example/acme/linux-64/mojo-acme.libbase-0.1.0-mojo1.1.0_0.conda", l11.packages[0].url);
    try std.testing.expectEqualStrings(&sha256Hex(staged_bytes), l11.packages[0].sha256);
    try std.testing.expectEqual(@as(u64, staged_bytes.len), l11.packages[0].size);
}

test "a set that adds a build to a version the registry holds leaves the registry's other versions of the package visible" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ov = try addSet(a, &tmp, try overlay.testCondaStamped(a, "acme/libbase", "0.1.0", libbase_meta, "1.1.0 linux"));
    var asked = false;
    var diag: resolve.Diagnostic = .{};
    const source = overlay.Index(Registry){ .overlay = &ov, .inner = try registry(a), .asked = &asked };

    // 0.0.9 is only on the registry, and is what a requirement that excludes 0.1.0 gets.
    const old_roots = [_]resolve.Root{.{ .name = "acme/libbase", .requirement = "=0.0.9" }};
    const res = try resolve.resolve(a, source, .{ .mojo = "1.0.0", .roots = &old_roots }, &diag);
    try std.testing.expectEqual(@as(usize, 1), res.packages.len);
    try std.testing.expectEqualStrings("0.0.9", res.packages[0].record.version);
    try std.testing.expectEqualStrings(test_sha, res.packages[0].record.buildFor("1.0.0").?.files[0].sha256);
    // It is the registry's file of a version the set does not hold, so its channel is asked for.
    const subs = try overlay.registrySubdirs(a, ov, res);
    try std.testing.expectEqual(@as(usize, 1), subs.len);
    try std.testing.expectEqualStrings("acme/linux-64", subs[0]);

    // Without a requirement, the newest version with a build for the Mojo: 0.1.0 for both.
    const any_roots = [_]resolve.Root{.{ .name = "acme/libbase", .requirement = "0" }};
    const newest = try resolve.resolve(a, source, .{ .mojo = "1.0.0", .roots = &any_roots }, &diag);
    try std.testing.expectEqualStrings("0.1.0", newest.packages[0].record.version);
}

test "a staged version the registry does not hold is the staged line alone, whatever other versions the registry has" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged_bytes = try overlay.testCondaStamped(a, "acme/libbase", "0.2.0", "{\"schema\":2,\"name\":\"acme/libbase\",\"version\":\"0.2.0\",\"deps\":[]}", "new");
    const dir = try overlay.testSet(a, &tmp, &.{.{ .name = "acme/libbase", .version = "0.2.0", .files = &.{.{ .bytes = staged_bytes }} }});
    var why: []const u8 = "";
    const ov = try overlay.load(a, dir, &why);
    var asked = false;
    var diag: resolve.Diagnostic = .{};
    const source = overlay.Index(Registry){ .overlay = &ov, .inner = try registry(a), .asked = &asked };

    const m = ov.member("acme/libbase").?;
    const staged_line = try overlay.indexText(a, m);
    try std.testing.expectEqualStrings(staged_line, (try source.fetch(a, "acme/libbase", &diag)).?);
    try std.testing.expect(asked);
    // The registry's 0.1.0 is hidden, as before the registry was asked.
    const roots = [_]resolve.Root{.{ .name = "acme/libbase", .requirement = "=0.1.0" }};
    try std.testing.expectError(error.ResolveFailed, resolve.resolve(a, source, .{ .mojo = "1.0.0", .roots = &roots }, &diag));

    // A package the registry has no record of is the staged line alone too.
    const none = overlay.Index(Registry){ .overlay = &ov, .inner = .{ .libbase = "", .regdep = "" }, .asked = &asked };
    try std.testing.expectEqualStrings(staged_line, (try none.fetch(a, "acme/libbase", &diag)).?);
    // And a package the set does not hold is the registry's text, as it is.
    const reg = try registry(a);
    try std.testing.expectEqualStrings(reg.regdep, (try source.fetch(a, "acme/regdep", &diag)).?);
    try std.testing.expect((try source.fetch(a, "acme/unknown", &diag)) == null);
}

/// The staged member of `addSet`, and the registry's 0.1.0 line with `builds` as given.
fn merged(a: Allocator, ov: overlay.Overlay, held: []const u8) ![]const resolve.Record {
    var diag: resolve.Diagnostic = .{};
    return resolve.parseIndex(a, "acme/libbase", try overlay.mergedIndexText(a, ov.member("acme/libbase").?, held), &diag);
}

test "the merged line holds the registry's builds and the staged one by compiler, with the top-level build of the lowest, and keeps the registry's other lines and fields" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const staged_bytes = try overlay.testCondaStamped(a, "acme/libbase", "0.1.0", libbase_meta, "1.1.0 linux");
    const ov = try addSet(a, &tmp, staged_bytes);
    const b10 = try build(a, "acme.libbase", "0.1.0", "1.0.0", "linux-64", sha_a, 20);
    const b12 = try build(a, "acme.libbase", "0.1.0", "1.2.0", "linux-64", sha_b, 21);
    const other = try oldLine(a, "acme/libbase", "0.0.9", "", try build(a, "acme.libbase", "0.0.9", "1.0.0", "linux-64", sha_c, 9));

    // A registry version with builds for 1.0.0 and 1.2.0 gets the staged 1.1.0 build between them.
    const held = try std.mem.concat(a, u8, &.{ other, try line(a, "acme/libbase", "0.1.0", "{\"name\":\"acme/regdep\"}", &.{ b10, b12 }) });
    const recs = try merged(a, ov, held);
    try std.testing.expectEqual(@as(usize, 2), recs.len);
    try std.testing.expectEqualStrings("0.0.9", recs[0].version);
    const r = recs[1];
    try std.testing.expectEqualStrings("0.1.0", r.version);
    try std.testing.expectEqual(@as(usize, 3), r.builds.len);
    try std.testing.expectEqualStrings("mojo1.0.0_0", r.builds[0].build);
    try std.testing.expectEqualStrings("mojo1.1.0_0", r.builds[1].build);
    try std.testing.expectEqualStrings(&sha256Hex(staged_bytes), r.builds[1].files[0].sha256);
    try std.testing.expectEqualStrings("mojo1.2.0_0", r.builds[2].build);
    try std.testing.expectEqualStrings(sha_b, r.builds[2].files[0].sha256);
    try std.testing.expectEqualStrings("mojo1.0.0_0", r.build);
    try std.testing.expectEqualStrings("==1.0.0", r.requires_mojo);
    try std.testing.expectEqualStrings(sha_a, r.files[0].sha256);
    try std.testing.expectEqual(@as(usize, 1), r.deps.len);
    try std.testing.expectEqualStrings("acme/regdep", r.deps[0].name);

    // A version with a 1.2.0 build alone: the staged 1.1.0 build becomes the primary one.
    const only12 = try merged(a, ov, try line(a, "acme/libbase", "0.1.0", "", &.{b12}));
    try std.testing.expectEqual(@as(usize, 1), only12.len);
    try std.testing.expectEqualStrings("mojo1.1.0_0", only12[0].build);
    try std.testing.expectEqualStrings("==1.1.0", only12[0].requires_mojo);
    try std.testing.expectEqualStrings(&sha256Hex(staged_bytes), only12[0].files[0].sha256);
    try std.testing.expectEqual(@as(usize, 2), only12[0].builds.len);

    // A build both hold is the staged one: the registry's other bytes under that name are for registryDiffers to refuse.
    const b11 = try build(a, "acme.libbase", "0.1.0", "1.1.0", "linux-64", sha_c, 22);
    const both = try merged(a, ov, try line(a, "acme/libbase", "0.1.0", "", &.{ b10, b11 }));
    try std.testing.expectEqual(@as(usize, 2), both[0].builds.len);
    try std.testing.expectEqualStrings(&sha256Hex(staged_bytes), both[0].builds[1].files[0].sha256);
    try std.testing.expect(!std.mem.eql(u8, sha_c, both[0].builds[1].files[0].sha256));
    const why = try overlay.registryDiffers(a, ov.dir, ov.member("acme/libbase").?, try resolveRecords(a, try line(a, "acme/libbase", "0.1.0", "", &.{ b10, b11 })));
    try std.testing.expect(why != null);

    // Lines are read as the registry writes them: CRLF, blank lines, a line of the version twice (the second as it is).
    const crlf = try std.mem.concat(a, u8, &.{ "\r\n", std.mem.trimRight(u8, other, "\n"), "\r\n\r\n", std.mem.trimRight(u8, try line(a, "acme/libbase", "0.1.0", "", &.{b10}), "\n"), "\r\n" });
    const text = try overlay.mergedIndexText(a, ov.member("acme/libbase").?, crlf);
    try std.testing.expect(std.mem.startsWith(u8, text, std.mem.trimRight(u8, other, "\n")));
    var all: resolve.Diagnostic = .{};
    try std.testing.expectEqual(@as(usize, 2), (try resolve.parseIndex(a, "acme/libbase", text, &all)).len);
    const twice = try std.mem.concat(a, u8, &.{ try line(a, "acme/libbase", "0.1.0", "", &.{b10}), try line(a, "acme/libbase", "0.1.0", "", &.{b12}) });
    const twice_text = try overlay.mergedIndexText(a, ov.member("acme/libbase").?, twice);
    try std.testing.expect(std.mem.endsWith(u8, twice_text, try line(a, "acme/libbase", "0.1.0", "", &.{b12})));
}

fn resolveRecords(a: Allocator, text: []const u8) ![]const resolve.Record {
    var diag: resolve.Diagnostic = .{};
    return resolve.parseIndex(a, "acme/libbase", text, &diag);
}

test "a registry line the merge cannot add to leaves the staged line alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ov = try addSet(a, &tmp, try overlay.testCondaStamped(a, "acme/libbase", "0.1.0", libbase_meta, "1.1.0 linux"));
    const m = ov.member("acme/libbase").?;
    const staged_line = try overlay.indexText(a, m);
    const b10 = try build(a, "acme.libbase", "0.1.0", "1.0.0", "linux-64", sha_a, 20);
    const cases = [_][]const u8{
        "",
        "\n\n",
        "not json\n",
        "[]\n",
        "{\"v\":2,\"name\":\"acme/libbase\"}\n",
        "{\"v\":2,\"name\":\"acme/libbase\",\"version\":\"0.1.0\"}\n",
        "{\"version\":\"0.1.0\",\"builds\":\"mojo1.0.0_0\"}\n",
        "{\"version\":\"0.1.0\",\"builds\":[1]}\n",
        "{\"version\":\"0.1.0\",\"builds\":[{\"requires_mojo\":\"==1.0.0\",\"files\":[]}]}\n",
        "{\"version\":\"0.1.0\",\"builds\":[{\"build\":\"py3_0\",\"requires_mojo\":\"==1.0.0\",\"files\":[]}]}\n",
        "{\"version\":\"0.1.0\",\"build\":\"mojo1.0.0_0\",\"requires_mojo\":\"==1.0.0\"}\n",
    };
    for (cases) |held| {
        try std.testing.expectEqualStrings(staged_line, try overlay.mergedIndexText(a, m, held));
    }
    // A bad line after the line of the version is the same: the registry's text is not one this reads.
    const good = try line(a, "acme/libbase", "0.1.0", "", &.{b10});
    try std.testing.expectEqualStrings(staged_line, try overlay.mergedIndexText(a, m, try std.mem.concat(a, u8, &.{ good, "not json\n" })));
}

fn mergeWithFailures(a: Allocator) !void {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const m = overlay.Member{
        .name = "acme/libbase",
        .version = "0.1.0",
        .deps = &.{},
        .native = &.{},
        .builds = &.{.{ .build = "mojo1.1.0_0", .requires_mojo = "==1.1.0", .files = &.{.{ .subdir = "linux-64", .filename = "mojo-acme.libbase-0.1.0-mojo1.1.0_0.conda", .sha256 = sha_a, .size = 5 }} }},
    };
    const old = "{\"v\":2,\"name\":\"acme/libbase\",\"version\":\"0.0.9\",\"build\":\"mojo1.0.0_0\",\"requires_mojo\":\"==1.0.0\",\"files\":[]}\n";
    const cur = "{\"v\":2,\"name\":\"acme/libbase\",\"version\":\"0.1.0\",\"build\":\"mojo1.0.0_0\",\"requires_mojo\":\"==1.0.0\",\"files\":[]}\n";
    _ = try overlay.mergedIndexText(arena, &m, old ++ cur);
}

test "an allocation that fails while a line is merged is an out-of-memory error and leaks nothing" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, mergeWithFailures, .{});
}
