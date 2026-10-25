//! Tests of `mopm publish --staged` (group_publish.zig), by behaviour, against a scripted registry: the stand-in answers the
//! requests of a run in the order a test lists them, and the test reads what the run sent, said and wrote. The real registry,
//! over a socket, is the fake in registry/fake, driven by tests/drivers/group_publish_test.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");
const Net = gp.Net;
const Console = gp.Console;
const Publisher = gp.Publisher;
const Result = gp.Result;
const isGroupId = gp.isGroupId;
const parseFlags = gp.parseFlags;
const wants = gp.wants;
const default_wait_secs = gp.default_wait_secs;
const max_reserving_rounds = gp.max_reserving_rounds;

const sha_x = "c" ** 64;

/// A scripted registry: it answers the requests of a run in the order a test lists them, and remembers what it was sent.
pub const Script = struct {
    pub const Step = struct {
        method: std.http.Method,
        /// The request's URL must end with this.
        suffix: []const u8,
        status: u16,
        body: []const u8 = "",
        retry_after: ?u32 = null,
    };
    pub const Seen = struct { method: std.http.Method, url: []const u8, token: ?[]const u8, body: ?[]const u8, content_type_set: bool };

    steps: []const Step,
    next: usize = 0,
    seen: std.ArrayList(Seen),
    clock: i64 = 1000,
    slept: u64 = 0,
    /// A step beyond the end of the script repeats the last.
    mismatch: ?[]const u8 = null,

    pub fn net(s: *Script) Net {
        return .{ .ptr = s, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        const s: *Script = @ptrCast(@alignCast(ptr));
        try s.seen.append(.{ .method = method, .url = url, .token = options.token, .body = options.body, .content_type_set = options.content_type != null });
        const idx = @min(s.next, s.steps.len - 1);
        s.next += 1;
        const step = s.steps[idx];
        if (step.method != method or !std.mem.endsWith(u8, url, step.suffix)) {
            s.mismatch = try std.fmt.allocPrint(arena, "request {d} was {s} {s}; the script has {s} ...{s}", .{ s.next, @tagName(method), url, @tagName(step.method), step.suffix });
            return error.ConnectionRefused;
        }
        return .{ .status = step.status, .body = step.body, .request_id = "req-test", .retry_after = step.retry_after };
    }

    fn sleep(ptr: *anyopaque, secs: u64) void {
        const s: *Script = @ptrCast(@alignCast(ptr));
        s.slept += secs;
        s.clock += @intCast(secs);
    }

    fn now(ptr: *anyopaque) i64 {
        const s: *Script = @ptrCast(@alignCast(ptr));
        return s.clock;
    }

    fn count(s: *const Script, method: std.http.Method) usize {
        var n: usize = 0;
        for (s.seen.items) |x| {
            if (x.method == method) n += 1;
        }
        return n;
    }
};

const gid = "grp_0123456789abcdef0123456789abcdef";
const url_a = "http://127.0.0.1:1/put/a";
const url_b = "http://127.0.0.1:1/put/b";
const url_c = "http://127.0.0.1:1/put/c";

/// A staged directory of three packages a, b, c (in that order) whose files have the bytes `a-bytes`, `b-bytes`, `c-bytes`.
fn stage(a: Allocator, tmp: *std.testing.TmpDir, extra: []const u8) !plan_mod.Plan {
    return stageWith(a, tmp, extra, false);
}

/// With `readme`, package a names a readme, `R.md`, which holds `# a readme`.
fn stageWith(a: Allocator, tmp: *std.testing.TmpDir, extra: []const u8, readme: bool) !plan_mod.Plan {
    const names = [_][]const u8{ "a", "b", "c" };
    var members = std.ArrayList(u8).init(a);
    for (names, 0..) |n, i| {
        if (i != 0) try members.append(',');
        const bytes = try std.fmt.allocPrint(a, "{s}-bytes", .{n});
        const filename = try std.fmt.allocPrint(a, "mojo-{s}-1.0.0-x.conda", .{n});
        try tmp.dir.makePath("noarch");
        try tmp.dir.writeFile(try std.fmt.allocPrint(a, "noarch/{s}", .{filename}), bytes);
        try members.writer().print(
            "{{\"name\":\"{s}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",{s}\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":{d}}}]}}",
            .{ n, sha_x, if (readme and i == 0) "\"readme\":\"R.md\"," else "", filename, try core.install.sha256Hex(a, bytes), bytes.len },
        );
    }
    if (readme) try tmp.dir.writeFile("R.md", "# a readme\n");
    const text = try std.fmt.allocPrint(a, "{{\"version\":1,\"members\":[{s}{s}]}}", .{ members.items, extra });
    try tmp.dir.writeFile(plan_mod.plan_name, text);
    const parsed = try plan_mod.parsePlan(a, text);
    try std.testing.expectEqualStrings("a plan", if (parsed == .ok) "a plan" else parsed.bad);
    return parsed.ok;
}

fn createAnswer(comptime status: []const u8, comptime uploaded: [3]bool) []const u8 {
    const names = [_][]const u8{ "a", "b", "c" };
    const urls = [_][]const u8{ url_a, url_b, url_c };
    comptime var out: []const u8 = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"" ++ status ++ "\",\"attempt\":1,\"deadline_at\":\"2026-10-23T00:00:00Z\",\"members\":[";
    inline for (names, urls, uploaded, 0..) |n, u, up, i| {
        if (i != 0) out = out ++ ",";
        out = out ++ "{\"name\":\"" ++ n ++ "\",\"version\":\"1.0.0\",\"action\":\"new\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-" ++ n ++ "-1.0.0-x.conda\",\"upload_id\":\"upl_" ++ n ++ "\",\"uploaded\":" ++
            (if (up) "true" else "false") ++ (if (up) "" else ",\"put_url\":\"" ++ u ++ "\",\"put_headers\":{\"content-length\":\"7\",\"x-amz-checksum-sha256\":\"abc=\"}") ++ "}]}";
    }
    return out ++ "]}";
}

const create_new = createAnswer("open", .{ false, false, false });
const group_status = struct {
    fn of(comptime status: []const u8) []const u8 {
        return "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"" ++ status ++ "\",\"attempt\":1}";
    }
};

const err_404 = "{\"error\":{\"code\":\"route_not_found\",\"message\":\"There is no such operation.\",\"hint\":\"x\"}}";

fn publisher(a: Allocator, tmp: *std.testing.TmpDir, plan: plan_mod.Plan, script: *Script, console: *Console) Publisher {
    return .{
        .arena = a,
        .net = script.net(),
        .console = console,
        .dir = tmp.dir,
        .plan = plan,
        .api_url = "http://127.0.0.1:1/api/v1",
        .token = "mopm_test_token",
        .wait_secs = 30,
        .state = .{ .registry = "http://127.0.0.1:1/api/v1", .plan_sha256 = plan.sha256 },
    };
}

fn newScript(a: Allocator, steps: []const Script.Step) Script {
    return .{ .steps = steps, .seen = std.ArrayList(Script.Seen).init(a) };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// One line, so a failing test shows the text that lacked the needle.
fn expectContains(hay: []const u8, needle: []const u8) !void {
    try std.testing.expectEqualStrings(needle, if (contains(hay, needle)) needle else hay);
}

test "a chain of three is created, uploaded in order, committed and waited for as one group" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, ",{\"name\":\"d\",\"version\":\"2.0.0\",\"action\":\"skip\",\"reason\":\"already published\"}");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("committed") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    const result = p.run();
    try std.testing.expectEqual(Result.published, result);
    try std.testing.expectEqual(@as(u8, 0), p.finish(result));
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 8), script.seen.items.len);

    // The create asks for the three uploads, in the plan's order, and not for the skipped one.
    const create_body = script.seen.items[0].body.?;
    const ia = std.mem.indexOf(u8, create_body, "\"name\":\"a\"").?;
    const ib = std.mem.indexOf(u8, create_body, "\"name\":\"b\"").?;
    const ic = std.mem.indexOf(u8, create_body, "\"name\":\"c\"").?;
    try std.testing.expect(ia < ib and ib < ic);
    try std.testing.expect(!contains(create_body, "\"name\":\"d\""));
    try expectContains(create_body, "\"size\":7");

    // The PUTs are in dependency order, carry the bytes of the plan and no token; the API calls carry the token.
    try std.testing.expectEqualStrings(url_a, script.seen.items[1].url);
    try std.testing.expectEqualStrings("a-bytes", script.seen.items[1].body.?);
    try std.testing.expectEqualStrings("c-bytes", script.seen.items[3].body.?);
    for (script.seen.items) |x| {
        if (x.method == .PUT) {
            try std.testing.expect(x.token == null);
            try std.testing.expect(!x.content_type_set);
        } else {
            try std.testing.expectEqualStrings("mopm_test_token", x.token.?);
        }
    }
    // The commit names every upload member and its manifest, and nothing else.
    const commit_body = script.seen.items[4].body.?;
    try expectContains(commit_body, "\"name\":\"c\",\"manifest_sha256\":\"" ++ sha_x ++ "\"");
    try std.testing.expect(!contains(commit_body, "\"name\":\"d\""));
    try std.testing.expectEqual(@as(u64, 2), script.slept);
    try expectContains(console.out.items, "published group " ++ gid ++ ": a 1.0.0 b 1.0.0 c 1.0.0");
    try expectContains(console.out.items, "skipped d 2.0.0: already published");
    // No token anywhere in what was said.
    try std.testing.expect(!contains(console.out.items, "mopm_test_token") and !contains(console.err.items, "mopm_test_token"));

    // The records.
    const state = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expectEqualStrings(gid, state.group_id);
    try std.testing.expect(state.committed);
    try std.testing.expectEqual(@as(usize, 3), state.uploaded.len);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    try std.testing.expectEqualStrings("published", report.object.get("outcome").?.string);
    try std.testing.expectEqualStrings(gid, report.object.get("group_id").?.string);
    const members = report.object.get("members").?.array.items;
    try std.testing.expectEqualStrings("published", members[2].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("skipped", members[3].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("already published", members[3].object.get("code").?.string);
}

test "a rerun asks for the same group and sends only the files the registry does not hold" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    // First run: the second PUT fails.
    var first = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 503 },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &first, &console);
    const result = p.run();
    try std.testing.expectEqual(Result.failed, result);
    try std.testing.expectEqual(@as(u8, 1), p.finish(result));
    try expectContains(console.err.items, "uploading mojo-b-1.0.0-x.conda failed: the storage answered HTTP 503; run the same command again to resume group " ++ gid);
    try std.testing.expectEqual(@as(usize, 0), first.count(.GET));
    try std.testing.expect(!contains(first.seen.items[first.seen.items.len - 1].url, "commit"));
    const kept = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expectEqualStrings(gid, kept.group_id);
    try std.testing.expect(!kept.committed);
    try std.testing.expectEqual(@as(usize, 1), kept.uploaded.len);
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    try std.testing.expectEqualStrings("failed", report.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("pending", report.object.get("members").?.array.items[1].object.get("outcome").?.string);

    // Second run, from the state the first left: the registry holds a's file already and says so.
    var second = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("open", .{ true, false, false }) },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console2 = Console.init(a, null);
    var q = publisher(a, &tmp, plan, &second, &console2);
    q.state = kept;
    const again = q.run();
    try std.testing.expectEqual(Result.published, again);
    try std.testing.expect(second.mismatch == null);
    try std.testing.expectEqual(@as(usize, 2), second.count(.PUT));
    try expectContains(console2.out.items, "1 file(s) were already in the registry's storage");
    try std.testing.expectEqual(@as(usize, 3), q.state.uploaded.len);
}

test "a group the registry already has in full is waited for, not uploaded or committed again" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    inline for (.{ "validating", "committed", "visible" }) |status| {
        var script = newScript(a, &.{
            .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer(status, .{ true, true, true }) },
            .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
        });
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        try std.testing.expectEqual(Result.published, p.run());
        try std.testing.expectEqual(@as(usize, 0), script.count(.PUT));
        try std.testing.expectEqual(@as(usize, 2), script.seen.items.len);
    }
}

test "a 404 from /groups means no group publish: refused, nothing uploaded, no state of a group kept" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    inline for (.{ err_404, "{\"message\":\"Not Found\"}", "" }) |body| {
        var script = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 404, .body = body }});
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        const result = p.run();
        try std.testing.expectEqual(Result.no_group_publish, result);
        try std.testing.expectEqual(@as(u8, 1), p.finish(result));
        try std.testing.expectEqual(@as(usize, 1), script.seen.items.len);
        try expectContains(console.err.items, "has no group publish");
        try expectContains(console.err.items, "nothing was uploaded");
        try std.testing.expectEqualStrings("", p.state.group_id);
    }
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    try std.testing.expectEqualStrings("no_group_publish", report.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("not_published", report.object.get("members").?.array.items[0].object.get("outcome").?.string);

    // A 404 that is the registry's answer about something else is an error to show, not the absence of the feature.
    var other = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 404, .body = "{\"error\":{\"code\":\"package_not_found\",\"message\":\"There is no package 'a'.\",\"hint\":\"claim it\"}}" }});
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &other, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try expectContains(console.err.items, "There is no package 'a'.");
    try std.testing.expect(!contains(console.err.items, "has no group publish"));
}

test "a 429 stops the run where it is, and says when to come back" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const busy = "{\"error\":{\"code\":\"rate_limited\",\"message\":\"Too many requests.\",\"hint\":\"Wait 30 seconds\"}}";
    // On the create, on a PUT, on the commit and on a poll: each stops with nothing more sent.
    const scripts = [_][]const Script.Step{
        &.{.{ .method = .POST, .suffix = "/groups", .status = 429, .body = busy, .retry_after = 30 }},
        &.{
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
            .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
            .{ .method = .PUT, .suffix = "/put/b", .status = 429, .retry_after = 30 },
        },
        &.{
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
            .{ .method = .POST, .suffix = "/commit", .status = 429, .body = busy, .retry_after = 30 },
        },
        &.{
            .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
            .{ .method = .GET, .suffix = gid, .status = 429, .body = busy, .retry_after = 30 },
        },
    };
    const requests = [_]usize{ 1, 3, 2, 2 };
    for (scripts, requests) |steps, want| {
        var script = newScript(a, steps);
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        const result = p.run();
        try std.testing.expectEqual(Result.rate_limited, result);
        try std.testing.expectEqual(want, script.seen.items.len);
        try std.testing.expectEqual(@as(?u32, 30), p.retry_after);
        try expectContains(console.err.items, "HTTP 429");
        try expectContains(console.err.items, "retry after 30 seconds");
        try std.testing.expectEqual(@as(u64, 0), script.slept);
        try std.testing.expectEqual(@as(u8, 1), p.finish(result));
    }
}

test "a rejected member ends the group: it is named, and none is published" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, ",{\"name\":\"d\",\"version\":\"2.0.0\",\"action\":\"skip\"}");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"rejected\",\"failure\":{\"code\":\"path_not_allowed\",\"message\":\"bin/tool is not an allowed path\",\"member\":\"b\"}}" },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    const result = p.run();
    try std.testing.expectEqual(Result.failed, result);
    try std.testing.expectEqual(@as(u8, 1), p.finish(result));
    try expectContains(console.err.items, "group " ++ gid ++ " is rejected: path_not_allowed: bin/tool is not an allowed path (member b)");
    try expectContains(console.err.items, "none of its members is published");
    try std.testing.expect(!contains(console.out.items, "published group"));
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    try std.testing.expectEqualStrings("failed", report.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("rejected", report.object.get("group_status").?.string);
    const members = report.object.get("members").?.array.items;
    try std.testing.expectEqualStrings("not_published", members[0].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("rejected", members[1].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("path_not_allowed", members[1].object.get("code").?.string);
    try std.testing.expectEqualStrings("not_published", members[2].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("skipped", members[3].object.get("outcome").?.string);

    // A group that ended with no member to blame, and one that ended with no reason at all.
    inline for (.{ "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"expired\",\"failure\":{\"code\":\"deadline_passed\",\"message\":\"too late\"}}", group_status.of("aborted") }) |body| {
        var s2 = newScript(a, &.{
            .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
            .{ .method = .GET, .suffix = gid, .status = 200, .body = body },
        });
        var c2 = Console.init(a, null);
        var q = publisher(a, &tmp, plan, &s2, &c2);
        try std.testing.expectEqual(Result.failed, q.run());
        try expectContains(c2.err.items, "none of its members is published");
    }
}

test "a commit the registry refuses is shown, with its hint" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 409, .body = "{\"error\":{\"code\":\"group_commit_refused\",\"message\":\"The group cannot be committed: group x expired at T.\",\"hint\":\"Create it again.\"}}" },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try expectContains(console.err.items, "The group cannot be committed: group x expired at T.");
    try expectContains(console.err.items, "hint: Create it again.");
    try std.testing.expect(!(try plan_mod.loadState(a, tmp.dir)).ok.committed);
}

test "the run gives up waiting, and says how to go on" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("committed") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    p.wait_secs = 5;
    const result = p.run();
    try std.testing.expectEqual(Result.timed_out, result);
    try std.testing.expectEqual(@as(u64, 5), script.slept);
    try expectContains(console.err.items, "gave up waiting after 5 seconds: group " ++ gid ++ " is committed");
    try std.testing.expectEqual(@as(u8, 1), p.finish(result));
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    try std.testing.expectEqualStrings("timed_out", report.object.get("outcome").?.string);
    try std.testing.expectEqualStrings("pending", report.object.get("members").?.array.items[0].object.get("outcome").?.string);
}

test "the create is repeated while the registry reserves, and an answer that is wrong is refused" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const partial = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"open\",\"attempt\":1,\"reserving\":{\"done\":1,\"total\":3},\"members\":[]}";
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = partial },
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try expectContains(console.out.items, "reserving: 1 of 3 members");
    try std.testing.expectEqual(@as(usize, 2), script.count(.POST) - 1);

    // A registry that reserves for ever.
    var forever = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 201, .body = partial }});
    var c2 = Console.init(a, null);
    var q = publisher(a, &tmp, plan, &forever, &c2);
    try std.testing.expectEqual(Result.failed, q.run());
    try std.testing.expectEqual(max_reserving_rounds, forever.seen.items.len);
    try expectContains(c2.err.items, "still reserving");

    // Answers that cannot be used.
    const bad_answers = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "not json", .want = "not one this mopm reads" },
        .{ .body = "{\"group_id\":\"nope\",\"status\":\"open\"}", .want = "a group id that is not one" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"failed\",\"members\":[]}", .want = "does not know how to continue" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"open\",\"members\":[]}", .want = "no reservation for a 1.0.0" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"open\",\"members\":[{\"name\":\"a\",\"version\":\"1.0.0\",\"files\":[]}]}", .want = "no upload for noarch/mojo-a-1.0.0-x.conda" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"open\",\"members\":[{\"name\":\"a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a-1.0.0-x.conda\",\"upload_id\":\"u\",\"uploaded\":false}]}]}", .want = "gave no upload URL" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"open\",\"members\":[{\"name\":\"a\",\"version\":\"1.0.0\",\"files\":[{\"subdir\":\"noarch\",\"filename\":\"mojo-a-1.0.0-x.conda\",\"upload_id\":\"u\",\"uploaded\":false,\"put_url\":\"http://example.com/x\"}]}]}", .want = "neither https nor loopback http" },
    };
    for (bad_answers) |c| {
        var s3 = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 201, .body = c.body }});
        var c3 = Console.init(a, null);
        var r = publisher(a, &tmp, plan, &s3, &c3);
        try std.testing.expectEqual(Result.failed, r.run());
        try expectContains(c3.err.items, c.want);
        try std.testing.expectEqual(@as(usize, 1), s3.count(.POST));
        try std.testing.expectEqual(@as(usize, 0), s3.count(.PUT));
    }

    // A state that names another group than the registry's answer.
    var s4 = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new }});
    var c4 = Console.init(a, null);
    var t = publisher(a, &tmp, plan, &s4, &c4);
    t.state.group_id = "grp_ffffffffffffffffffffffffffffffff";
    try std.testing.expectEqual(Result.failed, t.run());
    try expectContains(c4.err.items, "names group grp_ffffffffffffffffffffffffffffffff, but the registry answered " ++ gid);
}

test "a file that changed after the plan was checked is not uploaded, and neither is the rest" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    try tmp.dir.writeFile("noarch/mojo-b-1.0.0-x.conda", "b-bytes!");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try std.testing.expectEqual(@as(usize, 1), script.count(.PUT));
    try expectContains(console.err.items, "changed since the plan was read");
    try std.testing.expectEqual(@as(usize, 0), script.count(.GET));
}

test "transport errors and a state that cannot be written stop the run" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    // The script wants a PUT where the run sends a POST: the stand-in refuses the connection.
    var script = newScript(a, &.{.{ .method = .PUT, .suffix = "/x", .status = 200 }});
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try expectContains(console.err.items, "POST /groups: ConnectionRefused");
    try std.testing.expect(script.mismatch != null);

    // state.json is a directory: the first save fails before any request.
    var tmp2 = std.testing.tmpDir(.{});
    defer tmp2.cleanup();
    const plan2 = try stage(a, &tmp2, "");
    try tmp2.dir.makeDir(plan_mod.state_name);
    var untouched = newScript(a, &.{.{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new }});
    var c2 = Console.init(a, null);
    var q = publisher(a, &tmp2, plan2, &untouched, &c2);
    try std.testing.expectEqual(Result.failed, q.run());
    try expectContains(c2.err.items, "cannot write state.json");
    try std.testing.expectEqual(@as(usize, 0), untouched.seen.items.len);
}

test "flags" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const f = (try parseFlags(a, &.{ "--staged", "s", "--registry", "beta", "--config-dir", "c", "--wait", "9", "--dry-run" })).ok;
    try std.testing.expectEqualStrings("s", f.staged);
    try std.testing.expectEqualStrings("beta", f.registry);
    try std.testing.expectEqualStrings("c", f.config_dir.?);
    try std.testing.expectEqual(@as(i64, 9), f.wait_secs);
    try std.testing.expect(f.dry_run);
    const g = (try parseFlags(a, &.{ "--registry", "prod", "--staged", "s" })).ok;
    try std.testing.expectEqual(default_wait_secs, g.wait_secs);
    try std.testing.expect(!g.dry_run and g.config_dir == null);
    try std.testing.expect(wants(&.{ "--registry", "x", "--staged", "s" }));
    try std.testing.expect(!wants(&.{ "--compiler", "1.0.0" }));

    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{ "--staged", "s" }, .want = "--registry is required" },
        .{ .args = &.{ "--staged", "s", "--dry-run" }, .want = "there is no default" },
        .{ .args = &.{ "--registry", "beta" }, .want = "--staged <dir> is required" },
        .{ .args = &.{ "--staged", "s", "--registry" }, .want = "--registry needs a value" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--wait", "soon" }, .want = "a number of seconds" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--wait", "-1" }, .want = "not negative" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--mojoc", "x" }, .want = "--mojoc packs one package" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--compiler", "1.0.0" }, .want = "packs one package" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--frobnicate" }, .want = "unexpected argument '--frobnicate'" },
    };
    for (cases) |c| {
        const why = (try parseFlags(a, c.args)).bad;
        try expectContains(why, c.want);
    }
}

test "group ids" {
    try std.testing.expect(isGroupId(gid));
    try std.testing.expect(!isGroupId("grp_xyz"));
    try std.testing.expect(!isGroupId("grx_0123456789abcdef0123456789abcdef"));
    try std.testing.expect(!isGroupId("grp_0123456789ABCDEF0123456789abcdef"));
    try std.testing.expect(!isGroupId(""));
}

test "a readme goes with the commit; one that vanished after the check stops the run" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stageWith(a, &tmp, "", true);
    try std.testing.expect((try plan_mod.verify(a, tmp.dir, plan)) == null);
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try expectContains(script.seen.items[1].body.?, "{\"name\":\"a\",\"manifest_sha256\":\"" ++ sha_x ++ "\",\"readme\":\"# a readme\\n\"}");
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, script.seen.items[1].body.?, "\"readme\""));

    try tmp.dir.deleteFile("R.md");
    var again = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
    });
    var c2 = Console.init(a, null);
    var q = publisher(a, &tmp, plan, &again, &c2);
    try std.testing.expectEqual(Result.failed, q.run());
    try expectContains(c2.err.items, "the readme R.md of a: FileNotFound");
    try std.testing.expectEqual(@as(usize, 1), again.seen.items.len);
}

/// `count` upload members m0.., each with a readme of `len` bytes; the readme of m0 is `extra` bytes longer.
fn stageReadmes(a: Allocator, tmp: *std.testing.TmpDir, count: usize, len: usize, extra: usize) !plan_mod.Plan {
    var members = std.ArrayList(u8).init(a);
    try tmp.dir.makePath("noarch");
    const sha = try core.install.sha256Hex(a, "m-bytes");
    for (0..count) |i| {
        if (i != 0) try members.append(',');
        const filename = try std.fmt.allocPrint(a, "mojo-m{d}-1.0.0-x.conda", .{i});
        try tmp.dir.writeFile(try std.fmt.allocPrint(a, "noarch/{s}", .{filename}), "m-bytes");
        const readme = try a.alloc(u8, len + if (i == 0) extra else 0);
        @memset(readme, 'a');
        try tmp.dir.writeFile(try std.fmt.allocPrint(a, "R{d}.md", .{i}), readme);
        try members.writer().print(
            "{{\"name\":\"m{d}\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"readme\":\"R{d}.md\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"{s}\",\"sha256\":\"{s}\",\"size\":7}}]}}",
            .{ i, sha_x, i, filename, sha },
        );
    }
    const text = try std.fmt.allocPrint(a, "{{\"version\":1,\"members\":[{s}]}}", .{members.items});
    try tmp.dir.writeFile(plan_mod.plan_name, text);
    const parsed = try plan_mod.parsePlan(a, text);
    try std.testing.expectEqualStrings("a plan", if (parsed == .ok) "a plan" else parsed.bad);
    return parsed.ok;
}

/// The readme length of members 1.. and the extra for member 0 that make the commit body of `count` members exactly
/// `plan_mod.max_commit_body_bytes` long.
fn exactReadmes(a: Allocator, count: usize) !struct { len: usize, extra: usize } {
    const entries = try a.alloc(plan_mod.CommitEntry, count);
    for (entries, 0..) |*e, i| e.* = .{ .name = try std.fmt.allocPrint(a, "m{d}", .{i}), .manifest_sha256 = sha_x, .readme = "" };
    const room = plan_mod.max_commit_body_bytes - plan_mod.commitBodyBytes(entries);
    return .{ .len = room / count, .extra = room % count };
}

fn allHeld(a: Allocator, count: usize) ![]const u8 {
    var out = std.ArrayList(u8).init(a);
    try out.writer().print("{{\"group_id\":\"{s}\",\"status\":\"open\",\"attempt\":1,\"members\":[", .{gid});
    for (0..count) |i| {
        if (i != 0) try out.append(',');
        try out.writer().print("{{\"name\":\"m{d}\",\"version\":\"1.0.0\",\"action\":\"new\",\"files\":[{{\"subdir\":\"noarch\",\"filename\":\"mojo-m{d}-1.0.0-x.conda\",\"upload_id\":\"u{d}\",\"uploaded\":true}}]}}", .{ i, i, i });
    }
    try out.appendSlice("]}");
    return out.items;
}

test "a commit request exactly at the limit is sent whole; one byte over is refused before any request, and a resume says the same" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const count = 90;
    const sizes = try exactReadmes(a, count);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stageReadmes(a, &tmp, count, sizes.len, sizes.extra);
    try std.testing.expect((try plan_mod.verify(a, tmp.dir, plan)) == null);
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = try allHeld(a, count) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expectEqual(plan_mod.max_commit_body_bytes, script.seen.items[1].body.?.len);

    var over_tmp = std.testing.tmpDir(.{});
    defer over_tmp.cleanup();
    const over = try stageReadmes(a, &over_tmp, count, sizes.len, sizes.extra + 1);
    const why = (try plan_mod.verify(a, over_tmp.dir, over)).?;
    try expectContains(why, "make a commit request of 5242881 bytes; the registry takes at most 5242880. The largest readmes: m0 (");
    // The run stops on the staged directory before it resolves a registry or reads a token, and it keeps no state; a rerun
    // over the same directory is refused the same way.
    for (0..2) |_| {
        const planned = try gp.checkedPlan(a, over_tmp.dir, "staged");
        try expectContains(planned.bad, "make a commit request of 5242881 bytes");
        try expectContains(planned.bad, "; nothing was sent");
        try std.testing.expectError(error.FileNotFound, over_tmp.dir.access(plan_mod.state_name, .{}));
    }
}

test "a staged directory whose plan cannot be used stops the run before any request, with the reason" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();

    var empty = std.testing.tmpDir(.{});
    defer empty.cleanup();
    try expectContains((try gp.checkedPlan(a, empty.dir, "out/staged")).bad, "out/staged/");
    try expectContains((try gp.checkedPlan(a, empty.dir, "out/staged")).bad, "FileNotFound");

    var garbled = std.testing.tmpDir(.{});
    defer garbled.cleanup();
    try garbled.dir.writeFile(plan_mod.plan_name, "not json");
    try expectContains((try gp.checkedPlan(a, garbled.dir, "staged")).bad, "is not JSON");

    var refusing = std.testing.tmpDir(.{});
    defer refusing.cleanup();
    _ = try stageWith(a, &refusing, ",{\"name\":\"d\",\"version\":\"2.0.0\",\"action\":\"refuse\",\"reason\":\"yanked\"}", false);
    try std.testing.expectEqualStrings("the plan refuses d 2.0.0: yanked; nothing was sent", (try gp.checkedPlan(a, refusing.dir, "staged")).bad);

    var refusing_bare = std.testing.tmpDir(.{});
    defer refusing_bare.cleanup();
    _ = try stageWith(a, &refusing_bare, ",{\"name\":\"d\",\"version\":\"2.0.0\",\"action\":\"refuse\"}", false);
    try std.testing.expectEqualStrings("the plan refuses d 2.0.0; nothing was sent", (try gp.checkedPlan(a, refusing_bare.dir, "staged")).bad);

    var changed = std.testing.tmpDir(.{});
    defer changed.cleanup();
    _ = try stageWith(a, &changed, "", false);
    try changed.dir.writeFile("noarch/mojo-a-1.0.0-x.conda", "changed");
    try expectContains((try gp.checkedPlan(a, changed.dir, "staged")).bad, "has the sha256");

    var fine = std.testing.tmpDir(.{});
    defer fine.cleanup();
    _ = try stageWith(a, &fine, "", true);
    try std.testing.expectEqual(@as(usize, 3), (try gp.checkedPlan(a, fine.dir, "staged")).ok.members.len);
}

test "the length the client computes for a commit request is the length of the request it sends" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stageWith(a, &tmp, "", true);
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    const entries = [_]plan_mod.CommitEntry{
        .{ .name = "a", .manifest_sha256 = sha_x, .readme = "# a readme\n" },
        .{ .name = "b", .manifest_sha256 = sha_x, .readme = null },
        .{ .name = "c", .manifest_sha256 = sha_x, .readme = null },
    };
    try std.testing.expectEqual(script.seen.items[1].body.?.len, plan_mod.commitBodyBytes(&entries));
}

test "a PUT that cannot be made, and a poll that cannot be read" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    // The stand-in wants a POST where the run sends the PUT: it refuses the connection.
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .POST, .suffix = "/put/a", .status = 200 },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try expectContains(console.err.items, "uploading mojo-a-1.0.0-x.conda failed: ConnectionRefused; run the same command again to resume group " ++ gid);

    var unreadable = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = "{\"status\":" },
    });
    var c2 = Console.init(a, null);
    var q = publisher(a, &tmp, plan, &unreadable, &c2);
    try std.testing.expectEqual(Result.failed, q.run());
    try expectContains(c2.err.items, "to GET /groups/" ++ gid ++ " is not one this mopm reads");
}

test "a refused member is never published, and the report says so" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, ",{\"name\":\"d\",\"version\":\"3.0.0\",\"action\":\"refuse\",\"reason\":\"yanked\"},{\"name\":\"e\",\"version\":\"3.0.0\",\"action\":\"refuse\"}");
    var script = newScript(a, &.{.{ .method = .GET, .suffix = "/x", .status = 200 }});
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(@as(u8, 1), p.finish(.failed));
    const report = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(a, plan_mod.report_name, 1 << 16), .{});
    const members = report.object.get("members").?.array.items;
    try std.testing.expectEqualStrings("not_published", members[3].object.get("outcome").?.string);
    try std.testing.expectEqualStrings("yanked", members[3].object.get("code").?.string);
    try std.testing.expectEqualStrings("refused by the plan", members[4].object.get("code").?.string);
    try std.testing.expectEqual(@as(usize, 0), script.seen.items.len);
}

var sunk: [512]u8 = undefined;
var sunk_len: usize = 0;

fn recordingSink(out: []const u8, err: []const u8) void {
    for ([_][]const u8{ out, "|", err, "\n" }) |part| {
        @memcpy(sunk[sunk_len..][0..part.len], part);
        sunk_len += part.len;
    }
}

test "the console hands what was said to its sink and starts again" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    var console = Console.init(st.allocator(), recordingSink);
    console.say("hello {d}\n", .{1});
    console.fail("bad {s}\n", .{"thing"});
    console.note("and more\n", .{});
    try std.testing.expectEqualStrings("hello 1\n|\n|mopm: bad thing\n\n|  and more\n\n", sunk[0..sunk_len]);
    try std.testing.expectEqual(@as(usize, 0), console.out.items.len);
    try std.testing.expectEqual(@as(usize, 0), console.err.items.len);
}
