//! Tests of `mopm stage` with several Mojo compilers (stage_cmd.zig): the flags, a new version staged with every build, a build added
//! to a published version, and what is refused. The workspace and the stand-in registry are those of stage_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const conda = core.conda;
const source_digest = core.source_digest;
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const stage = @import("stage_cmd.zig");
const st = @import("stage_test.zig");
const Console = gp.Console;
const contains = st.contains;

const Ran = struct { code: u8, out: []const u8, err: []const u8 };

fn runWith(fx: st.Fx, stub: *st.Stub, flags: stage.Flags) !Ran {
    var console = Console.init(fx.a, null);
    const code = try stage.run(.{ .arena = fx.a, .net = stub.net(), .console = &console, .api_v2_url = st.api, .flags = flags });
    return .{ .code = code, .out = console.out.items, .err = console.err.items };
}

/// `--artifacts <mojo>=<dir>` for each of `pairs` ({compiler, directory below the temporary directory}).
fn named(fx: st.Fx, out: []const u8, pairs: []const [2][]const u8) !stage.Flags {
    var builds = std.ArrayList(stage.Build).init(fx.a);
    for (pairs) |p| try builds.append(.{ .compiler = p[0], .artifacts = try std.fs.path.join(fx.a, &.{ fx.root, p[1] }) });
    return .{
        .workspace_root = try std.fs.path.join(fx.a, &.{ fx.root, "ws" }),
        .builds = builds.items,
        .out = try std.fs.path.join(fx.a, &.{ fx.root, out }),
        .registry = st.api,
    };
}

/// The artifact of `pkg_a` for the directory `art` (below the temporary directory), for a compiler whose bytes differ.
fn artifact(fx: st.Fx, art: []const u8, subdir: []const u8, name: []const u8) !void {
    try fx.put(try std.fmt.allocPrint(fx.a, "{s}/{s}/example/{s}.mojoc", .{ art, subdir, name }), try std.fmt.allocPrint(fx.a, "the mojoc of {s} in {s}", .{ name, art }));
}

fn readPlan(fx: st.Fx, out: []const u8) !plan_mod.Plan {
    const text = try fx.tmp.dir.readFileAlloc(fx.a, try std.fmt.allocPrint(fx.a, "{s}/plan.json", .{out}), 1 << 26);
    const parsed = try plan_mod.parsePlan(fx.a, text);
    try std.testing.expect(parsed == .ok);
    return parsed.ok;
}

fn fileJson(a: Allocator, subdir: []const u8, filename: []const u8, sha: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"subdir\":\"{s}\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":100}}", .{ subdir, filename, sha });
}

/// A published `example/pkg_a` 1.0.0 with the builds `builds` (JSON text of the entries of `builds`), the manifest hash `manifest`
/// and the files of its first build at the top level, as the registry lists them.
fn publishedBuilds(a: Allocator, manifest: []const u8, first_files: []const u8, builds: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"name\":\"example/pkg_a\",\"version\":\"1.0.0\",\"state\":\"published\",\"published_at\":\"2026-10-01T00:00:00Z\",\"requires_mojo\":\"==1.0.0\",\"deps\":[],\"native\":[],\"files\":[{s}],\"manifest_sha256\":\"{s}\",\"provenance\":{{\"kind\":\"none\"}},\"builds\":[{s}]}}", .{ first_files, manifest, builds });
}

fn buildJson(a: Allocator, compiler: []const u8, files: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"build\":\"mojo{s}_0\",\"requires_mojo\":\"=={s}\",\"files\":[{s}]}}", .{ compiler, compiler, files });
}

fn packName(compiler: []const u8) []const u8 {
    return if (std.mem.eql(u8, compiler, "1.0.0")) "mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda" else if (std.mem.eql(u8, compiler, "1.1.0")) "mojo-example.pkg_a-1.0.0-mojo1.1.0_0.conda" else "mojo-example.pkg_a-1.0.0-mojo1.2.0_0.conda";
}

fn serve(a: Allocator, stub: *st.Stub, body: []const u8) !void {
    stub.entries = try a.dupe(st.Stub.Entry, &.{.{ .path = "/packages/example/pkg_a/1.0.0", .status = 200, .body = body }});
}

/// The workspace of the add tests: `pkg_a` 1.0.0 with artifacts for 1.0.0 (`art`), 1.1.0 (`art11`) and 1.2.0 (`art12`), staged once
/// for 1.0.0 alone, which gives the registry its published state: the returned plan member.
fn publishedWithOneBuild(fx: st.Fx, stub: *st.Stub) !plan_mod.Member {
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/README.md", "# pkg_a\n");
    // A library directory, so the member carries a source digest and a build can be added to its version.
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def first(): pass\n");
    try artifact(fx, "art11", "noarch", "pkg_a");
    try artifact(fx, "art12", "noarch", "pkg_a");
    const first = try runWith(fx, stub, try named(fx, "first", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 0), first.code);
    return (try readPlan(fx, "first")).members[0];
}

// ------------------------------------------------------------------ the flags

test "the flags: --artifacts <mojo>=<dir> once per compiler, or one --artifacts <dir> with one --compiler" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--workspace-root", "ws", "--out", "set", "--registry", "prod" };

    // Several compilers: no --compiler, each --artifacts names its own.
    const many = (try stage.parseFlags(a, &(base ++ [_][]const u8{ "--artifacts", "1.1.0=art/new", "--artifacts", "1.0.0=art/old", "pkg_a" }))).ok;
    try std.testing.expectEqual(@as(usize, 2), many.builds.len);
    try std.testing.expectEqualStrings("1.1.0", many.builds[0].compiler);
    try std.testing.expectEqualStrings("art/new", many.builds[0].artifacts);
    try std.testing.expectEqualStrings("1.0.0", many.builds[1].compiler);
    try std.testing.expectEqualStrings("art/old", many.builds[1].artifacts);
    try std.testing.expectEqualStrings("", many.compiler);
    try std.testing.expectEqualStrings("pkg_a", many.packages[0]);
    // A directory with a '=' in its own name keeps it.
    const eq = (try stage.parseFlags(a, &(base ++ [_][]const u8{ "--artifacts", "1.0.0=a=b" }))).ok;
    try std.testing.expectEqualStrings("a=b", eq.builds[0].artifacts);
    // The builds come in the order of the compiler versions, whatever the order they were given in.
    const sorted = try stage.buildsOf(a, many);
    try std.testing.expectEqualStrings("1.0.0", sorted[0].compiler);
    try std.testing.expectEqualStrings("1.1.0", sorted[1].compiler);
    const ten = try stage.buildsOf(a, (try stage.parseFlags(a, &(base ++ [_][]const u8{ "--artifacts", "1.10.0=x", "--artifacts", "1.9.0=y" }))).ok);
    try std.testing.expectEqualStrings("1.9.0", ten[0].compiler);

    // One compiler: as before, and a value with a '=' that does not start with a compiler is a directory.
    const one = (try stage.parseFlags(a, &(base ++ [_][]const u8{ "--artifacts", "art", "--compiler", "1.0.0" }))).ok;
    try std.testing.expectEqualStrings("art", one.artifacts);
    try std.testing.expectEqualStrings("1.0.0", one.compiler);
    try std.testing.expectEqual(@as(usize, 0), one.builds.len);
    const single = try stage.buildsOf(a, one);
    try std.testing.expectEqual(@as(usize, 1), single.len);
    try std.testing.expectEqualStrings("art", single[0].artifacts);
    const odd = (try stage.parseFlags(a, &(base ++ [_][]const u8{ "--artifacts", "v1=dir", "--compiler", "1.0.0" }))).ok;
    try std.testing.expectEqualStrings("v1=dir", odd.artifacts);
}

test "the flags: the forms are not mixed, a compiler is named once, and each refusal says what to do" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_][]const u8{ "--workspace-root", "ws", "--out", "set", "--registry", "prod" };
    const Case = struct { args: []const []const u8, why: []const u8 };
    const cases = [_]Case{
        .{ .args = &.{ "--artifacts", "1.0.0=a", "--artifacts", "art" }, .why = "--artifacts is given both as <dir> and as <mojo version>=<dir>; use one form" },
        .{ .args = &.{ "--artifacts", "art", "--artifacts", "1.0.0=a", "--compiler", "1.0.0" }, .why = "--artifacts is given both as <dir> and as <mojo version>=<dir>; use one form" },
        .{ .args = &.{ "--artifacts", "a", "--artifacts", "b", "--compiler", "1.0.0" }, .why = "--artifacts <dir> is given more than once; with one --compiler give one directory, or name each compiler as --artifacts <mojo version>=<dir>" },
        .{ .args = &.{ "--artifacts", "1.0.0=a", "--artifacts", "1.0.0=b" }, .why = "--artifacts names the compiler 1.0.0 twice" },
        .{ .args = &.{ "--artifacts", "1.0.0=a", "--artifacts", "1.1.0=b", "--compiler", "1.0.0" }, .why = "--compiler cannot be used with --artifacts <mojo version>=<dir>: the compiler is the text before the '='" },
        .{ .args = &.{ "--artifacts", "1.0.0=" }, .why = "--artifacts 1.0.0=: no directory after the '='" },
        .{ .args = &.{ "--artifacts", "art" }, .why = "--compiler <exact mojo version> is required" },
        .{ .args = &.{ "--artifacts", "art", "--compiler", "1.0.0", "--compiler", "1.1.0" }, .why = "--compiler is given twice; to stage several compilers, name each one in --artifacts <mojo version>=<dir> and leave --compiler out" },
        .{ .args = &.{ "--artifacts", "" }, .why = "--artifacts needs a value" },
        .{ .args = &.{"--artifacts"}, .why = "--artifacts needs a value" },
        .{ .args = &.{ "--compiler", "1.0.0" }, .why = "--artifacts <dir> is required" },
    };
    for (cases) |c| {
        var args = std.ArrayList([]const u8).init(a);
        try args.appendSlice(&base);
        try args.appendSlice(c.args);
        const got = try stage.parseFlags(a, args.items);
        try std.testing.expect(got == .bad);
        try std.testing.expectEqualStrings(c.why, got.bad);
    }
    // --out and --registry are still needed in the form with several compilers.
    try std.testing.expectEqualStrings("--out <dir> is required", (try stage.parseFlags(a, &.{ "--workspace-root", "ws", "--artifacts", "1.0.0=a", "--registry", "prod" })).bad);
    try std.testing.expect(std.mem.startsWith(u8, (try stage.parseFlags(a, &.{ "--workspace-root", "ws", "--artifacts", "1.0.0=a", "--out", "set" })).bad, "--registry is required"));
    try std.testing.expectEqualStrings("--workspace-root <dir> is required", (try stage.parseFlags(a, &.{ "--artifacts", "1.0.0=a", "--out", "set", "--registry", "prod" })).bad);
}

test "the usage names both forms of --artifacts" {
    try std.testing.expect(contains(stage.usage, "--artifacts <dir> --compiler <mojo version>"));
    try std.testing.expect(contains(stage.usage, "--artifacts <mojo version>=<dir>..."));
}

// ------------------------------------------------------- a new version, every build

test "a new version staged for two compilers has both builds in its plan, in compiler order, with every file written" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/README.md", "# pkg_a\n");
    try artifact(fx, "art", "noarch", "pkg_a");
    try artifact(fx, "art", "linux-64", "pkg_a");
    try artifact(fx, "art11", "noarch", "pkg_a");
    try artifact(fx, "art11", "linux-64", "pkg_a");
    var stub = st.newStub(a);
    // Given the newer compiler first: the plan is in the order of the versions all the same.
    const r = try runWith(fx, &stub, try named(fx, "two", &.{ .{ "1.1.0", "art11" }, .{ "1.0.0", "art" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "upload example/pkg_a 1.0.0 (4 files)"));
    try std.testing.expect(contains(r.out, "staged 1 members") and contains(r.out, "1 to upload, 0 skipped, 0 refused"));

    const m = (try readPlan(fx, "two")).members[0];
    try std.testing.expectEqual(plan_mod.Action.upload, m.action);
    try std.testing.expectEqual(@as(usize, 4), m.files.len);
    const want = [_][2][]const u8{ .{ "noarch", "mojo1.0.0_0" }, .{ "linux-64", "mojo1.0.0_0" }, .{ "noarch", "mojo1.1.0_0" }, .{ "linux-64", "mojo1.1.0_0" } };
    for (m.files, want) |f, w| {
        try std.testing.expectEqualStrings(w[0], f.subdir);
        try std.testing.expect(std.mem.endsWith(u8, f.filename, try std.fmt.allocPrint(a, "-{s}.conda", .{w[1]})));
        // Each file is where the plan says, with the bytes it says.
        try std.testing.expect(fx.exists(try std.fmt.allocPrint(a, "two/{s}/{s}", .{ f.subdir, f.filename })));
    }
    try std.testing.expect(m.readme != null);
    var dir = try fx.tmp.dir.openDir("two", .{});
    defer dir.close();
    try std.testing.expect((try plan_mod.verify(a, dir, .{ .members = &.{m}, .sha256 = "" })) == .ok);
    // The files are those the packer makes for each compiler.
    const want_pack = try conda.pack(a, .{ .name = "example/pkg_a", .version = "1.0.0", .compiler = "1.1.0", .subdir = "linux-64", .mojoc = "the mojoc of pkg_a in art11" });
    try std.testing.expectEqualSlices(u8, want_pack.bytes, try fx.tmp.dir.readFileAlloc(a, try std.fmt.allocPrint(a, "two/linux-64/{s}", .{want_pack.file_name}), 1 << 20));
}

test "every compiler's files carry the same source digest, and the digest is that of the member's sources" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def f(): pass\n");
    try fx.put("ws/src/pkg_a/src/pkg_a/util/more.mojo", "def g(): pass\n");
    try artifact(fx, "art11", "noarch", "pkg_a");
    var stub = st.newStub(a);
    const r = try runWith(fx, &stub, try named(fx, "d", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    // A member with a library directory has no note.
    try std.testing.expectEqualStrings("", r.err);

    var diag: core.manifest.Diagnostic = .{};
    const m = try core.manifest.parse(a, try fx.tmp.dir.readFileAlloc(a, "ws/src/pkg_a/mopm.toml", 1 << 16), &diag);
    const digest = (try source_digest.ofPackage(a, m, try std.fs.path.join(a, &.{ fx.root, "ws/src/pkg_a" }), "mopm.toml")).digest;
    const needle = try std.fmt.allocPrint(a, "\"source_sha256\":\"{s}\"", .{&digest});
    const old = try fx.tmp.dir.readFileAlloc(a, "d/noarch/mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda", 1 << 20);
    const new = try fx.tmp.dir.readFileAlloc(a, "d/noarch/mojo-example.pkg_a-1.0.0-mojo1.1.0_0.conda", 1 << 20);
    try std.testing.expect(contains(old, needle));
    try std.testing.expect(contains(new, needle));

    // The metadata, which the registry compares, is the same in both, so the plan's one hash serves for both.
    const same = try conda.pack(a, .{ .name = "example/pkg_a", .version = "1.0.0", .compiler = "1.1.0", .subdir = "noarch", .mojoc = "the mojoc of pkg_a in art11", .source_sha256 = &digest });
    try std.testing.expectEqualSlices(u8, same.bytes, new);
    try std.testing.expectEqualStrings(&same.manifest_sha256, (try readPlan(fx, "d")).members[0].manifest_sha256);
}

test "a member with no library directory is staged with a note and no digest; every member is noted once, not once per compiler" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try artifact(fx, "art11", "noarch", "pkg_a");
    var stub = st.newStub(a);
    const r = try runWith(fx, &stub, try named(fx, "n", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("mopm: note: src/pkg_a does not exist, so example/pkg_a 1.0.0 carries no source digest; a build for another Mojo can then never be added to this version\n", r.err);
    try std.testing.expect(!contains(try fx.tmp.dir.readFileAlloc(a, "n/noarch/mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda", 1 << 20), "source_sha256"));
}

test "a library directory with something that is not a source stops the run, naming the member and the file" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def f(): pass\n");
    try fx.tmp.dir.symLink("/dev/null", "ws/src/pkg_a/src/pkg_a/null.mojo", .{});
    var stub = st.newStub(a);
    const r = try runWith(fx, &stub, try named(fx, "bad", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("mopm: example/pkg_a: source digest: src/pkg_a/null.mojo is a character device, neither a file nor a directory; remove it, or move it out of the library directory\n", r.err);
    try std.testing.expect(!fx.exists("bad"));
    try std.testing.expectEqual(@as(usize, 0), stub.asked.items.len);
}

test "a compiler with no artifact for a member is refused naming the compiler and the path, and nothing is written" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.tmp.dir.makePath("art11/noarch");
    var stub = st.newStub(a);
    const r = try runWith(fx, &stub, try named(fx, "missing", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    const want = try std.fmt.allocPrint(a, "mopm: example/pkg_a has no build artifact for Mojo 1.1.0: expected {s}/art11/<subdir>/example/pkg_a.mojoc for one of noarch, linux-64, linux-aarch64, osx-arm64\n", .{fx.root});
    try std.testing.expectEqualStrings(want, r.err);
    try std.testing.expect(!fx.exists("missing"));
    try std.testing.expectEqual(@as(usize, 0), stub.asked.items.len);
}

test "one compiler named as <mojo>=<dir> is staged as the form with --compiler stages it; a compiler that is not a version is refused" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = st.newStub(a);
    var r = try runWith(fx, &stub, try named(fx, "x", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    r = try runWith(fx, &stub, try fx.flags("y", &.{}));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings(try fx.tmp.dir.readFileAlloc(a, "x/plan.json", 1 << 20), try fx.tmp.dir.readFileAlloc(a, "y/plan.json", 1 << 20));
    // A caller that builds the flags by hand with a compiler that is not a version is refused at the member.
    r = try runWith(fx, &stub, try named(fx, "z", &.{.{ "1.x", "art" }}));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "--compiler 1.x: an exact Mojo version is digits and dots, such as 1.0.0"));
}

test "more files than a version may have are refused before anything is written" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    const subdirs = [_][]const u8{ "noarch", "linux-64", "linux-aarch64", "osx-arm64" };
    const compilers = [_][]const u8{ "1.0.0", "1.1.0", "1.2.0", "1.3.0", "1.4.0", "1.5.0" };
    var pairs = std.ArrayList([2][]const u8).init(a);
    for (compilers) |c| {
        const dir = try std.fmt.allocPrint(a, "art_{s}", .{c});
        for (subdirs) |s| try artifact(fx, dir, s, "pkg_a");
        try pairs.append(.{ c, dir });
    }
    var stub = st.newStub(a);
    // Five compilers on four platforms is twenty files: the most there is.
    var r = try runWith(fx, &stub, try named(fx, "twenty", pairs.items[0..5]));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqual(@as(usize, 20), (try readPlan(fx, "twenty")).members[0].files.len);
    r = try runWith(fx, &stub, try named(fx, "twenty_four", pairs.items));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqualStrings("mopm: example/pkg_a would be 24 files for 6 compilers; a version has at most 20 files\n", r.err);
    try std.testing.expect(!fx.exists("twenty_four"));
}

// ------------------------------------------------------- adding to a published version

test "a build for another compiler is added to a published version: an upload of that build's files alone, and a line that says so" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const have = try buildJson(a, "1.0.0", try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256));
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256), have));

    // Staged for both compilers: the first is the registry's, byte for byte; the second is the add.
    const r = try runWith(fx, &stub, try named(fx, "add", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.1.0_0 (noarch)\n"));
    try std.testing.expect(!contains(r.out, "upload example/pkg_a"));
    try std.testing.expect(contains(r.out, "1 to upload, 0 skipped, 0 refused"));
    const m = (try readPlan(fx, "add")).members[0];
    try std.testing.expectEqual(plan_mod.Action.upload, m.action);
    try std.testing.expectEqual(@as(usize, 1), m.files.len);
    try std.testing.expectEqualStrings(packName("1.1.0"), m.files[0].filename);
    try std.testing.expectEqualStrings(first.manifest_sha256, m.manifest_sha256);
    // The published version's readme is not sent again.
    try std.testing.expect(m.readme == null);
    try std.testing.expect(!fx.exists("add/example/pkg_a/README.md"));
    // Only the new file is written.
    try std.testing.expect(fx.exists(try std.fmt.allocPrint(a, "add/noarch/{s}", .{packName("1.1.0")})));
    try std.testing.expect(!fx.exists(try std.fmt.allocPrint(a, "add/noarch/{s}", .{packName("1.0.0")})));
    var dir = try fx.tmp.dir.openDir("add", .{});
    defer dir.close();
    try std.testing.expect((try plan_mod.verify(a, dir, .{ .members = &.{m}, .sha256 = "" })) == .ok);
    try std.testing.expect(!stub.token_sent);

    // The same add, staged for the new compiler alone.
    const only = try runWith(fx, &stub, try named(fx, "only", &.{.{ "1.1.0", "art11" }}));
    try std.testing.expectEqual(@as(u8, 0), only.code);
    const same = (try readPlan(fx, "only")).members[0];
    try std.testing.expectEqualStrings(m.files[0].sha256, same.files[0].sha256);
    // And with the form that names the compiler apart.
    var flags = try fx.flags("form", &.{});
    flags.compiler = "1.1.0";
    flags.artifacts = try std.fs.path.join(a, &.{ fx.root, "art11" });
    const old_form = try runWith(fx, &stub, flags);
    try std.testing.expectEqual(@as(u8, 0), old_form.code);
    try std.testing.expect(contains(old_form.out, "add    example/pkg_a 1.0.0: build mojo1.1.0_0 (noarch)"));
}

test "the files of an add are one build's, whatever platforms it has" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    try artifact(fx, "art11", "linux-64", "pkg_a");
    try artifact(fx, "art11", "osx-arm64", "pkg_a");
    const have = try buildJson(a, "1.0.0", try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256));
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256), have));
    const r = try runWith(fx, &stub, try named(fx, "add3", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.1.0_0 (noarch, linux-64, osx-arm64)\n"));
    try std.testing.expectEqual(@as(usize, 3), (try readPlan(fx, "add3")).members[0].files.len);
}

test "a published build staged again with the same bytes is skipped, whatever other builds the version has" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, f10, try buildJson(a, "1.0.0", f10)));
    var r = try runWith(fx, &stub, try named(fx, "skip", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "skip   example/pkg_a 1.0.0: already published with these bytes"));
    try std.testing.expectEqual(plan_mod.Action.skip, (try readPlan(fx, "skip")).members[0].action);
    try std.testing.expect(!fx.exists(try std.fmt.allocPrint(a, "skip/noarch/{s}", .{packName("1.0.0")})));

    // The version has a second build too, which this stage does not mention: nothing to do still.
    const second = try runWith(fx, &stub, try named(fx, "second", &.{.{ "1.1.0", "art11" }}));
    try std.testing.expectEqual(@as(u8, 0), second.code);
    const add_plan = (try readPlan(fx, "second")).members[0];
    const f11 = try fileJson(a, "noarch", packName("1.1.0"), add_plan.files[0].sha256);
    const both = try std.mem.join(a, ",", &.{ try buildJson(a, "1.0.0", f10), try buildJson(a, "1.1.0", f11) });
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, f10, both));
    r = try runWith(fx, &stub, try named(fx, "again", &.{.{ "1.0.0", "art" }}));
    try std.testing.expect(r.code == 0 and contains(r.out, "skip   example/pkg_a 1.0.0"));
    // Both staged, both held, byte for byte: skip.
    r = try runWith(fx, &stub, try named(fx, "both", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expect(r.code == 0 and contains(r.out, "skip   example/pkg_a 1.0.0"));
    try std.testing.expectEqual(plan_mod.Action.skip, (try readPlan(fx, "both")).members[0].action);
}

test "a published file is never replaced: a build the version has with other bytes is refused, and the plan says why" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const other = try fileJson(a, "noarch", packName("1.0.0"), "1" ** 64);
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, other, try buildJson(a, "1.0.0", other)));
    // Even with a new build beside it, the replaced file decides.
    const r = try runWith(fx, &stub, try named(fx, "replaced", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "mopm: refused: example/pkg_a 1.0.0 is already published with different bytes (noarch/mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda is not what the registry holds); a published file is never replaced, so bump the version\n"));
    const m = (try readPlan(fx, "replaced")).members[0];
    try std.testing.expectEqual(plan_mod.Action.refuse, m.action);
    try std.testing.expect(contains(m.reason, "a published file is never replaced"));
    try std.testing.expect(!fx.exists(try std.fmt.allocPrint(a, "replaced/noarch/{s}", .{packName("1.1.0")})));
}

test "a build the version has with a file more or fewer than the stage is refused" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    const extra = try fileJson(a, "linux-64", packName("1.0.0"), first.files[0].sha256);
    const both = try std.mem.join(a, ",", &.{ f10, extra });
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, both, try buildJson(a, "1.0.0", both)));
    const r = try runWith(fx, &stub, try named(fx, "extra", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "example/pkg_a 1.0.0 is already published with 2 files and this stages 1 for mojo1.0.0_0; a published file is never replaced, so bump the version"));
}

test "a build from other sources than the published version is not added: the metadata must be the version's" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    const elsewhere = "9" ** 64;
    try serve(a, &stub, try publishedBuilds(a, elsewhere, f10, try buildJson(a, "1.0.0", f10)));
    const r = try runWith(fx, &stub, try named(fx, "sources", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    const want = try std.fmt.allocPrint(a, "example/pkg_a 1.0.0 is already published, and the build mojo1.1.0_0 was built from other sources than the published version (the metadata differs: the registry's manifest_sha256 is {s}, this stages {s}); a build for another Mojo is added only to the same sources, so bump the version", .{ elsewhere, first.manifest_sha256 });
    try std.testing.expect(contains(r.err, want));
    const m = (try readPlan(fx, "sources")).members[0];
    try std.testing.expectEqual(plan_mod.Action.refuse, m.action);
    try std.testing.expect(contains(m.reason, "was built from other sources than the published version"));
    // A change of a source file after the version was published is such a case: the digest, hence the hash, moves.
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def f(): pass\n");
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, f10, try buildJson(a, "1.0.0", f10)));
    const changed = try runWith(fx, &stub, try named(fx, "changed", &.{.{ "1.1.0", "art11" }}));
    try std.testing.expectEqual(@as(u8, 1), changed.code);
    try std.testing.expect(contains(changed.err, "was built from other sources than the published version"));
}

test "two builds the version lacks are refused: one Mojo build per publish" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, f10, try buildJson(a, "1.0.0", f10)));
    const r = try runWith(fx, &stub, try named(fx, "two_new", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" }, .{ "1.2.0", "art12" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "example/pkg_a 1.0.0 is already published and this stages 2 builds it does not have (mojo1.1.0_0, mojo1.2.0_0); the registry takes one Mojo build per publish, so stage one of them"));
    try std.testing.expectEqual(plan_mod.Action.refuse, (try readPlan(fx, "two_new")).members[0].action);
    // Staging one of them is the way out.
    const one = try runWith(fx, &stub, try named(fx, "one_new", &.{.{ "1.2.0", "art12" }}));
    try std.testing.expect(one.code == 0 and contains(one.out, "add    example/pkg_a 1.0.0: build mojo1.2.0_0 (noarch)"));
}

test "a yanked or burned version takes no build, whatever the stage holds" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    const live = try publishedBuilds(a, first.manifest_sha256, f10, try buildJson(a, "1.0.0", f10));
    const yanked = try std.mem.replaceOwned(u8, a, live, "\"state\":\"published\"", "\"state\":\"yanked\",\"yank_reason\":\"broken\"");
    try serve(a, &stub, yanked);
    var r = try runWith(fx, &stub, try named(fx, "yanked", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expect(r.code == 1 and contains(r.err, "example/pkg_a 1.0.0 is yanked: broken"));
    const burned = try std.mem.replaceOwned(u8, a, live, "\"state\":\"published\"", "\"state\":\"tombstoned\"");
    try serve(a, &stub, burned);
    r = try runWith(fx, &stub, try named(fx, "burned", &.{.{ "1.1.0", "art11" }}));
    try std.testing.expect(r.code == 1 and contains(r.err, "its number is burned; bump the version"));
}

test "a registry that lists no builds is read as a version with one build, and a build it lacks is added" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    const with = try publishedBuilds(a, first.manifest_sha256, f10, "");
    // The answer of a registry that predates `builds`: the key is not there.
    const cut = std.mem.indexOf(u8, with, ",\"builds\":[").?;
    const without = try std.fmt.allocPrint(a, "{s}}}", .{with[0..cut]});
    try serve(a, &stub, without);

    var r = try runWith(fx, &stub, try named(fx, "old_same", &.{.{ "1.0.0", "art" }}));
    try std.testing.expect(r.code == 0 and contains(r.out, "skip   example/pkg_a 1.0.0"));
    r = try runWith(fx, &stub, try named(fx, "old_add", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expect(r.code == 0 and contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.1.0_0 (noarch)"));
    // A file whose name has no build part reads as a build that no staged one is.
    const odd = try std.mem.replaceOwned(u8, a, without, packName("1.0.0"), "odd");
    try serve(a, &stub, odd);
    r = try runWith(fx, &stub, try named(fx, "old_odd", &.{.{ "1.0.0", "art" }}));
    try std.testing.expect(r.code == 0 and contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.0.0_0 (noarch)"));
    // And a version listing no files at all has no build either.
    const empty = try std.mem.replaceOwned(u8, a, without, f10, "");
    try serve(a, &stub, empty);
    r = try runWith(fx, &stub, try named(fx, "old_empty", &.{.{ "1.0.0", "art" }}));
    try std.testing.expect(r.code == 0 and contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.0.0_0 (noarch)"));
}

test "a set mixes new versions, adds, skips and refusals, each member judged alone" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const first = try publishedWithOneBuild(fx, &stub);
    try fx.member("pkg_b", "2.0.0", "");
    try artifact(fx, "art11", "noarch", "pkg_b");
    const f10 = try fileJson(a, "noarch", packName("1.0.0"), first.files[0].sha256);
    try serve(a, &stub, try publishedBuilds(a, first.manifest_sha256, f10, try buildJson(a, "1.0.0", f10)));
    const r = try runWith(fx, &stub, try named(fx, "mixed", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "add    example/pkg_a 1.0.0: build mojo1.1.0_0 (noarch)"));
    try std.testing.expect(contains(r.out, "upload example/pkg_b 2.0.0 (2 files)"));
    try std.testing.expect(contains(r.out, "staged 2 members") and contains(r.out, "2 to upload, 0 skipped, 0 refused"));
    const plan = try readPlan(fx, "mixed");
    try std.testing.expectEqual(@as(usize, 1), plan.members[0].files.len);
    try std.testing.expectEqual(@as(usize, 2), plan.members[1].files.len);
}

// ------------------------------------------------- versions packed before source digests

/// The file of `pkg_a` for `compiler` as a mopm that wrote no source digest packed it, from the artifact text `mojoc`.
fn packedBefore(a: Allocator, compiler: []const u8, mojoc: []const u8) !conda.Packed {
    return conda.pack(a, .{ .name = "example/pkg_a", .version = "1.0.0", .compiler = compiler, .subdir = "noarch", .mojoc = mojoc });
}

/// A workspace with `pkg_a` 1.0.0, which has a library directory, so a stage gives it a source digest.
fn digestWorkspace(fx: st.Fx) !void {
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def first(): pass\n");
    try artifact(fx, "art11", "noarch", "pkg_a");
}

/// The registry's answer for `pkg_a` 1.0.0 published with the builds `packs` (the files of 1.0.0 and 1.1.0, in that order).
fn servePacked(a: Allocator, stub: *st.Stub, packs: []const conda.Packed) !void {
    var builds = std.ArrayList([]const u8).init(a);
    const compilers = [_][]const u8{ "1.0.0", "1.1.0" };
    for (packs, 0..) |p, i| {
        try builds.append(try buildJson(a, compilers[i], try fileJson(a, "noarch", p.file_name, &p.sha256)));
    }
    try serve(a, stub, try publishedBuilds(a, &packs[0].manifest_sha256, try fileJson(a, "noarch", packs[0].file_name, &packs[0].sha256), try std.mem.join(a, ",", builds.items)));
}

test "a version packed before source digests is skipped again, with the reason, while its files differ from this pack only by the digest" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try digestWorkspace(fx);
    var stub = st.newStub(a);

    // Published by a mopm that wrote no digest, from the same artifact.
    try servePacked(a, &stub, &.{try packedBefore(a, "1.0.0", "the mojoc of pkg_a")});
    var r = try runWith(fx, &stub, try named(fx, "legacy", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(contains(r.out, "skip   example/pkg_a 1.0.0: already published, packed before source digests\n"));
    try std.testing.expect(contains(r.out, "staged 1 members") and contains(r.out, "0 to upload, 1 skipped, 0 refused"));
    const m = (try readPlan(fx, "legacy")).members[0];
    try std.testing.expectEqual(plan_mod.Action.skip, m.action);
    try std.testing.expectEqualStrings("already published, packed before source digests", m.reason);
    try std.testing.expect(!fx.exists(try std.fmt.allocPrint(a, "legacy/noarch/{s}", .{packName("1.0.0")})));

    // Both builds of the version were packed so: still a skip when both are staged.
    try servePacked(a, &stub, &.{ try packedBefore(a, "1.0.0", "the mojoc of pkg_a"), try packedBefore(a, "1.1.0", "the mojoc of pkg_a in art11") });
    r = try runWith(fx, &stub, try named(fx, "both", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expect(r.code == 0 and contains(r.out, "skip   example/pkg_a 1.0.0: already published, packed before source digests\n"));

    // Another artifact than the published one is another file, with or without the digest: refused.
    try servePacked(a, &stub, &.{try packedBefore(a, "1.0.0", "a mojoc built from other sources")});
    r = try runWith(fx, &stub, try named(fx, "other", &.{.{ "1.0.0", "art" }}));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "example/pkg_a 1.0.0 is already published with different bytes (noarch/mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda is not what the registry holds); a published file is never replaced, so bump the version"));
    try std.testing.expectEqual(plan_mod.Action.refuse, (try readPlan(fx, "other")).members[0].action);

    // A file the version holds beyond the staged ones is a difference the digest does not explain.
    const held = try packedBefore(a, "1.0.0", "the mojoc of pkg_a");
    const extra = try std.mem.join(a, ",", &.{ try fileJson(a, "noarch", held.file_name, &held.sha256), try fileJson(a, "linux-64", held.file_name, &held.sha256) });
    try serve(a, &stub, try publishedBuilds(a, &held.manifest_sha256, extra, try buildJson(a, "1.0.0", extra)));
    r = try runWith(fx, &stub, try named(fx, "more", &.{.{ "1.0.0", "art" }}));
    try std.testing.expect(r.code == 1 and contains(r.err, "is already published with different bytes"));
}

test "a build is not added to a version that cannot carry a source digest, and the message says to publish a new version" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    var stub = st.newStub(a);
    const want = "example/pkg_a 1.0.0 is already published without a source digest, so the build mojo1.1.0_0 cannot be added to it: the registry adds a build only to the same sources, and only a source digest shows that; publish a new version";

    // The staged member has no library directory, so no digest, and the registry's version has the same metadata.
    try fx.member("pkg_a", "1.0.0", "");
    try artifact(fx, "art11", "noarch", "pkg_a");
    const held = try packedBefore(a, "1.0.0", "the mojoc of pkg_a");
    try servePacked(a, &stub, &.{held});
    var r = try runWith(fx, &stub, try named(fx, "nodigest", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, want));
    var m = (try readPlan(fx, "nodigest")).members[0];
    try std.testing.expectEqual(plan_mod.Action.refuse, m.action);
    try std.testing.expectEqualStrings(want, m.reason);
    try std.testing.expect(!fx.exists(try std.fmt.allocPrint(a, "nodigest/noarch/{s}", .{packName("1.1.0")})));

    // The member has a digest now, but the version was published without one: the registry's metadata is the digest-less one.
    try fx.put("ws/src/pkg_a/src/pkg_a/lib.mojo", "def first(): pass\n");
    r = try runWith(fx, &stub, try named(fx, "legacy", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } }));
    try std.testing.expectEqual(@as(u8, 1), r.code);
    m = (try readPlan(fx, "legacy")).members[0];
    try std.testing.expectEqual(plan_mod.Action.refuse, m.action);
    try std.testing.expectEqualStrings(want, m.reason);

    // Staged for the new compiler alone it is the same: no digest to compare, nothing to add to.
    r = try runWith(fx, &stub, try named(fx, "alone", &.{.{ "1.1.0", "art11" }}));
    try std.testing.expect(r.code == 1 and contains(r.err, want));
}

test "a build staged against a published version whose artifacts are gone or unreadable stops the run with the reason, not a verdict" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try digestWorkspace(fx);
    var stub = st.newStub(a);
    const flags = try named(fx, "x", &.{ .{ "1.0.0", "art" }, .{ "1.1.0", "art11" } });
    const members = (try stage.discover(a, flags.workspace_root)).ok;
    try std.testing.expect(try stage.link(a, members) == null);
    const staged = (try stage.packMember(a, members, members[0], try stage.buildsOf(a, flags))).ok;
    const manifest = &staged.packs[0].manifest_sha256;

    // The version holds the 1.0.0 build and a file of 1.1.0 that is not the staged one, so the 1.1.0 build must be packed again
    // without the digest; its artifact has been removed since it was packed.
    const first = try fileJson(a, "noarch", staged.builds[0].packs[0].file_name, &staged.builds[0].packs[0].sha256);
    const other = try fileJson(a, "noarch", packName("1.1.0"), "9" ** 64);
    const both = try std.mem.join(a, ",", &.{ try buildJson(a, "1.0.0", first), try buildJson(a, "1.1.0", other) });
    try serve(a, &stub, try publishedBuilds(a, manifest, first, both));
    try fx.tmp.dir.deleteFile("art11/noarch/example/pkg_a.mojoc");
    const gone = try stage.check(a, stub.net(), st.api, "example/pkg_a", "1.0.0", staged.builds, manifest);
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "example/pkg_a has no build artifact for Mojo 1.1.0 below {s}/art11 any more", .{fx.root}), gone.bad);

    // The same for a build the version lacks: it is packed again to compare the metadata.
    try serve(a, &stub, try publishedBuilds(a, manifest, first, try buildJson(a, "1.0.0", first)));
    const lacking = try stage.check(a, stub.net(), st.api, "example/pkg_a", "1.0.0", staged.builds, manifest);
    try std.testing.expect(contains(lacking.bad, "has no build artifact for Mojo 1.1.0"));

    // An artifact that cannot be read is the reason itself.
    try fx.tmp.dir.makePath("art11/noarch/example/pkg_a.mojoc");
    const unreadable = try stage.check(a, stub.net(), st.api, "example/pkg_a", "1.0.0", staged.builds, manifest);
    try std.testing.expect(contains(unreadable.bad, "pkg_a.mojoc: IsDir"));
}
