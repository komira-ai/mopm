//! Tests of the namespaced staged set and of the calls that name a package: `plan.json` version 2 (members by full name,
//! files named `mojo-<namespace>.<name>-...`), the version 2 API root every request goes to, and the refusal of a plan
//! that predates namespaces. The scripted registries are the ones of stage_test.zig and group_publish_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const publish_cmd = @import("publish_cmd.zig");
const yank_cmd = @import("yank_cmd.zig");
const st = @import("stage_test.zig");
const gt = @import("group_publish_test.zig");

test "the status URL resolves against the API host, under /api/v2 or /api/v1, and nothing else does" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:5000/api/v2/publishes/pub_1",
        (try publish_cmd.resolveStatusUrl(a, "http://127.0.0.1:5000/api/v2", "/api/v2/publishes/pub_1")).?,
    );
    try std.testing.expectEqualStrings(
        "https://mopm.dev/api/v1/publishes/x",
        (try publish_cmd.resolveStatusUrl(a, "https://mopm.dev/api/v1", "/api/v1/publishes/x")).?,
    );
    for ([_][]const u8{ "https://evil.example/api/v2/publishes/x", "//evil.example/api/v2/publishes/x", "/api/v2/publishes/", "/api/v1/publishes/", "/api/v3/publishes/x", "/other" }) |bad| {
        try std.testing.expect((try publish_cmd.resolveStatusUrl(a, "https://mopm.dev/api/v2", bad)) == null);
    }
}

test "stage writes plan.json version 2: members by full name, files named for the conda package, a readme under the namespace, and the registry asked at the version 2 path" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var fx = try st.Fx.init(a);
    defer fx.deinit();
    try fx.member("pkg_a", "1.0.0", "");
    try fx.put("ws/src/pkg_a/README.md", "# pkg_a\n");
    var stub = st.newStub(a);
    const r = try st.runStage(fx, &stub, "out", &.{});
    try std.testing.expectEqual(@as(u8, 0), r.code);

    try std.testing.expectEqual(@as(usize, 1), stub.asked.items.len);
    try std.testing.expectEqualStrings("http://registry.test/api/v2/packages/example/pkg_a/1.0.0", stub.asked.items[0]);

    const text = try fx.tmp.dir.readFileAlloc(a, "out/plan.json", 1 << 20);
    try st.expectContainsText(text, "\"version\": 2,");
    const plan = (try plan_mod.parsePlan(a, text)).ok;
    try std.testing.expectEqual(@as(usize, 1), plan.members.len);
    try std.testing.expectEqualStrings("example/pkg_a", plan.members[0].name);
    try std.testing.expectEqualStrings("mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda", plan.members[0].files[0].filename);
    try std.testing.expectEqualStrings("example/pkg_a/README.md", plan.members[0].readme.?);
    try std.testing.expect(fx.exists("out/noarch/mojo-example.pkg_a-1.0.0-mojo1.0.0_0.conda"));
    try std.testing.expect(fx.exists("out/example/pkg_a/README.md"));
}

test "a plan.json of version 1 is refused naming the file, before any file is read or request made" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(plan_mod.plan_name, "{\"version\":1,\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"action\":\"skip\"}]}");
    try std.testing.expectEqualStrings("plan.json: is version 1 (it predates namespaces); stage the set again", try gt.badOf(try gp.checkedPlan(a, tmp.dir, "staged", false)));
    // An --abort reads the plan too, and refuses it the same way.
    try std.testing.expectEqualStrings("plan.json: is version 1 (it predates namespaces); stage the set again", try gt.badOf(try gp.checkedPlan(a, tmp.dir, "staged", true)));
    // A version 2 plan that names a package without its namespace is refused naming the member.
    try tmp.dir.writeFile(plan_mod.plan_name, "{\"version\":2,\"members\":[{\"name\":\"pkg_a\",\"version\":\"1.0.0\",\"action\":\"skip\"}]}");
    try std.testing.expectEqualStrings("plan.json: member 0 is named 'pkg_a', which is not a full name <namespace>/<name>", try gt.badOf(try gp.checkedPlan(a, tmp.dir, "staged", false)));
}

test "publish --staged sends every request to the version 2 API root with full names, keys state.json by the full name and reports the registry by its version 1 root" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "mojo-acme.pa-1.0.0-x.conda";
    try tmp.dir.makePath("noarch");
    try tmp.dir.writeFile("noarch/" ++ filename, "a-bytes");
    const sha = try core.install.sha256Hex(a, "a-bytes");
    const text = try std.fmt.allocPrint(a, "{{\"version\":2,\"members\":[{{\"name\":\"acme/pa\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":7}}]}}]}}", .{ gt.sha_x, filename, sha });
    try tmp.dir.writeFile(plan_mod.plan_name, text);
    const plan = (try plan_mod.parsePlan(a, text)).ok;
    const created = "{\"group_id\":\"" ++ gt.gid ++ "\",\"status\":\"open\",\"attempt\":1,\"members\":[{\"name\":\"acme/pa\",\"version\":\"1.0.0\",\"action\":\"new\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"" ++ filename ++ "\",\"upload_id\":\"upl_a\",\"uploaded\":false,\"put_url\":\"http://127.0.0.1:1/put/a\",\"put_headers\":{}}]}]}";
    var script = gt.newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = created },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
    });
    var console = gp.Console.init(a, null);
    var p = gt.publisherWith(a, &tmp, plan, "", &script, &console);
    p.no_commit = true;
    const result = p.run();
    try std.testing.expectEqual(gp.Result.staged, result);
    try std.testing.expectEqual(@as(u8, 0), p.finish(result));
    try std.testing.expect(script.mismatch == null);

    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/groups", script.seen.items[0].url);
    try st.expectContainsText(script.seen.items[0].body.?, "{\"members\":[{\"name\":\"acme/pa\",\"version\":\"1.0.0\",\"files\":[");
    const state = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expectEqual(@as(usize, 1), state.uploaded.len);
    try std.testing.expectEqualStrings("acme/pa/noarch/" ++ filename, state.uploaded[0]);
    const report = try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16);
    try st.expectContainsText(report, "\"registry\": \"http://127.0.0.1:1/api/v1\"");
    try st.expectContainsText(report, "\"name\": \"acme/pa\"");
}

test "yanking a group goes to the version 2 API root" {
    var arena = st.arenaTest();
    defer arena.deinit();
    const a = arena.allocator();
    const yanked = "{\"group_id\":\"" ++ gt.gid ++ "\",\"status\":\"visible\",\"yank\":{\"state\":\"yanked\",\"reason\":\"r\",\"yanked_members\":2}}";
    var script = gt.newScript(a, &.{.{ .method = .PUT, .suffix = "/yank", .status = 200, .body = yanked }});
    var console = gp.Console.init(a, null);
    var y = yank_cmd.Yanker{
        .arena = a,
        .net = script.net(),
        .console = &console,
        .api_v2_url = "http://127.0.0.1:1/api/v2",
        .token = "mopm_test_token",
        .group = gt.gid,
        .unyank = false,
        .reason = "broken",
        .wait_secs = 10,
    };
    try std.testing.expectEqual(yank_cmd.Result.done, y.run());
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/groups/" ++ gt.gid ++ "/yank", script.seen.items[0].url);
}
