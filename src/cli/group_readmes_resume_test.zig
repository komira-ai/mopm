//! Tests of the readme forms of `mopm publish --staged` across runs and answers (group_readmes.zig, group_publish.zig): a run
//! that resumes a group, a readme that changes between checks and sends, transfers that stop and are resumed, and create answers
//! that do not echo what was declared. They share the scripted registry and the helpers of group_readmes_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const gp = @import("group_publish.zig");
const gt = @import("group_publish_test.zig");
const rt = @import("group_readmes_test.zig");
const plan_mod = @import("group_plan.zig");
const readmes = @import("group_readmes.zig");
const Script = gt.Script;
const Console = gp.Console;
const Result = gp.Result;

const step = rt.step;
const answerOf = rt.answerOf;
const health_objects = rt.health_objects;
const health_plain = rt.health_plain;
const text_a = rt.text_a;
const validating = rt.validating;
const visible = rt.visible;

const big_count = 110;

/// 110 members, each with a 60 KiB readme: too large for one inline commit request, accepted as objects.
fn bigSet(a: Allocator, tmp: *std.testing.TmpDir) ![]const ?[]const u8 {
    const big = try a.alloc(u8, 60 * 1024);
    @memset(big, 'a');
    const texts = try a.alloc(?[]const u8, big_count);
    for (texts) |*t| t.* = big;
    _ = try rt.stageSet(a, tmp, texts);
    return texts;
}

/// The steps of a first run over `bigSet` in objects mode, up to and with the commit request.
fn bigFirstRun(a: Allocator, texts: []const ?[]const u8, commit: Script.Step, rest: []const Script.Step) ![]const Script.Step {
    var steps = std.ArrayList(Script.Step).init(a);
    try steps.append(step(.GET, "/health", 200, health_objects));
    try steps.append(step(.POST, "/groups", 201, try answerOf(a, texts, big_count, .pending, "")));
    for (0..big_count) |i| try steps.append(step(.PUT, try std.fmt.allocPrint(a, "/put/r{d}", .{i}), 200, ""));
    try steps.append(commit);
    try steps.appendSlice(rest);
    return steps.items;
}

/// The create answer of an existing group in `status`: the registry holds the whole group.
fn answerIn(a: Allocator, texts: []const ?[]const u8, status: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, a, try answerOf(a, texts, texts.len, .none, ""), "\"status\":\"open\"", try std.fmt.allocPrint(a, "\"status\":\"{s}\"", .{status}));
}

fn checkedOf(a: Allocator, tmp: *std.testing.TmpDir) !gp.Checked {
    const planned = try gp.checkedPlan(a, tmp.dir, "staged", false);
    try std.testing.expectEqualStrings("a checked plan", if (planned == .ok) "a checked plan" else planned.bad);
    return planned.ok;
}

test "a large group whose commit was accepted but whose answer was lost is waited for by a rerun that no longer lists the capability" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = try bigSet(a, &tmp);
    try std.testing.expect((try checkedOf(a, &tmp)).over != null);

    var first = gt.newScript(a, try bigFirstRun(a, texts, .{ .method = .POST, .suffix = "/commit", .status = 0, .err = error.ConnectionRefused }, &.{}));
    var c1 = Console.init(a, null);
    const d1 = try rt.drive(a, &tmp, &first, &c1, null);
    try std.testing.expectEqual(Result.failed, d1.result.?);
    const left = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expect(!left.committed);
    try std.testing.expectEqualStrings(gt.gid, left.group_id);

    // The rerun's /health lists nothing; the registry answers the create with the group validating.
    var again = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_plain),
        step(.POST, "/groups", 200, try answerIn(a, texts, "validating")),
        step(.GET, gt.gid, 200, visible),
    });
    var c2 = Console.init(a, null);
    const d2 = try rt.drive(a, &tmp, &again, &c2, left);
    try std.testing.expectEqual(Result.published, d2.result.?);
    try std.testing.expect(again.mismatch == null);
    try std.testing.expectEqual(@as(usize, 0), again.count(.PUT));
    try std.testing.expect(!gt.contains(c2.err.items, "too large"));
    for (again.seen.items) |x| try std.testing.expect(!std.mem.endsWith(u8, x.url, "/commit"));
    try std.testing.expect((try plan_mod.loadState(a, tmp.dir)).ok.committed);
}

test "a large group whose wait ran out is polled to visible by a rerun that no longer lists the capability, without reading /health" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = try bigSet(a, &tmp);

    var first = gt.newScript(a, try bigFirstRun(a, texts, step(.POST, "/commit", 202, validating), &.{step(.GET, gt.gid, 200, validating)}));
    var c1 = Console.init(a, null);
    const d1 = try rt.drive(a, &tmp, &first, &c1, null);
    try std.testing.expectEqual(Result.timed_out, d1.result.?);
    const left = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expect(left.committed);

    var again = gt.newScript(a, &.{
        step(.POST, "/groups", 200, try answerIn(a, texts, "validating")),
        step(.GET, gt.gid, 200, visible),
    });
    var c2 = Console.init(a, null);
    const d2 = try rt.drive(a, &tmp, &again, &c2, left);
    try std.testing.expectEqual(Result.published, d2.result.?);
    try std.testing.expect(again.mismatch == null);
    try std.testing.expectEqual(@as(usize, 2), again.seen.items.len);
    try std.testing.expectEqual(std.http.Method.POST, again.seen.items[0].method);
}

test "a staged large group resumed after the capability disappeared is refused once it is found open: before any PUT, state.json unchanged" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = try bigSet(a, &tmp);

    var first = gt.newScript(a, try bigFirstRun(a, texts, step(.POST, "/commit", 202, validating), &.{}));
    // The first run stops before the commit (--no-commit): the commit step is never asked for.
    var c1 = Console.init(a, null);
    const checked = try checkedOf(a, &tmp);
    const d1 = try rt.driveWith(a, &tmp, checked, &first, &c1, null, true);
    try std.testing.expectEqual(Result.staged, d1.result.?);
    const left = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expect(left.staged);
    const before = try tmp.dir.readFileAlloc(a, plan_mod.state_name, 1 << 20);

    var again = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_plain),
        step(.GET, gt.gid, 200, gt.group_status.of("open")),
        step(.POST, "/groups", 200, try answerOf(a, texts, big_count, .none, "")),
    });
    var c2 = Console.init(a, null);
    const d2 = try rt.drive(a, &tmp, &again, &c2, left);
    try std.testing.expectEqual(Result.failed, d2.result.?);
    try std.testing.expectEqual(@as(usize, 0), again.count(.PUT));
    for (again.seen.items) |x| try std.testing.expect(!std.mem.endsWith(u8, x.url, "/commit"));
    try gt.expectContains(c2.err.items, "which can take ");
    try gt.expectContains(c2.err.items, "; nothing was uploaded or committed\n");
    try gt.expectContains(c2.err.items, "Shorten them or publish fewer packages in one group");
    try gt.expectContains(c2.err.items, readmes.inline_note);
    try std.testing.expectEqualStrings(before, try tmp.dir.readFileAlloc(a, plan_mod.state_name, 1 << 20));
}

test "a resumed group is refused for an unreadable /health only once it is found open" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null };
    const plan = try rt.stageSet(a, &tmp, &texts);
    const state = plan_mod.State{ .registry = rt.api, .plan_sha256 = plan.sha256, .group_id = gt.gid, .attempt = 1 };

    // Found open: the run stops, and says what failed.
    // The GET of /health is repeated by the policy before it is an error.
    const tries = @as(usize, core.http.default_retries) + 1;
    const broken = Script.Step{ .method = .GET, .suffix = "/health", .status = 0, .err = error.ConnectionRefused };
    var open_steps = std.ArrayList(Script.Step).init(a);
    for (0..tries) |_| try open_steps.append(broken);
    try open_steps.append(step(.POST, "/groups", 200, try answerOf(a, &texts, 0, .none, "")));
    var open = gt.newScript(a, open_steps.items);
    var c1 = Console.init(a, null);
    const d1 = try rt.drive(a, &tmp, &open, &c1, state);
    try std.testing.expectEqual(Result.failed, d1.result.?);
    try gt.expectContains(c1.err.items, "GET /health: ConnectionRefused; nothing was uploaded or committed\n");
    try std.testing.expectEqual(@as(usize, 0), open.count(.PUT));

    // Found past open: waited for.
    var past_steps = std.ArrayList(Script.Step).init(a);
    for (0..tries) |_| try past_steps.append(broken);
    try past_steps.append(step(.POST, "/groups", 200, try answerIn(a, &texts, "committed")));
    try past_steps.append(step(.GET, gt.gid, 200, visible));
    var past = gt.newScript(a, past_steps.items);
    var c2 = Console.init(a, null);
    const d2 = try rt.drive(a, &tmp, &past, &c2, state);
    try std.testing.expectEqual(Result.published, d2.result.?);
}

test "the readme is sent as it was checked: a rewrite or deletion of the file after the plan check changes neither the PUT nor the commit" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null };
    _ = try rt.stageSet(a, &tmp, &texts);
    const checked = try checkedOf(a, &tmp);
    const sha = try core.install.sha256Hex(a, text_a);
    var script = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = try answerOf(a, &texts, 0, .pending, ""), .rewrite = .{ .dir = tmp.dir, .path = "R0.md", .bytes = "# rewritten after the check\n" } },
        .{ .method = .PUT, .suffix = "/put/f0", .status = 200, .rewrite = .{ .dir = tmp.dir, .path = "R0.md", .bytes = null } },
        step(.PUT, "/put/r0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var console = Console.init(a, null);
    const d = try rt.driveChecked(a, &tmp, checked, &script, &console, null);
    try std.testing.expectEqual(Result.published, d.result.?);
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqualStrings(text_a, script.seen.items[3].body.?);
    const commit = script.seen.items[5].body.?;
    try gt.expectContains(commit, try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":11}}", .{sha}));
    try std.testing.expect(!gt.contains(commit, "rewritten"));
}

test "a readme changed between a --no-commit run and its resume is declared, PUT and committed as the new bytes" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null };
    _ = try rt.stageSet(a, &tmp, &texts);
    var first = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
        step(.PUT, "/put/f0", 200, ""),
        step(.PUT, "/put/r0", 200, ""),
        step(.PUT, "/put/f1", 200, ""),
    });
    var c1 = Console.init(a, null);
    const d1 = try rt.driveWith(a, &tmp, try checkedOf(a, &tmp), &first, &c1, null, true);
    try std.testing.expectEqual(Result.staged, d1.result.?);
    const left = (try plan_mod.loadState(a, tmp.dir)).ok;

    const new_text = "# the readme, edited since\n";
    try tmp.dir.writeFile("R0.md", new_text);
    const new_texts = [_]?[]const u8{ new_text, null };
    const new_sha = try core.install.sha256Hex(a, new_text);
    var again = gt.newScript(a, &.{
        step(.GET, "/health", 200, health_objects),
        step(.GET, gt.gid, 200, gt.group_status.of("open")),
        step(.POST, "/groups", 200, try answerPartial(a, &new_texts)),
        step(.PUT, "/put/r0", 200, ""),
        step(.POST, "/commit", 202, validating),
        step(.GET, gt.gid, 200, visible),
    });
    var c2 = Console.init(a, null);
    const d2 = try rt.drive(a, &tmp, &again, &c2, left);
    try std.testing.expectEqual(Result.published, d2.result.?);
    try std.testing.expect(again.mismatch == null);
    const declared = try std.fmt.allocPrint(a, "\"readme\":{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ new_sha, new_text.len });
    try gt.expectContains(again.seen.items[2].body.?, declared);
    try std.testing.expectEqualStrings(new_text, again.seen.items[3].body.?);
    try gt.expectContains(again.seen.items[4].body.?, declared);
}

/// The answer of a group whose files are held and whose readme is not.
fn answerPartial(a: Allocator, texts: []const ?[]const u8) ![]const u8 {
    return rt.answerPartial(a, texts, texts.len, 0, .pending, "");
}

const Failure = struct { name: []const u8, step: Script.Step, result: Result };

test "a readme PUT that fails after earlier uploads stops the run without a commit; the rerun skips what is held and sends the rest" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const second = "# the second readme\n";
    const texts = [_]?[]const u8{ text_a, second };
    const failures = [_]Failure{
        .{ .name = "transport error", .step = .{ .method = .PUT, .suffix = "/put/r1", .status = 0, .err = error.ConnectionResetByPeer }, .result = .failed },
        .{ .name = "429", .step = .{ .method = .PUT, .suffix = "/put/r1", .status = 429, .retry_after = 7 }, .result = .rate_limited },
        .{ .name = "500", .step = step(.PUT, "/put/r1", 500, "{\"error\":{\"code\":\"x\",\"message\":\"y\",\"hint\":\"\"}}"), .result = .failed },
    };
    for (failures) |f| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try rt.stageSet(a, &tmp, &texts);
        var first = gt.newScript(a, &.{
            step(.GET, "/health", 200, health_objects),
            step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
            step(.PUT, "/put/f0", 200, ""),
            step(.PUT, "/put/r0", 200, ""),
            step(.PUT, "/put/f1", 200, ""),
            f.step,
        });
        var c1 = Console.init(a, null);
        const d1 = try rt.drive(a, &tmp, &first, &c1, null);
        try std.testing.expectEqual(f.result, d1.result.?);
        try std.testing.expectEqual(@as(usize, 0), first.count(.POST) - 1);
        const left = (try plan_mod.loadState(a, tmp.dir)).ok;
        try std.testing.expectEqualStrings(gt.gid, left.group_id);
        try std.testing.expect(!left.committed);
        try std.testing.expectEqual(@as(usize, 2), left.uploaded.len);

        // The rerun: the files and the first readme are held, the second readme is missing.
        var again_full = gt.newScript(a, &.{
            step(.GET, "/health", 200, health_objects),
            step(.POST, "/groups", 200, try rt.answerPartial(a, &texts, 2, 1, .pending, "")),
            step(.PUT, "/put/r1", 200, ""),
            step(.POST, "/commit", 202, validating),
            step(.GET, gt.gid, 200, visible),
        });
        var c2 = Console.init(a, null);
        const d2 = try rt.drive(a, &tmp, &again_full, &c2, left);
        try std.testing.expectEqual(Result.published, d2.result.?);
        try std.testing.expect(again_full.mismatch == null);
        try std.testing.expectEqual(@as(usize, 1), again_full.count(.PUT));
        try std.testing.expectEqualStrings(second, again_full.seen.items[2].body.?);
        try gt.expectContains(c2.out.items, "1 readme(s) were already in the registry's storage\n");
    }
}

test "/health listing the capability among other names, with other fields around it, selects objects mode; names alone do not" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const cases = [_]struct { body: []const u8, takes: bool }{
        .{ .body = "{\"status\":\"ok\",\"features\":[\"future_one\",\"group_readme_objects\",\"future_two\"]}", .takes = true },
        .{ .body = "{\"extra\":{\"a\":1},\"features\":[\"group_readme_objects\",\"x\"],\"more\":[1,2]}", .takes = true },
        .{ .body = "{\"features\":[\"future_one\",\"future_two\"]}", .takes = false },
        .{ .body = "{\"features\":[]}", .takes = false },
    };
    for (cases) |c| {
        var script = gt.newScript(a, &.{step(.GET, "/health", 200, c.body)});
        try std.testing.expectEqual(c.takes, try readmes.takesObjects(a, script.net(), rt.api));
    }
}

test "a create answer whose readme echoes another size or digest is not trusted: the run goes inline when that fits, with no readme PUT" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    const good = try answerOf(a, &texts, 0, .pending, "");
    const sha = try core.install.sha256Hex(a, text_a);
    const bad_answers = [_][]const u8{
        try std.mem.replaceOwned(u8, a, good, "\"size\":11,\"upload_id\"", "\"size\":12,\"upload_id\""),
        try std.mem.replaceOwned(u8, a, good, sha, "e" ** 64),
    };
    for (bad_answers) |bad| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try rt.stageSet(a, &tmp, &texts);
        var script = gt.newScript(a, &.{
            step(.GET, "/health", 200, health_objects),
            step(.POST, "/groups", 201, bad),
            step(.PUT, "/put/f0", 200, ""),
            step(.PUT, "/put/f1", 200, ""),
            step(.POST, "/commit", 202, validating),
            step(.GET, gt.gid, 200, visible),
        });
        var console = Console.init(a, null);
        const d = try rt.drive(a, &tmp, &script, &console, null);
        try std.testing.expectEqual(Result.published, d.result.?);
        try std.testing.expect(script.mismatch == null);
        try std.testing.expectEqual(@as(usize, 2), script.count(.PUT));
        try gt.expectContains(console.out.items, "the registry no longer takes readmes as objects (its answer names another readme than the one declared for m0); sending them inline\n");
        try gt.expectContains(script.seen.items[4].body.?, "\"readme\":\"# a readme\\n\"");
    }
}

test "a create answer for a set too large inline whose readme echoes another size stops the run before any PUT" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = try bigSet(a, &tmp);
    const wrong = try std.mem.replaceOwned(u8, a, try answerOf(a, texts, big_count, .pending, ""), "\"size\":61440,\"upload_id\":\"upl_r7\"", "\"size\":61441,\"upload_id\":\"upl_r7\"");
    try std.testing.expect(!std.mem.eql(u8, wrong, try answerOf(a, texts, big_count, .pending, "")));
    var script = gt.newScript(a, &.{ step(.GET, "/health", 200, health_objects), step(.POST, "/groups", 201, wrong) });
    var console = Console.init(a, null);
    const d = try rt.drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.failed, d.result.?);
    try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
    try gt.expectContains(console.err.items, "the registry no longer takes readmes as objects (its answer names another readme than the one declared for m7), and sent inline they are too large");
}

test "a create answer for another version of the member is refused before any PUT" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const texts = [_]?[]const u8{ text_a, null };
    _ = try rt.stageSet(a, &tmp, &texts);
    const other = try std.mem.replaceOwned(u8, a, try answerOf(a, &texts, 0, .pending, ""), "\"name\":\"m0\",\"version\":\"1.0.0\"", "\"name\":\"m0\",\"version\":\"2.0.0\"");
    var script = gt.newScript(a, &.{ step(.GET, "/health", 200, health_objects), step(.POST, "/groups", 201, other) });
    var console = Console.init(a, null);
    const d = try rt.drive(a, &tmp, &script, &console, null);
    try std.testing.expectEqual(Result.failed, d.result.?);
    try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
    try gt.expectContains(console.err.items, "the registry's answer has no reservation for m0 1.0.0\n");
}

test "an upload descriptor that is not one is refused clearly before any PUT: no URL, or headers that are not an object" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    const good = try answerOf(a, &texts, 0, .pending, "");
    const headers = "\"put_headers\":{\"content-length\":\"11\",\"x-amz-checksum-sha256\":\"rrr=\"}";
    const cases = [_]struct { answer: []const u8, why: []const u8 }{
        .{ .answer = try std.mem.replaceOwned(u8, a, good, "\"put_url\":\"http://127.0.0.1:1/put/r0\",", ""), .why = "it is not uploaded and has no put_url" },
        .{ .answer = try std.mem.replaceOwned(u8, a, good, headers, "\"put_headers\":[\"x\"]"), .why = "its put_headers is not an object" },
    };
    for (cases) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.answer, good));
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try rt.stageSet(a, &tmp, &texts);
        var script = gt.newScript(a, &.{ step(.GET, "/health", 200, health_objects), step(.POST, "/groups", 201, c.answer) });
        var console = Console.init(a, null);
        const d = try rt.drive(a, &tmp, &script, &console, null);
        try std.testing.expectEqual(Result.failed, d.result.?);
        try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
        try std.testing.expectEqualStrings(try std.fmt.allocPrint(a, "mopm: the registry's answer for the readme of m0 is not an upload descriptor: {s}; nothing was uploaded\n", .{c.why}), console.err.items);
    }
}

test "a refreshed answer is held to the declaration: another size or digest, or a descriptor that is not one, fails the run with no commit" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const texts = [_]?[]const u8{ text_a, null };
    const sha = try core.install.sha256Hex(a, text_a);
    const fresh = try answerOf(a, &texts, 1, .pending, "x");
    const cases = [_]struct { answer: []const u8, msg: []const u8 }{
        .{ .answer = try std.mem.replaceOwned(u8, a, fresh, "\"size\":11,\"upload_id\"", "\"size\":10,\"upload_id\""), .msg = "the registry's answer names another readme for m0 than the one declared" },
        .{ .answer = try std.mem.replaceOwned(u8, a, fresh, sha, "f" ** 64), .msg = "the registry's answer names another readme for m0 than the one declared" },
        .{ .answer = try std.mem.replaceOwned(u8, a, fresh, "\"put_url\":\"http://127.0.0.1:1/put/r0x\",", ""), .msg = "is not an upload descriptor: it is not uploaded and has no put_url; nothing was committed" },
    };
    for (cases) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.answer, fresh));
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        _ = try rt.stageSet(a, &tmp, &texts);
        var script = gt.newScript(a, &.{
            step(.GET, "/health", 200, health_objects),
            step(.POST, "/groups", 201, try answerOf(a, &texts, 0, .pending, "")),
            step(.PUT, "/put/f0", 200, ""),
            step(.PUT, "/put/r0", 403, ""),
            step(.POST, "/groups", 201, c.answer),
        });
        var console = Console.init(a, null);
        const d = try rt.drive(a, &tmp, &script, &console, null);
        try std.testing.expectEqual(Result.failed, d.result.?);
        try gt.expectContains(console.err.items, c.msg);
        try std.testing.expectEqual(@as(usize, 2), script.count(.PUT));
        try std.testing.expectEqual(@as(usize, 2), script.count(.POST));
    }
}
