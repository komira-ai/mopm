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
        /// Seconds the script's clock moves when this step answers (a slow transfer).
        advance_clock: i64 = 0,
        /// The request fails with this error, as a broken or silent connection does, and gets no answer.
        err: ?anyerror = null,
    };
    pub const Seen = struct { method: std.http.Method, url: []const u8, token: ?[]const u8, body: ?[]const u8, content_type_set: bool, timeout_secs: u32 };

    steps: []const Step,
    next: usize = 0,
    seen: std.ArrayList(Seen),
    clock: i64 = 1000,
    slept: u64 = 0,
    /// A step beyond the end of the script repeats the last.
    mismatch: ?[]const u8 = null,
    /// When set, the bytes it reports as held are noted at each PUT, in `held_at_put`.
    held_probe: ?*const usize = null,
    held_at_put: std.ArrayList(usize) = undefined,

    pub fn net(s: *Script) Net {
        return .{ .ptr = s, .vtable = &.{ .request = request, .sleep = sleep, .now = now } };
    }

    fn request(ptr: *anyopaque, _: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        const s: *Script = @ptrCast(@alignCast(ptr));
        // The run frees what it passed once the request is over; the script keeps its own copy of the body.
        const kept = if (options.body) |b| try s.seen.allocator.dupe(u8, b) else null;
        try s.seen.append(.{ .method = method, .url = url, .token = options.token, .body = kept, .content_type_set = options.content_type != null, .timeout_secs = options.timeout_secs });
        if (method == .PUT) {
            if (s.held_probe) |h| try s.held_at_put.append(h.*);
        }
        const idx = @min(s.next, s.steps.len - 1);
        s.next += 1;
        const step = s.steps[idx];
        if (step.method != method or !std.mem.endsWith(u8, url, step.suffix)) {
            s.mismatch = try std.fmt.allocPrint(s.seen.allocator,"request {d} was {s} {s}; the script has {s} ...{s}", .{ s.next, @tagName(method), url, @tagName(step.method), step.suffix });
            return error.ConnectionRefused;
        }
        s.clock += step.advance_clock;
        if (step.err) |e| return e;
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
    return .{ .steps = steps, .seen = std.ArrayList(Script.Seen).init(a), .held_at_put = std.ArrayList(usize).init(a) };
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

/// The answer of a create that signs the upload of c anew: its URL ends `/put/c2`.
fn freshAnswer(a: Allocator, comptime uploaded: [3]bool) ![]const u8 {
    return std.mem.replaceOwned(u8, a, createAnswer("open", uploaded), "/put/c\"", "/put/c2\"");
}

test "a long upload asks for fresh URLs before the old ones lapse, and goes on with them" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200, .advance_clock = 250 },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = try freshAnswer(a, .{ true, true, false }) },
        .{ .method = .PUT, .suffix = "/put/c2", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    // The create, the fresh create, the commit.
    try std.testing.expectEqual(@as(usize, 3), script.count(.POST));
    try std.testing.expectEqual(@as(usize, 3), script.count(.PUT));
    // The second create comes before the third PUT, and the third PUT uses the new URL.
    try std.testing.expectEqual(std.http.Method.POST, script.seen.items[3].method);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/put/c2", script.seen.items[4].url);
}

test "a fast upload does not ask for fresh URLs" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200, .advance_clock = 100 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200, .advance_clock = 100 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 2), script.count(.POST));
}

test "a storage 403 asks for fresh URLs once and sends the file again" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 403 },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = try freshAnswer(a, .{ true, true, false }) },
        .{ .method = .PUT, .suffix = "/put/c2", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqualStrings("c-bytes", script.seen.items[5].body.?);
}

test "a PUT retried until its URL lapsed gets the 403, which is final there, and is sent again to the fresh URL" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        // c fails once, and the wait for the retry outlasts the URL: the same URL then answers 403.
        .{ .method = .PUT, .suffix = "/put/c", .status = 503, .advance_clock = 300 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 403 },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = try freshAnswer(a, .{ true, true, false }) },
        .{ .method = .PUT, .suffix = "/put/c2", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    // a, b, c (503), c (403), c2: the 403 was not retried, and the refresh followed it at once.
    try std.testing.expectEqual(@as(usize, 5), script.count(.PUT));
    try std.testing.expectEqual(std.http.Method.POST, script.seen.items[5].method);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/put/c2", script.seen.items[6].url);
    try std.testing.expectEqualStrings("c-bytes", script.seen.items[6].body.?);
}

test "a storage 403 that fresh URLs do not cure fails the run after one more try" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 403 },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/b", .status = 403 },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.failed, p.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 2), script.count(.POST));
    try std.testing.expectEqual(@as(usize, 3), script.count(.PUT));
    try expectContains(console.err.items, "the storage answered HTTP 403");
}

test "a 403 whose fresh answer says the file is already held does not send it again" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 403 },
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("open", .{ true, true, true }) },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 3), script.count(.PUT));
    try expectContains(console.out.items, "1 file(s) were already in the registry's storage");
}

test "fresh URLs are refused when the registry answers another group or a group that is no longer open" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const other = "grp_ffffffffffffffffffffffffffffffff";
    const answers = [_]struct { body: []const u8, want: []const u8 }{
        .{ .body = "{\"group_id\":\"" ++ other ++ "\",\"status\":\"open\",\"members\":[]}", .want = "the registry answered group " ++ other ++ " in the state 'open'" },
        .{ .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"validating\",\"members\":[]}", .want = "the registry answered group " ++ gid ++ " in the state 'validating'" },
    };
    for (answers) |c| {
        var script = newScript(a, &.{
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
            .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
            .{ .method = .PUT, .suffix = "/put/b", .status = 403 },
            .{ .method = .POST, .suffix = "/groups", .status = 200, .body = c.body },
        });
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        try std.testing.expectEqual(Result.failed, p.run());
        try std.testing.expect(script.mismatch == null);
        try expectContains(console.err.items, c.want);
        try expectContains(console.err.items, "run the same command again to resume");
        try std.testing.expectEqual(@as(usize, 2), script.count(.PUT));
    }
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

/// The requests of a run that goes through: the create, the three PUTs, the commit and one poll that finds the group visible.
/// `put_b` is what stands in for b's PUT, so a test can fail it first.
fn throughWith(comptime put_b: []const Script.Step) []const Script.Step {
    return comptime blk: {
        const all = [_]Script.Step{
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
            .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        } ++ put_b[0..put_b.len].* ++ [_]Script.Step{
            .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
            .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
            .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
        };
        break :blk &all;
    };
}

test "a PUT the storage answers 503 once is repeated after a wait, and the run publishes" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, throughWith(&.{
        .{ .method = .PUT, .suffix = "/put/b", .status = 503, .body = "<Error><Code>SlowDown</Code></Error>" },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
    }));
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    const result = p.run();
    try std.testing.expectEqual(Result.published, result);
    try std.testing.expect(script.mismatch == null);
    // b's file was sent twice, the same bytes to the same URL; a and c once.
    try std.testing.expectEqual(@as(usize, 4), script.count(.PUT));
    try std.testing.expectEqualStrings(url_b, script.seen.items[2].url);
    try std.testing.expectEqualStrings(url_b, script.seen.items[3].url);
    try std.testing.expectEqualStrings("b-bytes", script.seen.items[2].body.?);
    try std.testing.expectEqualStrings("b-bytes", script.seen.items[3].body.?);
    // One wait, of the first retry's size (1 to 2 seconds); the poll found the group visible and waited for nothing.
    try std.testing.expect(script.slept >= 1 and script.slept <= 2);
    // Every request carried the default time limit.
    for (script.seen.items) |x| try std.testing.expectEqual(http.default_timeout_secs, x.timeout_secs);
    const state = (try plan_mod.loadState(a, tmp.dir)).ok;
    try std.testing.expectEqual(@as(usize, 3), state.uploaded.len);
    try std.testing.expect(!contains(console.err.items, "failed"));
}

test "a PUT that breaks or times out is repeated, and so is one the server asked to slow down" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var script = newScript(a, throughWith(&.{
        .{ .method = .PUT, .suffix = "/put/b", .status = 0, .err = error.RequestTimedOut },
        .{ .method = .PUT, .suffix = "/put/b", .status = 0, .err = error.ConnectionResetByPeer },
        .{ .method = .PUT, .suffix = "/put/b", .status = 429, .retry_after = 5 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
    }));
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    p.net.policy.retries = 3;
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expectEqual(@as(usize, 6), script.count(.PUT));
    // The 429 named 5 seconds, the least that wait could be.
    try std.testing.expect(script.slept >= 1 + 1 + 5);
}

test "a 4xx other than 429 is final: the PUT is not repeated, though the next try would have worked" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    // 403 is final for the retry loop too, but the run answers it with fresh URLs: tests of that are by the refresh tests above.
    for ([_]u16{ 400, 404, 409 }) |status| {
        var script = newScript(a, &.{
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
            .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
            .{ .method = .PUT, .suffix = "/put/b", .status = status },
            .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        });
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        try std.testing.expectEqual(Result.failed, p.run());
        try std.testing.expectEqual(@as(usize, 2), script.count(.PUT));
        try std.testing.expectEqual(@as(u64, 0), script.slept);
        try expectContains(console.err.items, try std.fmt.allocPrint(a, "uploading mojo-b-1.0.0-x.conda failed: the storage answered HTTP {d}; run the same command again to resume group " ++ gid, .{status}));
        try std.testing.expect(!contains(script.seen.items[script.seen.items.len - 1].url, "commit"));
    }
}

test "retries are bounded: a storage that keeps failing is tried retries plus one times, then the run stops and says so" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const steps = [_]Script.Step{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 503 },
    };
    const wants_tries = [_]struct { retries: u8, puts: usize }{ .{ .retries = 3, .puts = 1 + 4 }, .{ .retries = 0, .puts = 1 + 1 }, .{ .retries = 1, .puts = 1 + 2 } };
    for (wants_tries) |w| {
        var script = newScript(a, &steps);
        var console = Console.init(a, null);
        var p = publisher(a, &tmp, plan, &script, &console);
        p.net.policy.retries = w.retries;
        try std.testing.expectEqual(Result.failed, p.run());
        try std.testing.expectEqual(w.puts, script.count(.PUT));
        try expectContains(console.err.items, "failed: the storage answered HTTP 503; run the same command again to resume group " ++ gid);
    }
    // With the default three, the waits were 1-2, 2-4 and 4-8 seconds.
    var last = newScript(a, &steps);
    var last_console = Console.init(a, null);
    var last_run = publisher(a, &tmp, plan, &last, &last_console);
    try std.testing.expectEqual(Result.failed, last_run.run());
    try std.testing.expect(last.slept >= 7 and last.slept <= 14);
}

test "only requests that can be repeated are: the create and the commit are sent once, a poll is repeated" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    var create = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 503 },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
    });
    var c1 = Console.init(a, null);
    var p1 = publisher(a, &tmp, plan, &create, &c1);
    try std.testing.expectEqual(Result.failed, p1.run());
    try std.testing.expectEqual(@as(usize, 1), create.seen.items.len);

    var commit = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 503 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
    });
    var c2 = Console.init(a, null);
    var p2 = publisher(a, &tmp, plan, &commit, &c2);
    try std.testing.expectEqual(Result.failed, p2.run());
    try std.testing.expectEqual(@as(usize, 2), commit.count(.POST));

    // A poll the registry fails once is asked again; one it refuses is not.
    var poll = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
        .{ .method = .GET, .suffix = gid, .status = 503 },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var c3 = Console.init(a, null);
    var p3 = publisher(a, &tmp, plan, &poll, &c3);
    try std.testing.expectEqual(Result.published, p3.run());
    try std.testing.expectEqual(@as(usize, 2), poll.count(.GET));

    var refused = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 200, .body = createAnswer("validating", .{ true, true, true }) },
        .{ .method = .GET, .suffix = gid, .status = 403 },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    var c4 = Console.init(a, null);
    var p4 = publisher(a, &tmp, plan, &refused, &c4);
    try std.testing.expectEqual(Result.failed, p4.run());
    try std.testing.expectEqual(@as(usize, 1), refused.count(.GET));
}

test "the time limit and the retries the flags name are the ones every request runs under" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const f = (try parseFlags(a, &.{ "--staged", "s", "--registry", "beta", "--timeout", "7", "--retries", "0" })).ok;
    var script = newScript(a, throughWith(&.{.{ .method = .PUT, .suffix = "/put/b", .status = 503 }}));
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    p.net.policy = gp.policyOf(f);
    try std.testing.expectEqual(Result.failed, p.run());
    // retries 0: b's 503 ended the run after one try, and every request that was made carried 7 seconds.
    try std.testing.expectEqual(@as(usize, 2), script.count(.PUT));
    for (script.seen.items) |x| try std.testing.expectEqual(@as(u32, 7), x.timeout_secs);
    const defaults = gp.policyOf((try parseFlags(a, &.{ "--staged", "s", "--registry", "beta" })).ok);
    try std.testing.expectEqual(http.default_timeout_secs, defaults.timeout_secs);
    try std.testing.expectEqual(http.default_retries, defaults.retries);
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
    p.rerun = try gp.rerunCommand(a, .{ .staged = "out/staged", .registry = "beta", .config_dir = "my cfg", .wait_secs = 5, .dry_run = true });
    const result = p.run();
    try std.testing.expectEqual(Result.timed_out, result);
    try std.testing.expectEqual(@as(u64, 5), script.slept);
    try expectContains(console.err.items, "gave up waiting after 5 seconds: group " ++ gid ++ " is committed and still in progress");
    try expectContains(console.err.items, "to keep waiting (nothing is sent again), run: mopm publish --staged out/staged --registry beta --config-dir 'my cfg' --wait 5\n");
    try std.testing.expect(!contains(console.err.items, "--dry-run"));
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

test "the default wait is the base plus an allowance for each member, and a short group waits no less than the base" {
    try std.testing.expectEqual(@as(i64, 600), default_wait_secs);
    try std.testing.expectEqual(@as(i64, 5), gp.wait_per_member_secs);
    try std.testing.expectEqual(@as(i64, 600), gp.defaultWaitFor(0));
    try std.testing.expectEqual(@as(i64, 615), gp.defaultWaitFor(3));
    try std.testing.expectEqual(@as(i64, 1450), gp.defaultWaitFor(170));
    try std.testing.expectEqual(@as(i64, 2100), gp.defaultWaitFor(300));
    // The slowest estimate (25 minutes at 300 members, 12 at 170) is inside the default.
    try std.testing.expect(gp.defaultWaitFor(300) > 25 * 60);
    try std.testing.expect(gp.defaultWaitFor(170) > 12 * 60);
}

test "the command to keep waiting names the flags of the run and quotes what a shell would split" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expectEqualStrings(
        "mopm publish --staged ./s --registry prod",
        try gp.rerunCommand(a, .{ .staged = "./s", .registry = "prod" }),
    );
    try std.testing.expectEqualStrings(
        "mopm publish --staged 'a b' --registry 'it'\\''s'",
        try gp.rerunCommand(a, .{ .staged = "a b", .registry = "it's" }),
    );
}

test "flags" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const f = (try parseFlags(a, &.{ "--staged", "s", "--registry", "beta", "--config-dir", "c", "--wait", "9", "--dry-run" })).ok;
    try std.testing.expectEqualStrings("s", f.staged);
    try std.testing.expectEqualStrings("beta", f.registry);
    try std.testing.expectEqualStrings("c", f.config_dir.?);
    try std.testing.expectEqual(@as(?i64, 9), f.wait_secs);
    try std.testing.expect(f.dry_run);
    const g = (try parseFlags(a, &.{ "--registry", "prod", "--staged", "s" })).ok;
    try std.testing.expectEqual(@as(?i64, null), g.wait_secs);
    try std.testing.expect(!g.dry_run and g.config_dir == null);
    try std.testing.expectEqual(http.default_timeout_secs, g.timeout_secs);
    try std.testing.expectEqual(http.default_retries, g.retries);
    const t = (try parseFlags(a, &.{ "--registry", "prod", "--staged", "s", "--timeout", "90", "--retries", "10" })).ok;
    try std.testing.expectEqual(@as(u32, 90), t.timeout_secs);
    try std.testing.expectEqual(@as(u8, 10), t.retries);
    try std.testing.expectEqual(@as(u8, 0), (try parseFlags(a, &.{ "--registry", "prod", "--staged", "s", "--retries", "0" })).ok.retries);
    try std.testing.expect(wants(&.{ "--registry", "x", "--staged", "s" }));
    try std.testing.expect(!wants(&.{ "--compiler", "1.0.0" }));

    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{ "--staged", "s" }, .want = "--registry is required" },
        .{ .args = &.{ "--staged", "s", "--dry-run" }, .want = "there is no default" },
        .{ .args = &.{ "--registry", "beta" }, .want = "--staged <dir> is required" },
        .{ .args = &.{ "--staged", "s", "--registry" }, .want = "--registry needs a value" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--wait", "soon" }, .want = "a number of seconds" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--wait", "-1" }, .want = "not negative" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--timeout", "0" }, .want = "--timeout is 1 to 3600 seconds" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--timeout", "3601" }, .want = "--timeout is 1 to 3600 seconds" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--timeout", "-3" }, .want = "--timeout -3: a number of seconds" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--retries", "11" }, .want = "--retries is 0 to 10" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--retries", "many" }, .want = "--retries many: a number from 0 to 10" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--retries" }, .want = "--retries needs a value" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--mojoc", "x" }, .want = "--mojoc packs one package" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--compiler", "1.0.0" }, .want = "packs one package" },
        .{ .args = &.{ "--staged", "s", "--registry", "beta", "--frobnicate" }, .want = "unexpected argument '--frobnicate'" },
    };
    for (cases) |c| {
        const why = (try parseFlags(a, c.args)).bad;
        try expectContains(why, c.want);
    }
}

test "--oidc is a flag without a value, and the command that waits again keeps it" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    try std.testing.expect(!(try parseFlags(a, &.{ "--staged", "s", "--registry", "beta" })).ok.oidc);
    const f = (try parseFlags(a, &.{ "--staged", "s", "--oidc", "--registry", "beta" })).ok;
    try std.testing.expect(f.oidc);
    try std.testing.expectEqualStrings("s", f.staged);
    try std.testing.expectEqualStrings("mopm publish --staged s --registry beta --oidc", try gp.rerunCommand(a, f));
    try std.testing.expectEqualStrings("mopm publish --staged s --registry beta", try gp.rerunCommand(a, .{ .staged = "s", .registry = "beta" }));
    try expectContains((try parseFlags(a, &.{ "--staged", "s", "--registry", "beta", "--oidc", "yes" })).bad, "unexpected argument 'yes'");
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

test "the bytes of a file are held while it is uploaded and not after: a set of four 1 MiB files never holds two at once" {
    const mib = 1 << 20;
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("noarch");
    var files = std.ArrayList(u8).init(a);
    var answers = std.ArrayList(u8).init(a);
    for (0..4) |i| {
        const bytes = try a.alloc(u8, mib);
        @memset(bytes, @intCast('1' + i));
        try tmp.dir.writeFile(try std.fmt.allocPrint(a, "noarch/f{d}.conda", .{i}), bytes);
        if (i != 0) {
            try files.append(',');
            try answers.append(',');
        }
        try files.writer().print("{{\"subdir\":\"noarch\",\"filename\":\"f{d}.conda\",\"sha256\":\"{s}\",\"size\":{d}}}", .{ i, try core.install.sha256Hex(a, bytes), bytes.len });
        try answers.writer().print("{{\"subdir\":\"noarch\",\"filename\":\"f{d}.conda\",\"upload_id\":\"upl_{d}\",\"uploaded\":false,\"put_url\":\"http://127.0.0.1:1/put/{d}\",\"put_headers\":{{}}}}", .{ i, i, i });
    }
    const text = try std.fmt.allocPrint(a, "{{\"version\":1,\"members\":[{{\"name\":\"m\",\"version\":\"1.0.0\",\"action\":\"upload\",\"manifest_sha256\":\"{s}\",\"files\":[{s}]}}]}}", .{ sha_x, files.items });
    try tmp.dir.writeFile(plan_mod.plan_name, text);
    const parsed = try plan_mod.parsePlan(a, text);
    try std.testing.expectEqualStrings("a plan", if (parsed == .ok) "a plan" else parsed.bad);
    const created = try std.fmt.allocPrint(a, "{{\"group_id\":\"{s}\",\"status\":\"open\",\"attempt\":1,\"deadline_at\":\"2026-10-23T00:00:00Z\",\"members\":[{{\"name\":\"m\",\"version\":\"1.0.0\",\"action\":\"new\",\"files\":[{s}]}}]}}", .{ gid, answers.items });

    var counted = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = true }){};
    var script = newScript(a, &.{
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = created },
        .{ .method = .PUT, .suffix = "/put/0", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/1", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/2", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/3", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    script.held_probe = &counted.total_requested_bytes;
    var console = Console.init(a, null);
    var p = publisher(a, &tmp, parsed.ok, &script, &console);
    p.scratch = counted.allocator();
    try std.testing.expectEqual(Result.published, p.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 4), script.count(.PUT));

    // Each PUT is sent with the file's bytes in hand (so they were counted), and with no other file's bytes still held.
    try std.testing.expectEqual(@as(usize, 4), script.held_at_put.items.len);
    for (script.held_at_put.items) |held| {
        try std.testing.expect(held >= mib);
        try std.testing.expect(held < 2 * mib);
    }
    // Nothing is left held when the run is over.
    try std.testing.expectEqual(@as(usize, 0), counted.total_requested_bytes);
    try std.testing.expectEqual(std.heap.Check.ok, counted.deinit());
    // The bytes that were sent are the files', in order.
    try std.testing.expectEqual(@as(u8, '1'), script.seen.items[1].body.?[mib - 1]);
    try std.testing.expectEqual(@as(u8, '4'), script.seen.items[4].body.?[0]);
}

const oidc_actions = core.ci_oidc.Actions{ .url = "https://pipelines.example/idtoken?api-version=2.0", .token = "oidc-request-token-secret" };
const oidc_jwt = "head.payload.sig-secret";
const oidc_identity = "{\"value\":\"" ++ oidc_jwt ++ "\"}";
const oidc_minted = "mopm_group_token_secret";
const oidc_exchange_ok = "{\"token\":\"" ++ oidc_minted ++ "\",\"token_kind\":\"publish\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"packages\":[]}";
const oidc_api = "http://127.0.0.1:1/api/v1";

/// None of the three secrets of an --oidc run is in `text`.
fn expectNoOidcSecret(text: []const u8) !void {
    for ([_][]const u8{ oidc_actions.token, oidc_jwt, oidc_minted }) |s| try std.testing.expect(!contains(text, s));
}

test "--oidc covers a staged set of three with one identity request and one exchange, and that one token runs the whole group" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, ",{\"name\":\"d\",\"version\":\"2.0.0\",\"action\":\"skip\",\"reason\":\"already published\"}");
    var script = newScript(a, &.{
        .{ .method = .GET, .suffix = "audience=beta.mopm.dev", .status = 200, .body = oidc_identity },
        .{ .method = .POST, .suffix = "/auth/oidc/exchange", .status = 200, .body = oidc_exchange_ok },
        .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        .{ .method = .PUT, .suffix = "/put/a", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/b", .status = 200 },
        .{ .method = .PUT, .suffix = "/put/c", .status = 200 },
        .{ .method = .POST, .suffix = "/commit", .status = 202, .body = group_status.of("validating") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = group_status.of("visible") },
    });
    const uploads = try plan.uploads(a);
    const got = try gp.oidcToken(a, script.net(), oidc_actions, oidc_api, "beta", uploads);
    try std.testing.expectEqualStrings(oidc_minted, got.ok);

    var console = Console.init(a, null);
    var p = publisher(a, &tmp, plan, &script, &console);
    p.token = got.ok;
    const result = p.run();
    try std.testing.expectEqual(Result.published, result);
    try std.testing.expectEqual(@as(u8, 0), p.finish(result));
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 8), script.seen.items.len);

    // One request for the identity token, one exchange; the group's requests never ask for either again.
    var identity: usize = 0;
    var exchanges: usize = 0;
    for (script.seen.items) |x| {
        if (contains(x.url, "pipelines.example")) identity += 1;
        if (contains(x.url, "/auth/oidc/exchange")) exchanges += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), identity);
    try std.testing.expectEqual(@as(usize, 1), exchanges);
    try std.testing.expectEqualStrings(oidc_actions.token, script.seen.items[0].token.?);

    // The exchange names every member to upload at its version, in the plan's order, and not the skipped one; it holds the
    // identity token as the only credential.
    const ex = script.seen.items[1];
    try std.testing.expect(ex.token == null);
    try std.testing.expectEqualStrings(
        "{\"jwt\":\"" ++ oidc_jwt ++ "\",\"packages\":[{\"name\":\"a\",\"version\":\"1.0.0\"},{\"name\":\"b\",\"version\":\"1.0.0\"},{\"name\":\"c\",\"version\":\"1.0.0\"}]}",
        ex.body.?,
    );

    // The exchanged token is what the group's API calls carry (create, commit, poll); the PUTs carry none.
    for (script.seen.items[2..]) |x| {
        if (x.method == .PUT) {
            try std.testing.expect(x.token == null);
        } else {
            try std.testing.expectEqualStrings(oidc_minted, x.token.?);
        }
    }

    // None of the three secrets is in anything said, nor in a file the run wrote (the token stays in memory).
    try expectNoOidcSecret(console.out.items);
    try expectNoOidcSecret(console.err.items);
    var walker = try tmp.dir.walk(a);
    defer walker.deinit();
    var files: usize = 0;
    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;
        files += 1;
        try expectNoOidcSecret(try tmp.dir.readFileAlloc(a, entry.path, 1 << 20));
    }
    try std.testing.expect(files >= 5); // plan, three packages' files and the records: the walk did look at the run's files
}

test "--oidc: a refused exchange stops before the group is created, with the registry's message" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const plan = try stage(a, &tmp, "");
    const uploads = try plan.uploads(a);
    const refusals = [_]struct { status: u16, body: []const u8, text: []const u8 }{
        .{ .status = 403, .body = "{\"error\":{\"code\":\"not_owner\",\"message\":\"You are not an owner of 'b'.\",\"hint\":\"Ask an owner.\"}}", .text = "You are not an owner of 'b'." },
        .{ .status = 403, .body = "{\"error\":{\"code\":\"oidc_not_trusted\",\"message\":\"No trusted publisher of 'a' matches this CI identity.\",\"hint\":\"Register it.\"}}", .text = "No trusted publisher of 'a' matches this CI identity." },
    };
    for (refusals) |r| {
        var script = newScript(a, &.{
            .{ .method = .GET, .suffix = "audience=beta.mopm.dev", .status = 200, .body = oidc_identity },
            .{ .method = .POST, .suffix = "/auth/oidc/exchange", .status = r.status, .body = r.body },
            .{ .method = .POST, .suffix = "/groups", .status = 201, .body = create_new },
        });
        const got = try gp.oidcToken(a, script.net(), oidc_actions, oidc_api, "beta", uploads);
        try expectContains(got.bad, r.text);
        try expectContains(got.bad, "refused the identity token for the 3 packages of the set");
        try expectNoOidcSecret(got.bad);
        // Only the two token requests were made: no group, no upload.
        try std.testing.expectEqual(@as(usize, 2), script.seen.items.len);
        try std.testing.expect(script.mismatch == null);
    }
}

test "--oidc: each member is listed at its own version, in the plan's order" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const members = [_]plan_mod.Member{
        .{ .name = "zeta", .version = "0.0.3", .action = .upload },
        .{ .name = "alpha", .version = "2.1.0-rc.1", .action = .upload },
        .{ .name = "mid", .version = "10.0.0", .action = .upload },
    };
    var script = newScript(a, &.{
        .{ .method = .GET, .suffix = "audience=gamma.mopm.dev", .status = 200, .body = oidc_identity },
        .{ .method = .POST, .suffix = "/auth/oidc/exchange", .status = 200, .body = oidc_exchange_ok },
    });
    const got = try gp.oidcToken(a, script.net(), oidc_actions, oidc_api, "gamma", &members);
    try std.testing.expectEqualStrings(oidc_minted, got.ok);
    try std.testing.expectEqualStrings(
        "{\"jwt\":\"" ++ oidc_jwt ++ "\",\"packages\":[{\"name\":\"zeta\",\"version\":\"0.0.3\"},{\"name\":\"alpha\",\"version\":\"2.1.0-rc.1\"},{\"name\":\"mid\",\"version\":\"10.0.0\"}]}",
        script.seen.items[1].body.?,
    );
}

test "--oidc: more than 100 members is refused whole, before GitHub or the registry is asked" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var members = std.ArrayList(plan_mod.Member).init(a);
    for (0..101) |i| try members.append(.{ .name = try std.fmt.allocPrint(a, "pkg{d}", .{i}), .version = "1.0.0", .action = .upload });
    var script = newScript(a, &.{.{ .method = .GET, .suffix = "audience=beta.mopm.dev", .status = 200, .body = oidc_identity }});
    const got = try gp.oidcToken(a, script.net(), oidc_actions, oidc_api, "beta", members.items);
    try expectContains(got.bad, "at most 100 packages and this set uploads 101");
    try std.testing.expectEqual(@as(usize, 0), script.seen.items.len);
    // 100 is within the limit: it asks once for each.
    var ok_script = newScript(a, &.{
        .{ .method = .GET, .suffix = "audience=beta.mopm.dev", .status = 200, .body = oidc_identity },
        .{ .method = .POST, .suffix = "/auth/oidc/exchange", .status = 200, .body = oidc_exchange_ok },
    });
    const full = try gp.oidcToken(a, ok_script.net(), oidc_actions, oidc_api, "beta", members.items[0..100]);
    try std.testing.expectEqualStrings(oidc_minted, full.ok);
    try std.testing.expectEqual(@as(usize, 2), ok_script.seen.items.len);
}
