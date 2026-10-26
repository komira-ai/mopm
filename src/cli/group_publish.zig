//! `mopm publish --staged <dir> --registry <name>`: a staged set published through one group
//! (spec/staged-set.md; the registry's side is `createGroup`, `commitGroup` and `getGroup` in spec/api/openapi.yaml).
//!
//!   mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>]
//!                [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc]
//!
//! The run, in order:
//!   1. read `<dir>/plan.json`, refuse a plan that has a refused member, and check every file against the plan;
//!   2. `POST /groups` with the members to upload (the plan's order is dependency order): the registry answers one
//!      reservation per member, and a URL for each file it does not yet hold;
//!   3. PUT each file, member by member in that order; the PUT carries no token;
//!   4. `POST /groups/{id}/commit`;
//!   5. poll the group until it is `visible`, or ended.
//! Nothing is visible until the group is: a member the registry rejects ends the group `rejected`, and none of its
//! members is published.
//!
//! `--no-commit` stops after step 3: the group is open, every file is held, nothing is committed and nothing is readable.
//! The run prints the group id and the plan digest, ends 0 with the outcome `staged`, and keeps `state.json` (with
//! `staged: true`). The same command without `--no-commit`, in the same directory and with a token of the same actor (a
//! fresh `--oidc` exchange will do), resumes that group, commits it and waits. If the registry ended the group in between
//! (it expired, was aborted) that run says so and sends nothing. `--abort` is the failure job's verb: it ends the open group
//! that `state.json` names (`DELETE /groups/{id}`), which frees the actor's place on the registry at once; a group that is
//! already ended is not an error, and one that was committed is.
//!
//! `<dir>/state.json` names the group, so a rerun after a failure (a PUT that failed, a registry that was busy) asks for
//! the same group and sends only what the registry does not hold. `<dir>/report.json` says what each member came to.
//!
//! A 404 from `POST /groups` means the registry has no group publish: nothing is uploaded. A 429 stops the run at
//! once and says when to try again, unless the registry's Retry-After is short (http.max_retry_after_secs), when the
//! request waits that long and goes again; it is never retried into the limit. A request that can be repeated without
//! changing anything (every PUT of a file, every poll) is repeated, at most `--retries` times with jittered waits, when
//! the connection fails or times out (`--timeout`) or the server answers 500, 502, 503 or 504; a 4xx other than 429 is
//! final at once. The POSTs (create, commit) are sent once: a rerun of the command is their retry. The token (`$MOPM_TOKEN`, else the login's) is read after
//! the plan has been checked, goes only to the registry's API, is never printed, and is taken out of the environment of every
//! program mopm starts (src/core/child_env.zig).
//!
//! `--oidc` replaces that token with one from the CI job's identity (src/core/ci_oidc.zig): inside a GitHub Actions job
//! that may request an identity token, mopm exchanges it at the registry, in memory only, for one token that may publish
//! exactly the members the plan uploads, at their versions (the `packages` form of the exchange). An identity token is
//! single-use, so there is one identity request and one exchange for the whole set, and that token serves the group's
//! create, uploads, commit and waits. A set of more than 100 members is refused before any request (a group is one unit
//! and is not split); a rerun asks for a fresh token.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const registry = core.registry;
const ci_oidc = core.ci_oidc;
const plan_mod = @import("group_plan.zig");
const registry_cmd = @import("registry_cmd.zig");
const publish_cmd = @import("publish_cmd.zig");

const usage =
    \\usage: mopm publish --staged <dir> --registry <prod|gamma|beta|url> [--config-dir <dir>] [--wait <seconds>] [--timeout <seconds>] [--retries <n>] [--dry-run] [--oidc] [--no-commit | --abort]
    \\
    \\  Publishes the staged set in <dir> (plan.json and the files it names) through one group: every member is visible
    \\  together, or none is. --registry is required. A rerun after a failure resumes the same group (<dir>/state.json).
    \\  --oidc, inside a GitHub Actions job with 'id-token: write', gets the token from the job's identity, not $MOPM_TOKEN.
    \\  --no-commit uploads every file and stops with the group open (nothing committed, nothing readable); a later run
    \\  without it resumes the same group and commits. --abort ends the open group <dir>/state.json names.
    \\
;

/// The least the run waits for the group to be visible, unless `--wait` says: the base of the default.
pub const default_wait_secs: i64 = 600;
/// The longest `--timeout` may be: an hour, so a typo does not read as no limit.
pub const max_timeout_secs: u32 = 3600;
/// What each member adds to the default wait: validation and the chain take longer the more members a group has
/// (about 8 to 12 minutes at 170 members, 15 to 25 at 300).
pub const wait_per_member_secs: i64 = 5;

/// The default wait of a group of `members`: `default_wait_secs` plus `wait_per_member_secs` for each member.
pub fn defaultWaitFor(members: usize) i64 {
    return default_wait_secs + wait_per_member_secs * @as(i64, @intCast(members));
}
/// The most times one create is repeated while the registry answers `reserving`.
pub const max_reserving_rounds: usize = 50;
/// The registry signs upload URLs for 300 seconds. A URL older than this is not used: the run asks for fresh ones first.
pub const url_refresh_secs: i64 = 240;

pub const Flags = struct {
    staged: []const u8,
    registry: []const u8,
    config_dir: ?[]const u8 = null,
    /// `--wait`; null means the default of the group's size (`defaultWaitFor`).
    wait_secs: ?i64 = null,
    /// The connect limit and the longest a read or write waits for the server, per request.
    timeout_secs: u32 = http.default_timeout_secs,
    /// Repeats of a request that can be repeated, after its first try.
    retries: u8 = http.default_retries,
    dry_run: bool = false,
    /// `--oidc`: the registry token comes from the CI job's identity, not `$MOPM_TOKEN` or a login.
    oidc: bool = false,
    /// `--no-commit`: upload, then stop with the group open.
    no_commit: bool = false,
    /// `--abort`: end the open group `state.json` names; no file is read, uploaded or committed.
    abort: bool = false,
};

/// The command that waits for the group again: the flags of this run, without `--dry-run`.
pub fn rerunCommand(arena: Allocator, flags: Flags) Allocator.Error![]const u8 {
    var b = std.ArrayList(u8).init(arena);
    const w = b.writer();
    try w.writeAll("mopm publish --staged ");
    try shellWord(w, flags.staged);
    try w.writeAll(" --registry ");
    try shellWord(w, flags.registry);
    if (flags.config_dir) |c| {
        try w.writeAll(" --config-dir ");
        try shellWord(w, c);
    }
    if (flags.wait_secs) |s| try w.print(" --wait {d}", .{s});
    if (flags.oidc) try w.writeAll(" --oidc");
    return b.items;
}

/// `s` as one shell word: bare when it has only safe characters, else in single quotes.
fn shellWord(w: anytype, s: []const u8) !void {
    var safe = s.len > 0;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or std.mem.indexOfScalar(u8, "/._-:=@+,", c) != null)) safe = false;
    }
    if (safe) return w.writeAll(s);
    try w.writeByte('\'');
    for (s) |c| {
        if (c == '\'') try w.writeAll("'\\''") else try w.writeByte(c);
    }
    try w.writeByte('\'');
}

pub const Parsed = union(enum) { ok: Flags, bad: []const u8 };

/// Whether `args` of `mopm publish` are the staged form.
pub fn wants(args: []const []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, "--staged")) return true;
    }
    return false;
}

pub fn parseFlags(arena: Allocator, args: []const []const u8) Allocator.Error!Parsed {
    var staged: ?[]const u8 = null;
    var reg: ?[]const u8 = null;
    var f = Flags{ .staged = "", .registry = "" };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--dry-run")) {
            f.dry_run = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--oidc")) {
            f.oidc = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--no-commit")) {
            f.no_commit = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--abort")) {
            f.abort = true;
            continue;
        }
        const takes = std.mem.eql(u8, a, "--staged") or std.mem.eql(u8, a, "--registry") or std.mem.eql(u8, a, "--config-dir") or std.mem.eql(u8, a, "--wait") or std.mem.eql(u8, a, "--timeout") or std.mem.eql(u8, a, "--retries");
        if (!takes) {
            const why = if (std.mem.eql(u8, a, "--compiler") or std.mem.eql(u8, a, "--mojoc") or std.mem.eql(u8, a, "--manifest") or std.mem.eql(u8, a, "--native") or std.mem.eql(u8, a, "--readme"))
                try std.fmt.allocPrint(arena, "{s} packs one package; --staged publishes a staged set, which was packed already", .{a})
            else
                try std.fmt.allocPrint(arena, "unexpected argument '{s}'", .{a});
            return .{ .bad = why };
        }
        if (i + 1 >= args.len) return .{ .bad = try std.fmt.allocPrint(arena, "{s} needs a value", .{a}) };
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--staged")) {
            staged = v;
        } else if (std.mem.eql(u8, a, "--registry")) {
            reg = v;
        } else if (std.mem.eql(u8, a, "--config-dir")) {
            f.config_dir = v;
        } else if (std.mem.eql(u8, a, "--timeout")) {
            f.timeout_secs = std.fmt.parseInt(u32, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--timeout {s}: a number of seconds", .{v}) };
            if (f.timeout_secs == 0 or f.timeout_secs > max_timeout_secs) return .{ .bad = try std.fmt.allocPrint(arena, "--timeout is 1 to {d} seconds", .{max_timeout_secs}) };
        } else if (std.mem.eql(u8, a, "--retries")) {
            f.retries = std.fmt.parseInt(u8, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--retries {s}: a number from 0 to {d}", .{ v, http.max_retries }) };
            if (f.retries > http.max_retries) return .{ .bad = try std.fmt.allocPrint(arena, "--retries is 0 to {d}", .{http.max_retries}) };
        } else {
            const n = std.fmt.parseInt(i64, v, 10) catch return .{ .bad = try std.fmt.allocPrint(arena, "--wait {s}: a number of seconds", .{v}) };
            if (n < 0) return .{ .bad = "--wait is not negative" };
            f.wait_secs = n;
        }
    }
    f.staged = staged orelse return .{ .bad = "--staged <dir> is required" };
    f.registry = reg orelse return .{ .bad = "--registry is required with --staged: there is no default, so a staged set is never published to a registry by accident" };
    if (f.abort and f.no_commit) return .{ .bad = "--abort ends a group and --no-commit stages one: give one of them" };
    if (f.abort and f.dry_run) return .{ .bad = "--abort cannot be a --dry-run: it sends one request and has nothing to preview" };
    return .{ .ok = f };
}

// ---------------------------------------------------------------- the network

/// What the run needs of the world, so its tests need no socket: requests, time and sleeping.
pub const Net = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    /// The time limit of every request and how often an idempotent one is repeated (`--timeout`, `--retries`).
    policy: http.Policy = .{},

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer,
        sleep: *const fn (ptr: *anyopaque, secs: u64) void,
        now: *const fn (ptr: *anyopaque) i64,
    };

    /// One request, repeated by the policy when it is idempotent and fails in a way a second try can cure.
    fn request(n: Net, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        return http.retrying(arena, n, method, url, options, n.policy);
    }
    /// One try, as `http.retrying` asks for it.
    pub fn once(n: Net, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
        return n.vtable.request(n.ptr, arena, method, url, options);
    }
    /// The wait between tries, as `http.retrying` asks for it.
    pub fn pause(n: Net, secs: u64) void {
        n.sleep(secs);
    }
    fn sleep(n: Net, secs: u64) void {
        n.vtable.sleep(n.ptr, secs);
    }
    pub fn now(n: Net) i64 {
        return n.vtable.now(n.ptr);
    }
};

var real_marker: u8 = 0;
const real_vtable = Net.VTable{ .request = realRequest, .sleep = realSleep, .now = realNow };

pub fn realNet() Net {
    return .{ .ptr = &real_marker, .vtable = &real_vtable };
}

fn realRequest(_: *anyopaque, arena: Allocator, method: std.http.Method, url: []const u8, options: http.Options) anyerror!http.Answer {
    return http.request(arena, method, url, options);
}

fn realSleep(_: *anyopaque, secs: u64) void {
    std.time.sleep(secs * std.time.ns_per_s);
}

fn realNow(_: *anyopaque) i64 {
    return std.time.timestamp();
}

// ----------------------------------------------------------------- the console

/// What the run says. Each line is held until `flush`, which hands both streams to the sink; with no sink (the tests) the
/// text stays in `out` and `err` to be read.
pub const Console = struct {
    out: std.ArrayList(u8),
    err: std.ArrayList(u8),
    sink: ?*const fn (out: []const u8, err: []const u8) void,

    pub fn init(arena: Allocator, sink: ?*const fn (out: []const u8, err: []const u8) void) Console {
        return .{ .out = std.ArrayList(u8).init(arena), .err = std.ArrayList(u8).init(arena), .sink = sink };
    }

    /// The sink of the real commands: standard output and standard error.
    pub fn stdStreams(out: []const u8, errs: []const u8) void {
        std.io.getStdOut().writeAll(out) catch {};
        std.io.getStdErr().writeAll(errs) catch {};
    }

    pub fn say(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.out.writer().print(fmt, args) catch {};
        c.flush();
    }

    pub fn fail(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.err.writer().print("mopm: " ++ fmt, args) catch {};
        c.flush();
    }

    /// A line that goes on from the last `fail`: indented, with no `mopm:`.
    pub fn note(c: *Console, comptime fmt: []const u8, args: anytype) void {
        c.err.writer().print("  " ++ fmt, args) catch {};
        c.flush();
    }

    fn flush(c: *Console) void {
        const sink = c.sink orelse return;
        sink(c.out.items, c.err.items);
        c.out.clearRetainingCapacity();
        c.err.clearRetainingCapacity();
    }
};

/// `staged`: `--no-commit` stopped with the group open and every file held. `aborted`: `--abort` ended the group, or found
/// it already ended. `nothing_to_abort`: `--abort` found no group recorded in state.json. All three end 0.
pub const Result = enum { published, staged, aborted, nothing_to_abort, failed, rate_limited, no_group_publish, timed_out };

const Stop = error{ Failed, RateLimited, NoGroupPublish, TimedOut, Staged, OutOfMemory };

const FileAnswer = struct {
    subdir: []const u8,
    filename: []const u8,
    upload_id: []const u8 = "",
    uploaded: bool = false,
    put_url: ?[]const u8 = null,
    put_headers: ?std.json.Value = null,
};
const MemberAnswer = struct { name: []const u8, version: []const u8, action: []const u8 = "", files: []const FileAnswer = &.{} };
const CreateAnswer = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u32 = 1,
    reserving: ?struct { done: u32 = 0, total: u32 = 0 } = null,
    members: []const MemberAnswer = &.{},
};
pub const Failure = struct { code: []const u8, message: []const u8 = "", member: ?[]const u8 = null };
const GroupAnswer = struct { group_id: []const u8 = "", status: []const u8, failure: ?Failure = null };

/// The statuses of a group that ended without being published.
const ended_statuses = [_][]const u8{ "rejected", "failed", "expired", "aborted", "superseded" };

pub fn isGroupId(s: []const u8) bool {
    if (s.len != 36 or !std.mem.startsWith(u8, s, "grp_")) return false;
    return isHex32(s[4..]);
}

fn isHex32(s: []const u8) bool {
    if (s.len != 32) return false;
    for (s) |c| {
        if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    }
    return true;
}

pub const Publisher = struct {
    arena: Allocator,
    net: Net,
    console: *Console,
    dir: std.fs.Dir,
    plan: plan_mod.Plan,
    /// The registry's API root, without a trailing slash (`http://127.0.0.1:1234/api/v1`).
    api_url: []const u8,
    token: []const u8,
    wait_secs: i64,
    /// `--no-commit`: stop after the uploads, with the group open.
    no_commit: bool = false,
    /// The command that waits for this group again, named when the wait runs out.
    rerun: []const u8 = "the same command",
    state: plan_mod.State,
    group_status: ?[]const u8 = null,
    /// When the registry last signed the upload URLs in hand (`net.now()` at the create that returned them).
    urls_signed_at: i64 = 0,
    failure: ?Failure = null,
    /// The group `--abort` ended (state.json no longer names it), for the report.
    reported_group: []const u8 = "",
    /// Seconds the registry asked the client to wait, when it answered 429.
    retry_after: ?u32 = null,
    /// Where the bytes of one file are held while it is uploaded; freed after each file.
    scratch: Allocator = std.heap.page_allocator,

    fn call(p: *Publisher, method: std.http.Method, path: []const u8, body: ?[]const u8) Stop!http.Answer {
        const url = try std.fmt.allocPrint(p.arena, "{s}{s}", .{ p.api_url, path });
        return p.net.request(p.arena, method, url, .{ .token = p.token, .body = body }) catch |e| {
            p.console.fail("{s} {s}: {s}\n", .{ @tagName(method), path, @errorName(e) });
            return error.Failed;
        };
    }

    /// An answer that is not a success: printed, and the run stops. A 429 is a stop of its own.
    fn refuse(p: *Publisher, a: http.Answer) Stop {
        if (a.status == 429) {
            p.retry_after = a.retry_after;
            p.console.fail("the registry is rate limiting this client (HTTP 429); nothing more was sent{s}\n", .{p.retryText(a.retry_after)});
            p.console.note("rerun the same command later to resume (state: {s})\n", .{plan_mod.state_name});
            return error.RateLimited;
        }
        const text = http.describe(p.arena, a) catch return error.OutOfMemory;
        p.console.fail("{s}", .{text});
        return error.Failed;
    }

    fn retryText(p: *Publisher, retry: ?u32) []const u8 {
        const secs = retry orelse return "";
        return std.fmt.allocPrint(p.arena, "; retry after {d} seconds", .{secs}) catch "";
    }

    fn save(p: *Publisher) Stop!void {
        plan_mod.saveState(p.arena, p.dir, p.state) catch |e| {
            p.console.fail("cannot write {s}: {s}\n", .{ plan_mod.state_name, @errorName(e) });
            return error.Failed;
        };
    }

    fn createBody(p: *Publisher) Stop![]const u8 {
        var out = std.ArrayList(u8).init(p.arena);
        const w = out.writer();
        try w.writeAll("{\"members\":[");
        var first = true;
        for (p.plan.members) |m| {
            if (m.action != .upload) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try std.json.encodeJsonString(m.name, .{}, w);
            try w.writeAll(",\"version\":");
            try std.json.encodeJsonString(m.version, .{}, w);
            try w.writeAll(",\"files\":[");
            for (m.files, 0..) |f, i| {
                if (i != 0) try w.writeByte(',');
                try w.writeAll("{\"subdir\":");
                try std.json.encodeJsonString(f.subdir, .{}, w);
                try w.writeAll(",\"filename\":");
                try std.json.encodeJsonString(f.filename, .{}, w);
                try w.print(",\"sha256\":\"{s}\",\"size\":{d}}}", .{ f.sha256, f.size });
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
        return out.items;
    }

    fn commitBody(p: *Publisher) Stop![]const u8 {
        var out = std.ArrayList(u8).init(p.arena);
        const w = out.writer();
        try w.writeAll("{\"members\":[");
        var first = true;
        for (p.plan.members) |m| {
            if (m.action != .upload) continue;
            if (!first) try w.writeByte(',');
            first = false;
            try w.writeAll("{\"name\":");
            try std.json.encodeJsonString(m.name, .{}, w);
            try w.print(",\"manifest_sha256\":\"{s}\"", .{m.manifest_sha256});
            if (m.readme) |path| {
                const text = p.dir.readFileAlloc(p.arena, path, plan_mod.max_readme_bytes + 1) catch |e| {
                    p.console.fail("the readme {s} of {s}: {s}\n", .{ path, m.name, @errorName(e) });
                    return error.Failed;
                };
                try w.writeAll(",\"readme\":");
                try std.json.encodeJsonString(text, .{}, w);
            }
            try w.writeByte('}');
        }
        try w.writeAll("]}");
        return out.items;
    }

    /// Asks for the group, repeating the request while the registry has reserved only some of the members.
    fn create(p: *Publisher) Stop!CreateAnswer {
        const body = try p.createBody();
        var round: usize = 0;
        while (round < max_reserving_rounds) : (round += 1) {
            const a = try p.call(.POST, "/groups", body);
            if (a.status == 404) {
                const e = try http.apiError(p.arena, a);
                if (e.code.len == 0 or std.mem.eql(u8, e.code, "route_not_found")) {
                    p.console.fail("the registry at {s} has no group publish (POST /groups answered HTTP 404); nothing was uploaded\n", .{p.api_url});
                    return error.NoGroupPublish;
                }
            }
            if (!a.ok()) return p.refuse(a);
            const made = std.json.parseFromSliceLeaky(CreateAnswer, p.arena, a.body, .{ .ignore_unknown_fields = true }) catch {
                p.console.fail("the registry's answer to POST /groups is not one this mopm reads\n", .{});
                return error.Failed;
            };
            if (!isGroupId(made.group_id)) {
                p.console.fail("the registry named a group id that is not one: {s}\n", .{made.group_id});
                return error.Failed;
            }
            if (made.reserving == null) {
                p.urls_signed_at = p.net.now();
                return made;
            }
            p.console.say("reserving: {d} of {d} members\n", .{ made.reserving.?.done, made.reserving.?.total });
        }
        p.console.fail("the registry is still reserving the members after {d} requests\n", .{max_reserving_rounds});
        return error.Failed;
    }

    fn findMember(answer: CreateAnswer, name: []const u8, version: []const u8) ?MemberAnswer {
        for (answer.members) |m| {
            if (std.mem.eql(u8, m.name, name) and std.mem.eql(u8, m.version, version)) return m;
        }
        return null;
    }

    fn findFile(m: MemberAnswer, f: plan_mod.File) ?FileAnswer {
        for (m.files) |x| {
            if (std.mem.eql(u8, x.subdir, f.subdir) and std.mem.eql(u8, x.filename, f.filename)) return x;
        }
        return null;
    }

    fn hasUploaded(p: *Publisher, key: []const u8) bool {
        for (p.state.uploaded) |u| {
            if (std.mem.eql(u8, u, key)) return true;
        }
        return false;
    }

    fn markUploaded(p: *Publisher, key: []const u8) Stop!void {
        if (p.hasUploaded(key)) return;
        const list = try p.arena.alloc([]const u8, p.state.uploaded.len + 1);
        @memcpy(list[0..p.state.uploaded.len], p.state.uploaded);
        list[p.state.uploaded.len] = key;
        p.state.uploaded = list;
        try p.save();
    }

    /// PUTs every file the registry does not hold, member by member in the plan's order.
    fn upload(p: *Publisher, first: CreateAnswer) Stop!void {
        var answer = first;
        var held: usize = 0;
        for (p.plan.members) |m| {
            if (m.action != .upload) continue;
            for (m.files) |f| {
                const key = try std.fmt.allocPrint(p.arena, "{s}/{s}/{s}", .{ m.name, f.subdir, f.filename });
                // The URLs expire; a long run asks for fresh ones before the old ones are about to lapse.
                if (p.net.now() - p.urls_signed_at >= url_refresh_secs) answer = try p.refresh(answer);
                var af = try p.answerFor(answer, m, f);
                if (af.uploaded) {
                    held += 1;
                    try p.markUploaded(key);
                    continue;
                }
                // A storage refusal (HTTP 403) is how an expired URL answers: ask for fresh URLs and try once more.
                if (!try p.put(m, f, af, true)) {
                    answer = try p.refresh(answer);
                    af = try p.answerFor(answer, m, f);
                    if (af.uploaded) {
                        held += 1;
                        try p.markUploaded(key);
                        continue;
                    }
                    _ = try p.put(m, f, af, false);
                }
                try p.markUploaded(key);
            }
        }
        if (held > 0) p.console.say("{d} file(s) were already in the registry's storage\n", .{held});
    }

    fn answerFor(p: *Publisher, answer: CreateAnswer, m: plan_mod.Member, f: plan_mod.File) Stop!FileAnswer {
        const am = findMember(answer, m.name, m.version) orelse {
            p.console.fail("the registry's answer has no reservation for {s} {s}\n", .{ m.name, m.version });
            return error.Failed;
        };
        return findFile(am, f) orelse {
            p.console.fail("the registry's answer has no upload for {s}/{s} of {s}\n", .{ f.subdir, f.filename, m.name });
            return error.Failed;
        };
    }

    /// Asks again for the same group: for a group still open the registry writes nothing, signs the URLs anew and
    /// reports the files it already holds as uploaded.
    fn refresh(p: *Publisher, old: CreateAnswer) Stop!CreateAnswer {
        const made = try p.create();
        if (!std.mem.eql(u8, made.group_id, old.group_id) or !std.mem.eql(u8, made.status, "open")) {
            p.console.fail("asking for fresh upload URLs of group {s}, the registry answered group {s} in the state '{s}'; run the same command again to resume\n", .{ old.group_id, made.group_id, made.status });
            return error.Failed;
        }
        return made;
    }

    /// PUTs one file. With `may_retry`, a 403 is not a failure but a `false`: the caller refreshes the URLs and tries again.
    fn put(p: *Publisher, m: plan_mod.Member, f: plan_mod.File, af: FileAnswer, may_retry: bool) Stop!bool {
        const url = af.put_url orelse {
            p.console.fail("the registry gave no upload URL for {s} of {s}\n", .{ f.filename, m.name });
            return error.Failed;
        };
        if (!registry.allowedUrl(url)) {
            p.console.fail("the registry named an upload URL that is neither https nor loopback http\n", .{});
            return error.Failed;
        }
        const headers = (publish_cmd.putHeaders(p.arena, af.put_headers) catch return error.OutOfMemory) orelse return error.Failed;
        // The file's bytes, the request and its answer live only for this PUT: one file at a time is held, not the whole set.
        var each = std.heap.ArenaAllocator.init(p.scratch);
        defer each.deinit();
        const scratch = each.allocator();
        const bytes = switch (try plan_mod.readChecked(scratch, p.dir, f)) {
            .bytes => |b| b,
            .bad => |why| {
                p.console.fail("{s}; nothing more was uploaded\n", .{why});
                return error.Failed;
            },
        };
        // No bearer token: the URL is presigned.
        const r = p.net.request(scratch, .PUT, url, .{ .body = bytes, .content_type = null, .extra_headers = headers }) catch |e| {
            p.console.fail("uploading {s} failed: {s}; run the same command again to resume group {s}\n", .{ f.filename, @errorName(e), p.state.group_id });
            return error.Failed;
        };
        if (r.status == 429) return p.refuse(r);
        if (r.status == 403 and may_retry) return false;
        if (!r.ok()) {
            p.console.fail("uploading {s} failed: the storage answered HTTP {d}; run the same command again to resume group {s}\n", .{ f.filename, r.status, p.state.group_id });
            return error.Failed;
        }
        p.console.say("uploaded {s} ({s}) of {s}\n", .{ f.filename, f.subdir, m.name });
        return true;
    }

    fn commit(p: *Publisher) Stop!void {
        const path = try std.fmt.allocPrint(p.arena, "/groups/{s}/commit", .{p.state.group_id});
        const a = try p.call(.POST, path, try p.commitBody());
        if (!a.ok()) return p.refuse(a);
        p.state.committed = true;
        p.state.staged = false;
        try p.save();
        p.console.say("committed group {s}\n", .{p.state.group_id});
    }

    /// A group an earlier `--no-commit` run staged: its state is read before anything is created, because a create would
    /// open an ended group again as the next attempt, and a caller who staged a group, tested it and comes back to commit
    /// it must hear that it ended, not find a different one committed. Only an `open` group (or one past open, which this
    /// run then waits for, or refuses under `--no-commit`) goes on.
    fn checkStaged(p: *Publisher) Stop!void {
        const path = try std.fmt.allocPrint(p.arena, "/groups/{s}", .{p.state.group_id});
        const a = try p.call(.GET, path, null);
        if (a.status == 404) {
            p.console.fail("group {s}, staged by an earlier run (see {s}), is not known to the registry; nothing was sent\n", .{ p.state.group_id, plan_mod.state_name });
            p.console.note("remove {s} and stage the set again\n", .{plan_mod.state_name});
            return error.Failed;
        }
        if (!a.ok()) return p.refuse(a);
        const g = std.json.parseFromSliceLeaky(GroupAnswer, p.arena, a.body, .{ .ignore_unknown_fields = true }) catch {
            p.console.fail("the registry's answer to GET {s} is not one this mopm reads\n", .{path});
            return error.Failed;
        };
        p.group_status = g.status;
        for (ended_statuses) |e| {
            if (!std.mem.eql(u8, g.status, e)) continue;
            p.console.fail("group {s}, staged by an earlier run, is {s}: it can no longer be committed; nothing was sent\n", .{ p.state.group_id, g.status });
            p.console.note("the files tested locally are unchanged: remove {s} and stage the set again to get a new group\n", .{plan_mod.state_name});
            return error.Failed;
        }
    }

    /// Ends the group state.json names. Idempotent for a group that already ended without being published; refused, with the
    /// reason, for one that was committed.
    fn abortGroup(p: *Publisher) Stop!Result {
        if (p.state.group_id.len == 0) {
            p.console.say("{s} names no group: nothing to abort\n", .{plan_mod.state_name});
            return .nothing_to_abort;
        }
        const path = try std.fmt.allocPrint(p.arena, "/groups/{s}", .{p.state.group_id});
        const a = try p.call(.DELETE, path, null);
        var gone = false;
        if (a.ok()) {
            p.group_status = "aborted";
        } else if (a.status == 409) {
            // Not open: read what it is. An ended group holds nothing; a committed one is not this command's to stop.
            const g = try p.call(.GET, path, null);
            if (!g.ok()) return p.refuse(g);
            const now = std.json.parseFromSliceLeaky(GroupAnswer, p.arena, g.body, .{ .ignore_unknown_fields = true }) catch {
                p.console.fail("the registry's answer to GET {s} is not one this mopm reads\n", .{path});
                return error.Failed;
            };
            p.group_status = now.status;
            var ended = false;
            for (ended_statuses) |e| {
                if (std.mem.eql(u8, now.status, e)) ended = true;
            }
            if (!ended) {
                p.console.fail("group {s} is {s}: it was committed, so it cannot be aborted; if it becomes visible, 'mopm yank --group {s}' takes it back\n", .{ p.state.group_id, now.status, p.state.group_id });
                return error.Failed;
            }
            p.console.say("group {s} is already {s}: nothing is held\n", .{ p.state.group_id, now.status });
        } else if (a.status == 404) {
            // The registry does not know the group (swept, or never created): nothing is left to abort.
            p.group_status = "unknown";
            gone = true;
        } else return p.refuse(a);
        p.reported_group = p.state.group_id;
        p.state.group_id = "";
        p.state.attempt = 0;
        p.state.committed = false;
        p.state.staged = false;
        p.state.uploaded = &.{};
        try p.save();
        if (gone) {
            p.console.say("the registry no longer has group {s}: nothing to abort; {s} no longer names it\n", .{ p.reported_group, plan_mod.state_name });
        } else p.console.say("aborted group {s}: its place is free and none of its members was published\n", .{p.reported_group});
        return .aborted;
    }

    /// Polls the group until it is visible. A group that ended without being visible is a failure, and says why.
    fn wait(p: *Publisher) Stop!void {
        const path = try std.fmt.allocPrint(p.arena, "/groups/{s}", .{p.state.group_id});
        const deadline = p.net.now() + p.wait_secs;
        while (true) {
            const a = try p.call(.GET, path, null);
            if (!a.ok()) return p.refuse(a);
            const g = std.json.parseFromSliceLeaky(GroupAnswer, p.arena, a.body, .{ .ignore_unknown_fields = true }) catch {
                p.console.fail("the registry's answer to GET {s} is not one this mopm reads\n", .{path});
                return error.Failed;
            };
            p.group_status = g.status;
            if (std.mem.eql(u8, g.status, "visible")) return;
            for (ended_statuses) |e| {
                if (!std.mem.eql(u8, g.status, e)) continue;
                p.failure = g.failure;
                if (g.failure) |f| {
                    if (f.member) |m| {
                        p.console.fail("group {s} is {s}: {s}: {s} (member {s})\n", .{ p.state.group_id, g.status, f.code, f.message, m });
                    } else {
                        p.console.fail("group {s} is {s}: {s}: {s}\n", .{ p.state.group_id, g.status, f.code, f.message });
                    }
                } else {
                    p.console.fail("group {s} is {s}\n", .{ p.state.group_id, g.status });
                }
                p.console.note("none of its members is published\n", .{});
                return error.Failed;
            }
            if (p.net.now() >= deadline) {
                p.console.fail("gave up waiting after {d} seconds: group {s} is {s} and still in progress, not failed; it may yet become visible\n", .{ p.wait_secs, p.state.group_id, g.status });
                p.console.note("to keep waiting (nothing is sent again), run: {s}\n", .{p.rerun});
                return error.TimedOut;
            }
            p.net.sleep(1);
        }
    }

    fn execute(p: *Publisher) Stop!void {
        // The state file is written before the first request, so a directory that cannot be written is found while nothing is held.
        try p.save();
        if (p.state.staged and p.state.group_id.len > 0) try p.checkStaged();
        const made = try p.create();
        if (p.state.group_id.len > 0 and !std.mem.eql(u8, p.state.group_id, made.group_id)) {
            p.console.fail("{s} names group {s}, but the registry answered {s} for this plan; remove {s} to start again\n", .{ plan_mod.state_name, p.state.group_id, made.group_id, plan_mod.state_name });
            return error.Failed;
        }
        p.state.group_id = made.group_id;
        p.state.attempt = made.attempt;
        p.group_status = made.status;
        try p.save();
        const members = try p.plan.uploads(p.arena);
        var files: usize = 0;
        for (members) |m| files += m.files.len;
        p.console.say("group {s} (attempt {d}): {d} members, {d} files, status {s}\n", .{ made.group_id, made.attempt, members.len, files, made.status });
        if (p.no_commit and !std.mem.eql(u8, made.status, "open")) {
            p.console.fail("group {s} is {s}, not open: --no-commit stages a group before its commit, and this one has been committed or ended\n", .{ made.group_id, made.status });
            return error.Failed;
        }
        if (std.mem.eql(u8, made.status, "open")) {
            try p.upload(made);
            if (p.no_commit) {
                p.state.staged = true;
                try p.save();
                return error.Staged;
            }
            try p.commit();
        } else if (std.mem.eql(u8, made.status, "validating") or std.mem.eql(u8, made.status, "committed") or std.mem.eql(u8, made.status, "visible")) {
            // The registry has the whole group: there is nothing to upload and nothing to commit again.
            p.state.committed = true;
            p.state.staged = false;
            try p.save();
        } else {
            p.console.fail("the registry opened the group in the state '{s}', which this mopm does not know how to continue\n", .{made.status});
            return error.Failed;
        }
        try p.wait();
    }

    /// Runs the publish. The result says how it ended; `failure` and `group_status` say more.
    pub fn run(p: *Publisher) Result {
        p.execute() catch |e| return switch (e) {
            error.RateLimited => .rate_limited,
            error.NoGroupPublish => .no_group_publish,
            error.TimedOut => .timed_out,
            error.Staged => .staged,
            error.Failed, error.OutOfMemory => .failed,
        };
        return .published;
    }

    /// Runs `--abort`: ends the group state.json names. The result says how it ended.
    pub fn abort(p: *Publisher) Result {
        return p.abortGroup() catch |e| switch (e) {
            error.RateLimited => .rate_limited,
            else => .failed,
        };
    }

    fn outcomeName(r: Result) []const u8 {
        return @tagName(r);
    }

    /// Writes report.json and says how it ended; the exit code.
    pub fn finish(p: *Publisher, result: Result) u8 {
        const run_id = plan_mod.newRunId(p.arena) catch "0000000000000000";
        var members = std.ArrayList(plan_mod.MemberReport).init(p.arena);
        for (p.plan.members) |m| {
            var outcome: []const u8 = undefined;
            var code: ?[]const u8 = null;
            switch (m.action) {
                .skip => {
                    outcome = "skipped";
                    code = if (m.reason.len > 0) m.reason else "skipped by the plan";
                },
                .refuse => {
                    outcome = "not_published";
                    code = if (m.reason.len > 0) m.reason else "refused by the plan";
                },
                .upload => {
                    if (result == .published) {
                        outcome = "published";
                    } else if (result == .staged) {
                        outcome = "staged";
                    } else if (result == .aborted or result == .nothing_to_abort) {
                        outcome = "not_published";
                    } else if (p.failure != null and p.failure.?.member != null and std.mem.eql(u8, p.failure.?.member.?, m.name)) {
                        outcome = "rejected";
                        code = p.failure.?.code;
                    } else if (result == .no_group_publish or p.failure != null) {
                        outcome = "not_published";
                    } else {
                        outcome = "pending";
                    }
                },
            }
            var files = std.ArrayList(plan_mod.FileReport).init(p.arena);
            if (m.action == .upload) {
                for (m.files) |f| files.append(.{ .subdir = f.subdir, .filename = f.filename, .sha256 = f.sha256 }) catch {};
            }
            members.append(.{ .name = m.name, .version = m.version, .outcome = outcome, .code = code, .files = files.items }) catch {};
        }
        const report = plan_mod.Report{
            .run_id = run_id,
            .registry = p.api_url,
            .group_id = if (p.state.group_id.len > 0) p.state.group_id else if (p.reported_group.len > 0) p.reported_group else null,
            .group_status = p.group_status,
            .outcome = outcomeName(result),
            .plan_sha256 = p.plan.sha256,
            .members = members.items,
        };
        plan_mod.saveReport(p.arena, p.dir, report) catch |e| p.console.fail("cannot write {s}: {s}\n", .{ plan_mod.report_name, @errorName(e) });
        if (result == .staged) {
            var files: usize = 0;
            for (p.plan.members) |m| {
                if (m.action == .upload) files += m.files.len;
            }
            p.console.say("staged group {s}: open, {d} file(s) held, not committed, nothing readable\nplan sha256 {s}\n", .{ p.state.group_id, files, p.plan.sha256 });
            p.console.say("to commit it (same directory, a token of the same actor): {s}\nto end it: {s} --abort\n", .{ p.rerun, p.rerun });
            return 0;
        }
        if (result == .aborted or result == .nothing_to_abort) return 0;
        if (result == .published) {
            p.console.say("published group {s}:", .{p.state.group_id});
            for (p.plan.members) |m| {
                if (m.action == .upload) p.console.say(" {s} {s}", .{ m.name, m.version });
            }
            p.console.say("\n", .{});
            for (p.plan.members) |m| {
                if (m.action == .skip) p.console.say("skipped {s} {s}: {s}\n", .{ m.name, m.version, if (m.reason.len > 0) m.reason else "skipped by the plan" });
            }
            return 0;
        }
        return 1;
    }
};

// ------------------------------------------------------------- the command

fn err(comptime fmt: []const u8, args: anytype) void {
    std.io.getStdErr().writer().print("mopm: " ++ fmt, args) catch {};
}

/// `mopm publish --staged ...`.
pub fn main(arena: Allocator, args: []const []const u8, cli_version: []const u8) u8 {
    const flags = switch (parseFlags(arena, args) catch return 1) {
        .ok => |f| f,
        .bad => |why| {
            err("{s}\n", .{why});
            std.io.getStdErr().writeAll(usage) catch {};
            return 2;
        },
    };
    return command(arena, flags, cli_version, realNet()) catch |e| {
        err("{s}\n", .{@errorName(e)});
        return 1;
    };
}

/// The time limit and the retries `flags` ask for.
pub fn policyOf(flags: Flags) http.Policy {
    return .{ .timeout_secs = flags.timeout_secs, .retries = flags.retries };
}

fn command(arena: Allocator, flags: Flags, cli_version: []const u8, base_net: Net) anyerror!u8 {
    var net = base_net;
    net.policy = policyOf(flags);
    var dir = std.fs.cwd().openDir(flags.staged, .{ .iterate = false }) catch |e| {
        err("{s}: {s}\n", .{ flags.staged, @errorName(e) });
        return 1;
    };
    defer dir.close();
    const text = dir.readFileAlloc(arena, plan_mod.plan_name, 1 << 26) catch |e| {
        err("{s}/{s}: {s}\n", .{ flags.staged, plan_mod.plan_name, @errorName(e) });
        return 1;
    };
    const plan = switch (try plan_mod.parsePlan(arena, text)) {
        .ok => |p| p,
        .bad => |why| {
            err("{s}\n", .{why});
            return 1;
        },
    };
    var console = Console.init(arena, Console.stdStreams);
    if (flags.abort) return abortCommand(arena, flags, cli_version, net, dir, plan, &console);
    if (plan_mod.refusedMember(plan)) |m| {
        err("the plan refuses {s} {s}{s}{s}; nothing was sent\n", .{ m.name, m.version, if (m.reason.len > 0) ": " else "", m.reason });
        return 1;
    }
    if (try plan_mod.verify(arena, dir, plan)) |why| {
        err("{s}; nothing was sent\n", .{why});
        return 1;
    }
    const uploads = try plan.uploads(arena);
    if (flags.dry_run) return dryRun(flags, plan, uploads, &console);
    if (uploads.len == 0) {
        console.say("nothing to publish: every member of the plan is skipped\n", .{});
        var idle = Publisher{ .arena = arena, .net = net, .console = &console, .dir = dir, .plan = plan, .api_url = flags.registry, .token = "", .wait_secs = 0, .state = .{ .registry = flags.registry, .plan_sha256 = plan.sha256 } };
        // No request is made, so no registry is resolved: the report names the registry as it was given.
        const code = idle.finish(.published);
        return code;
    }

    const creds = (try credentials(arena, net, flags, cli_version, uploads)) orelse return 1;
    const loaded = (try loadStateFor(arena, dir, creds.api_url, plan.sha256, &console, "resuming")) orelse return 1;

    var p = Publisher{
        .arena = arena,
        .net = net,
        .console = &console,
        .dir = dir,
        .plan = plan,
        .api_url = creds.api_url,
        .token = creds.token,
        .wait_secs = flags.wait_secs orelse defaultWaitFor(uploads.len),
        .no_commit = flags.no_commit,
        .rerun = try rerunCommand(arena, flags),
        .state = loaded.state,
    };
    const result = p.run();
    return p.finish(result);
}

const Credentials = struct { api_url: []const u8, token: []const u8 };

/// The registry's API root and the token of this run (`--oidc`, `$MOPM_TOKEN` or the login's), or null after saying why not.
fn credentials(arena: Allocator, net: Net, flags: Flags, cli_version: []const u8, uploads: []const plan_mod.Member) anyerror!?Credentials {
    // --oidc outside a job that can ask for an identity: stop before any request.
    const actions = if (flags.oidc) (ci_oidc.actionsFromEnv(arena) orelse {
        err("{s}\n", .{ci_oidc.outside_actions});
        return null;
    }) else null;
    const s = registry_cmd.open(arena, .{ .registry = flags.registry, .config_dir = flags.config_dir }, cli_version) orelse return null;
    const token = if (actions) |act| switch (try oidcToken(arena, net, act, s.config.api_url, s.config.stage, uploads)) {
        .ok => |t| t,
        .bad => |why| {
            err("{s}\n", .{why});
            return null;
        },
    } else (try publish_cmd.findToken(s)) orelse {
        err("not logged in to {s}; run 'mopm login' or set MOPM_TOKEN\n", .{s.config.stage});
        return null;
    };
    return .{ .api_url = s.config.api_url, .token = token };
}

const LoadedFor = struct { state: plan_mod.State, found: bool };

/// state.json of this directory for this registry and plan: a fresh state when there is none, the old one when it
/// belongs to both, and null (after saying why) when it is another registry's, another plan's or not a state file.
fn loadStateFor(arena: Allocator, dir: std.fs.Dir, api_url: []const u8, plan_sha256: []const u8, console: *Console, verb: []const u8) anyerror!?LoadedFor {
    var state = plan_mod.State{ .registry = api_url, .plan_sha256 = plan_sha256 };
    switch (try plan_mod.loadState(arena, dir)) {
        .none => return .{ .state = state, .found = false },
        .bad => |why| {
            err("{s}\n", .{why});
            return null;
        },
        .ok => |old| {
            if (!std.mem.eql(u8, old.registry, state.registry)) {
                err("{s} belongs to the registry {s}, not {s}; remove it to publish this set there\n", .{ plan_mod.state_name, old.registry, state.registry });
                return null;
            }
            if (!std.mem.eql(u8, old.plan_sha256, state.plan_sha256)) {
                err("{s} belongs to another plan (the staged set changed since the run that wrote it); remove it to start a new group\n", .{plan_mod.state_name});
                return null;
            }
            state = old;
            console.say("{s} group {s} from {s}\n", .{ verb, if (old.group_id.len > 0) old.group_id else "(none yet)", plan_mod.state_name });
            return .{ .state = state, .found = true };
        },
    }
}

/// `--abort`: the plan is read (for the packages an `--oidc` exchange names and the digest state.json is checked against) but
/// no file of the set is: the job that ends a group need not hold the bytes.
fn abortCommand(arena: Allocator, flags: Flags, cli_version: []const u8, net: Net, dir: std.fs.Dir, plan: plan_mod.Plan, console: *Console) anyerror!u8 {
    const uploads = try plan.uploads(arena);
    const creds = (try credentials(arena, net, flags, cli_version, uploads)) orelse return 1;
    const loaded = (try loadStateFor(arena, dir, creds.api_url, plan.sha256, console, "aborting")) orelse return 1;
    if (!loaded.found) {
        err("{s} has no {s}: this is not a directory that was staged (or it is another job's); nothing was sent\n", .{ flags.staged, plan_mod.state_name });
        return 1;
    }
    var p = Publisher{
        .arena = arena,
        .net = net,
        .console = console,
        .dir = dir,
        .plan = plan,
        .api_url = creds.api_url,
        .token = creds.token,
        .wait_secs = 0,
        .state = loaded.state,
    };
    const result = p.abort();
    return p.finish(result);
}

/// The registry token of `--oidc` for a staged set: one identity token, one exchange of the `packages` form naming every
/// member to upload at its version (the plan's), and that one token for the group's create, uploads, commit and waits.
/// A set of one member uses the same form, so a group has one path. The token stays in memory: it is returned to the
/// caller and goes nowhere else.
pub fn oidcToken(arena: Allocator, net: Net, act: ci_oidc.Actions, api_url: []const u8, stage: []const u8, uploads: []const plan_mod.Member) anyerror!ci_oidc.Result {
    const packages = try arena.alloc(ci_oidc.Package, uploads.len);
    for (uploads, packages) |m, *p| p.* = .{ .name = m.name, .version = m.version };
    return ci_oidc.obtainPackages(arena, net, net.policy, act, api_url, stage, packages);
}

fn dryRun(flags: Flags, plan: plan_mod.Plan, uploads: []const plan_mod.Member, console: *Console) anyerror!u8 {
    switch (registry.resolve(flags.registry)) {
        .ok => {},
        .bad => |why| {
            err("--registry {s}: {s}\n", .{ flags.registry, why });
            return 1;
        },
    }
    var files: usize = 0;
    for (uploads) |m| files += m.files.len;
    console.say("would create one group of {d} members ({d} files), in this order:\n", .{ uploads.len, files });
    for (uploads) |m| console.say("  {s} {s} ({d} files)\n", .{ m.name, m.version, m.files.len });
    for (plan.members) |m| {
        if (m.action == .skip) console.say("would skip {s} {s}: {s}\n", .{ m.name, m.version, if (m.reason.len > 0) m.reason else "skipped by the plan" });
    }
    if (flags.no_commit) {
        console.say("would upload each file the registry does not hold, and stop with the group open (--no-commit)\ndry run: nothing was sent\n", .{});
    } else {
        console.say("would upload each file the registry does not hold, commit the group, and wait for it to be visible\ndry run: nothing was sent\n", .{});
    }
    return 0;
}
