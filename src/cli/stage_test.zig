//! Tests of `mopm stage` (stage_cmd.zig), by behaviour. A workspace is written to a temporary directory; the registry is a
//! stand-in that answers `GET /packages/<name>/<version>` from a table, so the tests need no socket. The real fake
//! registry, over a socket, with `publish --staged` after it, is driven by tests/drivers/stage_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const conda = core.conda;
const http = core.http;
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const stage = @import("stage_cmd.zig");
const Net = gp.Net;
const Console = gp.Console;

const api = "http://registry.test/api/v1";
const not_found = "{\"error\":{\"code\":\"version_not_found\",\"message\":\"no such version\",\"hint\":\"\"}}";

/// A registry that answers the version reads of a run from a table; a version it does not list is not found.
const Stub = struct {
    pub const Entry = struct { path: []const u8, status: u16, body: []const u8 };

    entries: []const Entry = &.{},
    /// Every URL asked for, and whether any request carried a token.
    asked: std.ArrayList([]const u8),
    token_sent: bool = false,
    broken: bool = false,

    fn net(s: *Stub) Net {
        return .{ .ptr = s, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, arena: Allocator, _: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        const s: *Stub = @ptrCast(@alignCast(ptr));
        try s.asked.append(try arena.dupe(u8, url));
        if (options.token != null) s.token_sent = true;
        if (s.broken) return error.ConnectionRefused;
        for (s.entries) |e| {
            if (std.mem.endsWith(u8, url, e.path)) return .{ .status = e.status, .body = e.body };
        }
        return .{ .status = 404, .body = not_found };
    }

    fn sleep(_: *anyopaque, _: u64) void {}
    fn now(_: *anyopaque) i64 {
        return 0;
    }
};

const Fx = struct {
    a: Allocator,
    tmp: std.testing.TmpDir,
    /// The temporary directory, absolute.
    root: []const u8,

    fn init(a: Allocator) !Fx {
        const tmp = std.testing.tmpDir(.{});
        return .{ .a = a, .tmp = tmp, .root = try tmp.dir.realpathAlloc(a, ".") };
    }

    fn deinit(fx: *Fx) void {
        fx.tmp.cleanup();
    }

    fn path(fx: Fx, rel: []const u8) ![]const u8 {
        return std.fs.path.join(fx.a, &.{ fx.root, rel });
    }

    fn put(fx: Fx, rel: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try fx.tmp.dir.makePath(d);
        try fx.tmp.dir.writeFile(rel, bytes);
    }

    fn read(fx: Fx, rel: []const u8) ![]u8 {
        return fx.tmp.dir.readFileAlloc(fx.a, rel, 1 << 26);
    }

    fn exists(fx: Fx, rel: []const u8) bool {
        fx.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }

    /// A member `name` at `version` in `ws/src/<name>`, with the lines of `[dependencies]`, and its noarch artifact.
    fn member(fx: Fx, name: []const u8, version: []const u8, deps: []const u8) !void {
        const manifest = try std.fmt.allocPrint(fx.a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\nmojo = [\"1.0.0\"]\n\n[dependencies]\n{s}\n", .{ name, version, deps });
        try fx.put(try std.fmt.allocPrint(fx.a, "ws/src/{s}/mopm.toml", .{name}), manifest);
        try fx.put(try std.fmt.allocPrint(fx.a, "art/noarch/{s}.mojoc", .{name}), try std.fmt.allocPrint(fx.a, "the mojoc of {s}", .{name}));
    }

    /// `pkg_x = { path = "../pkg_x", version = "<req>" }`
    fn pathDep(fx: Fx, name: []const u8, req: []const u8) ![]const u8 {
        return std.fmt.allocPrint(fx.a, "{s} = {{ path = \"../{s}\", version = \"{s}\" }}\n", .{ name, name, req });
    }

    fn flags(fx: Fx, out: []const u8, packages: []const []const u8) !stage.Flags {
        return .{
            .workspace_root = try fx.path("ws"),
            .packages = packages,
            .artifacts = try fx.path("art"),
            .compiler = "1.0.0",
            .out = try fx.path(out),
            .registry = api,
        };
    }
};

const Ran = struct { code: u8, out: []const u8, err: []const u8 };

fn runStage(fx: Fx, stub: *Stub, out: []const u8, packages: []const []const u8) !Ran {
    var console = Console.init(fx.a, null);
    const code = try stage.run(.{ .arena = fx.a, .net = stub.net(), .console = &console, .api_url = api, .flags = try fx.flags(out, packages) });
    return .{ .code = code, .out = console.out.items, .err = console.err.items };
}

fn newStub(a: Allocator) Stub {
    return .{ .asked = std.ArrayList([]const u8).init(a) };
}

fn answer(a: Allocator, path: []const u8, status: u16, body: []const u8) ![]const Stub.Entry {
    return a.dupe(Stub.Entry, &.{.{ .path = path, .status = status, .body = body }});
}

fn readPlan(fx: Fx, out: []const u8) !plan_mod.Plan {
    const text = try fx.read(try std.fmt.allocPrint(fx.a, "{s}/plan.json", .{out}));
    const parsed = try plan_mod.parsePlan(fx.a, text);
    try std.testing.expect(parsed == .ok);
    return parsed.ok;
}

fn names(a: Allocator, plan: plan_mod.Plan) ![]const u8 {
    var list = std.ArrayList([]const u8).init(a);
    for (plan.members) |m| try list.append(m.name);
    return std.mem.join(a, ",", list.items);
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn arenaTest() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

// ------------------------------------------------------------------------ order

test "a chain is staged in dependency order, whatever the order of the names" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    // The names sort the other way round from the dependencies: pkg_a needs pkg_b, which needs pkg_c.
    try fx.member("pkg_c", "1.0.0", "");
    try fx.member("pkg_b", "1.2.0", try fx.pathDep("pkg_c", "1.0"));
    try fx.member("pkg_a", "0.3.0", try fx.pathDep("pkg_b", "^1.1"));
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "chain", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const plan = try readPlan(fx, "chain");
    try std.testing.expectEqualStrings("pkg_c,pkg_b,pkg_a", try names(a, plan));
    for (plan.members) |m| try std.testing.expectEqual(plan_mod.Action.upload, m.action);
    try std.testing.expect(contains(r.out, "staged 3 members"));
    try std.testing.expect(!stub.token_sent);
    try std.testing.expectEqual(@as(usize, 3), stub.asked.items.len);
    // The stand-in is a registry: it is never slept on, and its clock stands still.
    stub.net().vtable.sleep(&stub, 1);
    try std.testing.expectEqual(@as(i64, 0), stub.net().vtable.now(&stub));
}

test "a diamond is staged with the base first and the top last, the middle by name" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("top", "1.0.0", try std.mem.concat(a, u8, &.{ try fx.pathDep("right", "1"), try fx.pathDep("left", "1") }));
    try fx.member("right", "1.0.0", try fx.pathDep("base", "1"));
    try fx.member("left", "1.0.0", try fx.pathDep("base", "1"));
    try fx.member("base", "1.0.0", "");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "diamond", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("base,left,right,top", try names(a, try readPlan(fx, "diamond")));
}

test "a registry dependency on a member is an edge, and a dev-dependency is not" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "pkg_b = \"^1\"\n");
    try fx.member("pkg_b", "1.4.0", "");
    // pkg_b lists pkg_a as a dev-dependency: that would be a cycle if it counted.
    try fx.put("ws/src/pkg_b/mopm.toml", "[package]\nname = \"pkg_b\"\nversion = \"1.4.0\"\nmojo = [\"1.0.0\"]\n\n[dev-dependencies]\npkg_a = { path = \"../pkg_a\" }\n");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "reg", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("pkg_b,pkg_a", try names(a, try readPlan(fx, "reg")));
}

test "naming a package stages it and what it needs, and no more" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_a", "1"));
    try fx.member("pkg_c", "1.0.0", try fx.pathDep("pkg_b", "1"));
    try fx.member("pkg_d", "1.0.0", "");
    var stub = newStub(a);
    var r = try runStage(fx, &stub, "named", &.{"pkg_b"});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("pkg_a,pkg_b", try names(a, try readPlan(fx, "named")));
    try std.testing.expect(!fx.exists("named/noarch/mojo-pkg_c-1.0.0-mojo1.0.0_0.conda"));
    r = try runStage(fx, &stub, "unknown", &.{"pkg_z"});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_z is not a member of the workspace"));
    try std.testing.expect(!fx.exists("unknown"));
}

// --------------------------------------------------------------------- refusals

test "a cycle is refused with nothing staged and nothing asked of the registry" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", try fx.pathDep("pkg_b", "1"));
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_c", "1"));
    try fx.member("pkg_c", "1.0.0", try fx.pathDep("pkg_a", "1"));
    try fx.member("pkg_ok", "1.0.0", "");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "cycle", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_a, pkg_b, pkg_c form a cycle"));
    try std.testing.expect(!contains(r.err, "pkg_ok"));
    try std.testing.expect(!fx.exists("cycle"));
    try std.testing.expectEqual(@as(usize, 0), stub.asked.items.len);
}

test "a package that needs itself is a cycle" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "pkg_a = { path = \".\", version = \"1\" }\n");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "self", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "form a cycle"));
}

test "a sibling whose version does not meet the requirement is refused, by path or by name" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_a", "^2"));
    var stub = newStub(a);
    var r = try runStage(fx, &stub, "path", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_b requires pkg_a \"^2\", but the workspace has pkg_a 1.0.0"));
    try std.testing.expect(!fx.exists("path"));

    try fx.member("pkg_b", "1.0.0", "pkg_a = \">=1.1\"\n");
    r = try runStage(fx, &stub, "name", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_b requires pkg_a \">=1.1\", but the workspace has pkg_a 1.0.0"));
    try std.testing.expect(!fx.exists("name"));
    try std.testing.expectEqual(@as(usize, 0), stub.asked.items.len);
}

test "a dependency that cannot be staged is refused with the reason" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    var stub = newStub(a);
    try fx.member("pkg_a", "1.0.0", "");

    // A path that is not a member.
    try fx.member("pkg_b", "1.0.0", "outside = { path = \"../../../outside\", version = \"1\" }\n");
    var r = try runStage(fx, &stub, "o1", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_b depends on 'outside' at the path '../../../outside', which is not a member of the workspace"));

    // A path to a member by another name.
    try fx.member("pkg_b", "1.0.0", "other = { path = \"../pkg_a\", version = \"1\" }\n");
    r = try runStage(fx, &stub, "o2", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_b calls the package at '../pkg_a' other, but it is pkg_a"));

    // A path with no version.
    try fx.member("pkg_b", "1.0.0", "pkg_a = { path = \"../pkg_a\" }\n");
    r = try runStage(fx, &stub, "o3", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "is a path dependency with no version"));

    // A requirement that is not one (the manifest parser says so, naming the file).
    try fx.member("pkg_b", "1.0.0", "pkg_a = \"^^\"\n");
    r = try runStage(fx, &stub, "o4", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_b/mopm.toml:") and contains(r.err, "invalid version requirement"));

    // Native libraries are not packed by stage.
    try fx.put("ws/src/pkg_b/mopm.toml", "[package]\nname = \"pkg_b\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[native.shim]\nkind = \"static\"\nmode = \"link\"\n");
    r = try runStage(fx, &stub, "o5", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_b declares native libraries, which stage does not pack"));

    // Native dependencies are not packed by anything yet: the packer says so.
    try fx.put("ws/src/pkg_b/mopm.toml", "[package]\nname = \"pkg_b\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n\n[native-dependencies]\nzlib = { version = \">=1.2\", kind = \"shared\", mode = \"link\" }\n");
    r = try runStage(fx, &stub, "o6", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_b: native dependencies are not packed yet"));
    for ([_][]const u8{ "o1", "o2", "o3", "o4", "o5", "o6" }) |o| try std.testing.expect(!fx.exists(o));
}

test "a workspace that cannot be read is refused" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    var stub = newStub(a);
    try fx.tmp.dir.makePath("ws/src");
    var r = try runStage(fx, &stub, "none", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "holds no mopm.toml"));

    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_a2", "1.0.0", "");
    try fx.put("ws/src/pkg_a2/mopm.toml", "[package]\nname = \"pkg_a\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n");
    r = try runStage(fx, &stub, "twice", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "are both the package pkg_a"));

    try fx.put("ws/src/pkg_a2/mopm.toml", "[package\n");
    r = try runStage(fx, &stub, "broken", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_a2/mopm.toml:"));

    var flags = try fx.flags("missing_root", &.{});
    flags.workspace_root = try fx.path("no_such_dir");
    var console = Console.init(a, null);
    const code = try stage.run(.{ .arena = a, .net = stub.net(), .console = &console, .api_url = api, .flags = flags });
    try std.testing.expect(code == 1 and contains(console.err.items, "--workspace-root"));
}

test "a member with no artifact, an empty one, a version that is not one, or a readme that is not text is refused" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    var stub = newStub(a);
    try fx.member("pkg_a", "1.0.0", "");

    try fx.tmp.dir.deleteFile("art/noarch/pkg_a.mojoc");
    var r = try runStage(fx, &stub, "p1", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_a has no build artifact: expected "));

    try fx.put("art/noarch/pkg_a.mojoc", "");
    r = try runStage(fx, &stub, "p2", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_a.mojoc is empty"));

    try fx.put("art/noarch/pkg_a.mojoc", "bytes");
    try fx.put("ws/src/pkg_a/README.md", "\xff\xfe not utf-8");
    r = try runStage(fx, &stub, "p3", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "is not UTF-8 text"));

    try fx.put("ws/src/pkg_a/README.md", "# a\n");
    try fx.put("ws/src/pkg_a/mopm.toml", "[package]\nname = \"pkg_a\"\nversion = \"1.0.0\"\nreadme = \"DOCS.md\"\nmojo = [\"1.0.0\"]\n");
    r = try runStage(fx, &stub, "p4", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "DOCS.md: FileNotFound"));

    try fx.put("ws/src/pkg_a/mopm.toml", "[package]\nname = \"pkg_a\"\nversion = \"1.0.0-rc.1\"\nmojo = [\"1.0.0\"]\n");
    r = try runStage(fx, &stub, "p5", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "must be exactly MAJOR.MINOR.PATCH"));

    try fx.put("ws/src/pkg_a/mopm.toml", "[package]\nname = \"pkg_a\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n");
    var flags = try fx.flags("p6", &.{});
    flags.compiler = "one";
    var console = Console.init(a, null);
    const code = try stage.run(.{ .arena = a, .net = stub.net(), .console = &console, .api_url = api, .flags = flags });
    try std.testing.expect(code == 1 and contains(console.err.items, "--compiler one"));
    for ([_][]const u8{ "p1", "p2", "p3", "p4", "p5", "p6" }) |o| try std.testing.expect(!fx.exists(o));
}

// ---------------------------------------------------------------------- registry

fn publishedBody(a: Allocator, name: []const u8, version: []const u8, sha: []const u8, state: []const u8) ![]const u8 {
    return std.fmt.allocPrint(a, "{{\"state\":\"{s}\",\"yank_reason\":{s},\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-{s}-{s}-mojo1.0.0_0.conda\",\"sha256\":\"{s}\"}}]}}", .{
        state, if (std.mem.eql(u8, state, "yanked")) "\"broken build\"" else "null", name, version, sha,
    });
}

test "a version published with the same bytes is skipped, and a rerun gives the same set" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_a", "1"));
    var stub = newStub(a);
    var r = try runStage(fx, &stub, "first", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const first = try readPlan(fx, "first");
    const sha_a = first.members[0].files[0].sha256;

    // The registry now holds pkg_a 1.0.0 with those bytes.
    const body = try publishedBody(a, "pkg_a", "1.0.0", sha_a, "published");
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, body);
    r = try runStage(fx, &stub, "second", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const second = try readPlan(fx, "second");
    try std.testing.expectEqual(plan_mod.Action.skip, second.members[0].action);
    try std.testing.expectEqualStrings("already published with these bytes", second.members[0].reason);
    try std.testing.expectEqual(plan_mod.Action.upload, second.members[1].action);
    try std.testing.expect(!fx.exists("second/noarch/mojo-pkg_a-1.0.0-mojo1.0.0_0.conda"));
    try std.testing.expect(fx.exists("second/noarch/mojo-pkg_b-1.0.0-mojo1.0.0_0.conda"));
    try std.testing.expect(contains(r.out, "skip   pkg_a 1.0.0: already published with these bytes"));
    try std.testing.expect(contains(r.out, "staged 2 members") and contains(r.out, "1 to upload, 1 skipped, 0 refused"));
    try std.testing.expect(!stub.token_sent);
    // The second set is publishable as it stands: every file is where the plan says, with the bytes it says.
    try std.testing.expect(plan_mod.refusedMember(second) == null);
    var dir = try fx.tmp.dir.openDir("second", .{});
    defer dir.close();
    try std.testing.expect((try plan_mod.verify(a, dir, second)) == null);
}

test "a version published with different bytes is refused, and the plan says so" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    const body = try publishedBody(a, "pkg_a", "1.0.0", "0" ** 64, "published");
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, body);
    const r = try runStage(fx, &stub, "different", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_a 1.0.0 is already published with different bytes"));
    try std.testing.expect(contains(r.err, "bump the version"));
    const plan = try readPlan(fx, "different");
    try std.testing.expectEqual(plan_mod.Action.refuse, plan.members[0].action);
    try std.testing.expect(plan_mod.refusedMember(plan) != null);
    try std.testing.expect(!fx.exists("different/noarch/mojo-pkg_a-1.0.0-mojo1.0.0_0.conda"));
}

test "a published version with a file the stage does not have is refused" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    var first = try runStage(fx, &stub, "probe", &.{});
    try std.testing.expectEqual(@as(u8, 0), first.code);
    const sha = (try readPlan(fx, "probe")).members[0].files[0].sha256;
    const body = try std.fmt.allocPrint(a, "{{\"state\":\"published\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-pkg_a-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"{s}\"}},{{\"subdir\":\"linux-64\",\"filename\":\"mojo-pkg_a-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"{s}\"}}]}}", .{ sha, sha });
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, body);
    first = try runStage(fx, &stub, "extra", &.{});
    try std.testing.expectEqual(@as(u8, 1), first.code);
    try std.testing.expect(contains(first.err, "is already published with 2 files and this stages 1"));
}

test "a yanked version is refused" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    var r = try runStage(fx, &stub, "probe", &.{});
    const sha = (try readPlan(fx, "probe")).members[0].files[0].sha256;
    // Even with the same bytes: a yanked number is not for publishing again.
    const body = try publishedBody(a, "pkg_a", "1.0.0", sha, "yanked");
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, body);
    r = try runStage(fx, &stub, "yanked", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "pkg_a 1.0.0 is yanked: broken build"));
    const plan = try readPlan(fx, "yanked");
    try std.testing.expectEqual(plan_mod.Action.refuse, plan.members[0].action);
    try std.testing.expect(contains(plan.members[0].reason, "is yanked"));
}

test "a burned version is refused, and the message says to bump" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    const body = "{\"state\":\"tombstoned\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-pkg_a-1.0.0-mojo1.0.0_0.conda\",\"sha256\":\"" ++ "1" ** 64 ++ "\"}]}";
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, body);
    const r = try runStage(fx, &stub, "burned", &.{});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expect(contains(r.err, "its number is burned; bump the version"));
    try std.testing.expectEqual(plan_mod.Action.refuse, (try readPlan(fx, "burned")).members[0].action);
}

test "a registry that cannot be asked, or answers what is not a version, stops the run before anything is written" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    stub.broken = true;
    var r = try runStage(fx, &stub, "down", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "cannot ask the registry about pkg_a 1.0.0"));
    stub.broken = false;
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 500, "oops");
    r = try runStage(fx, &stub, "five", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "the registry answered HTTP 500 about pkg_a 1.0.0"));
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, "[]");
    r = try runStage(fx, &stub, "junk", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "is not a version"));
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 200, "{\"state\":\"hidden\"}");
    r = try runStage(fx, &stub, "state", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "the state 'hidden'"));
    // A package the registry has never heard of is an upload, like a version it has not.
    stub.entries = try answer(a, "/packages/pkg_a/1.0.0", 404, "{\"error\":{\"code\":\"package_not_found\",\"message\":\"x\",\"hint\":\"\"}}");
    r = try runStage(fx, &stub, "new", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    for ([_][]const u8{ "down", "five", "junk", "state" }) |o| try std.testing.expect(!fx.exists(o));
}

// ---------------------------------------------------------------- the packages

test "packing is deterministic, and what is packed holds no URL, no lock entry and no path" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "2.1.0", try fx.pathDep("pkg_a", "^1.0"));
    try fx.put("ws/src/pkg_b/mopm.lock", "version = 2\n");
    var stub = newStub(a);
    const r1 = try runStage(fx, &stub, "one", &.{});
    const r2 = try runStage(fx, &stub, "two", &.{});
    try std.testing.expect(r1.code == 0 and r2.code == 0);
    const plan1 = try fx.read("one/plan.json");
    try std.testing.expectEqualStrings(plan1, try fx.read("two/plan.json"));
    for ([_][]const u8{ "pkg_a-1.0.0", "pkg_b-2.1.0" }) |stem| {
        const rel = try std.fmt.allocPrint(a, "noarch/mojo-{s}-mojo1.0.0_0.conda", .{stem});
        const x = try fx.read(try std.fmt.allocPrint(a, "one/{s}", .{rel}));
        const y = try fx.read(try std.fmt.allocPrint(a, "two/{s}", .{rel}));
        try std.testing.expectEqualSlices(u8, x, y);
        for ([_][]const u8{ "127.0.0.1", "localhost", "mopm.lock", "../pkg_a", "://" }) |needle| try std.testing.expect(!contains(x, needle));
    }
    // The version requirement stays, in the conda spelling, and the path is gone.
    const b = try fx.read("one/noarch/mojo-pkg_b-2.1.0-mojo1.0.0_0.conda");
    try std.testing.expect(contains(b, "\"name\":\"pkg_a\",\"range\":\">=1.0,<2\""));
}

test "the metadata check refuses a URL, a lock entry and a path, and passes a plain dependency" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const base = conda.Input{ .name = "pkg_b", .version = "1.0.0", .compiler = "1.0.0", .subdir = "noarch", .mojoc = "x", .deps = &.{.{ .name = "pkg_a", .range = ">=1.0.0,<2.0.0" }} };
    try std.testing.expect((try stage.metadataProblem(a, base, &.{"../pkg_a"})) == null);
    var in = base;
    in.deps = &.{.{ .name = "pkg_a", .range = "http://127.0.0.1:9/x" }};
    try std.testing.expect(contains((try stage.metadataProblem(a, in, &.{})).?, "://"));
    in.deps = &.{.{ .name = "mopm.lock", .range = "" }};
    try std.testing.expect(contains((try stage.metadataProblem(a, in, &.{})).?, "mopm.lock"));
    in.deps = &.{.{ .name = "pkg_a", .range = "../util" }};
    try std.testing.expect(contains((try stage.metadataProblem(a, in, &.{"../util"})).?, "../util"));
}

test "a readme is staged beside the package and named in the plan" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "1.0.0", "");
    try fx.put("ws/src/pkg_a/README.md", "# pkg_a\n");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "readme", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const plan = try readPlan(fx, "readme");
    try std.testing.expectEqualStrings("pkg_a/README.md", plan.members[0].readme.?);
    try std.testing.expect(plan.members[1].readme == null);
    try std.testing.expectEqualStrings("# pkg_a\n", try fx.read("readme/pkg_a/README.md"));
}

test "the staged plan is the one publish --staged reads: members, files and hashes check out" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_a", "1"));
    // One member for two platforms.
    try fx.put("art/linux-64/pkg_a.mojoc", "the linux mojoc of pkg_a");
    var stub = newStub(a);
    const r = try runStage(fx, &stub, "round", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const plan = try readPlan(fx, "round");
    try std.testing.expectEqual(@as(usize, 2), plan.members[0].files.len);
    try std.testing.expectEqualStrings("noarch", plan.members[0].files[0].subdir);
    try std.testing.expectEqualStrings("linux-64", plan.members[0].files[1].subdir);
    var dir = try fx.tmp.dir.openDir("round", .{});
    defer dir.close();
    try std.testing.expect((try plan_mod.verify(a, dir, plan)) == null);
    // A stage that fails before it writes leaves the set it found as it was.
    const before = try fx.read("round/plan.json");
    try fx.member("pkg_b", "1.0.0", try fx.pathDep("pkg_a", "^3"));
    const failed = try runStage(fx, &stub, "round", &.{});
    try std.testing.expectEqual(@as(u8, 1), failed.code);
    try std.testing.expectEqualStrings(before, try fx.read("round/plan.json"));
}

test "a stage over a directory that holds an old plan replaces it" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);
    try fx.put("again/plan.json", "{\"stale\":true}");
    const r = try runStage(fx, &stub, "again", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    const plan = try readPlan(fx, "again");
    try std.testing.expectEqualStrings("pkg_a", plan.members[0].name);
}

// ------------------------------------------------------- what cannot be written

test "a directory that cannot be written stops the run with the file named, and the old plan is gone" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    var stub = newStub(a);

    // --out below a file.
    try fx.put("blocked", "a file");
    var r = try runStage(fx, &stub, "blocked/set", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "blocked/set: "));

    // plan.json that is a directory cannot be replaced.
    try fx.tmp.dir.makePath("planless/plan.json");
    r = try runStage(fx, &stub, "planless", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "planless/plan.json: IsDir"));

    // A package file that is a directory cannot be written, and no plan is left to publish.
    try fx.put("half/plan.json", "{\"stale\":true}");
    try fx.tmp.dir.makePath("half/noarch/mojo-pkg_a-1.0.0-mojo1.0.0_0.conda");
    r = try runStage(fx, &stub, "half", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "mojo-pkg_a-1.0.0-mojo1.0.0_0.conda: IsDir"));
    try std.testing.expect(!fx.exists("half/plan.json"));
}

test "a manifest that cannot be read is refused with the file named" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    var stub = newStub(a);
    try fx.tmp.dir.makePath("ws/src/pkg_a/mopm.toml");
    const r = try runStage(fx, &stub, "unreadable", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "pkg_a/mopm.toml: IsDir"));
}

test "a set of more members than a group holds is refused before anything is packed" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    var fx = try Fx.init(a);
    defer fx.deinit();
    var stub = newStub(a);
    var i: usize = 0;
    while (i <= plan_mod.max_members) : (i += 1) {
        const name = try std.fmt.allocPrint(a, "pkg_{d}", .{i});
        try fx.put(try std.fmt.allocPrint(a, "ws/src/{s}/mopm.toml", .{name}), try std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n", .{name}));
    }
    const r = try runStage(fx, &stub, "big", &.{});
    try std.testing.expect(r.code == 1 and contains(r.err, "501 members; a group has at most 500"));
    try std.testing.expectEqual(@as(usize, 0), stub.asked.items.len);
    try std.testing.expect(!fx.exists("big"));
}

// -------------------------------------------------------------------- the flags

test "the flags: all of them are needed, and --registry has no default" {
    var st = arenaTest();
    defer st.deinit();
    const a = st.allocator();
    const ok = [_][]const u8{ "--workspace-root", "ws", "pkg_b", "--artifacts", "art", "--compiler", "1.0.0", "--out", "set", "--registry", "prod", "pkg_a" };
    const f = (try stage.parseFlags(a, &ok)).ok;
    try std.testing.expectEqualStrings("ws", f.workspace_root);
    try std.testing.expectEqualStrings("art", f.artifacts);
    try std.testing.expectEqualStrings("1.0.0", f.compiler);
    try std.testing.expectEqualStrings("set", f.out);
    try std.testing.expectEqualStrings("prod", f.registry);
    try std.testing.expectEqual(@as(usize, 2), f.packages.len);
    try std.testing.expectEqualStrings("pkg_b", f.packages[0]);
    try std.testing.expectEqualStrings("pkg_a", f.packages[1]);

    const Case = struct { drop: usize, why: []const u8 };
    // Dropping a flag and its value (positions in `ok`) names what is missing.
    const cases = [_]Case{
        .{ .drop = 0, .why = "--workspace-root <dir> is required" },
        .{ .drop = 3, .why = "--artifacts <dir> is required" },
        .{ .drop = 5, .why = "--compiler <exact mojo version> is required" },
        .{ .drop = 7, .why = "--out <dir> is required" },
        .{ .drop = 9, .why = "--registry is required: there is no default" },
    };
    for (cases) |c| {
        var args = std.ArrayList([]const u8).init(a);
        for (ok, 0..) |x, i| {
            if (i != c.drop and i != c.drop + 1) try args.append(x);
        }
        const got = try stage.parseFlags(a, args.items);
        try std.testing.expect(got == .bad);
        try std.testing.expect(std.mem.startsWith(u8, got.bad, c.why));
    }
    try std.testing.expect(contains((try stage.parseFlags(a, &.{"--frob"})).bad, "unexpected argument '--frob'"));
    try std.testing.expect(contains((try stage.parseFlags(a, &.{"--out"})).bad, "--out needs a value"));
    try std.testing.expect(contains((try stage.parseFlags(a, &.{ "--out", "" })).bad, "--out needs a value"));
}
