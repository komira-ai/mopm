//! A group whose commit request is not one the contract has, and the package create that is repeated after a busy answer
//! (group_publish.zig, publish_cmd.zig), and the runaway guard of the scripted registry of group_publish_test.zig, which
//! they share.

const std = @import("std");
const gp = @import("group_publish.zig");
const gt = @import("group_publish_test.zig");
const publish_cmd = @import("publish_cmd.zig");

test "a commit request the contract does not have stops the run before the commit is sent, naming the group and the error" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try gt.stage(a, &tmp, "");
    var script = gt.newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = gt.createAnswer("open", .{ true, true, true }) },
    });
    var console = gp.Console.init(a, null);
    var p = gt.publisherWith(a, &tmp, plan, "{}", &script, &console);
    try std.testing.expectEqual(gp.Result.failed, p.run());
    try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
    try gt.expectContains(console.out.items, "status open\n");
    try std.testing.expect(!gt.contains(console.out.items, "published"));
    const want = try std.fmt.allocPrint(a, "mopm: the commit request of group {s} is not one the contract has: MissingField\n", .{p.state.group_id});
    try std.testing.expectEqualStrings(want, console.err.items);
}

test "a package create the registry answers 503 once is sent again after a wait, and the second answer decides" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var script = gt.newScript(a, &.{
        .{ .method = .PUT, .suffix = "/packages/example/x", .status = 503, .body = "" },
        .{ .method = .PUT, .suffix = "/packages/example/x", .status = 201, .body = "{\"name\":\"example/x\"}" },
    });
    try std.testing.expect(try publish_cmd.ensurePackage(a, script.net(), &con, "http://127.0.0.1:1/api/v2", "tok", "beta", "example/x"));
    try std.testing.expectEqual(@as(usize, 2), script.seen.items.len);
    try std.testing.expect(script.slept > 0);
    try std.testing.expectEqualStrings("created example/x on beta\n", con.out.items);
    try std.testing.expectEqualStrings("", con.err.items);
}

test "the scripted registry stops a runaway: the request after max_requests fails and names the cause" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var script = gt.newScript(a, &.{.{ .method = .GET, .suffix = "/x", .status = 200 }});
    const n = script.net();
    var i: usize = 0;
    while (i < gt.Script.max_requests) : (i += 1) {
        const answer = try n.vtable.request(n.ptr, a, .GET, "http://registry.test/x", .{});
        try std.testing.expectEqual(@as(u16, 200), answer.status);
    }
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectError(error.ScriptRanAway, n.vtable.request(n.ptr, a, .GET, "http://registry.test/x", .{}));
    try std.testing.expectEqualStrings("the script was asked for more than max_requests requests", script.mismatch.?);
}
