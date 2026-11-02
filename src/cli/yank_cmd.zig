//! `mopm yank --group <id>`: yank, or with `--unyank` restore, every version a group published.
//!
//!   mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]
//!   mopm yank --group <id> --registry <prod|gamma|beta|url> --unyank [--config-dir <dir>] [--wait <seconds>]
//!
//! `PUT /groups/{id}/yank` records the intent and answers at once (`yankGroup` in spec/api/openapi.yaml); the registry
//! yanks the versions, then rebuilds its repodata and index. The command waits until the group says it has: `yank.state`
//! is `yanked` (or, after `--unyank`, `restored`). An unyank restores the versions the group's yank changed, and no
//! others: a version somebody yanked by hand before stays yanked. The group id is the one `mopm publish --staged` prints
//! and writes to `report.json`. Only a group that is `visible` can be yanked.
//!
//! The token is `$MOPM_TOKEN`, else the one `mopm login` stored. A 429 stops the command and says when to try again.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const gp = @import("group_publish.zig");
const registry_cmd = @import("registry_cmd.zig");
const publish_cmd = @import("publish_cmd.zig");

const usage =
    \\usage: mopm yank --group <id> --registry <prod|gamma|beta|url> --reason <text> [--config-dir <dir>] [--wait <seconds>]
    \\       mopm yank --group <id> --registry <prod|gamma|beta|url> --unyank [--config-dir <dir>] [--wait <seconds>]
    \\
    \\  Yanks every version of a group (--reason says why), or with --unyank restores the ones its yank changed.
    \\  --registry is required.
    \\
;

pub const Flags = struct {
    group: []const u8,
    registry: []const u8,
    reason: ?[]const u8 = null,
    unyank: bool = false,
    config_dir: ?[]const u8 = null,
    wait_secs: i64 = gp.default_wait_secs,
};

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

const max_reason: usize = 280;

pub fn parseFlags(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var group: ?[]const u8 = null;
    var reg: ?[]const u8 = null;
    var f = Flags{ .group = "", .registry = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--unyank")) {
            f.unyank = true;
            continue;
        }
        const takes = std.mem.eql(u8, a, "--group") or std.mem.eql(u8, a, "--registry") or std.mem.eql(u8, a, "--reason") or
            std.mem.eql(u8, a, "--config-dir") or std.mem.eql(u8, a, "--wait");
        if (!takes) return .{ .bad = try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{a}) };
        if (i + 1 >= args.len) return .{ .bad = try std.fmt.allocPrint(arena, "{s} needs a value", .{a}) };
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--group")) {
            group = v;
        } else if (std.mem.eql(u8, a, "--registry")) {
            reg = v;
        } else if (std.mem.eql(u8, a, "--reason")) {
            f.reason = v;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            f.config_dir = v;
        } else {
            f.wait_secs = std.fmt.parseInt(i64, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--wait {s}: a number of seconds", .{v}) };
            if (f.wait_secs < 0) return .{ .bad = "--wait is not negative" };
        }
    }
    f.group = group orelse return .{ .bad = "--group <id> is required" };
    f.registry = reg orelse return .{ .bad = "--registry is required: there is no default, so a group is never yanked on a registry by accident" };
    if (f.unyank and f.reason != null) return .{ .bad = "--reason is for a yank; an unyank restores what the yank changed" };
    if (!f.unyank) {
        const r = f.reason orelse return .{ .bad = "a yank needs --reason <text> (at most 280 characters)" };
        if (r.len == 0 or r.len > max_reason) return .{ .bad = "--reason is 1 to 280 characters" };
    }
    return .{ .ok = f };
}

const YankAnswer = struct {
    status: []const u8 = "",
    yank: ?struct { state: []const u8 = "", yanked_members: u32 = 0 } = null,
};

pub const Result = enum { done, failed, rate_limited, timed_out };

pub const Yanker = struct {
    arena: Allocator,
    net: gp.Net,
    console: *gp.Console,
    api_url: []const u8,
    token: []const u8,
    group: []const u8,
    unyank: bool,
    reason: []const u8 = "",
    wait_secs: i64,

    fn call(y: *Yanker, method: std.http.Method, path: []const u8, body: ?[]const u8) ?http.Answer {
        const url = std.fmt.allocPrint(y.arena, "{s}{s}", .{ y.api_url, path }) catch return null;
        return y.net.vtable.request(y.net.ptr, y.arena, method, url, .{ .token = y.token, .body = body }) catch |e| {
            y.console.fail("{s} {s}: {s}\n", .{ @tagName(method), path, @errorName(e) });
            return null;
        };
    }

    /// An answer that is not a success: shown, and the command stops.
    fn refuse(y: *Yanker, a: http.Answer) Result {
        if (a.status == 429) {
            y.console.fail("the registry is rate limiting this client (HTTP 429); nothing more was sent{s}\n", .{y.retryText(a.retry_after)});
            return .rate_limited;
        }
        const text = http.describe(y.arena, a) catch return .failed;
        y.console.fail("{s}", .{text});
        return .failed;
    }

    fn retryText(y: *Yanker, retry: ?u32) []const u8 {
        const secs = retry orelse return "";
        return std.fmt.allocPrint(y.arena, "; retry after {d} seconds", .{secs}) catch "";
    }

    fn parse(y: *Yanker, a: http.Answer) ?YankAnswer {
        return std.json.parseFromSliceLeaky(YankAnswer, y.arena, a.body, .{ .ignore_unknown_fields = true }) catch {
            y.console.fail("the registry's answer is not one this mopm reads\n", .{});
            return null;
        };
    }

    pub fn run(y: *Yanker) Result {
        const path = std.fmt.allocPrint(y.arena, "/groups/{s}/yank", .{y.group}) catch return .failed;
        var body = std.ArrayList(u8).init(y.arena);
        if (y.unyank) {
            body.appendSlice("{\"yanked\":false}") catch return .failed;
        } else {
            body.appendSlice("{\"yanked\":true,\"reason\":") catch return .failed;
            std.json.encodeJsonString(y.reason, .{}, body.writer()) catch return .failed;
            body.append('}') catch return .failed;
        }
        const asked = y.call(.PUT, path, body.items) orelse return .failed;
        if (!asked.ok()) return y.refuse(asked);
        const first = y.parse(asked) orelse return .failed;
        const want = if (y.unyank) "restored" else "yanked";
        if (done(first, y.unyank)) {
            y.report(first, if (asked.status == 200) "is already" else "is");
            return .done;
        }
        y.console.say("{s} group {s}: waiting for the registry to finish\n", .{ if (y.unyank) "unyanking" else "yanking", y.group });
        const status_path = std.fmt.allocPrint(y.arena, "/groups/{s}", .{y.group}) catch return .failed;
        const deadline = y.net.vtable.now(y.net.ptr) + y.wait_secs;
        while (true) {
            const a = y.call(.GET, status_path, null) orelse return .failed;
            if (!a.ok()) return y.refuse(a);
            const g = y.parse(a) orelse return .failed;
            if (done(g, y.unyank)) {
                y.report(g, "is");
                return .done;
            }
            if (y.net.vtable.now(y.net.ptr) >= deadline) {
                y.console.fail("gave up waiting after {d} seconds: the yank of group {s} is {s}, not {s} yet; look again with GET /groups/{s}\n", .{ y.wait_secs, y.group, if (g.yank) |k| k.state else g.status, want, y.group });
                return .timed_out;
            }
            y.net.vtable.sleep(y.net.ptr, 1);
        }
    }

    fn done(g: YankAnswer, unyank: bool) bool {
        const k = g.yank orelse return unyank; // never yanked: nothing to restore
        const want = if (unyank) "restored" else "yanked";
        return std.mem.eql(u8, k.state, want);
    }

    fn report(y: *Yanker, g: YankAnswer, verb: []const u8) void {
        const n = if (g.yank) |k| k.yanked_members else 0;
        if (y.unyank) {
            y.console.say("group {s} {s} restored ({d} versions it had yanked)\n", .{ y.group, verb, n });
        } else {
            y.console.say("group {s} {s} yanked ({d} versions)\n", .{ y.group, verb, n });
        }
    }
};

fn err(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("mopm: " ++ fmt, args) catch {};
}

pub fn main(arena: Allocator, args: []const []const u8, cli_version: []const u8) u8 {
    const flags = switch (parseFlags(arena, args) catch return 1) {
        .ok => |f| f,
        .bad => |why| {
            err("{s}\n", .{why});
            std.io.getStdErr().writeAll(usage) catch {};
            return 2;
        },
    };
    const s = registry_cmd.open(arena, .{ .registry = flags.registry, .config_dir = flags.config_dir }, cli_version) orelse return 1;
    const token = (publish_cmd.findToken(s) catch null) orelse {
        err("not logged in to {s}; run 'mopm login' or set MOPM_TOKEN\n", .{s.config.stage});
        return 1;
    };
    var console = gp.Console.init(arena, gp.Console.stdStreams);
    var y = Yanker{
        .arena = arena,
        .net = gp.realNet(),
        .console = &console,
        .api_url = s.config.api_url,
        .token = token,
        .group = flags.group,
        .unyank = flags.unyank,
        .reason = flags.reason orelse "",
        .wait_secs = flags.wait_secs,
    };
    return if (y.run() == .done) 0 else 1;
}

// ------------------------------------------------------------------------ tests

const gt = @import("group_publish_test.zig");

const gid = "grp_0123456789abcdef0123456789abcdef";

fn yankState(comptime status: []const u8, comptime state: []const u8, comptime n: []const u8) []const u8 {
    return "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"" ++ status ++ "\",\"yank\":{\"state\":\"" ++ state ++ "\",\"reason\":\"r\",\"requested_at\":\"2026-10-22T00:00:00Z\",\"yanked_members\":" ++ n ++ "}}";
}

fn yanker(a: Allocator, script: *gt.Script, console: *gp.Console, unyank: bool) Yanker {
    return .{
        .arena = a,
        .net = script.net(),
        .console = console,
        .api_url = "http://127.0.0.1:1/api/v1",
        .token = "mopm_test_token",
        .group = gid,
        .unyank = unyank,
        .reason = "broken \"build\"",
        .wait_secs = 10,
    };
}

test "a group is yanked: the intent is sent with the token, and the command waits for the registry to finish" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var script = gt.Script{ .steps = &.{
        .{ .method = .PUT, .suffix = "/yank", .status = 202, .body = yankState("visible", "yanking", "0") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = yankState("visible", "yanking", "0") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = yankState("visible", "yanked", "3") },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var console = gp.Console.init(a, null);
    var y = yanker(a, &script, &console, false);
    try std.testing.expectEqual(Result.done, y.run());
    try std.testing.expect(script.mismatch == null);
    try std.testing.expectEqual(@as(usize, 3), script.seen.items.len);
    try std.testing.expectEqualStrings("{\"yanked\":true,\"reason\":\"broken \\\"build\\\"\"}", script.seen.items[0].body.?);
    for (script.seen.items) |x| try std.testing.expectEqualStrings("mopm_test_token", x.token.?);
    try std.testing.expectEqual(@as(u64, 1), script.slept);
    try std.testing.expect(std.mem.indexOf(u8, console.out.items, "group " ++ gid ++ " is yanked (3 versions)") != null);
    try std.testing.expect(std.mem.indexOf(u8, console.out.items, "mopm_test_token") == null);
}

test "an unyank sends no reason, and a group already as asked is not waited for" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var script = gt.Script{ .steps = &.{
        .{ .method = .PUT, .suffix = "/yank", .status = 202, .body = yankState("visible", "unyanking", "2") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = yankState("visible", "restored", "2") },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var console = gp.Console.init(a, null);
    var y = yanker(a, &script, &console, true);
    try std.testing.expectEqual(Result.done, y.run());
    try std.testing.expectEqualStrings("{\"yanked\":false}", script.seen.items[0].body.?);
    try std.testing.expect(std.mem.indexOf(u8, console.out.items, "restored (2 versions it had yanked)") != null);

    // Already yanked: the registry answers 200 and the command is done at once.
    var again = gt.Script{ .steps = &.{.{ .method = .PUT, .suffix = "/yank", .status = 200, .body = yankState("visible", "yanked", "3") }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c2 = gp.Console.init(a, null);
    var z = yanker(a, &again, &c2, false);
    try std.testing.expectEqual(Result.done, z.run());
    try std.testing.expectEqual(@as(usize, 1), again.seen.items.len);
    try std.testing.expect(std.mem.indexOf(u8, c2.out.items, "is already yanked") != null);

    // A group that was never yanked has nothing to restore.
    var never = gt.Script{ .steps = &.{.{ .method = .PUT, .suffix = "/yank", .status = 200, .body = "{\"group_id\":\"" ++ gid ++ "\",\"status\":\"visible\"}" }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c3 = gp.Console.init(a, null);
    var w = yanker(a, &never, &c3, true);
    try std.testing.expectEqual(Result.done, w.run());
    try std.testing.expectEqual(@as(usize, 1), never.seen.items.len);
}

test "a group that cannot be yanked yet, a busy registry, a slow one and a broken one" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const not_settled = "{\"error\":{\"code\":\"group_not_settled\",\"message\":\"Group x cannot be yanked or unyanked now: it is validating.\",\"hint\":\"A group is yanked once it is visible.\"}}";
    var s1 = gt.Script{ .steps = &.{.{ .method = .PUT, .suffix = "/yank", .status = 409, .body = not_settled }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c1 = gp.Console.init(a, null);
    var y1 = yanker(a, &s1, &c1, false);
    try std.testing.expectEqual(Result.failed, y1.run());
    try std.testing.expect(std.mem.indexOf(u8, c1.err.items, "it is validating") != null);
    try std.testing.expect(std.mem.indexOf(u8, c1.err.items, "hint: A group is yanked once it is visible.") != null);

    // 429 on the request, and on a poll.
    var s2 = gt.Script{ .steps = &.{.{ .method = .PUT, .suffix = "/yank", .status = 429, .retry_after = 12 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c2 = gp.Console.init(a, null);
    var y2 = yanker(a, &s2, &c2, false);
    try std.testing.expectEqual(Result.rate_limited, y2.run());
    try std.testing.expect(std.mem.indexOf(u8, c2.err.items, "retry after 12 seconds") != null);
    var s3 = gt.Script{ .steps = &.{
        .{ .method = .PUT, .suffix = "/yank", .status = 202, .body = yankState("visible", "yanking", "0") },
        .{ .method = .GET, .suffix = gid, .status = 429 },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c3 = gp.Console.init(a, null);
    var y3 = yanker(a, &s3, &c3, false);
    try std.testing.expectEqual(Result.rate_limited, y3.run());
    try std.testing.expectEqual(@as(usize, 2), s3.seen.items.len);

    // Never finishes.
    var s4 = gt.Script{ .steps = &.{
        .{ .method = .PUT, .suffix = "/yank", .status = 202, .body = yankState("visible", "yanking", "0") },
        .{ .method = .GET, .suffix = gid, .status = 200, .body = yankState("visible", "yanking", "0") },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c4 = gp.Console.init(a, null);
    var y4 = yanker(a, &s4, &c4, false);
    try std.testing.expectEqual(Result.timed_out, y4.run());
    try std.testing.expectEqual(@as(u64, 10), s4.slept);
    try std.testing.expect(std.mem.indexOf(u8, c4.err.items, "is yanking, not yanked yet") != null);

    // Answers that are not the registry's, and a connection that fails.
    var s5 = gt.Script{ .steps = &.{.{ .method = .PUT, .suffix = "/yank", .status = 202, .body = "nope" }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c5 = gp.Console.init(a, null);
    var y5 = yanker(a, &s5, &c5, false);
    try std.testing.expectEqual(Result.failed, y5.run());
    try std.testing.expect(std.mem.indexOf(u8, c5.err.items, "not one this mopm reads") != null);
    var s6 = gt.Script{ .steps = &.{.{ .method = .GET, .suffix = "/x", .status = 200 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c6 = gp.Console.init(a, null);
    var y6 = yanker(a, &s6, &c6, false);
    try std.testing.expectEqual(Result.failed, y6.run());
    try std.testing.expect(std.mem.indexOf(u8, c6.err.items, "PUT /groups/" ++ gid ++ "/yank: ConnectionRefused") != null);
    var s7 = gt.Script{ .steps = &.{
        .{ .method = .PUT, .suffix = "/yank", .status = 202, .body = yankState("visible", "yanking", "0") },
        .{ .method = .GET, .suffix = gid, .status = 404, .body = "{\"error\":{\"code\":\"group_not_found\",\"message\":\"There is no such group.\",\"hint\":\"h\"}}" },
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    var c7 = gp.Console.init(a, null);
    var y7 = yanker(a, &s7, &c7, false);
    try std.testing.expectEqual(Result.failed, y7.run());
    try std.testing.expect(std.mem.indexOf(u8, c7.err.items, "There is no such group.") != null);
}

test "flags" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    const f = (try parseFlags(a, &.{ "--group", gid, "--registry", "beta", "--reason", "bad", "--config-dir", "c", "--wait", "5" })).ok;
    try std.testing.expectEqualStrings(gid, f.group);
    try std.testing.expectEqualStrings("bad", f.reason.?);
    try std.testing.expectEqual(@as(i64, 5), f.wait_secs);
    try std.testing.expect(!f.unyank);
    const u = (try parseFlags(a, &.{ "--unyank", "--registry", "prod", "--group", gid })).ok;
    try std.testing.expect(u.unyank and u.reason == null);
    const cases = [_]struct { args: []const []const u8, want: []const u8 }{
        .{ .args = &.{ "--registry", "beta", "--reason", "x" }, .want = "--group <id> is required" },
        .{ .args = &.{ "--group", gid, "--reason", "x" }, .want = "--registry is required" },
        .{ .args = &.{ "--group", gid, "--registry", "beta" }, .want = "needs --reason" },
        .{ .args = &.{ "--group", gid, "--registry", "beta", "--reason", "" }, .want = "1 to 280 characters" },
        .{ .args = &.{ "--group", gid, "--registry", "beta", "--unyank", "--reason", "x" }, .want = "--reason is for a yank" },
        .{ .args = &.{ "--group", gid, "--registry", "beta", "--reason", "x", "--wait", "soon" }, .want = "a number of seconds" },
        .{ .args = &.{ "--group", gid, "--registry", "beta", "--reason", "x", "--wait", "-3" }, .want = "not negative" },
        .{ .args = &.{ "--group", gid, "--registry" }, .want = "--registry needs a value" },
        .{ .args = &.{ "--group", gid, "--registry", "beta", "--force" }, .want = "unexpected argument '--force'" },
    };
    for (cases) |c| {
        const why = (try parseFlags(a, c.args)).bad;
        try std.testing.expectEqualStrings(c.want, if (std.mem.indexOf(u8, why, c.want) != null) c.want else why);
    }
    var long: [281]u8 = undefined;
    @memset(&long, 'x');
    try std.testing.expect((try parseFlags(a, &.{ "--group", gid, "--registry", "beta", "--reason", &long })) == .bad);
}
