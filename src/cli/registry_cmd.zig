//! `mopm login` and `mopm logout`: an account on a registry (`mopm whoami` is generated from GET /me, see api_cmd.zig).
//!
//!   mopm login  [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!   mopm logout [--registry ...] [--config-dir <dir>]
//!
//! Login is GitHub's device flow through the registry: mopm prints a code and
//! a page to enter it on, and polls until the person decides. Once approved it
//! asks `GET <api_v2_url>/me` who the account is and which namespaces it has.
//! What is stored in `<config dir>/credentials.json` (mode 0600), per registry,
//! is the session token (never printed), the handle and the account's user
//! namespace: the namespace of kind "user" equal to the handle in lower case,
//! else the first of kind "user", else none (an account whose GitHub login is
//! not a namespace has none, and the registry says why in `unavailable_namespace`).
//! A /me that fails does not fail the login: the token is stored without a
//! namespace and mopm says so.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const registry = core.registry;
const v2 = core.registry_v2;
const credentials = core.credentials;
const gp = @import("group_publish.zig");

const usage =
    \\usage: mopm login  [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm logout [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\
;

pub const Flags = struct {
    registry: []const u8 = "prod",
    config_dir: ?[]const u8 = null,
};

/// `--registry` and `--config-dir`; null on anything else.
pub fn parseFlags(args: []const []const u8) ?Flags {
    var f = Flags{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (i + 1 >= args.len) return null;
        if (std.mem.eql(u8, args[i], "--registry")) {
            f.registry = args[i + 1];
        } else if (std.mem.eql(u8, args[i], "--config-dir")) {
            f.config_dir = args[i + 1];
        } else return null;
        i += 1;
    }
    return f;
}

/// What every account command needs: the registry's config and where the
/// credentials live.
pub const Session = struct {
    arena: Allocator,
    config: registry.Config,
    config_dir: []const u8,
};

fn err(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("mopm: " ++ fmt, args) catch {};
}

/// Resolves the flags to a session, or prints why not and returns null.
pub fn open(arena: Allocator, flags: Flags, cli_version: []const u8) ?Session {
    const base = switch (registry.resolve(flags.registry)) {
        .ok => |b| b,
        .bad => |why| {
            err("--registry {s}: {s}\n", .{ flags.registry, why });
            return null;
        },
    };
    const config = switch (registry.load(arena, base, cli_version) catch |e| {
        err("{s}: {s}\n", .{ base, @errorName(e) });
        return null;
    }) {
        .ok => |c| c,
        .bad => |why| {
            err("{s}: {s}\n", .{ base, why });
            return null;
        },
    };
    const dir = flags.config_dir orelse (credentials.defaultDir(arena) catch {
        err("no config directory: set HOME or pass --config-dir\n", .{});
        return null;
    });
    return .{ .arena = arena, .config = config, .config_dir = dir };
}

pub fn main(arena: Allocator, cmd: []const u8, args: []const []const u8, cli_version: []const u8) u8 {
    const flags = parseFlags(args) orelse {
        std.io.getStdErr().writeAll(usage) catch {};
        return 2;
    };
    const s = open(arena, flags, cli_version) orelse return 1;
    var con = gp.Console.init(arena, gp.Console.stdStreams);
    const result = if (std.mem.eql(u8, cmd, "login"))
        login(s, gp.realNet(), &con, cli_version)
    else
        logout(s);
    return result catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
}

pub fn printFailure(a: http.Answer) void {
    const text = http.describe(std.heap.page_allocator, a) catch return;
    std.io.getStdErr().writer().print("mopm: {s}", .{text}) catch {};
}

/// `printFailure`, through `con`.
pub fn reportFailure(con: *gp.Console, a: http.Answer) void {
    const text = http.describe(std.heap.page_allocator, a) catch return;
    con.fail("{s}", .{text});
}

/// `GET /me` with `token`; the answer, or the failed answer for the caller to report.
fn getMe(s: Session, net: gp.Net, token: []const u8) anyerror!http.Answer {
    return v2.send(v2.GetMe, s.arena, net, net.policy, s.config.api_v2_url, token, .{});
}

/// The account's user namespace: the one of kind "user" equal to `handle` in lower case, else the first of kind "user".
fn userNamespace(me: v2.MeV2, handle: []const u8) ?[]const u8 {
    for (me.namespaces) |n| {
        if (n.kind == .user and std.ascii.eqlIgnoreCase(n.namespace, handle)) return n.namespace;
    }
    for (me.namespaces) |n| {
        if (n.kind == .user) return n.namespace;
    }
    return null;
}

/// Reads /me for a login that was just approved; null when it cannot be read (the request failed, was refused, or
/// its body is not a `MeV2`).
fn readMe(s: Session, net: gp.Net, token: []const u8) ?v2.MeV2 {
    const answer = getMe(s, net, token) catch return null;
    if (!answer.ok()) return null;
    return v2.decode(v2.GetMe, s.arena, answer.body) catch null;
}

/// The device flow. The clock, the pauses between polls and the requests are `net`'s, and everything it says goes through
/// `con`, so a test drives it without waiting and without touching the real standard streams.
fn login(s: Session, net: gp.Net, con: *gp.Console, cli_version: []const u8) anyerror!u8 {
    const client = try std.fmt.allocPrint(s.arena, "mopm {s}", .{cli_version});
    const started = try v2.sendOnce(v2.StartDeviceLogin, s.arena, net, s.config.api_url, null, .{ .body = .{ .client = client } });
    if (!started.ok()) {
        reportFailure(con, started);
        return 1;
    }
    const start = try v2.decode(v2.StartDeviceLogin, s.arena, started.body);
    con.say("To log in to {s}, open {s} and enter the code {s}\n", .{ s.config.stage, start.verification_uri, start.user_code });

    var interval = @max(start.interval, 1);
    const deadline = net.now() + start.expires_in + 30;
    while (net.now() < deadline) {
        net.pause(@intCast(interval));
        const polled = try v2.sendOnce(v2.PollDeviceLogin, s.arena, net, s.config.api_url, null, .{ .body = .{ .device_code = start.device_code } });
        if (!polled.ok()) {
            reportFailure(con, polled);
            return 1;
        }
        const state = try v2.decode(v2.PollDeviceLogin, s.arena, polled.body);
        if (state.status == .pending) {
            if (state.interval) |n| interval = @max(n, 1);
            continue;
        }
        if (state.status == .approved) {
            const handle = state.handle orelse "";
            const token = state.token orelse return error.ApprovedWithoutToken;
            if (s.config.api_v2_url.len == 0) {
                try credentials.store(s.arena, s.config_dir, s.config.api_url, .{ .token = token, .handle = handle });
                con.say("Logged in to {s} as {s}.\n", .{ s.config.stage, handle });
                return 0;
            }
            const me = readMe(s, net, token) orelse {
                try credentials.store(s.arena, s.config_dir, s.config.api_url, .{ .token = token, .handle = handle });
                con.say("Logged in to {s} as {s}.\n", .{ s.config.stage, handle });
                con.fail("could not read your namespace from {s}; 'mopm whoami' shows it\n", .{s.config.stage});
                return 0;
            };
            const namespace = userNamespace(me, handle);
            try credentials.store(s.arena, s.config_dir, s.config.api_url, .{ .token = token, .handle = handle, .namespace = namespace });
            if (namespace) |ns| {
                con.say("Logged in to {s} as {s}; your namespace is {s}.\n", .{ s.config.stage, handle, ns });
            } else if (me.unavailable_namespace) |login_name| {
                con.say("Logged in to {s} as {s}. Your GitHub login '{s}' is not a namespace on {s} (another account holds it, it is reserved, or it is not a valid namespace); publish in an organization's namespace.\n", .{ s.config.stage, handle, login_name, s.config.stage });
            } else {
                con.say("Logged in to {s} as {s}.\n", .{ s.config.stage, handle });
            }
            return 0;
        }
        if (state.status == .denied) {
            con.fail("the login was denied\n", .{});
            return 1;
        }
        con.fail("the login expired; run 'mopm login' again\n", .{});
        return 1;
    }
    con.fail("the login expired; run 'mopm login' again\n", .{});
    return 1;
}

fn logout(s: Session) anyerror!u8 {
    const out = std.io.getStdOut().writer();
    if (try credentials.remove(s.arena, s.config_dir, s.config.api_url)) {
        try out.print("Logged out of {s}.\n", .{s.config.stage});
    } else {
        try out.print("Not logged in to {s}.\n", .{s.config.stage});
    }
    return 0;
}

test "account command flags" {
    const f = parseFlags(&.{ "--registry", "beta", "--config-dir", "/tmp/x" }).?;
    try std.testing.expectEqualStrings("beta", f.registry);
    try std.testing.expectEqualStrings("/tmp/x", f.config_dir.?);
    try std.testing.expectEqualStrings("prod", parseFlags(&.{}).?.registry);
    try std.testing.expect(parseFlags(&.{"--registry"}) == null);
    try std.testing.expect(parseFlags(&.{ "--token", "x" }) == null);
}

const gt = @import("group_publish_test.zig");

fn begun(comptime expires_in: []const u8, comptime interval: []const u8) gt.Script.Step {
    return .{ .method = .POST, .suffix = v2.StartDeviceLogin.path_template, .status = 200, .body = "{\"device_code\":\"dc\",\"user_code\":\"AB-12\",\"verification_uri\":\"https://example.test/device\",\"expires_in\":" ++ expires_in ++ ",\"interval\":" ++ interval ++ "}" };
}

fn poll(comptime body: []const u8) gt.Script.Step {
    return .{ .method = .POST, .suffix = v2.PollDeviceLogin.path_template, .status = 200, .body = body };
}

fn me_step(comptime body: []const u8) gt.Script.Step {
    return .{ .method = .GET, .suffix = v2.GetMe.path_template, .status = 200, .body = body };
}

const me_ada = "{\"github_id\":7,\"handle\":\"ada\",\"namespaces\":[{\"namespace\":\"ada\",\"kind\":\"user\",\"role\":\"owner\",\"packages\":[]}]}";

fn loginSession(a: Allocator, dir: []const u8) Session {
    return .{ .arena = a, .config = .{ .stage = "beta", .api_url = "http://127.0.0.1:1/api/v1", .api_v2_url = "http://127.0.0.1:1/api/v2", .channel_url = "", .min_cli_version = "", .read_only = false }, .config_dir = dir };
}

test "login pauses the interval the registry named before the first poll and the one each pending answer names after, then stores the token" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var script = gt.Script{ .steps = &.{
        begun("900", "5"),
        poll("{\"status\":\"pending\",\"interval\":2}"),
        poll("{\"status\":\"pending\"}"),
        poll("{\"status\":\"approved\",\"token\":\"mopm_tok\",\"handle\":\"ada\"}"),
        me_step(me_ada),
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try login(loginSession(a, dir), script.net(), &con, "1.2.3"));
    try std.testing.expect(script.mismatch == null);
    // The device request carries the client; each of the three polls carries the device code; /me is a GET, last.
    try std.testing.expectEqual(@as(usize, 5), script.seen.items.len);
    try std.testing.expectEqualStrings("{\"client\":\"mopm 1.2.3\"}", script.seen.items[0].body.?);
    for (script.seen.items[1..4]) |x| try std.testing.expectEqualStrings("{\"device_code\":\"dc\"}", x.body.?);
    try std.testing.expect(script.seen.items[4].body == null);
    // 5 before the first poll, 2 after the interval it was told, 2 again when the next pending names none: 9, not 15.
    try std.testing.expectEqual(@as(u64, 9), script.slept);
    const entry = (try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")).?;
    try std.testing.expectEqualStrings("mopm_tok", entry.token);
    try std.testing.expectEqualStrings("ada", entry.handle);
    try std.testing.expectEqualStrings("ada", entry.namespace.?);
    // /me is asked with the new token, under API version 2.
    const last = script.seen.items[script.seen.items.len - 1];
    try std.testing.expectEqualStrings("http://127.0.0.1:1/api/v2/me", last.url);
    try std.testing.expectEqualStrings("mopm_tok", last.token.?);
    // What it says goes through the console it was given, not the process's standard output.
    try std.testing.expectEqualStrings("To log in to beta, open https://example.test/device and enter the code AB-12\nLogged in to beta as ada; your namespace is ada.\n", con.out.items);
    try std.testing.expectEqualStrings("", con.err.items);
}

test "login gives up when the net's clock passes expires_in plus 30 seconds, and polls at least once a second" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    // Limit 10 + 30 = 40 seconds at an interval of 5: eight polls, forty seconds of pauses.
    var slow = gt.Script{ .steps = &.{ begun("10", "5"), poll("{\"status\":\"pending\"}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), slow.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(usize, 9), slow.seen.items.len);
    try std.testing.expectEqual(@as(u64, 40), slow.slept);
    try std.testing.expect((try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")) == null);

    // An interval of 0 is raised to 1: thirty seconds of limit is thirty one-second pauses.
    var zero = gt.Script{ .steps = &.{ begun("0", "0"), poll("{\"status\":\"pending\",\"interval\":0}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), zero.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(u64, 30), zero.slept);
}

test "login stops with no pause when the registry refuses the device request, and after the first pause when it refuses a poll" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var refused = gt.Script{ .steps = &.{.{ .method = .POST, .suffix = "/auth/device", .status = 503 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, "unused"), refused.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(u64, 0), refused.slept);
    try std.testing.expectEqual(@as(usize, 1), refused.seen.items.len);
    var broken = gt.Script{ .steps = &.{ begun("900", "4"), .{ .method = .POST, .suffix = "/auth/device/poll", .status = 500 } }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, "unused"), broken.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(u64, 4), broken.slept);
    try std.testing.expectEqual(@as(usize, 2), broken.seen.items.len);
}

test "login ends at once, with no more pauses, when the person denies or the registry says expired" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var denied = gt.Script{ .steps = &.{ begun("900", "3"), poll("{\"status\":\"denied\"}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), denied.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(u64, 3), denied.slept);
    try std.testing.expect(std.mem.endsWith(u8, con.err.items, "mopm: the login was denied\n"));
    var expired = gt.Script{ .steps = &.{ begun("900", "3"), poll("{\"status\":\"expired\"}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), expired.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(u64, 3), expired.slept);
    try std.testing.expect((try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")) == null);
}

/// One approved login against `me`, with a fresh credentials directory; returns the console and the stored entry.
const LoginRun = struct { con: gp.Console, entry: credentials.Entry, code: u8, script: gt.Script };

fn approvedLogin(a: Allocator, dir: []const u8, me: gt.Script.Step) !LoginRun {
    var run: LoginRun = undefined;
    run.con = gp.Console.init(a, null);
    const steps = try a.dupe(gt.Script.Step, &.{
        begun("900", "1"),
        poll("{\"status\":\"approved\",\"token\":\"mopm_tok\",\"handle\":\"Ada\"}"),
        me,
    });
    run.script = gt.Script{ .steps = steps, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    run.code = try login(loginSession(a, dir), run.script.net(), &run.con, "1.2.3");
    run.entry = (try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")).?;
    return run;
}

test "login stores the user namespace equal to the handle in lower case when the account holds two user namespaces and an organization" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try approvedLogin(a, dir, me_step(
        \\{"github_id":7,"handle":"Ada","namespaces":[{"namespace":"old-ada","kind":"user","role":"owner","packages":[]},{"namespace":"acme","kind":"org","role":"owner","packages":["acme/tool"]},{"namespace":"ada","kind":"user","role":"owner","packages":[]}]}
    ));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expectEqualStrings("ada", r.entry.namespace.?);
    try std.testing.expectEqualStrings("Ada", r.entry.handle);
    try std.testing.expect(std.mem.endsWith(u8, r.con.out.items, "Logged in to beta as Ada; your namespace is ada.\n"));
    try std.testing.expectEqualStrings("", r.con.err.items);
}

test "login stores the first user namespace when none equals the handle, and never an organization namespace" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try approvedLogin(a, dir, me_step(
        \\{"github_id":7,"handle":"Ada","namespaces":[{"namespace":"acme","kind":"org","role":"owner","packages":[]},{"namespace":"old-ada","kind":"user","role":"owner","packages":[]}]}
    ));
    try std.testing.expectEqualStrings("old-ada", r.entry.namespace.?);
    try std.testing.expect(std.mem.endsWith(u8, r.con.out.items, "Logged in to beta as Ada; your namespace is old-ada.\n"));
}

test "login stores no namespace and says so when the account has only organization namespaces" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try approvedLogin(a, dir, me_step(
        \\{"github_id":7,"handle":"Ada","namespaces":[{"namespace":"acme","kind":"org","role":"member","packages":[]}]}
    ));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(r.entry.namespace == null);
    try std.testing.expect(std.mem.endsWith(u8, r.con.out.items, "Logged in to beta as Ada.\n"));
}

test "login with an unavailable_namespace stores none and says why on standard output" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const r = try approvedLogin(a, dir, me_step(
        \\{"github_id":7,"handle":"Ada","namespaces":[],"unavailable_namespace":"Ada"}
    ));
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try std.testing.expect(r.entry.namespace == null);
    try std.testing.expectEqualStrings("mopm_tok", r.entry.token);
    try std.testing.expectEqualStrings("To log in to beta, open https://example.test/device and enter the code AB-12\nLogged in to beta as Ada. Your GitHub login 'Ada' is not a namespace on beta (another account holds it, it is reserved, or it is not a valid namespace); publish in an organization's namespace.\n", r.con.out.items);
    try std.testing.expectEqualStrings("", r.con.err.items);
}

test "login whose /me is refused or unreadable still stores the token, with no namespace, and warns on standard error" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    const warning = "mopm: could not read your namespace from beta; 'mopm whoami' shows it\n";
    const refused = try approvedLogin(a, dir, .{ .method = .GET, .suffix = "/me", .status = 500 });
    try std.testing.expectEqual(@as(u8, 0), refused.code);
    try std.testing.expectEqualStrings("mopm_tok", refused.entry.token);
    try std.testing.expect(refused.entry.namespace == null);
    try std.testing.expectEqualStrings(warning, refused.con.err.items);
    try std.testing.expect(std.mem.endsWith(u8, refused.con.out.items, "Logged in to beta as Ada.\n"));

    const garbled = try approvedLogin(a, dir, me_step("not json"));
    try std.testing.expectEqual(@as(u8, 0), garbled.code);
    try std.testing.expect(garbled.entry.namespace == null);
    try std.testing.expectEqualStrings(warning, garbled.con.err.items);

    const broken = try approvedLogin(a, dir, .{ .method = .GET, .suffix = "/me", .status = 0, .err = error.ConnectionRefused });
    try std.testing.expectEqual(@as(u8, 0), broken.code);
    try std.testing.expectEqualStrings("mopm_tok", broken.entry.token);
    try std.testing.expectEqualStrings(warning, broken.con.err.items);
}

test "login asks for no /me when the config names no API version 2" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(a, ".");
    var session = loginSession(a, dir);
    session.config.api_v2_url = "";
    var script = gt.Script{ .steps = &.{ begun("900", "1"), poll("{\"status\":\"approved\",\"token\":\"mopm_tok\",\"handle\":\"ada\"}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try login(session, script.net(), &con, "1.2.3"));
    try std.testing.expectEqual(@as(usize, 2), script.seen.items.len);
    try std.testing.expect(std.mem.endsWith(u8, con.out.items, "Logged in to beta as ada.\n"));
    try std.testing.expectEqualStrings("", con.err.items);
}
