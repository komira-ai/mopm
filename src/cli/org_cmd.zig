//! `mopm org create|add|remove|list`: an organization's namespace on a registry and its members.
//!
//!   mopm org create <org>            [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!   mopm org add <org> <user> [--owner] [--registry ...] [--config-dir <dir>]
//!   mopm org remove <org> <user>     [--registry ...] [--config-dir <dir>]
//!   mopm org list <org>              [--registry ...] [--config-dir <dir>]
//!
//! `create` is a GitHub device flow through the registry, as `mopm login` is: mopm prints a code and a page to enter it on,
//! and polls until the person decides. The registry asks GitHub once, with the one-time token of that flow, whether the
//! account that approved is the logged-in account and an active admin of the GitHub organization `<org>`; it then
//! registers the namespace and makes the account its first owner. Nothing about the organization is asked of GitHub
//! afterwards: `add`, `remove` and `list` work on the member table the registry keeps. `<user>` is a mopm username, the
//! user namespace of an account, which it gets at its first `mopm login`. `add` sets the role: without `--owner` the
//! account becomes a member, also when it was an owner.
//!
//! Every verb needs the session `mopm login` stored for the registry and refuses without a request when there is none.
//! `<org>` and `<user>` are checked against the namespace grammar before anything is sent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const v2 = core.registry_v2;
const credentials = core.credentials;
const gp = @import("group_publish.zig");
const rc = @import("registry_cmd.zig");

const usage =
    \\usage: mopm org create <org>            [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm org add <org> <user> [--owner] [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm org remove <org> <user>     [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm org list <org>              [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\
;

pub const Verb = enum { create, add, remove, list };

pub const Parsed = struct {
    verb: Verb,
    org: []const u8,
    /// `add` and `remove`: the mopm username; empty for the other verbs.
    user: []const u8 = "",
    /// `add`: the account becomes an owner, not a member.
    owner: bool = false,
    flags: rc.Flags = .{},
};

/// The arguments after `org`; null on a usage error (an unknown verb or flag, a flag without its value, a missing or extra
/// name, `--owner` on a verb but `add`).
pub fn parse(args: []const []const u8) ?Parsed {
    if (args.len == 0) return null;
    const verb = std.meta.stringToEnum(Verb, args[0]) orelse return null;
    var flags = rc.Flags{};
    var owner = false;
    var positional: [2][]const u8 = undefined;
    var n: usize = 0;
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
        } else if (std.mem.eql(u8, a, "--owner")) {
            if (verb != .add) return null;
            owner = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return null;
        } else {
            if (n == positional.len) return null;
            positional[n] = a;
            n += 1;
        }
    }
    const wanted: usize = switch (verb) {
        .create, .list => 1,
        .add, .remove => 2,
    };
    if (n != wanted) return null;
    return .{
        .verb = verb,
        .org = positional[0],
        .user = if (wanted == 2) positional[1] else "",
        .owner = owner,
        .flags = flags,
    };
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

/// Whether the names of `p` are namespaces; if not, says which is not, on standard error.
fn namesValid(con: *gp.Console, p: Parsed) bool {
    if (!isNamespace(p.org)) {
        con.fail("'{s}' is not a valid namespace\n", .{p.org});
        return false;
    }
    if (p.user.len > 0 and !isNamespace(p.user)) {
        con.fail("'{s}' is not a valid namespace\n", .{p.user});
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

/// One verb. The clock, the pauses between polls and the requests are `net`'s, and everything it says goes through `con`, so
/// a test drives it without waiting and without touching the real standard streams.
fn execute(s: Session, net: gp.Net, con: *gp.Console, p: Parsed) anyerror!u8 {
    const entry = (try credentials.load(s.arena, s.config_dir, s.config.api_url)) orelse {
        con.fail("not logged in to {s}; run 'mopm login'\n", .{s.config.stage});
        return 1;
    };
    if (s.config.api_v2_url.len == 0) {
        con.fail("{s} serves no API version 2, which organization namespaces need\n", .{s.config.stage});
        return 1;
    }
    return switch (p.verb) {
        .create => create(s, net, con, entry.token, p.org),
        .add => add(s, net, con, entry.token, p),
        .remove => remove(s, net, con, entry.token, p),
        .list => list(s, net, con, entry.token, p.org),
    };
}

const Session = rc.Session;

/// The device flow of the registration, as `mopm login`'s.
fn create(s: Session, net: gp.Net, con: *gp.Console, token: []const u8, org: []const u8) anyerror!u8 {
    const start_params: v2.CreateNamespace.Params = .{ .body = .{ .namespace = org } };
    const request = (try v2.CreateNamespace.body(s.arena, start_params)).?;
    const started = try net.once(s.arena, v2.CreateNamespace.method, try v2.url(v2.CreateNamespace, s.arena, s.config.api_v2_url, start_params), .{ .token = token, .body = request });
    if (!started.ok()) {
        rc.reportFailure(con, started);
        return 1;
    }
    const start = try v2.decode(v2.CreateNamespace, s.arena, started.body);
    con.say("To register the GitHub organization {s} on {s}, open {s} and enter the code {s}\n", .{ org, s.config.stage, start.verification_uri, start.user_code });

    var interval = @max(start.interval, 1);
    const poll_params: v2.PollNamespace.Params = .{ .body = .{ .device_code = start.device_code } };
    const body = (try v2.PollNamespace.body(s.arena, poll_params)).?;
    const poll_url = try v2.url(v2.PollNamespace, s.arena, s.config.api_v2_url, poll_params);
    const deadline = net.now() + start.expires_in + 30;
    while (net.now() < deadline) {
        net.pause(@intCast(interval));
        const polled = try net.once(s.arena, v2.PollNamespace.method, poll_url, .{ .token = token, .body = body });
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

fn add(s: Session, net: gp.Net, con: *gp.Console, token: []const u8, p: Parsed) anyerror!u8 {
    const params: v2.SetMember.Params = .{ .namespace = p.org, .user = p.user, .body = .{ .role = if (p.owner) .owner else .member } };
    const body = (try v2.SetMember.body(s.arena, params)).?;
    const answer = try net.once(s.arena, v2.SetMember.method, try v2.url(v2.SetMember, s.arena, s.config.api_v2_url, params), .{ .token = token, .body = body });
    if (!answer.ok()) {
        rc.reportFailure(con, answer);
        return 1;
    }
    con.say("{s} is now {s} of {s} on {s}.\n", .{ p.user, if (p.owner) "an owner" else "a member", p.org, s.config.stage });
    return 0;
}

fn remove(s: Session, net: gp.Net, con: *gp.Console, token: []const u8, p: Parsed) anyerror!u8 {
    const params: v2.RemoveMember.Params = .{ .namespace = p.org, .user = p.user };
    const answer = try net.once(s.arena, v2.RemoveMember.method, try v2.url(v2.RemoveMember, s.arena, s.config.api_v2_url, params), .{ .token = token });
    if (!answer.ok()) {
        rc.reportFailure(con, answer);
        return 1;
    }
    con.say("Removed {s} from {s} on {s}.\n", .{ p.user, p.org, s.config.stage });
    return 0;
}

fn list(s: Session, net: gp.Net, con: *gp.Console, token: []const u8, org: []const u8) anyerror!u8 {
    const params: v2.ListMembers.Params = .{ .namespace = org };
    const answer = try net.request(s.arena, v2.ListMembers.method, try v2.url(v2.ListMembers, s.arena, s.config.api_v2_url, params), .{ .token = token });
    if (!answer.ok()) {
        rc.reportFailure(con, answer);
        return 1;
    }
    const members = try v2.decode(v2.ListMembers, s.arena, answer.body);
    con.say("{s} on {s}:\n", .{ org, s.config.stage });
    for (members.members) |m| con.say("  {s} ({s})\n", .{ m.user, @tagName(m.role) });
    return 0;
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

const refusal = "{\"error\":{\"code\":\"not_namespace_owner\",\"message\":\"You are not an owner of 'acme'.\",\"hint\":\"Ask an owner of 'acme'; 'mopm org list acme' shows them.\"}}";

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

test "org arguments: each verb with its names, the flags in any place, and every other shape is a usage error" {
    const c = parse(&.{ "create", "acme" }).?;
    try std.testing.expectEqual(Verb.create, c.verb);
    try std.testing.expectEqualStrings("acme", c.org);
    try std.testing.expectEqualStrings("prod", c.flags.registry);
    try std.testing.expect(c.flags.config_dir == null);
    try std.testing.expect(!c.owner);

    const a = parse(&.{ "add", "--registry", "beta", "acme", "--owner", "ada", "--config-dir", "/cfg" }).?;
    try std.testing.expectEqual(Verb.add, a.verb);
    try std.testing.expectEqualStrings("acme", a.org);
    try std.testing.expectEqualStrings("ada", a.user);
    try std.testing.expect(a.owner);
    try std.testing.expectEqualStrings("beta", a.flags.registry);
    try std.testing.expectEqualStrings("/cfg", a.flags.config_dir.?);
    try std.testing.expect(!parse(&.{ "add", "acme", "ada" }).?.owner);

    const r = parse(&.{ "remove", "acme", "ada" }).?;
    try std.testing.expectEqual(Verb.remove, r.verb);
    try std.testing.expectEqualStrings("ada", r.user);
    const l = parse(&.{ "list", "acme" }).?;
    try std.testing.expectEqual(Verb.list, l.verb);
    try std.testing.expectEqualStrings("", l.user);

    const bad = [_][]const []const u8{
        &.{},
        &.{"destroy"},
        &.{"create"},
        &.{ "create", "acme", "extra" },
        &.{ "add", "acme" },
        &.{ "add", "acme", "ada", "bob" },
        &.{ "remove", "acme" },
        &.{ "list", "acme", "ada" },
        &.{ "create", "acme", "--owner" },
        &.{ "remove", "acme", "ada", "--owner" },
        &.{ "list", "acme", "--token", "x" },
        &.{ "list", "acme", "--registry" },
        &.{ "list", "acme", "--config-dir" },
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
    try std.testing.expect(!namesValid(&con2, parse(&.{ "add", "acme", "Ada_1" }).?));
    try std.testing.expectEqualStrings("mopm: 'Ada_1' is not a valid namespace\n", con2.err.items);
    var con3 = gp.Console.init(a, null);
    try std.testing.expect(namesValid(&con3, parse(&.{ "add", "acme", "ada" }).?));
    try std.testing.expectEqualStrings("", con3.err.items);
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

test "org add sets the role the flag names and says so; the registry's refusal is printed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const member = try run(a, dir, true, &.{ "add", "acme", "bob" }, &.{reply(.PUT, "/namespaces/acme/members/bob", 201, "{}")});
    try std.testing.expectEqual(@as(u8, 0), member.code);
    try std.testing.expectEqualStrings("bob is now a member of acme on beta.\n", member.con.out.items);
    try std.testing.expectEqualStrings("{\"role\":\"member\"}", member.script.seen.items[0].body.?);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/namespaces/acme/members/bob", member.script.seen.items[0].url);
    try std.testing.expectEqualStrings("mopm_tok", member.script.seen.items[0].token.?);
    try std.testing.expectEqual(std.http.Method.PUT, member.script.seen.items[0].method);

    const owner = try run(a, dir, true, &.{ "add", "acme", "bob", "--owner" }, &.{reply(.PUT, "/namespaces/acme/members/bob", 200, "{}")});
    try std.testing.expectEqual(@as(u8, 0), owner.code);
    try std.testing.expectEqualStrings("bob is now an owner of acme on beta.\n", owner.con.out.items);
    try std.testing.expectEqualStrings("{\"role\":\"owner\"}", owner.script.seen.items[0].body.?);

    const refused = try run(a, dir, true, &.{ "add", "acme", "bob" }, &.{reply(.PUT, "/namespaces/acme/members/bob", 403, refusal)});
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expectEqualStrings(try failureText(a, 403, refusal), refused.con.err.items);
    try std.testing.expectEqualStrings("", refused.con.out.items);
}

test "org remove sends a DELETE with no body and says who was removed; the registry's refusal is printed" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const done = try run(a, dir, true, &.{ "remove", "acme", "bob" }, &.{.{ .method = .DELETE, .suffix = "/namespaces/acme/members/bob", .status = 204 }});
    try std.testing.expectEqual(@as(u8, 0), done.code);
    try std.testing.expectEqualStrings("Removed bob from acme on beta.\n", done.con.out.items);
    try std.testing.expectEqual(std.http.Method.DELETE, done.script.seen.items[0].method);
    try std.testing.expect(done.script.seen.items[0].body == null);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/namespaces/acme/members/bob", done.script.seen.items[0].url);
    try std.testing.expectEqualStrings("mopm_tok", done.script.seen.items[0].token.?);

    const last = "{\"error\":{\"code\":\"last_owner\",\"message\":\"'bob' is the last owner of 'acme'.\",\"hint\":\"Make another member an owner first.\"}}";
    const refused = try run(a, dir, true, &.{ "remove", "acme", "bob" }, &.{reply(.DELETE, "/namespaces/acme/members/bob", 409, last)});
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expectEqualStrings(try failureText(a, 409, last), refused.con.err.items);
}

test "org list prints the organization and one line per member in the order the registry sent" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const listed = try run(a, dir, true, &.{ "list", "acme" }, &.{reply(.GET, "/namespaces/acme/members", 200,
        \\{"namespace":"acme","members":[{"user":"ada","handle":"Ada","github_id":7,"role":"owner","added_at":"2026-09-02T00:00:00Z"},{"user":"bob","handle":"bob","github_id":8,"role":"member","added_at":"2026-09-03T00:00:00Z"}]}
    )});
    try std.testing.expectEqual(@as(u8, 0), listed.code);
    try std.testing.expectEqualStrings("acme on beta:\n  ada (owner)\n  bob (member)\n", listed.con.out.items);
    try std.testing.expectEqual(std.http.Method.GET, listed.script.seen.items[0].method);
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/namespaces/acme/members", listed.script.seen.items[0].url);
    try std.testing.expectEqualStrings("mopm_tok", listed.script.seen.items[0].token.?);

    const refused = try run(a, dir, true, &.{ "list", "acme" }, &.{reply(.GET, "/namespaces/acme/members", 403, "{\"error\":{\"code\":\"not_namespace_member\",\"message\":\"You cannot write in 'acme'.\",\"hint\":\"Ask an owner of 'acme'.\"}}")});
    try std.testing.expectEqual(@as(u8, 1), refused.code);
    try std.testing.expectEqualStrings("", refused.con.out.items);
    try std.testing.expect(std.mem.startsWith(u8, refused.con.err.items, "mopm: You cannot write in 'acme'.\n"));
}

test "every org verb without a stored login says so, exits 1 and sends nothing" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const all = [_][]const []const u8{ &.{ "create", "acme" }, &.{ "add", "acme", "bob" }, &.{ "remove", "acme", "bob" }, &.{ "list", "acme" } };
    for (all) |args| {
        const r = try run(a, dir, false, args, &.{reply(.GET, "/namespaces", 200, "{}")});
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expectEqual(@as(usize, 0), r.script.seen.items.len);
        try std.testing.expectEqualStrings("mopm: not logged in to beta; run 'mopm login'\n", r.con.err.items);
        try std.testing.expectEqualStrings("", r.con.out.items);
    }
}

test "org on a registry with no API version 2 says so and sends nothing" {
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
    try std.testing.expectEqual(@as(u8, 1), try execute(session, script.net(), &con, parse(&.{ "list", "acme" }).?));
    try std.testing.expectEqual(@as(usize, 0), script.seen.items.len);
    try std.testing.expectEqualStrings("mopm: beta serves no API version 2, which organization namespaces need\n", con.err.items);
}
