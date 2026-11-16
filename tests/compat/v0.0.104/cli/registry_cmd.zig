//! `mopm login`, `mopm logout` and `mopm whoami`: an account on a registry.
//!
//!   mopm login  [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
//!   mopm logout [--registry ...] [--config-dir <dir>]
//!   mopm whoami [--registry ...] [--config-dir <dir>]
//!
//! Login is GitHub's device flow through the registry: mopm prints a code and
//! a page to enter it on, and polls until the person decides. The session
//! token is stored in `<config dir>/credentials.json` (mode 0600) and never
//! printed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const registry = core.registry;
const credentials = core.credentials;
const gp = @import("group_publish.zig");

const usage =
    \\usage: mopm login  [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm logout [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
    \\       mopm whoami [--registry <prod|gamma|beta|url>] [--config-dir <dir>]
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

    pub fn api(s: Session, path: []const u8) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(s.arena, "{s}{s}", .{ s.config.api_url, path });
    }
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
    else if (std.mem.eql(u8, cmd, "logout"))
        logout(s)
    else
        whoami(s);
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

/// The device flow. The clock, the pauses between polls and the requests are `net`'s, and everything it says goes through
/// `con`, so a test drives it without waiting and without touching the real standard streams.
fn login(s: Session, net: gp.Net, con: *gp.Console, cli_version: []const u8) anyerror!u8 {
    const client = try std.fmt.allocPrint(s.arena, "{{\"client\":\"mopm {s}\"}}", .{cli_version});
    const started = try net.once(s.arena, .POST, try s.api("/auth/device"), .{ .body = client });
    if (!started.ok()) {
        reportFailure(con, started);
        return 1;
    }
    const start = try std.json.parseFromSliceLeaky(struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        expires_in: i64,
        interval: i64,
    }, s.arena, started.body, .{ .ignore_unknown_fields = true });
    con.say("To log in to {s}, open {s} and enter the code {s}\n", .{ s.config.stage, start.verification_uri, start.user_code });

    var interval = @max(start.interval, 1);
    const body = try std.fmt.allocPrint(s.arena, "{{\"device_code\":\"{s}\"}}", .{start.device_code});
    const deadline = net.now() + start.expires_in + 30;
    while (net.now() < deadline) {
        net.pause(@intCast(interval));
        const polled = try net.once(s.arena, .POST, try s.api("/auth/device/poll"), .{ .body = body });
        if (!polled.ok()) {
            reportFailure(con, polled);
            return 1;
        }
        const state = try std.json.parseFromSliceLeaky(struct {
            status: []const u8,
            interval: ?i64 = null,
            token: ?[]const u8 = null,
            handle: ?[]const u8 = null,
        }, s.arena, polled.body, .{ .ignore_unknown_fields = true });
        if (std.mem.eql(u8, state.status, "pending")) {
            if (state.interval) |n| interval = @max(n, 1);
            continue;
        }
        if (std.mem.eql(u8, state.status, "approved")) {
            const handle = state.handle orelse "";
            try credentials.store(s.arena, s.config_dir, s.config.api_url, .{ .token = state.token orelse return error.ApprovedWithoutToken, .handle = handle });
            con.say("Logged in to {s} as {s}.\n", .{ s.config.stage, handle });
            return 0;
        }
        if (std.mem.eql(u8, state.status, "denied")) {
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

fn whoami(s: Session) anyerror!u8 {
    const entry = (try credentials.load(s.arena, s.config_dir, s.config.api_url)) orelse {
        err("not logged in to {s}; run 'mopm login'\n", .{s.config.stage});
        return 1;
    };
    const answer = try http.request(s.arena, .GET, try s.api("/me"), .{ .token = entry.token });
    if (!answer.ok()) {
        printFailure(answer);
        return 1;
    }
    const me = try std.json.parseFromSliceLeaky(struct {
        handle: []const u8,
        github_id: u64,
        packages: []const []const u8,
        pending_invitations: u64,
    }, s.arena, answer.body, .{ .ignore_unknown_fields = true });
    const out = std.io.getStdOut().writer();
    try out.print("{s} (GitHub id {d}) on {s}\n", .{ me.handle, me.github_id, s.config.stage });
    if (me.packages.len > 0) {
        try out.writeAll("packages:");
        for (me.packages) |p| try out.print(" {s}", .{p});
        try out.writeAll("\n");
    }
    if (me.pending_invitations > 0) try out.print("pending invitations: {d}\n", .{me.pending_invitations});
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
    return .{ .method = .POST, .suffix = "/auth/device", .status = 200, .body = "{\"device_code\":\"dc\",\"user_code\":\"AB-12\",\"verification_uri\":\"https://example.test/device\",\"expires_in\":" ++ expires_in ++ ",\"interval\":" ++ interval ++ "}" };
}

fn poll(comptime body: []const u8) gt.Script.Step {
    return .{ .method = .POST, .suffix = "/auth/device/poll", .status = 200, .body = body };
}

fn loginSession(a: Allocator, dir: []const u8) Session {
    return .{ .arena = a, .config = .{ .stage = "beta", .api_url = "http://127.0.0.1:1/api/v1", .channel_url = "", .min_cli_version = "", .read_only = false }, .config_dir = dir };
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
    }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 0), try login(loginSession(a, dir), script.net(), &con,"1.2.3"));
    try std.testing.expect(script.mismatch == null);
    // The device request carries the client; every poll carries the device code.
    try std.testing.expectEqualStrings("{\"client\":\"mopm 1.2.3\"}", script.seen.items[0].body.?);
    for (script.seen.items[1..]) |x| try std.testing.expectEqualStrings("{\"device_code\":\"dc\"}", x.body.?);
    // 5 before the first poll, 2 after the interval it was told, 2 again when the next pending names none: 9, not 15.
    try std.testing.expectEqual(@as(u64, 9), script.slept);
    const entry = (try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")).?;
    try std.testing.expectEqualStrings("mopm_tok", entry.token);
    try std.testing.expectEqualStrings("ada", entry.handle);
    // What it says goes through the console it was given, not the process's standard output.
    try std.testing.expectEqualStrings("To log in to beta, open https://example.test/device and enter the code AB-12\nLogged in to beta as ada.\n", con.out.items);
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
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), slow.net(), &con,"1.2.3"));
    try std.testing.expectEqual(@as(usize, 9), slow.seen.items.len);
    try std.testing.expectEqual(@as(u64, 40), slow.slept);
    try std.testing.expect((try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")) == null);

    // An interval of 0 is raised to 1: thirty seconds of limit is thirty one-second pauses.
    var zero = gt.Script{ .steps = &.{ begun("0", "0"), poll("{\"status\":\"pending\",\"interval\":0}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), zero.net(), &con,"1.2.3"));
    try std.testing.expectEqual(@as(u64, 30), zero.slept);
}

test "login stops with no pause when the registry refuses the device request, and after the first pause when it refuses a poll" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var con = gp.Console.init(a, null);
    var refused = gt.Script{ .steps = &.{.{ .method = .POST, .suffix = "/auth/device", .status = 503 }}, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, "unused"), refused.net(), &con,"1.2.3"));
    try std.testing.expectEqual(@as(u64, 0), refused.slept);
    try std.testing.expectEqual(@as(usize, 1), refused.seen.items.len);
    var broken = gt.Script{ .steps = &.{ begun("900", "4"), .{ .method = .POST, .suffix = "/auth/device/poll", .status = 500 } }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, "unused"), broken.net(), &con,"1.2.3"));
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
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), denied.net(), &con,"1.2.3"));
    try std.testing.expectEqual(@as(u64, 3), denied.slept);
    try std.testing.expect(std.mem.endsWith(u8, con.err.items, "mopm: the login was denied\n"));
    var expired = gt.Script{ .steps = &.{ begun("900", "3"), poll("{\"status\":\"expired\"}") }, .seen = std.ArrayList(gt.Script.Seen).init(a) };
    try std.testing.expectEqual(@as(u8, 1), try login(loginSession(a, dir), expired.net(), &con,"1.2.3"));
    try std.testing.expectEqual(@as(u64, 3), expired.slept);
    try std.testing.expect((try credentials.load(a, dir, "http://127.0.0.1:1/api/v1")) == null);
}
