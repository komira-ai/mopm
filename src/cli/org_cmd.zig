//! `mopm org create`: an organization's namespace on a registry. The members of a namespace are generated commands
//! (`mopm org add|remove|list`, see `mopm org add --help`); only `create` is not one call.
//!
//!   mopm org create <org> [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!
//! `create` is a GitHub device flow through the registry, as `mopm login` is: mopm prints a code and a page to enter it on,
//! and polls until the person decides. The registry asks GitHub once, with the one-time token of that flow, whether the
//! account that approved is the logged-in account and an active admin of the GitHub organization `<org>`; it then
//! registers the namespace and makes the account its first owner.
//!
//! It needs the session `mopm login` stored for the registry and refuses without a request when there is none.
//! `<org>` is checked against the namespace grammar before anything is sent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const v2 = core.registry_v2;
const credentials = core.credentials;
const gp = @import("group_publish.zig");
const rc = @import("registry_cmd.zig");

const usage =
    \\usage: mopm org create <org> [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       'mopm org add|remove|list' are generated commands: mopm org add --help
    \\
;

pub const Parsed = struct {
    org: []const u8,
    flags: rc.Flags = .{},
};

/// The arguments after `org`; null on a usage error (a verb but `create`, an unknown flag, a flag without its value, a
/// missing or extra name).
pub fn parse(args: []const []const u8) ?Parsed {
    if (args.len == 0) return null;
    if (!std.mem.eql(u8, args[0], "create")) return null;
    var flags = rc.Flags{};
    var org: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--registry")) {
            if (i + 1 >= args.len) return null;
            flags.registry = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            if (i + 1 >= args.len) return null;
            flags.config_dir = args[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return null;
        } else {
            if (org != null) return null;
            org = a;
        }
    }
    return .{ .org = org orelse return null, .flags = flags };
}

/// `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 39 characters: a GitHub login in lower case.
pub fn isNamespace(s: []const u8) bool {
    if (s.len == 0 or s.len > core.names.max_namespace_len) return false;
    if (s[0] == '-' or s[s.len - 1] == '-') return false;
    var prev: u8 = 0;
    for (s) |b| {
        if (!std.ascii.isLower(b) and !std.ascii.isDigit(b) and b != '-') return false;
        if (b == '-' and prev == '-') return false;
        prev = b;
    }
    return true;
}

/// Whether the name of `p` is a namespace; if not, says so on standard error.
fn namesValid(con: *gp.Console, p: Parsed) bool {
    if (!isNamespace(p.org)) {
        con.fail("'{s}' is not a valid namespace\n", .{p.org});
        return false;
    }
    return true;
}

pub fn main(arena: Allocator, args: []const []const u8, cli_version: []const u8) u8 {
    const p = parse(args) orelse {
        std.io.getStdErr().writeAll(usage) catch {};
        return 2;
    };
    var con = gp.Console.init(arena, gp.Console.stdStreams);
    if (!namesValid(&con, p)) return 1;
    const s = rc.open(arena, p.flags, cli_version) orelse return 1;
    return execute(s, gp.realNet(), &con, p) catch |e| {
        con.fail("{s}\n", .{@errorName(e)});
        return 1;
    };
}

/// The registration. The clock, the pauses between polls and the requests are `net`'s, and everything it says goes through
/// `con`, so a test drives it without waiting and without touching the real standard streams.
fn execute(s: Session, net: gp.Net, con: *gp.Console, p: Parsed) anyerror!u8 {
    const entry = (try credentials.load(s.arena, s.config_dir, s.config.api_url)) orelse {
        con.fail("not logged in to {s}; run 'mopm login'\n", .{s.config.stage});
        return 1;
    };
    if (s.config.api_v2_url.len == 0) {
        con.fail("{s} serves no API version 2, which organization namespaces need\n", .{s.config.stage});
        return 1;
    }
    return create(s, net, con, entry.token, p.org);
}

const Session = rc.Session;

/// The device flow of the registration, as `mopm login`'s.
fn create(s: Session, net: gp.Net, con: *gp.Console, token: []const u8, org: []const u8) anyerror!u8 {
    const started = try v2.sendOnce(v2.CreateNamespace, s.arena, net, s.config.api_v2_url, token, .{ .body = .{ .namespace = org } });
    if (!started.ok()) {
        rc.reportFailure(con, started);
        return 1;
    }
    const start = try v2.decode(v2.CreateNamespace, s.arena, started.body);
    con.say("To register the GitHub organization {s} on {s}, open {s} and enter the code {s}\n", .{ org, s.config.stage, start.verification_uri, start.user_code });

    var interval = @max(start.interval, 1);
    const deadline = net.now() + start.expires_in + 30;
    while (net.now() < deadline) {
        net.pause(@intCast(interval));
        const polled = try v2.sendOnce(v2.PollNamespace, s.arena, net, s.config.api_v2_url, token, .{ .body = .{ .device_code = start.device_code } });
        if (!polled.ok()) {
            rc.reportFailure(con, polled);
            return 1;
        }
        const state = try v2.decode(v2.PollNamespace, s.arena, polled.body);
        switch (state.status) {
            .pending => {
                if (state.interval) |n| interval = @max(n, 1);
                continue;
            },
            .created => {
                const made = state.namespace orelse return error.CreatedWithoutNamespace;
                con.say("Registered {s} on {s} (GitHub organization id {d}); you are its owner.\n", .{ org, s.config.stage, made.github_id });
                return 0;
            },
            .denied => {
                con.fail("the registration was denied\n", .{});
                return 1;
            },
            .expired, .unknown => {
                con.fail("the registration expired; run 'mopm org create {s}' again\n", .{org});
                return 1;
            },
        }
    }
    con.fail("the registration expired; run 'mopm org create {s}' again\n", .{org});
    return 1;
}

// ---------------------------------------------------------------------------- tests

const gt = @import("group_publish_test.zig");

fn testSession(a: Allocator, dir: []const u8) Session {
    return .{ .arena = a, .config = .{ .stage = "beta", .api_url = "http://127.0.0.1:1/api/v1", .api_v2_url = "http://127.0.0.1:1/api/v2", .channel_url = "", .min_cli_version = "", .read_only = false }, .config_dir = dir };
}

fn loggedIn(a: Allocator, dir: []const u8) !void {
    try credentials.store(a, dir, "http://127.0.0.1:1/api/v1", .{ .token = "mopm_tok", .handle = "ada" });
}

fn reply(method: std.http.Method, comptime suffix: []const u8, status: u16, comptime body: []const u8) gt.Script.Step {
    return .{ .method = method, .suffix = suffix, .status = status, .body = body };
}

fn beginStep(comptime expires_in: []const u8, comptime interval: []const u8) gt.Script.Step {
    return reply(.POST, "/namespaces", 202, "{\"device_code\":\"dc\",\"user_code\":\"AB-12\",\"verification_uri\":\"https://example.test/device\",\"expires_in\":" ++ expires_in ++ ",\"interval\":" ++ interval ++ "}");
}

fn pollStep(comptime body: []const u8) gt.Script.Step {
    return reply(.POST, "/namespaces/poll", 200, body);
}

/// The text `mopm` prints for the failed answer `status` with `body` (what `reportFailure` says).
fn failureText(a: Allocator, status: u16, body: []const u8) ![]const u8 {
    const text = try http.describe(a, .{ .status = status, .body = body, .request_id = "req-test" });
    return std.fmt.allocPrint(a, "mopm: {s}", .{text});
}

const Run = struct { code: u8, con: gp.Console, script: gt.Script };

/// `args` of `mopm org` against the scripted registry `steps`, logged in unless `login` is false.
fn run(a: Allocator, dir: []const u8, login: bool, args: []const []const u8, steps: []const gt.Script.Step) !Run {
    if (login) try loggedIn(a, dir);
    var r: Run = undefined;
    r.con = gp.Console.init(a, null);
    r.script = gt.Script{ .steps = steps, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    const p = parse(args) orelse return error.TestBadArguments;
    r.code = try execute(testSession(a, dir), r.script.net(), &r.con, p);
    return r;
}

test "org arguments: create with its name, the flags in any place, and every other shape is a usage error" {
    const c = parse(&.{ "create", "acme" }).?;
    try std.testing.expectEqualStrings("acme", c.org);
    try std.testing.expectEqualStrings("prod", c.flags.registry);
    try std.testing.expect(c.flags.config_dir == null);

    const a = parse(&.{ "create", "--registry", "beta", "acme", "--config-dir", "/cfg" }).?;
    try std.testing.expectEqualStrings("acme", a.org);
    try std.testing.expectEqualStrings("beta", a.flags.registry);
    try std.testing.expectEqualStrings("/cfg", a.flags.config_dir.?);

    const bad = [_][]const []const u8{
        &.{},
        &.{"destroy"},
        &.{ "add", "acme", "ada" },
        &.{ "remove", "acme", "ada" },
        &.{ "list", "acme" },
        &.{"create"},
        &.{ "create", "acme", "extra" },
        &.{ "create", "acme", "--owner" },
        &.{ "create", "acme", "--registry" },
        &.{ "create", "acme", "--config-dir" },
    };
    for (bad) |args| try std.testing.expect(parse(args) == null);
}

test "org names are checked against the namespace grammar before any request, and the one that is not is named" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    for ([_][]const u8{ "Acme", "-acme", "acme-", "ac--me", "ac_me", "ac.me", "", "a" ** 40 }) |bad| {
        try std.testing.expect(!isNamespace(bad));
    }
    for ([_][]const u8{ "a", "acme", "ac-me", "a1-b2-c3", "a" ** 39 }) |good| {
        try std.testing.expect(isNamespace(good));
    }
    var con = gp.Console.init(a, null);
    try std.testing.expect(!namesValid(&con, parse(&.{ "create", "Acme" }).?));
    try std.testing.expectEqualStrings("mopm: 'Acme' is not a valid namespace\n", con.err.items);
    var con2 = gp.Console.init(a, null);
    try std.testing.expect(namesValid(&con2, parse(&.{ "create", "acme" }).?));
    try std.testing.expectEqualStrings("", con2.err.items);
}

test "org create prints the code, pauses as the registry says, and reports the namespace the registry made" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try run(a, dir, true, &.{ "create", "acme" }, &.{
        beginStep("900", "5"),
        pollStep("{\"status\":\"pending\",\"interval\":2}"),
        pollStep("{\"status\":\"created\",\"namespace\":{\"namespace\":\"acme\",\"kind\":\"org\",\"github_id\":4242,\"login\":\"acme\"}}"),
    });
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(r.script.mismatch == null);
    try std.testing.expectEqualStrings(
        "To register the GitHub organization acme on beta, open https://example.test/device and enter the code AB-12\nRegistered acme on beta (GitHub organization id 4242); you are its owner.\n",
        r.con.out.items,
    );
    try std.testing.expectEqualStrings("", r.con.err.items);
    // The start names the namespace, under API version 2 with the stored session; each poll names the device code.
    try std.testing.expectEqual(@as(usize, 3), r.script.seen.items.len);
    const first = r.script.seen.items[0];
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/namespaces", first.url);
    try std.testing.expectEqualStrings("{\"namespace\":\"acme\"}", first.body.?);
    for (r.script.seen.items) |x| try std.testing.expectEqualStrings("mopm_tok", x.token.?);
    for (r.script.seen.items[1..]) |x| {
        try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/namespaces/poll", x.url);
        try std.testing.expectEqualStrings("{\"device_code\":\"dc\"}", x.body.?);
    }
    // 5 before the first poll, then the 2 the pending answer asked for.
    try std.testing.expectEqual(@as(u64, 7), r.script.slept);
}

test "org create ends with exit 1 and its own message when the person denies, the flow expires, or the clock passes the limit" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const denied = try run(a, dir, true, &.{ "create", "acme" }, &.{ beginStep("900", "3"), pollStep("{\"status\":\"denied\"}") });
    try std.testing.expectEqual(@as(u8, 1), denied.code);
    try std.testing.expectEqualStrings("mopm: the registration was denied\n", denied.con.err.items);
    try std.testing.expectEqualStrings("To register the GitHub organization acme on beta, open https://example.test/device and enter the code AB-12\n", denied.con.out.items);
    const expired = try run(a, dir, true, &.{ "create", "acme" }, &.{ beginStep("900", "3"), pollStep("{\"status\":\"expired\"}") });
    try std.testing.expectEqual(@as(u8, 1), expired.code);
    try std.testing.expectEqualStrings("mopm: the registration expired; run 'mopm org create acme' again\n", expired.con.err.items);
    // Pending for good: ten seconds and the thirty of grace, polled every five, are eight polls and forty seconds.
    const slow = try run(a, dir, true, &.{ "create", "acme" }, &.{ beginStep("10", "5"), pollStep("{\"status\":\"pending\"}") });
    try std.testing.expectEqual(@as(u8, 1), slow.code);
    try std.testing.expectEqual(@as(u64, 40), slow.script.slept);
    try std.testing.expectEqual(@as(usize, 9), slow.script.seen.items.len);
    try std.testing.expectEqualStrings("mopm: the registration expired; run 'mopm org create acme' again\n", slow.con.err.items);
}

test "org create treats a status it does not know as the end of the flow, like expired" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try run(a, dir, true, &.{ "create", "acme" }, &.{ beginStep("900", "3"), pollStep("{\"status\":\"suspended\"}") });
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqual(@as(u64, 3), r.script.slept);
    try std.testing.expectEqualStrings("mopm: the registration expired; run 'mopm org create acme' again\n", r.con.err.items);
}

test "org create prints the failure the registry gave, at the start and at a poll, and exits 1" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const taken = "{\"error\":{\"code\":\"namespace_taken\",\"message\":\"'acme' is taken.\",\"hint\":\"Choose the namespace of another GitHub organization.\"}}";
    const at_start = try run(a, dir, true, &.{ "create", "acme" }, &.{reply(.POST, "/namespaces", 409, taken)});
    try std.testing.expectEqual(@as(u8, 1), at_start.code);
    try std.testing.expectEqualStrings(try failureText(a, 409, taken), at_start.con.err.items);
    try std.testing.expectEqual(@as(u64, 0), at_start.script.slept);
    try std.testing.expectEqual(@as(usize, 1), at_start.script.seen.items.len);

    const not_admin = "{\"error\":{\"code\":\"not_org_admin\",\"message\":\"You are not an active admin of the GitHub organization 'acme'.\",\"hint\":\"An admin of the GitHub organization runs 'mopm org create acme'.\"}}";
    const at_poll = try run(a, dir, true, &.{ "create", "acme" }, &.{ beginStep("900", "4"), reply(.POST, "/namespaces/poll", 403, not_admin) });
    try std.testing.expectEqual(@as(u8, 1), at_poll.code);
    try std.testing.expectEqualStrings(try failureText(a, 403, not_admin), at_poll.con.err.items);
    try std.testing.expectEqual(@as(u64, 4), at_poll.script.slept);
}

test "org create without a stored login says so, exits 1 and sends nothing" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try run(a, dir, false, &.{ "create", "acme" }, &.{reply(.GET, "/namespaces", 200, "{}")});
    try std.testing.expectEqual(@as(u8, 1), r.code);
    try std.testing.expectEqual(@as(usize, 0), r.script.seen.items.len);
    try std.testing.expectEqualStrings("mopm: not logged in to beta; run 'mopm login'\n", r.con.err.items);
    try std.testing.expectEqualStrings("", r.con.out.items);
}

test "org create on a registry with no API version 2 says so and sends nothing" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    try loggedIn(a, dir);
    var session = testSession(a, dir);
    session.config.api_v2_url = "";
    var con = gp.Console.init(a, null);
    var script = gt.Script{ .steps = &.{reply(.GET, "/namespaces", 200, "{}")}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try execute(session, script.net(), &con, parse(&.{ "create", "acme" }).?));
    try std.testing.expectEqual(@as(usize, 0), script.seen.items.len);
    try std.testing.expectEqualStrings("mopm: beta serves no API version 2, which organization namespaces need\n", con.err.items);
}
