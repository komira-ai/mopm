//! Tests of `[package] publish = false` in `mopm stage` (stage_cmd.zig). `mopm pack` and `mopm publish` are tested in
//! tests/drivers/publish_test.zig; the manifest key itself, and that other commands read the member as before, in
//! src/core/manifest.zig and src/core/unit_graph.zig. A workspace is written to a temporary directory and the registry is
//! a stand-in that has no version of anything, so a stage needs no socket.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const stage = @import("stage_cmd.zig");

const api = "http://registry.test/api/v1";
const not_found = "{\"error\":{\"code\":\"version_not_found\",\"message\":\"no such version\",\"hint\":\"\"}}";

fn request(_: *anyopaque, _: Allocator, _: std.http.Method, _: []const u8, _: http.Options) anyerror!http.Answer {
    return .{ .status = 404, .body = not_found };
}
fn sleep(_: *anyopaque, _: u64) void {}
fn now(_: *anyopaque) i64 {
    return 0;
}

const Fx = struct {
    a: Allocator,
    tmp: std.testing.TmpDir,
    root: []const u8,

    fn init(a: Allocator) !Fx {
        const tmp = std.testing.tmpDir(.{});
        return .{ .a = a, .tmp = tmp, .root = try tmp.dir.realpathAlloc(a, ".") };
    }

    fn deinit(fx: *Fx) void {
        fx.tmp.cleanup();
    }

    fn put(fx: Fx, rel: []const u8, bytes: []const u8) !void {
        if (std.fs.path.dirname(rel)) |d| try fx.tmp.dir.makePath(d);
        try fx.tmp.dir.writeFile(rel, bytes);
    }

    fn exists(fx: Fx, rel: []const u8) bool {
        fx.tmp.dir.access(rel, .{}) catch return false;
        return true;
    }

    /// A member `name` in `ws/<name>`. `publish` is the text of a `publish` line ("" for none); `deps` and `dev` are lines
    /// of `[dependencies]` and `[dev-dependencies]`. Only `built` members have an artifact, as a helper never does.
    fn member(fx: Fx, name: []const u8, publish: []const u8, deps: []const u8, dev: []const u8, built: bool) !void {
        const text = try std.fmt.allocPrint(fx.a, "[package]\nname = \"{s}\"\nversion = \"1.0.0\"\nmojo = [\"1.0.0\"]\n{s}\n[dependencies]\n{s}\n[dev-dependencies]\n{s}\n", .{ name, publish, deps, dev });
        try fx.put(try std.fmt.allocPrint(fx.a, "ws/{s}/mopm.toml", .{name}), text);
        if (built) try fx.put(try std.fmt.allocPrint(fx.a, "art/noarch/{s}.mojoc", .{name}), "the mojoc");
    }

    fn dep(fx: Fx, name: []const u8) ![]const u8 {
        return std.fmt.allocPrint(fx.a, "{s} = {{ path = \"../{s}\", version = \"1.0\" }}\n", .{ name, name });
    }
};

const Ran = struct { code: u8, out: []const u8, err: []const u8 };

fn runStage(fx: Fx, out: []const u8, packages: []const []const u8) !Ran {
    var console = gp.Console.init(fx.a, null);
    var unused: u8 = 0;
    const net = gp.Net{ .ptr = &unused, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    const code = try stage.run(.{ .arena = fx.a, .net = net, .console = &console, .api_url = api, .flags = .{
        .workspace_root = try std.fs.path.join(fx.a, &.{ fx.root, "ws" }),
        .packages = packages,
        .artifacts = try std.fs.path.join(fx.a, &.{ fx.root, "art" }),
        .compiler = "1.0.0",
        .out = try std.fs.path.join(fx.a, &.{ fx.root, out }),
        .registry = api,
    } });
    return .{ .code = code, .out = console.out.items, .err = console.err.items };
}

fn planNames(fx: Fx, out: []const u8) ![]const u8 {
    const text = try fx.tmp.dir.readFileAlloc(fx.a, try std.fmt.allocPrint(fx.a, "{s}/plan.json", .{out}), 1 << 20);
    const parsed = try plan_mod.parsePlan(fx.a, text);
    try std.testing.expect(parsed == .ok);
    var list = std.ArrayList([]const u8).init(fx.a);
    for (parsed.ok.members) |m| try list.append(m.name);
    return std.mem.join(fx.a, ",", list.items);
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

// Defect it catches: `mopm stage` with no names walking a test-support helper, which has no artifact, and refusing the whole
// set; or staging it anyway; or skipping it without saying so.
test "stage with no names leaves out a member with publish = false and says so" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var fx = try Fx.init(st.allocator());
    defer fx.deinit();
    // The helper is a dev-dependency of the library and has no artifact.
    try fx.member("pkg_lib", "", "", try fx.dep("pkg_helper"), true);
    try fx.member("pkg_helper", "publish = false\n", "", "", false);
    const r = try runStage(fx, "out", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("pkg_lib", try planNames(fx, "out"));
    try std.testing.expect(has(r.out, "not staged pkg_helper 1.0.0: publish = false\n"));
    try std.testing.expect(!has(r.out, "not staged pkg_lib"));
    try std.testing.expect(has(r.out, "staged 1 members"));
}

// Defect it catches: a named helper staged (or silently dropped, exit 0), so a person who asked for it is told nothing.
test "stage refuses a named package with publish = false, writes nothing, and a named publishable one is unaffected" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var fx = try Fx.init(st.allocator());
    defer fx.deinit();
    try fx.member("pkg_lib", "", "", try fx.dep("pkg_helper"), true);
    try fx.member("pkg_helper", "publish = false\n", "", "", true);
    const refused = try runStage(fx, "refused", &.{"pkg_helper"});
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expect(has(refused.err, "pkg_helper has publish = false"));
    try std.testing.expect(!fx.exists("refused"));
    const ok = try runStage(fx, "named", &.{"pkg_lib"});
    try std.testing.expectEqual(@as(u8, 0), ok.code);
    try std.testing.expectEqualStrings("pkg_lib", try planNames(fx, "named"));
    try std.testing.expect(fx.exists("named"));
    try std.testing.expect(!has(ok.out, "not staged"));
}

// Defect it catches: a published package whose [dependencies] need a package that is never published, which a consumer
// could not install; or [dev-dependencies] refused as if they were that.
test "stage refuses a publishable member that needs a publish = false one, directly or through another, naming both" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var fx = try Fx.init(st.allocator());
    defer fx.deinit();
    try fx.member("pkg_top", "", try fx.dep("pkg_mid"), "", true);
    try fx.member("pkg_mid", "", try fx.dep("pkg_helper"), "", true);
    try fx.member("pkg_helper", "publish = false\n", "", "", true);
    const all = try runStage(fx, "all", &.{});
    try std.testing.expectEqual(@as(u8, 1), all.code);
    try std.testing.expect(has(all.err, "pkg_mid is staged for publishing but depends on pkg_helper, which has publish = false"));
    try std.testing.expect(!fx.exists("all"));
    // Naming the top reaches the same member through its closure.
    const top = try runStage(fx, "top", &.{"pkg_top"});
    try std.testing.expectEqual(@as(u8, 1), top.code);
    try std.testing.expect(has(top.err, "pkg_mid") and has(top.err, "pkg_helper"));
    try std.testing.expect(!fx.exists("top"));
}

// Defect it catches: any change for a workspace that does not use the key.
test "stage with no publish key anywhere stages every member, in the same order, and prints no skip line" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var fx = try Fx.init(st.allocator());
    defer fx.deinit();
    try fx.member("pkg_c", "", "", "", true);
    try fx.member("pkg_b", "publish = true\n", try fx.dep("pkg_c"), "", true);
    try fx.member("pkg_a", "", try fx.dep("pkg_b"), "", true);
    const r = try runStage(fx, "out", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("pkg_c,pkg_b,pkg_a", try planNames(fx, "out"));
    try std.testing.expect(!has(r.out, "not staged"));
}

test "the stand-in registry never waits and its clock stands still" {
    var unused: u8 = 0;
    sleep(&unused, 1);
    try std.testing.expectEqual(@as(i64, 0), now(&unused));
}
