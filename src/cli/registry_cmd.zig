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
    const result = if (std.mem.eql(u8, cmd, "login"))
        login(s, cli_version)
    else if (std.mem.eql(u8, cmd, "logout"))
        logout(s)
    else
        whoami(s);
    return result catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
}

fn printFailure(a: http.Answer) void {
    const text = http.describe(std.heap.page_allocator, a) catch return;
    std.io.getStdErr().writer().print("mopm: {s}", .{text}) catch {};
}

fn login(s: Session, cli_version: []const u8) anyerror!u8 {
    const out = std.io.getStdOut().writer();
    const client = try std.fmt.allocPrint(s.arena, "{{\"client\":\"mopm {s}\"}}", .{cli_version});
    const started = try http.request(s.arena, .POST, try s.api("/auth/device"), .{ .body = client });
    if (!started.ok()) {
        printFailure(started);
        return 1;
    }
    const start = try std.json.parseFromSliceLeaky(struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        expires_in: i64,
        interval: i64,
    }, s.arena, started.body, .{ .ignore_unknown_fields = true });
    try out.print("To log in to {s}, open {s} and enter the code {s}\n", .{ s.config.stage, start.verification_uri, start.user_code });

    var interval = @max(start.interval, 1);
    const body = try std.fmt.allocPrint(s.arena, "{{\"device_code\":\"{s}\"}}", .{start.device_code});
    const deadline = std.time.timestamp() + start.expires_in + 30;
    while (std.time.timestamp() < deadline) {
        std.time.sleep(@as(u64, @intCast(interval)) * std.time.ns_per_s);
        const polled = try http.request(s.arena, .POST, try s.api("/auth/device/poll"), .{ .body = body });
        if (!polled.ok()) {
            printFailure(polled);
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
            try out.print("Logged in to {s} as {s}.\n", .{ s.config.stage, handle });
            return 0;
        }
        if (std.mem.eql(u8, state.status, "denied")) {
            err("the login was denied\n", .{});
            return 1;
        }
        err("the login expired; run 'mopm login' again\n", .{});
        return 1;
    }
    err("the login expired; run 'mopm login' again\n", .{});
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
