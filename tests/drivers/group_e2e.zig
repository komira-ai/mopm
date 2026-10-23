//! The authenticated end-to-end check of group publishing, run against a deployed stage (beta or gamma) by the
//! `group-e2e` job of .github/workflows/e2e.yml after that stage's deploy, or by hand with workflow_dispatch.
//!
//!     mopm-group-e2e --stage beta|gamma [--registry <name|url>] --mopm <exe> --work <dir> --run-id <n> --attempt <n>
//!                    [--summary <file>] [--wait-seconds <n>]
//!
//! The token is the environment variable MOPM_E2E_TOKEN (the job maps the repository secret MOPM_E2E_GROUP_TOKEN to
//! it on this one step); it is never passed to a child process and never printed. Each stage keeps its own tokens, so the
//! one secret holds either a single token or a token for each stage, `beta=<token>` and `gamma=<token>` on lines of their
//! own (tokenFor): a stage with no entry skips.
//!
//! What it publishes. The e2e account owns a fixed set of throwaway packages (zz_e2e_core, zz_e2e_mid, zz_e2e_app;
//! the package name pattern has no hyphen, so the namespace is spelled zz_e2e_*), and the token lists exactly those. A
//! version is never deleted, so every run uses numbers no run has used: MAJOR is the case, MINOR the run id of the
//! workflow run and PATCH its attempt.
//!
//!   1  the switch      A group is created for a version nobody ever commits (the expiry probe). If the registry answers
//!                      `route_not_found` the stage's groups switch is off for this actor and the run SKIPs. The probe
//!                      is the one expiry check a run can make: a deadline is hours away, so the probe group stays
//!                      open, and the first run after its deadline finds it ended and opened again (attempt 2 or
//!                      more). It also pins the deadline to between 30 minutes and 19 hours after the call.
//!   2  the chain       zz_e2e_core <- zz_e2e_mid <- zz_e2e_app, real packages made by `mopm pack`'s writer, created,
//!                      uploaded and committed as one group. While the group is open or validating no member is
//!                      readable (a read of all three, with the group still before its commit on both sides of
//!                      it, shows none). Once it is `visible`, every member's version, the sparse index, the channel's
//!                      repodata and `mopm add` of the top package agree with the bytes that were uploaded, and
//!                      the lock holds the whole chain with the sha256 of each file; each locked file is downloaded
//!                      and hashed.
//!   3  a rejected member   a group of two where one archive is not a package: it ends `rejected`, names that
//!                      member, and neither member is ever readable, in the API, the index or the channel.
//!   4  yank and unyank the chain group is yanked as a whole, then restored: the API and the index follow each time.
//!
//! The pure parts (the version numbers, the dependency ranges, the time arithmetic, the environment of a child) are
//! unit tests below; tests/drivers/group_e2e_test.zig runs the whole walk against a loopback registry that serves the
//! group routes, and with each way the registry could go wrong.

const std = @import("std");
const core = @import("mopm_core");
const h = @import("harness.zig");
const http = core.http;
const conda = core.conda;
const registry = core.registry;
const lock = core.lock;
const semver = core.semver;
const Allocator = std.mem.Allocator;

/// The environment variable that carries the token into this program.
pub const token_env = "MOPM_E2E_TOKEN";
/// The repository secret the job maps to it (named in the SKIP line).
pub const secret_name = "MOPM_E2E_GROUP_TOKEN";

pub const pkg_core = "zz_e2e_core";
pub const pkg_mid = "zz_e2e_mid";
pub const pkg_app = "zz_e2e_app";
/// The Mojo version every package is built for.
pub const compiler = "1.0.0";
/// The subdir every package is published for: the platform of the runner that resolves them (ubuntu-24.04, x86_64).
pub const subdir = "linux-64";
/// The version of the expiry probe: never uploaded, never committed, so never burned.
pub const probe_version = "0.0.1";

pub const Case = enum(u8) { chain = 1, rejected = 2 };

/// MAJOR is the case, MINOR the workflow run id, PATCH the run attempt.
pub fn versionOf(arena: Allocator, case: Case, run_id: u64, attempt: u64) ![]u8 {
    return std.fmt.allocPrint(arena, "{d}.{d}.{d}", .{ @intFromEnum(case), run_id, attempt });
}

/// What a package asks of the one it depends on: that version or a newer one of the same major.
pub fn rangeFrom(arena: Allocator, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(arena, ">={s},<2", .{version});
}

/// The seconds since the epoch of `2026-10-22T12:34:56Z` (a fraction of a second is ignored), or null.
pub fn epochOf(s: []const u8) ?i64 {
    if (s.len < 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[s.len - 1] != 'Z') return null;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const m = std.fmt.parseInt(i64, s[5..7], 10) catch return null;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return null;
    const hh = std.fmt.parseInt(i64, s[11..13], 10) catch return null;
    const mm = std.fmt.parseInt(i64, s[14..16], 10) catch return null;
    const ss = std.fmt.parseInt(i64, s[17..19], 10) catch return null;
    if (m < 1 or m > 12 or d < 1 or d > 31 or hh > 23 or mm > 59 or ss > 60) return null;
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const mp = @mod(m + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

/// The environment a child process (`mopm`) gets: the path and a home inside the work directory, and nothing else.
/// In particular not the token.
pub fn childEnv(a: Allocator, parent: *const std.process.EnvMap, home: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    if (parent.get("PATH")) |p| try env.put("PATH", p);
    try env.put("HOME", home);
    return env;
}

/// The path of a package in the sparse index (spec/index.md): the first two characters, the next two, then the name.
pub fn indexPath(arena: Allocator, name: []const u8) ![]u8 {
    var pad: [4]u8 = .{ '_', '_', '_', '_' };
    @memcpy(pad[0..@min(name.len, 4)], name[0..@min(name.len, 4)]);
    return std.fmt.allocPrint(arena, "index/{s}/{s}/{s}", .{ pad[0..2], pad[2..4], name });
}

const token_separators = " \t\r\n,";

/// The token for `stage` in the value of MOPM_E2E_TOKEN. Each stage keeps its own tokens, and the job has one repository secret,
/// so the value is either one token (taken for any stage) or entries `<stage>=<token>` separated by white space or commas,
/// one for beta and one for gamma, added as each stage's switch is turned on. Empty when there is none for the stage.
pub fn tokenFor(bundle: []const u8, stage: []const u8) []const u8 {
    const all = std.mem.trim(u8, bundle, token_separators);
    if (std.mem.indexOfScalar(u8, all, '=') == null) return all;
    var it = std.mem.tokenizeAny(u8, all, token_separators);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        if (std.mem.eql(u8, entry[0..eq], stage)) return entry[eq + 1 ..];
    }
    return "";
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var d: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &d, .{});
    return std.fmt.bytesToHex(d, .lower);
}

// ---- what is sent and what comes back -------------------------------------------------------------------------------

const FileDecl = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
const MemberDecl = struct { name: []const u8, version: []const u8, files: []const FileDecl };
const CreateBody = struct { members: []const MemberDecl };
const CommitMember = struct { name: []const u8, manifest_sha256: []const u8 };
const CommitBody = struct { members: []const CommitMember };

const UploadFile = struct {
    subdir: []const u8 = "",
    filename: []const u8 = "",
    upload_id: []const u8 = "",
    uploaded: bool = false,
    put_url: ?[]const u8 = null,
    put_headers: ?std.json.Value = null,
};
const MemberAnswer = struct { name: []const u8, version: []const u8, action: []const u8 = "", files: []const UploadFile = &.{} };
const Reserving = struct { done: u64 = 0, total: u64 = 0 };
const Created = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u64,
    deadline_at: []const u8 = "",
    reserving: ?Reserving = null,
    members: []const MemberAnswer = &.{},
};
const Failure = struct { code: []const u8 = "", message: []const u8 = "", member: ?[]const u8 = null };
const YankInfo = struct { state: []const u8 = "", yanked_members: u64 = 0 };
const GroupMember = struct { name: []const u8, version: []const u8, state: []const u8 = "" };
const Group = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u64 = 0,
    created_at: []const u8 = "",
    deadline_at: []const u8 = "",
    committed_at: ?[]const u8 = null,
    failure: ?Failure = null,
    member_count: u64 = 0,
    yank: ?YankInfo = null,
    members: []const GroupMember = &.{},
};
const FileRef = struct { subdir: []const u8 = "", filename: []const u8 = "", sha256: []const u8 = "", size: u64 = 0 };
const DepRef = struct { name: []const u8, range: ?[]const u8 = null };
const VersionDetail = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    state: []const u8 = "",
    yank_reason: ?[]const u8 = null,
    manifest_sha256: []const u8 = "",
    deps: []const DepRef = &.{},
    files: []const FileRef = &.{},
};
const IndexLine = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    state: []const u8 = "",
    deps: []const DepRef = &.{},
    files: []const FileRef = &.{},
};
const Health = struct { stage: []const u8 = "", status: []const u8 = "" };
const ErrorBody = struct { @"error": struct { code: []const u8 = "", message: []const u8 = "" } = .{} };
const RepoEntry = struct { sha256: []const u8 = "", size: u64 = 0, version: []const u8 = "" };
const Repodata = struct { @"packages.conda": std.json.ArrayHashMap(RepoEntry) = .{} };

fn parse(comptime T: type, a: Allocator, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, a, body, .{ .ignore_unknown_fields = true }) catch null;
}

fn errorCode(a: Allocator, body: []const u8) []const u8 {
    const e = parse(ErrorBody, a, body) orelse return "";
    return e.@"error".code;
}

fn excerpt(s: []const u8) []const u8 {
    return s[0..@min(s.len, 300)];
}

// ---- the package files ----------------------------------------------------------------------------------------------

const Pkg = struct {
    name: []const u8,
    version: []const u8,
    file_name: []const u8,
    bytes: []const u8,
    sha256: []const u8,
    manifest_sha256: []const u8,
    /// The version a dependency of this package asks for, "" for none.
    dep: []const u8 = "",
};

fn mojocOf(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "e2e mojoc {s} {s}\n", .{ name, version });
}

/// A package as `mopm pack` writes it, depending on `dep_name` at `dep_version` or newer ("" for none).
pub fn buildPkg(a: Allocator, name: []const u8, version: []const u8, dep_name: []const u8, dep_version: []const u8) !Pkg {
    var deps = std.ArrayList(conda.Dep).init(a);
    if (dep_name.len > 0) try deps.append(.{ .name = dep_name, .range = try rangeFrom(a, dep_version) });
    const p = try conda.pack(a, .{
        .name = name,
        .version = version,
        .compiler = compiler,
        .subdir = subdir,
        .deps = deps.items,
        .mojoc = try mojocOf(a, name, version),
    });
    return .{
        .name = name,
        .version = version,
        .file_name = p.file_name,
        .bytes = p.bytes,
        .sha256 = try a.dupe(u8, &p.sha256),
        .manifest_sha256 = try a.dupe(u8, &p.manifest_sha256),
        .dep = dep_version,
    };
}

/// The right file name with bytes that are not an archive: the registry must refuse it.
pub fn badPkg(a: Allocator, name: []const u8, version: []const u8) !Pkg {
    const bytes = try std.fmt.allocPrint(a, "this is not a conda package: {s} {s}\n", .{ name, version });
    return .{
        .name = name,
        .version = version,
        .file_name = try std.fmt.allocPrint(a, "mojo-{s}-{s}-mojo{s}_0.conda", .{ name, version, compiler }),
        .bytes = bytes,
        .sha256 = try a.dupe(u8, &sha256Hex(bytes)),
        .manifest_sha256 = try a.dupe(u8, &sha256Hex(name)),
    };
}

// ---- the run --------------------------------------------------------------------------------------------------------

pub const Opts = struct {
    /// The registry's base URL, without a trailing slash (https://api.beta.mopm.dev).
    base: []const u8,
    stage: []const u8,
    /// The value of MOPM_E2E_TOKEN: one token, or a token for each stage (`tokenFor` says how). Empty: the secret is not set, and
    /// the run SKIPs.
    token: []const u8,
    mopm: ?[]const u8 = null,
    work: []const u8,
    run_id: u64,
    attempt: u64,
    /// A file to append the summary to (the job's $GITHUB_STEP_SUMMARY).
    summary: ?[]const u8 = null,
    /// How long a group may take to reach each state.
    wait_ms: u64 = 10 * 60 * 1000,
    poll_ms: u64 = 3000,
    /// Where a transport error or a 429 waits before the call is made again.
    retry_ms: u64 = 2000,
    /// The environment of this process, for the PATH a child gets.
    parent_env: ?*const std.process.EnvMap = null,
};

pub const Result = struct {
    skipped: bool,
    /// The one line the run ends with: PASS, FAIL or SKIP, the stage and why.
    line: []const u8,
    checks: usize,
    failures: usize,
    /// One line per check (`- ok   <name>` or `- FAIL <name>: <detail>`), in the order they ran.
    notes: []const []const u8 = &.{},
};

const Cx = struct {
    a: Allocator,
    rep: *h.Report,
    o: Opts,
    checks: usize = 0,
    notes: std.ArrayList([]const u8),
    /// The bearer token of this stage.
    token: []const u8 = "",
    /// A step the rest cannot go on without failed.
    stop: bool = false,

    fn check(self: *Cx, name: []const u8, ok: bool, detail: []const u8) void {
        self.checks += 1;
        self.rep.check(name, ok, detail);
        const line = std.fmt.allocPrint(self.a, "- {s} {s}{s}{s}\n", .{ if (ok) "ok  " else "FAIL", name, if (ok or detail.len == 0) "" else ": ", if (ok) "" else excerpt(detail) }) catch return;
        self.notes.append(line) catch {};
    }

    fn fail(self: *Cx, name: []const u8, detail: []const u8) void {
        self.check(name, false, detail);
        self.stop = true;
    }

    fn url(self: *Cx, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.a, "{s}/api/v1{s}", .{ self.o.base, path });
    }

    /// One call, with a pause and another try on a transport error, and on a 429.
    fn send(self: *Cx, method: std.http.Method, full_url: []const u8, body: ?[]const u8, auth: bool) !http.Answer {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            const ans = http.request(self.a, method, full_url, .{ .token = if (auth) self.token else null, .body = body }) catch |e| {
                if (tries >= 3) return e;
                std.time.sleep(self.o.retry_ms * std.time.ns_per_ms);
                continue;
            };
            if (ans.status == 429 and tries < 3) {
                // The registry says how long to wait (at most a minute); never less than the pause of a transport error.
                const wait_ms = @max(self.o.retry_ms, @min(@as(u64, ans.retry_after orelse 0) * 1000, 60_000));
                std.time.sleep(wait_ms * std.time.ns_per_ms);
                continue;
            }
            return ans;
        }
    }

    fn api(self: *Cx, method: std.http.Method, path: []const u8, body: ?[]const u8) !http.Answer {
        return self.send(method, try self.url(path), body, true);
    }

    fn getGroup(self: *Cx, id: []const u8) !?Group {
        const ans = try self.api(.GET, try std.fmt.allocPrint(self.a, "/groups/{s}", .{id}), null);
        if (ans.status != 200) return null;
        return parse(Group, self.a, ans.body);
    }

    /// The state of one version in the API: null when the registry does not show it (404), else its record.
    fn getVersion(self: *Cx, name: []const u8, version: []const u8) !?VersionDetail {
        const ans = try self.send(.GET, try self.url(try std.fmt.allocPrint(self.a, "/packages/{s}/{s}", .{ name, version })), null, false);
        if (ans.status == 404) return null;
        if (ans.status != 200) return error.UnexpectedStatus;
        return parse(VersionDetail, self.a, ans.body) orelse error.BadJson;
    }

    /// How many of `pkgs` the API shows right now.
    fn shown(self: *Cx, pkgs: []const Pkg) !usize {
        var n: usize = 0;
        for (pkgs) |p| {
            if (try self.getVersion(p.name, p.version) != null) n += 1;
        }
        return n;
    }

    /// The lines of a package's sparse-index file; null when there is no file.
    fn indexLines(self: *Cx, name: []const u8) !?[]const IndexLine {
        const ans = try self.send(.GET, try std.fmt.allocPrint(self.a, "{s}/{s}", .{ self.o.base, try indexPath(self.a, name) }), null, false);
        if (ans.status == 404) return null;
        if (ans.status != 200) return error.UnexpectedStatus;
        var out = std.ArrayList(IndexLine).init(self.a);
        var it = std.mem.splitScalar(u8, ans.body, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            try out.append(parse(IndexLine, self.a, line) orelse return error.BadJson);
        }
        return out.items;
    }

    fn indexLineOf(self: *Cx, name: []const u8, version: []const u8) !?IndexLine {
        const lines = (try self.indexLines(name)) orelse return null;
        for (lines) |l| {
            if (std.mem.eql(u8, l.version, version)) return l;
        }
        return null;
    }
};

fn groupBody(a: Allocator, pkgs: []const Pkg) ![]u8 {
    const members = try a.alloc(MemberDecl, pkgs.len);
    for (pkgs, members) |p, *m| {
        const files = try a.alloc(FileDecl, 1);
        files[0] = .{ .subdir = subdir, .filename = p.file_name, .sha256 = p.sha256, .size = p.bytes.len };
        m.* = .{ .name = p.name, .version = p.version, .files = files };
    }
    return std.json.stringifyAlloc(a, CreateBody{ .members = members }, .{});
}

fn commitBody(a: Allocator, pkgs: []const Pkg) ![]u8 {
    const members = try a.alloc(CommitMember, pkgs.len);
    for (pkgs, members) |p, *m| m.* = .{ .name = p.name, .manifest_sha256 = p.manifest_sha256 };
    return std.json.stringifyAlloc(a, CommitBody{ .members = members }, .{});
}

fn validGroupId(id: []const u8) bool {
    if (id.len != 36 or !std.mem.startsWith(u8, id, "grp_")) return false;
    for (id[4..]) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f'))) return false;
    }
    return true;
}

fn isOneOf(s: []const u8, set: []const []const u8) bool {
    for (set) |x| {
        if (std.mem.eql(u8, s, x)) return true;
    }
    return false;
}

const pre_commit = [_][]const u8{ "open", "validating" };
const ended = [_][]const u8{ "rejected", "failed", "expired", "aborted", "superseded" };

/// Create a group (again, while it says it has not reached every member) and return the answer that holds every member.
fn createGroup(cx: *Cx, label: []const u8, pkgs: []const Pkg) !?struct { ans: http.Answer, created: Created, first_status: u16 } {
    const body = try groupBody(cx.a, pkgs);
    var rounds: u32 = 0;
    // The first call is the one that makes the group (201); the calls after it only ask whether it has reached every member.
    var first_status: ?u16 = null;
    while (rounds < 20) : (rounds += 1) {
        const ans = try cx.api(.POST, "/groups", body);
        if (ans.status != 201 and ans.status != 200) {
            cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the group is created", .{label}), try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ ans.status, excerpt(ans.body) }));
            return null;
        }
        const created = parse(Created, cx.a, ans.body) orelse {
            cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the create answer is a group", .{label}), ans.body);
            return null;
        };
        if (first_status == null) first_status = ans.status;
        if (created.reserving == null) return .{ .ans = ans, .created = created, .first_status = first_status orelse ans.status };
    }
    cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the registry reserved every member", .{label}), "still reserving after 20 calls");
    return null;
}

/// PUT every file the registry has not got yet, with the headers it named, exactly.
fn uploadAll(cx: *Cx, label: []const u8, created: Created, pkgs: []const Pkg) !bool {
    var ok = created.members.len == pkgs.len;
    for (created.members) |m| {
        const p = for (pkgs) |q| {
            if (std.mem.eql(u8, q.name, m.name)) break q;
        } else {
            ok = false;
            continue;
        };
        for (m.files) |f| {
            if (f.uploaded) continue;
            const put_url = f.put_url orelse {
                ok = false;
                continue;
            };
            var headers = std.ArrayList(std.http.Header).init(cx.a);
            if (f.put_headers) |ph| switch (ph) {
                .object => |obj| {
                    var it = obj.iterator();
                    while (it.next()) |e| {
                        if (std.ascii.eqlIgnoreCase(e.key_ptr.*, "content-length")) continue;
                        if (e.value_ptr.* == .string) try headers.append(.{ .name = e.key_ptr.*, .value = e.value_ptr.string });
                    }
                },
                else => {},
            };
            // The URL is presigned: no bearer token goes to the storage.
            const put = http.request(cx.a, .PUT, put_url, .{ .body = p.bytes, .content_type = null, .extra_headers = headers.items }) catch |e| {
                cx.check(try std.fmt.allocPrint(cx.a, "{s}: {s} is uploaded", .{ label, p.name }), false, @errorName(e));
                ok = false;
                continue;
            };
            if (!put.ok()) {
                cx.check(try std.fmt.allocPrint(cx.a, "{s}: {s} is uploaded", .{ label, p.name }), false, try std.fmt.allocPrint(cx.a, "the storage answered HTTP {d}", .{put.status}));
                ok = false;
            }
        }
    }
    return ok;
}

const Waited = struct { group: Group, timed_out: bool };

/// Poll a group until its status is one of `until`, or it ended, or `wait_ms` is over. While the group is before its
/// commit, on both sides of a read of every member, no member may be readable.
fn waitGroup(cx: *Cx, label: []const u8, id: []const u8, pkgs: []const Pkg, until: []const []const u8) !Waited {
    const start = std.time.milliTimestamp();
    var reported = false;
    while (true) {
        const g1 = (try cx.getGroup(id)) orelse {
            cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the group can be read", .{label}), "GET /groups/{id} did not answer 200");
            return error.GroupUnreadable;
        };
        if (isOneOf(g1.status, until) or isOneOf(g1.status, &ended)) return .{ .group = g1, .timed_out = false };
        if (isOneOf(g1.status, &pre_commit)) {
            const n = try cx.shown(pkgs);
            const g2 = (try cx.getGroup(id)) orelse g1;
            if (n > 0 and isOneOf(g2.status, &pre_commit) and !reported) {
                reported = true;
                cx.check(try std.fmt.allocPrint(cx.a, "{s}: no member is readable before the commit", .{label}), false, "a member was readable while the group was still before its commit");
            }
        }
        if (std.time.milliTimestamp() - start > @as(i64, @intCast(cx.o.wait_ms))) return .{ .group = g1, .timed_out = true };
        std.time.sleep(cx.o.poll_ms * std.time.ns_per_ms);
    }
}

/// Run `f` until it returns true or `wait_ms` is over; the last answer's text is the reason.
fn eventually(cx: *Cx, comptime Ctx: type, ctx: Ctx, comptime f: fn (*Cx, Ctx, *[]const u8) anyerror!bool, why: *[]const u8) !bool {
    const start = std.time.milliTimestamp();
    while (true) {
        if (f(cx, ctx, why)) |ok| {
            if (ok) return true;
        } else |e| {
            why.* = @errorName(e);
        }
        if (std.time.milliTimestamp() - start > @as(i64, @intCast(cx.o.wait_ms))) return false;
        std.time.sleep(cx.o.poll_ms * std.time.ns_per_ms);
    }
}

// ---- the steps ------------------------------------------------------------------------------------------------------

/// Step 1. False when the stage's groups switch is off for this actor.
fn probeStep(cx: *Cx) !bool {
    const bytes = "expiry probe: this group is never uploaded or committed\n";
    const probe = Pkg{
        .name = pkg_core,
        .version = probe_version,
        .file_name = try std.fmt.allocPrint(cx.a, "mojo-{s}-{s}-mojo{s}_0.conda", .{ pkg_core, probe_version, compiler }),
        .bytes = bytes,
        .sha256 = try cx.a.dupe(u8, &sha256Hex(bytes)),
        .manifest_sha256 = "",
    };
    const body = try groupBody(cx.a, &.{probe});
    const now = std.time.timestamp();
    const ans = try cx.api(.POST, "/groups", body);
    if (ans.status == 404 and std.mem.eql(u8, errorCode(cx.a, ans.body), "route_not_found")) return false;
    if (ans.status != 201 and ans.status != 200) {
        cx.fail("the switch: the e2e actor may create groups", try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ ans.status, excerpt(ans.body) }));
        return true;
    }
    const created = parse(Created, cx.a, ans.body) orelse {
        cx.fail("the switch: the create answer is a group", ans.body);
        return true;
    };
    cx.check("the switch: the group id has the contract's shape", validGroupId(created.group_id), created.group_id);
    cx.check("the probe group is open", std.mem.eql(u8, created.status, "open"), created.status);
    if (epochOf(created.deadline_at)) |deadline| {
        const ahead = deadline - now;
        cx.check("the probe group's deadline is between 30 minutes and 19 hours away", ahead >= 30 * 60 and ahead <= 19 * 3600, try std.fmt.allocPrint(cx.a, "{d} seconds ahead ({s})", .{ ahead, created.deadline_at }));
    } else {
        cx.check("the probe group's deadline is a timestamp", false, created.deadline_at);
    }
    if (ans.status == 201 and created.attempt > 1) {
        cx.check("expiry: a probe group left open by an earlier run ended at its deadline and was opened again", true, "");
    } else if (ans.status == 201) {
        cx.check("expiry: the probe group is open; the first run after its deadline will find it ended", true, "");
    } else {
        cx.check("expiry: the probe group is still open from an earlier run; the first run after its deadline will find it ended", true, "");
    }
    if (try cx.getGroup(created.group_id)) |g| {
        cx.check("the probe group reads back as the same open group", std.mem.eql(u8, g.group_id, created.group_id) and std.mem.eql(u8, g.status, "open") and g.attempt == created.attempt, g.status);
    } else {
        cx.check("the probe group reads back as the same open group", false, "GET /groups/{id} did not answer 200");
    }
    return true;
}

const Chain = struct { id: []const u8, pkgs: []const Pkg };

/// Step 2. The chain group, committed and visible; null when it did not get that far.
fn chainStep(cx: *Cx) !?Chain {
    const ver = try versionOf(cx.a, .chain, cx.o.run_id, cx.o.attempt);
    const pkgs = [_]Pkg{
        try buildPkg(cx.a, pkg_core, ver, "", ""),
        try buildPkg(cx.a, pkg_mid, ver, pkg_core, ver),
        try buildPkg(cx.a, pkg_app, ver, pkg_mid, ver),
    };
    const L = "chain";
    const made = (try createGroup(cx, L, &pkgs)) orelse return null;
    cx.check("chain: the group is created open", made.first_status == 201 and std.mem.eql(u8, made.created.status, "open") and made.created.attempt == 1, made.created.status);
    var all_new = made.created.members.len == 3;
    for (made.created.members) |m| {
        if (!std.mem.eql(u8, m.action, "new")) all_new = false;
    }
    cx.check("chain: every member's number is new", all_new, "a member was not `new`");
    const id = made.created.group_id;
    errdefer abort(cx, id);
    if (!try uploadAll(cx, L, made.created, &pkgs)) {
        cx.stop = true;
        abort(cx, id);
        return null;
    }
    cx.check("chain: nothing is readable once the files are uploaded", (try cx.shown(&pkgs)) == 0, "a member is readable before the commit");
    const commit = try cx.api(.POST, try std.fmt.allocPrint(cx.a, "/groups/{s}/commit", .{id}), try commitBody(cx.a, &pkgs));
    cx.check("chain: the commit is accepted", commit.status == 202, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ commit.status, excerpt(commit.body) }));
    if (commit.status != 202) {
        cx.stop = true;
        abort(cx, id);
        return null;
    }

    const first = try waitGroup(cx, L, id, &pkgs, &.{ "committed", "visible" });
    if (first.timed_out or !isOneOf(first.group.status, &.{ "committed", "visible" })) {
        cx.fail("chain: the group commits", try std.fmt.allocPrint(cx.a, "status {s}{s}", .{ first.group.status, if (first.timed_out) " (timed out)" else "" }));
        return null;
    }
    // The API shows a committed group's members at once, all of them.
    const live = try cx.shown(&pkgs);
    cx.check("chain: once committed, all three members are readable at once", live == 3, try std.fmt.allocPrint(cx.a, "{d} of 3", .{live}));
    const done = try waitGroup(cx, L, id, &pkgs, &.{"visible"});
    cx.check("chain: the group becomes visible", std.mem.eql(u8, done.group.status, "visible"), try std.fmt.allocPrint(cx.a, "status {s}{s}", .{ done.group.status, if (done.timed_out) " (timed out)" else "" }));
    if (!std.mem.eql(u8, done.group.status, "visible")) {
        cx.stop = true;
        return null;
    }
    cx.check("chain: the group names its three members", done.group.member_count == 3 and done.group.members.len == 3, "member_count");
    var all_pub = true;
    for (done.group.members) |m| {
        if (!std.mem.eql(u8, m.state, "published")) all_pub = false;
    }
    cx.check("chain: every member is published", all_pub, "a member is not published");
    try readBack(cx, L, &pkgs, "published");
    return .{ .id = id, .pkgs = try cx.a.dupe(Pkg, &pkgs) };
}

fn abort(cx: *Cx, id: []const u8) void {
    const path = std.fmt.allocPrint(cx.a, "/groups/{s}", .{id}) catch return;
    _ = cx.api(.DELETE, path, null) catch return;
}

/// The API, the index and the channel agree with the bytes that were uploaded.
fn readBack(cx: *Cx, label: []const u8, pkgs: []const Pkg, state: []const u8) !void {
    for (pkgs) |p| {
        const name = try std.fmt.allocPrint(cx.a, "{s}: {s} in the API is {s} with the uploaded bytes", .{ label, p.name, state });
        const v = (try cx.getVersion(p.name, p.version)) orelse {
            cx.check(name, false, "404");
            continue;
        };
        const f_ok = v.files.len == 1 and std.mem.eql(u8, v.files[0].sha256, p.sha256) and v.files[0].size == p.bytes.len and std.mem.eql(u8, v.files[0].filename, p.file_name);
        const dep_ok = p.dep.len == 0 or v.deps.len == 1;
        cx.check(name, std.mem.eql(u8, v.state, state) and f_ok and dep_ok and std.mem.eql(u8, v.manifest_sha256, p.manifest_sha256), try std.fmt.allocPrint(cx.a, "state {s}, {d} files, manifest {s}", .{ v.state, v.files.len, v.manifest_sha256 }));
    }
    for (pkgs) |p| {
        var why: []const u8 = "not yet";
        const ok = try eventually(cx, PkgState, .{ .p = p, .state = state }, indexHas, &why);
        cx.check(try std.fmt.allocPrint(cx.a, "{s}: the sparse index lists {s} {s} as {s}, with its file and dependency", .{ label, p.name, p.version, state }), ok, why);
    }
}

const PkgState = struct { p: Pkg, state: []const u8 };

fn indexHas(cx: *Cx, ps: PkgState, why: *[]const u8) !bool {
    const line = (try cx.indexLineOf(ps.p.name, ps.p.version)) orelse {
        why.* = "no line for the version";
        return false;
    };
    if (!std.mem.eql(u8, line.state, ps.state)) {
        why.* = line.state;
        return false;
    }
    if (line.files.len != 1 or !std.mem.eql(u8, line.files[0].sha256, ps.p.sha256)) {
        why.* = "the file's sha256 differs";
        return false;
    }
    if (ps.p.dep.len > 0) {
        if (line.deps.len != 1) {
            why.* = "the dependency is missing";
            return false;
        }
        const want = try rangeFrom(cx.a, ps.p.dep);
        if (line.deps[0].range == null or !std.mem.eql(u8, line.deps[0].range.?, want)) {
            why.* = "the dependency's range differs";
            return false;
        }
    }
    return true;
}

/// The channel's repodata lists the file with the uploaded sha256, and the file itself hashes to it.
fn channelStep(cx: *Cx, label: []const u8, pkgs: []const Pkg) !void {
    const cfg = try registry.load(cx.a, cx.o.base, "0.0.1+dev");
    const config = switch (cfg) {
        .ok => |c| c,
        .bad => |why| {
            cx.check(try std.fmt.allocPrint(cx.a, "{s}: the registry's index config is readable", .{label}), false, why);
            return;
        },
    };
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: the index config names this stage", .{label}), std.mem.eql(u8, config.stage, cx.o.stage), config.stage);
    for (pkgs) |p| {
        const key = ChannelFile{ .channel = config.channel_url, .p = p };
        var why: []const u8 = "not yet";
        const ok = try eventually(cx, ChannelFile, key, channelHas, &why);
        cx.check(try std.fmt.allocPrint(cx.a, "{s}: the channel serves {s} with the uploaded sha256, in repodata and as a file", .{ label, p.file_name }), ok, why);
    }
}

const ChannelFile = struct { channel: []const u8, p: Pkg };

fn channelHas(cx: *Cx, cf: ChannelFile, why: *[]const u8) !bool {
    const repodata_url = try std.fmt.allocPrint(cx.a, "{s}{s}/repodata.json", .{ cf.channel, subdir });
    const rd = try cx.send(.GET, repodata_url, null, false);
    if (rd.status != 200) {
        why.* = "repodata.json is not served";
        return false;
    }
    const doc = parse(Repodata, cx.a, rd.body) orelse {
        why.* = "repodata.json is not repodata";
        return false;
    };
    const entry = doc.@"packages.conda".map.get(cf.p.file_name) orelse {
        why.* = "repodata.json does not list the file";
        return false;
    };
    if (!std.mem.eql(u8, entry.sha256, cf.p.sha256)) {
        why.* = "repodata.json lists another sha256";
        return false;
    }
    const file = try cx.send(.GET, try std.fmt.allocPrint(cx.a, "{s}{s}/{s}", .{ cf.channel, subdir, cf.p.file_name }), null, false);
    if (file.status != 200) {
        why.* = "the file is not served";
        return false;
    }
    if (!std.mem.eql(u8, &sha256Hex(file.body), cf.p.sha256)) {
        why.* = "the served file hashes to another sha256";
        return false;
    }
    return true;
}

/// `mopm add` of the top package resolves the whole chain from the index, and the lock pins what was uploaded.
fn lockStep(cx: *Cx, chain: Chain) !void {
    const mopm = cx.o.mopm orelse {
        cx.check("lock: --mopm names the CLI", false, "no --mopm");
        return;
    };
    const dir = try std.fs.path.join(cx.a, &.{ cx.o.work, "consumer" });
    const home = try std.fs.path.join(cx.a, &.{ cx.o.work, "home" });
    try std.fs.cwd().makePath(home);
    try std.fs.cwd().makePath(try std.fs.path.join(cx.a, &.{ dir, "src", "consumer" }));
    try h.writeFile(try std.fs.path.join(cx.a, &.{ dir, "mopm.toml" }), "[package]\nname = \"consumer\"\nversion = \"0.1.0\"\nmojo = [\"" ++ compiler ++ "\"]\n\n[dependencies]\n");
    try h.writeFile(try std.fs.path.join(cx.a, &.{ dir, "src", "consumer", "__init__.mojo" }), "def run():\n    pass\n");
    var parent = std.process.EnvMap.init(cx.a);
    if (cx.o.parent_env) |p| {
        if (p.get("PATH")) |v| try parent.put("PATH", v);
    }
    var env = try childEnv(cx.a, &parent, home);
    defer env.deinit();
    const app = chain.pkgs[2];
    const spec = try std.fmt.allocPrint(cx.a, "{s}@={s}", .{ app.name, app.version });
    const ran = try h.run(cx.a, &.{ mopm, "add", spec, "--registry", cx.o.base }, &env, .{ .cwd = dir });
    cx.check("lock: mopm add of the top package resolves", ran.code == 0, ran.text);
    if (ran.code != 0) return;
    const text = h.readFile(cx.a, try std.fs.path.join(cx.a, &.{ dir, "mopm.lock" })) catch {
        cx.check("lock: mopm add wrote a lock", false, "no mopm.lock");
        return;
    };
    var why: []const u8 = "";
    const parsed = lock.parse(cx.a, text, &why) catch {
        cx.check("lock: the lock is a lock", false, why);
        return;
    };
    // A lock may hold one build per Mojo version: the one this check built for.
    const l = try lock.forMojo(cx.a, parsed, compiler);
    for (chain.pkgs) |p| {
        var found: ?lock.Package = null;
        for (l.packages) |lp| {
            if (std.mem.eql(u8, lp.name, p.name)) found = lp;
        }
        const name = try std.fmt.allocPrint(cx.a, "lock: {s} is locked at the uploaded file", .{p.name});
        const lp = found orelse {
            cx.check(name, false, "not in the lock");
            continue;
        };
        const mine = std.mem.eql(u8, lp.version, p.version);
        // A later run may have published a newer 1.x of a dependency (the range allows it): then it is that run's file.
        const newer = !mine and isNewerSameMajor(lp.version, p.version);
        const sha_ok = if (mine) std.mem.eql(u8, lp.sha256, p.sha256) and lp.size == p.bytes.len else newer;
        cx.check(name, sha_ok and std.mem.eql(u8, lp.subdir, subdir), try std.fmt.allocPrint(cx.a, "version {s}, sha256 {s}", .{ lp.version, lp.sha256 }));
        // Installing downloads this URL and checks the sha256.
        const file = try cx.send(.GET, lp.url, null, false);
        cx.check(try std.fmt.allocPrint(cx.a, "lock: the file {s} pins downloads and hashes to the lock's sha256", .{p.name}), file.status == 200 and std.mem.eql(u8, &sha256Hex(file.body), lp.sha256), try std.fmt.allocPrint(cx.a, "HTTP {d}", .{file.status}));
    }
    var app_deps_mid = false;
    for (l.packages) |lp| {
        if (std.mem.eql(u8, lp.name, pkg_app)) {
            for (lp.deps) |d| {
                if (std.mem.eql(u8, d, pkg_mid)) app_deps_mid = true;
            }
        }
    }
    cx.check("lock: the top package's entry names the middle one as its dependency", app_deps_mid, "no dependency edge");
}

fn isNewerSameMajor(got: []const u8, want: []const u8) bool {
    const g = semver.parseVersion(got) orelse return false;
    const w = semver.parseVersion(want) orelse return false;
    return g.major == w.major and semver.compare(g, w) == .gt;
}

/// Step 3. A group where one member is not a package.
fn rejectedStep(cx: *Cx) !void {
    const ver = try versionOf(cx.a, .rejected, cx.o.run_id, cx.o.attempt);
    const pkgs = [_]Pkg{
        try buildPkg(cx.a, pkg_core, ver, "", ""),
        try badPkg(cx.a, pkg_mid, ver),
    };
    const L = "rejected";
    const made = (try createGroup(cx, L, &pkgs)) orelse return;
    const id = made.created.group_id;
    if (!try uploadAll(cx, L, made.created, &pkgs)) {
        cx.stop = true;
        abort(cx, id);
        return;
    }
    const commit = try cx.api(.POST, try std.fmt.allocPrint(cx.a, "/groups/{s}/commit", .{id}), try commitBody(cx.a, &pkgs));
    cx.check("rejected: the commit is accepted (the archive is read after it)", commit.status == 202, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ commit.status, excerpt(commit.body) }));
    if (commit.status != 202) {
        cx.stop = true;
        abort(cx, id);
        return;
    }
    const w = try waitGroup(cx, L, id, &pkgs, &.{ "committed", "visible" });
    cx.check("rejected: the group ends rejected", std.mem.eql(u8, w.group.status, "rejected"), try std.fmt.allocPrint(cx.a, "status {s}{s}", .{ w.group.status, if (w.timed_out) " (timed out)" else "" }));
    if (w.group.failure) |f| {
        cx.check("rejected: the failure names the member that is not a package", f.member != null and std.mem.eql(u8, f.member.?, pkg_mid) and f.code.len > 0, try std.fmt.allocPrint(cx.a, "code {s}, member {s}", .{ f.code, f.member orelse "(none)" }));
    } else {
        cx.check("rejected: the failure names the member that is not a package", false, "no failure on the group");
    }
    // The good sibling is as invisible as the bad one: in the API, the index and the channel.
    for (pkgs) |p| {
        const hidden = (try cx.getVersion(p.name, p.version)) == null;
        cx.check(try std.fmt.allocPrint(cx.a, "rejected: {s} is not readable in the API", .{p.name}), hidden, "the API shows the version");
        const line = try cx.indexLineOf(p.name, p.version);
        cx.check(try std.fmt.allocPrint(cx.a, "rejected: {s} is not in the sparse index", .{p.name}), line == null, "the index lists the version");
    }
    const cfg = try registry.load(cx.a, cx.o.base, "0.0.1+dev");
    switch (cfg) {
        .ok => |c| {
            const rd = try cx.send(.GET, try std.fmt.allocPrint(cx.a, "{s}{s}/repodata.json", .{ c.channel_url, subdir }), null, false);
            const listed = std.mem.indexOf(u8, rd.body, pkgs[0].file_name) != null;
            cx.check("rejected: the good sibling is not in the channel's repodata", rd.status == 200 and !listed, try std.fmt.allocPrint(cx.a, "HTTP {d}", .{rd.status}));
        },
        .bad => |why| cx.check("rejected: the registry's index config is readable", false, why),
    }
    // A group that ended is not open: the abort that follows is refused, and nothing is left holding a slot.
    const again = try cx.api(.DELETE, try std.fmt.allocPrint(cx.a, "/groups/{s}", .{id}), null);
    cx.check("rejected: an ended group cannot be aborted", again.status == 409, try std.fmt.allocPrint(cx.a, "HTTP {d}", .{again.status}));
}

fn yankState(cx: *Cx, id: []const u8, want: []const u8) !bool {
    const start = std.time.milliTimestamp();
    while (true) {
        if (try cx.getGroup(id)) |g| {
            if (g.yank != null and std.mem.eql(u8, g.yank.?.state, want)) return true;
        }
        if (std.time.milliTimestamp() - start > @as(i64, @intCast(cx.o.wait_ms))) return false;
        std.time.sleep(cx.o.poll_ms * std.time.ns_per_ms);
    }
}

/// Step 4. The chain group, yanked as a whole and restored.
fn yankStep(cx: *Cx, chain: Chain) !void {
    const path = try std.fmt.allocPrint(cx.a, "/groups/{s}/yank", .{chain.id});
    const yank = try cx.api(.PUT, path, "{\"yanked\":true,\"reason\":\"group end-to-end check\"}");
    cx.check("yank: the group yank is accepted", yank.status == 202 or yank.status == 200, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ yank.status, excerpt(yank.body) }));
    if (yank.status != 202 and yank.status != 200) return;
    cx.check("yank: the group reaches yanked", try yankState(cx, chain.id, "yanked"), "yank.state did not reach yanked");
    try readBack(cx, "yank", chain.pkgs, "yanked");
    const restore = try cx.api(.PUT, path, "{\"yanked\":false}");
    cx.check("unyank: the group unyank is accepted", restore.status == 202 or restore.status == 200, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ restore.status, excerpt(restore.body) }));
    if (restore.status != 202 and restore.status != 200) return;
    cx.check("unyank: the group reaches restored", try yankState(cx, chain.id, "restored"), "yank.state did not reach restored");
    try readBack(cx, "unyank", chain.pkgs, "published");
}

/// Everything, in order. The result says whether it ran and the one line it ends with.
pub fn run(a: Allocator, rep: *h.Report, o: Opts) !Result {
    var cx = Cx{ .a = a, .rep = rep, .o = o, .notes = std.ArrayList([]const u8).init(a) };
    if (std.mem.eql(u8, o.stage, "prod")) return skipped(a, o, "this check never runs on prod");
    if (std.mem.trim(u8, o.token, token_separators).len == 0) return skipped(a, o, "the repository secret " ++ secret_name ++ " is not set");
    cx.token = tokenFor(o.token, o.stage);
    if (cx.token.len == 0) {
        return skipped(a, o, try std.fmt.allocPrint(a, "the repository secret " ++ secret_name ++ " holds no token for {s}", .{o.stage}));
    }

    const before = rep.failures;
    // An error out of a step (the registry did not answer, an answer was not JSON) is a failed check, not a crash.
    const not_enabled = walk(&cx) catch |e| blk: {
        cx.check("the walk ends without an error", false, @errorName(e));
        break :blk false;
    };
    if (not_enabled) return skipped(a, o, "group publishing is not enabled for the e2e actor on this stage (creating a group answered route_not_found)");
    return finish(&cx, before);
}

/// A run that did nothing, and says so on one line, in the job summary too.
fn skipped(a: Allocator, o: Opts, why: []const u8) !Result {
    const line = try std.fmt.allocPrint(a, "group-e2e: SKIP {s}: {s}", .{ o.stage, why });
    if (o.summary) |path| try appendTo(path, try std.fmt.allocPrint(a, "{s}\n", .{line}));
    return .{ .skipped = true, .line = line, .checks = 0, .failures = 0 };
}

/// The four cases in order. True when the stage's groups switch is off for this actor (nothing was published).
fn walk(cx: *Cx) !bool {
    const health = try cx.send(.GET, try cx.url("/health"), null, false);
    const hb = if (health.status == 200) parse(Health, cx.a, health.body) else null;
    const same_stage = hb != null and std.mem.eql(u8, hb.?.stage, cx.o.stage);
    cx.check("health: the stage answers as the stage under test", same_stage, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ health.status, excerpt(health.body) }));
    if (!same_stage) return false;

    if (!try probeStep(cx)) return true;
    if (cx.stop) return false;

    const chain = try chainStep(cx);
    if (chain) |c| {
        try channelStep(cx, "chain", c.pkgs);
        try lockStep(cx, c);
    }
    cx.stop = false;
    try rejectedStep(cx);
    cx.stop = false;
    if (chain) |c| try yankStep(cx, c);
    return false;
}

fn finish(cx: *Cx, before: usize) !Result {
    const failures = cx.rep.failures - before;
    const line = if (failures == 0)
        try std.fmt.allocPrint(cx.a, "group-e2e: PASS {s}: {d} checks", .{ cx.o.stage, cx.checks })
    else
        try std.fmt.allocPrint(cx.a, "group-e2e: FAIL {s}: {d} of {d} checks failed", .{ cx.o.stage, failures, cx.checks });
    if (cx.o.summary) |path| {
        var all = std.ArrayList(u8).init(cx.a);
        try all.writer().print("### group end-to-end, {s}\n\n{s}\n\n", .{ cx.o.stage, line });
        for (cx.notes.items) |n| try all.appendSlice(n);
        try appendTo(path, all.items);
    }
    return .{ .skipped = false, .line = line, .checks = cx.checks, .failures = failures, .notes = cx.notes.items };
}

pub fn appendTo(path: []const u8, text: []const u8) !void {
    var f = try std.fs.cwd().createFile(path, .{ .truncate = false });
    defer f.close();
    try f.seekFromEnd(0);
    try f.writeAll(text);
}

// ---- the command line -----------------------------------------------------------------------------------------------

const usage = "usage: mopm-group-e2e --stage beta|gamma --mopm <exe> --work <dir> --run-id <n> --attempt <n> [--registry <name|url>] [--summary <file>] [--wait-seconds <n>]\n";

/// The command line, flag by flag; null when it is not one this program takes.
pub const Args = struct {
    stage: []const u8,
    /// `--registry`: a stage name or a URL; the stage's own registry when absent.
    registry_spec: ?[]const u8 = null,
    mopm: ?[]const u8 = null,
    work: []const u8,
    run_id: u64,
    attempt: u64,
    summary: ?[]const u8 = null,
    wait_seconds: u64 = 600,
};

pub fn parseArgs(argv: []const []const u8) ?Args {
    var stage: ?[]const u8 = null;
    var out = Args{ .stage = "", .work = "", .run_id = 0, .attempt = 0 };
    var work: ?[]const u8 = null;
    var run_id: ?u64 = null;
    var attempt: ?u64 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 2) {
        if (i + 1 >= argv.len) return null;
        const flag = argv[i];
        const value = argv[i + 1];
        if (std.mem.eql(u8, flag, "--stage")) {
            stage = value;
        } else if (std.mem.eql(u8, flag, "--registry")) {
            out.registry_spec = value;
        } else if (std.mem.eql(u8, flag, "--mopm")) {
            out.mopm = value;
        } else if (std.mem.eql(u8, flag, "--work")) {
            work = value;
        } else if (std.mem.eql(u8, flag, "--run-id")) {
            run_id = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, flag, "--attempt")) {
            attempt = std.fmt.parseInt(u64, value, 10) catch return null;
        } else if (std.mem.eql(u8, flag, "--summary")) {
            out.summary = value;
        } else if (std.mem.eql(u8, flag, "--wait-seconds")) {
            out.wait_seconds = std.fmt.parseInt(u64, value, 10) catch return null;
        } else return null;
    }
    out.stage = stage orelse return null;
    out.work = work orelse return null;
    out.run_id = run_id orelse return null;
    out.attempt = attempt orelse return null;
    return out;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const a = arena_state.allocator();
    const argv = try std.process.argsAlloc(a);
    const args = parseArgs(argv[1..]) orelse return usageExit();
    const base = switch (registry.resolve(args.registry_spec orelse args.stage)) {
        .ok => |b| b,
        .bad => |why| {
            std.debug.print("group-e2e: {s}\n", .{why});
            std.process.exit(2);
        },
    };
    var env = try std.process.getEnvMap(a);
    var rep = h.Report{};
    const result = try run(a, &rep, .{
        .base = base,
        .stage = args.stage,
        .token = env.get(token_env) orelse "",
        .mopm = args.mopm,
        .work = args.work,
        .run_id = args.run_id,
        .attempt = args.attempt,
        .summary = args.summary,
        .wait_ms = args.wait_seconds * 1000,
        .parent_env = &env,
    });
    std.debug.print("{s}\n", .{result.line});
    if (result.failures != 0) std.process.exit(1);
}

fn usageExit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}

