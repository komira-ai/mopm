//! The authenticated end-to-end check of group publishing, run against a deployed stage (beta or gamma) by the
//! `group-e2e` job of .github/workflows/e2e.yml after that stage's deploy, or by hand with workflow_dispatch.
//!
//!     mopm-group-e2e --stage beta|gamma [--registry <name|url>] --mopm <exe> --work <dir> --run-id <n> --attempt <n>
//!                    --pixi <exe> [--pixi-manifest <pixi.toml> | --mojo-env <prefix>]
//!                    [--summary <file>] [--wait-seconds <n>]
//!
//! The token is the environment variable MOPM_E2E_TOKEN (the job maps the repository secret MOPM_E2E_GROUP_TOKEN to
//! it on this one step). It reaches one child, `mopm publish --staged`, as MOPM_TOKEN, as a person's CI would give it,
//! and is never printed; no other child gets it (toolEnv, childEnv). Each stage keeps its own tokens, so the one
//! secret holds either a single token or a token for each stage, `beta=<token>` and `gamma=<token>` on lines of their
//! own (tokenFor): a stage with no entry skips.
//!
//! This is the path of a person who publishes a workspace, run with the real CLI, the real Mojo toolchain and the
//! real pixi. The e2e account owns a fixed set of throwaway packages (zz_e2e_core, zz_e2e_mid, zz_e2e_app; the
//! package name pattern has no hyphen, so the namespace is spelled zz_e2e_*), and the token lists exactly those. A
//! version is never deleted, so every run uses numbers no run has used: MAJOR is the case, MINOR the run id of the
//! workflow run and PATCH its attempt.
//!
//!   1  the switch      A group is created for a version nobody ever commits (the expiry probe). If the registry answers
//!                      `route_not_found` the stage's groups switch is off for this actor and the run SKIPs. The probe
//!                      is the one expiry check a run can make: a deadline is hours away, so the probe group stays
//!                      open, and the first run after its deadline finds it ended and opened again (attempt 2 or
//!                      more). It also pins the deadline to between 30 minutes and 19 hours after the call.
//!   2  the chain       zz_e2e_core <- zz_e2e_mid <- zz_e2e_app, three Mojo packages of a workspace, in three steps:
//!      a stage         `mojo precompile` builds each one; `mopm stage` packs them against the stage's registry and
//!                      writes the staged set (no token, nothing written to the registry).
//!      b overlay       A fresh project locks and syncs the staged set with `--overlay` while the registry holds
//!                      none of it, builds the program of the app's README, and runs it. Its lock names every file
//!                      with the sha256 of the staged one.
//!      c publish       `mopm publish --staged` publishes the set as one group. While it runs, the API is read: no
//!                      member is readable before the group commits, and the members appear all at once, never some.
//!                      report.json says the set was published, with every planned file. Once the group is `visible`,
//!                      every member's version, the sparse index, the channel's repodata and `mopm add` of the top
//!                      package agree with the bytes that were staged, the lock equals the one the overlay made, and
//!                      each locked file is downloaded and hashed. The lock is equal byte for byte, but for the entry of
//!                      a set package that a later run published a newer release of in the same major meanwhile.
//!   3  a rejected member   a staged set of two where one file is not a package: `publish --staged` ends 1, the group ends
//!                      `rejected`, names that member, and neither member is ever readable, in the API, the index or
//!                      the channel.
//!   4  yank and unyank the chain group is yanked as a whole, then restored: the API and the index follow each time.
//!
//! A skip has two causes and no more: the secret holds no token for the stage, or the registry says (route_not_found
//! to the probe) that groups are off for the actor. Both end the run with a SKIP line in the job summary and a
//! workflow warning annotation that names the reason. With a token and groups on, nothing is skipped: a missing
//! piece of the toolchain (--mopm, --pixi, a Mojo environment) is a failed check.
//!
//! The pure parts (the version numbers, the dependency ranges, the time arithmetic, the environments of a child, the
//! README program) are unit tests below; tests/drivers/group_e2e_test.zig runs the whole walk against a loopback registry that
//! serves the group routes, with the farm's Mojo toolchain and a stand-in pixi, and with each way the registry could go wrong.

const std = @import("std");
const core = @import("mopm_core");
const h = @import("harness.zig");
const http = core.http;
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
/// The packages of the chain, each after the ones it depends on.
pub const members = [_][]const u8{ pkg_core, pkg_mid, pkg_app };
/// The Mojo version every package is built for.
pub const compiler = "1.0.0";
/// The subdir every package is published for: the platform of the runner that resolves them (ubuntu-24.04, x86_64).
pub const subdir = "linux-64";
/// The version of the expiry probe: never uploaded, never committed, so never burned.
pub const probe_version = "0.0.1";
/// What the program of the app's README prints.
pub const readme_output = "zz_e2e total 3\n";

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

/// The environment a `mopm` child gets: the path and a home inside the work directory, and nothing else.
/// In particular not the token.
pub fn childEnv(a: Allocator, parent: *const std.process.EnvMap, home: []const u8) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    if (parent.get("PATH")) |p| try env.put("PATH", p);
    try env.put("HOME", home);
    return env;
}

/// Whether the runner's variable `name` is withheld from the toolchain: the token, and the credentials of the cloud and the workflow.
fn withheld(name: []const u8) bool {
    for ([_][]const u8{ token_env, "MOPM_TOKEN", "GITHUB_TOKEN", "GH_TOKEN" }) |n| {
        if (std.mem.eql(u8, name, n)) return true;
    }
    for ([_][]const u8{ "AWS_", "ACTIONS_", "INPUT_" }) |p| {
        if (std.mem.startsWith(u8, name, p)) return true;
    }
    return false;
}

/// The environment of a child that runs the toolchain (mojo, pixi, `mopm sync` and `mopm build`, the program built): the
/// parent's, because the compiler and the linker need what the runner set up (HOME, TMPDIR, the library path), without the
/// token and without the credentials the runner holds.
pub fn toolEnv(a: Allocator, parent: *const std.process.EnvMap) !std.process.EnvMap {
    var env = std.process.EnvMap.init(a);
    var it = parent.iterator();
    while (it.next()) |e| {
        if (withheld(e.key_ptr.*)) continue;
        try env.put(e.key_ptr.*, e.value_ptr.*);
    }
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

// ---- the workspace --------------------------------------------------------------------------------------------------

/// The package a member of the chain depends on, or null.
pub fn depOf(name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, name, pkg_mid)) return pkg_core;
    if (std.mem.eql(u8, name, pkg_app)) return pkg_mid;
    return null;
}

/// The mopm.toml of a member at `version`: a path dependency on the member below it, which the package keeps as a requirement
/// for that version or a newer one of the same major.
pub fn memberToml(a: Allocator, name: []const u8, version: []const u8) ![]u8 {
    const head = try std.fmt.allocPrint(a, "[package]\nname = \"{s}\"\nversion = \"{s}\"\nmojo = [\"{s}\"]\n\n[dependencies]\n", .{ name, version, compiler });
    const dep = depOf(name) orelse return head;
    return std.fmt.allocPrint(a, "{s}{s} = {{ path = \"../{s}\", version = \"^{s}\" }}\n", .{ head, dep, dep, version });
}

/// The Mojo source of a member (src/<name>/__init__.mojo): each package adds one to the one below it.
pub fn sourceOf(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, pkg_mid)) return "from zz_e2e_core import base\n\n\ndef middle() -> Int:\n    return base() + 1\n";
    if (std.mem.eql(u8, name, pkg_app)) return "from zz_e2e_mid import middle\n\n\ndef total() -> Int:\n    return middle() + 1\n";
    return "def base() -> Int:\n    return 1\n";
}

/// The README of a member. The app's holds the program a reader of the package page would copy.
pub fn readmeOf(a: Allocator, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, name, pkg_app)) {
        return std.fmt.allocPrint(a, "# {s}\n\nA throwaway package of the group publishing end-to-end check. Install it, then:\n\n```mojo\nfrom zz_e2e_app import total\n\n\ndef main():\n    print(\"zz_e2e total\", total())\n```\n\nIt prints `zz_e2e total 3`.\n", .{name});
    }
    return std.fmt.allocPrint(a, "# {s}\n\nA throwaway package of the group publishing end-to-end check.\n", .{name});
}

/// The first ```mojo block of a README, or null.
pub fn readmeProgram(text: []const u8) ?[]const u8 {
    const open = "```mojo\n";
    const start = std.mem.indexOf(u8, text, open) orelse return null;
    const body = text[start + open.len ..];
    const end = std.mem.indexOf(u8, body, "```") orelse return null;
    return body[0..end];
}

/// Writes the workspace of `names` at `version` under `ws`: for each member its mopm.toml, README.md and source.
pub fn writeWorkspace(a: Allocator, ws: []const u8, version: []const u8, names: []const []const u8) !void {
    for (names) |name| {
        const dir = try std.fs.path.join(a, &.{ ws, name });
        try h.writeFile(try std.fs.path.join(a, &.{ dir, "mopm.toml" }), try memberToml(a, name, version));
        try h.writeFile(try std.fs.path.join(a, &.{ dir, "README.md" }), try readmeOf(a, name));
        try h.writeFile(try std.fs.path.join(a, &.{ dir, "src", name, "__init__.mojo" }), sourceOf(name));
    }
}

/// Builds the `.mojoc` of the three members of `ws`, each after the ones below it, with `<mojo_env>/bin/mojo`, into
/// `<art>/<subdir>/<name>.mojoc` (the layout `mopm stage --artifacts` reads). Null when they are built, else what went wrong.
pub fn precompileAll(a: Allocator, mojo_env: []const u8, parent: *const std.process.EnvMap, ws: []const u8, art: []const u8) !?[]const u8 {
    var env = try toolEnv(a, parent);
    try env.put("MODULAR_HOME", try std.fmt.allocPrint(a, "{s}/share/max", .{mojo_env}));
    const mojo = try std.fs.path.join(a, &.{ mojo_env, "bin", "mojo" });
    var dep_flags = std.ArrayList([]const u8).init(a);
    for (members) |name| {
        const out_dir = try std.fs.path.join(a, &.{ art, "deps", name });
        try std.fs.cwd().makePath(out_dir);
        const out = try std.fs.path.join(a, &.{ out_dir, try std.fmt.allocPrint(a, "{s}.mojoc", .{name}) });
        var argv = std.ArrayList([]const u8).init(a);
        try argv.appendSlice(&.{ mojo, "precompile" });
        try argv.appendSlice(dep_flags.items);
        try argv.appendSlice(&.{ name, "-o", out });
        const ran = try h.run(a, argv.items, &env, .{ .cwd = try std.fs.path.join(a, &.{ ws, name, "src" }) });
        if (ran.code != 0 or ran.signaled) return try std.fmt.allocPrint(a, "mojo precompile {s} ended {d}: {s}", .{ name, ran.code, tailOf(ran.text) });
        try dep_flags.append(try std.fmt.allocPrint(a, "-I{s}", .{out_dir}));
        const staged = try std.fs.path.join(a, &.{ art, subdir, try std.fmt.allocPrint(a, "{s}.mojoc", .{name}) });
        try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ art, subdir }));
        try std.fs.cwd().copyFile(out, std.fs.cwd(), staged, .{});
    }
    return null;
}

// ---- what is sent and what comes back -------------------------------------------------------------------------------

const FileDecl = struct { subdir: []const u8, filename: []const u8, sha256: []const u8, size: u64 };
const MemberDecl = struct { name: []const u8, version: []const u8, files: []const FileDecl };
const CreateBody = struct { members: []const MemberDecl };
const Created = struct {
    group_id: []const u8,
    status: []const u8,
    attempt: u64,
    deadline_at: []const u8 = "",
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

/// plan.json of a staged set (spec/staged-set.md), the parts this check reads.
const PlanMember = struct {
    name: []const u8 = "",
    version: []const u8 = "",
    action: []const u8 = "",
    manifest_sha256: []const u8 = "",
    files: []const FileRef = &.{},
};
const Plan = struct { members: []const PlanMember = &.{} };
/// report.json, which `mopm publish --staged` writes into the staged directory.
const ReportMember = struct { name: []const u8 = "", version: []const u8 = "", outcome: []const u8 = "", code: ?[]const u8 = null, files: []const FileRef = &.{} };
const PublishReport = struct { group_id: []const u8 = "", group_status: []const u8 = "", outcome: []const u8 = "", members: []const ReportMember = &.{} };
/// state.json, which names the group before any file is sent.
const StateFile = struct { group_id: []const u8 = "" };

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

/// The last 400 bytes of the output of a program: where it says why it stopped.
fn tailOf(s: []const u8) []const u8 {
    return s[s.len -| 400 ..];
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

// ---- the clock ------------------------------------------------------------------------------------------------------

/// What time it is and how to wait for it to pass: the one place the check reads the clock or sleeps. The default is the real
/// clock; a test hands in a clock that it moves itself, so that no wait of the check is a wait of the test.
pub const Clock = struct {
    ctx: ?*anyopaque = null,
    now_ms_fn: *const fn (?*anyopaque) i64 = realNowMs,
    sleep_ms_fn: *const fn (?*anyopaque, u64) void = realSleepMs,

    pub fn nowMs(c: Clock) i64 {
        return c.now_ms_fn(c.ctx);
    }

    /// Whole seconds since the epoch.
    pub fn nowSecs(c: Clock) i64 {
        return @divFloor(c.nowMs(), 1000);
    }

    pub fn sleepMs(c: Clock, ms: u64) void {
        c.sleep_ms_fn(c.ctx, ms);
    }
};

fn realNowMs(_: ?*anyopaque) i64 {
    return std.time.milliTimestamp();
}

fn realSleepMs(_: ?*anyopaque, ms: u64) void {
    std.time.sleep(ms * std.time.ns_per_ms);
}

/// Run `attempt` until it returns true, or until `wait_ms` has passed since the first try (then false), with `poll_ms` between
/// two tries. An error of `attempt` ends the poll.
pub fn pollUntil(clock: Clock, wait_ms: u64, poll_ms: u64, comptime Ctx: type, ctx: Ctx, comptime attempt: fn (Ctx) anyerror!bool) !bool {
    const start = clock.nowMs();
    while (true) {
        if (try attempt(ctx)) return true;
        if (clock.nowMs() - start > @as(i64, @intCast(wait_ms))) return false;
        clock.sleepMs(poll_ms);
    }
}

/// Make a call again after a transport error, and after a 429, at most three times: the pause of a transport error is `retry_ms`;
/// a 429 waits as long as the registry says in Retry-After (at most a minute), and never less than `retry_ms`. The fourth answer
/// is the answer, whatever it is.
pub fn retrying(clock: Clock, retry_ms: u64, comptime Ctx: type, ctx: Ctx, comptime call: fn (Ctx) anyerror!http.Answer) !http.Answer {
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        const ans = call(ctx) catch |e| {
            if (tries >= 3) return e;
            clock.sleepMs(retry_ms);
            continue;
        };
        if (ans.status == 429 and tries < 3) {
            clock.sleepMs(@max(retry_ms, @min(@as(u64, ans.retry_after orelse 0) * 1000, 60_000)));
            continue;
        }
        return ans;
    }
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
    /// How long `mopm publish --staged` waits for its group to be visible or to end. That is the registry's own promise (the group
    /// reaches a state, and then every member is readable), so it is a backstop for a registry that never gets there and does
    /// not follow how long a read of the index may lag. Null: the same as `wait_ms`, and at least a second. Given, it is what
    /// `mopm publish --wait` gets, in whole seconds (0: it asks once and gives up).
    publish_wait_ms: ?u64 = null,
    poll_ms: u64 = 3000,
    /// Where a transport error or a 429 waits before the call is made again.
    retry_ms: u64 = 2000,
    /// Every read of the time and every wait of the check.
    clock: Clock = .{},
    /// The environment of this process: what the toolchain children start from, and the PATH of the others.
    parent_env: ?*const std.process.EnvMap = null,
    /// pixi: `mopm sync` installs through it, and, with no `mojo_env`, it creates the Mojo environment from `pixi_manifest`.
    pixi: ?[]const u8 = null,
    pixi_manifest: ?[]const u8 = null,
    /// A Mojo environment that exists (`bin/mojo`, `lib/mojo`): then no environment is created.
    mojo_env: ?[]const u8 = null,
    /// Packages already built: `<dir>/linux-64/<name>.mojoc` for the three. Then none is precompiled.
    prebuilt: ?[]const u8 = null,
    /// Lays the Mojo toolchain into the environment `mopm sync` made, for a stand-in pixi that installs packages and nothing else.
    after_sync: ?*const fn (Allocator, []const u8) anyerror!void = null,
};

/// Why a run did nothing.
pub const SkipReason = enum { none, prod, no_secret, no_stage_token, groups_off };

pub const Result = struct {
    skipped: bool,
    skip_reason: SkipReason = .none,
    /// The one line the run ends with: PASS, FAIL or SKIP, the stage and why.
    line: []const u8,
    checks: usize,
    failures: usize,
    /// One line per check (`- ok   <name>` or `- FAIL <name>: <detail>`), in the order they ran.
    notes: []const []const u8 = &.{},
};

/// One call of `Cx.send`.
const Request = struct { a: Allocator, method: std.http.Method, url: []const u8, token: ?[]const u8, body: ?[]const u8 };

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
    /// The environment when the run was given none.
    empty: std.process.EnvMap,
    /// The Mojo environment, once there is one.
    mojo_prefix: ?[]const u8 = null,
    /// The built packages, once there are some; `art_tried` is set when they were asked for, built or not.
    art: ?[]const u8 = null,
    art_tried: bool = false,

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

    fn parent(self: *Cx) *const std.process.EnvMap {
        return self.o.parent_env orelse &self.empty;
    }

    fn join(self: *Cx, parts: []const []const u8) ![]u8 {
        return std.fs.path.join(self.a, parts);
    }

    /// One call, with a pause and another try on a transport error, and on a 429.
    fn send(self: *Cx, method: std.http.Method, full_url: []const u8, body: ?[]const u8, auth: bool) !http.Answer {
        const once = struct {
            fn call(r: Request) anyerror!http.Answer {
                return http.request(r.a, r.method, r.url, .{ .token = r.token, .body = r.body });
            }
        }.call;
        return retrying(self.o.clock, self.o.retry_ms, Request, .{ .a = self.a, .method = method, .url = full_url, .token = if (auth) self.token else null, .body = body }, once);
    }

    fn api(self: *Cx, method: std.http.Method, p: []const u8, body: ?[]const u8) !http.Answer {
        return self.send(method, try self.url(p), body, true);
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

    /// The home of every child: below the work directory.
    fn home(self: *Cx) ![]u8 {
        const p = try self.join(&.{ self.o.work, "home" });
        try std.fs.cwd().makePath(p);
        return p;
    }

    /// `mopm <args>` in `dir`, with the path and a home and nothing else; with `token`, also MOPM_TOKEN, as a person's CI sets it.
    fn mopmRun(self: *Cx, dir: ?[]const u8, args: []const []const u8, with_token: bool) !h.Ran {
        const mopm = self.o.mopm orelse return error.NoMopm;
        var env = try childEnv(self.a, self.parent(), try self.home());
        if (with_token) try env.put("MOPM_TOKEN", self.token);
        var argv = std.ArrayList([]const u8).init(self.a);
        try argv.append(mopm);
        try argv.appendSlice(args);
        return h.run(self.a, argv.items, &env, .{ .cwd = dir });
    }

    /// A program of the toolchain (`mopm sync`, `mopm build`, the program built), with the runner's environment less its credentials.
    fn toolRun(self: *Cx, dir: ?[]const u8, argv: []const []const u8) !h.Ran {
        var env = try toolEnv(self.a, self.parent());
        return h.run(self.a, argv, &env, .{ .cwd = dir });
    }
};

fn groupBody(a: Allocator, pkgs: []const Pkg) ![]u8 {
    const mems = try a.alloc(MemberDecl, pkgs.len);
    for (pkgs, mems) |p, *m| {
        const files = try a.alloc(FileDecl, 1);
        files[0] = .{ .subdir = subdir, .filename = p.file_name, .sha256 = p.sha256, .size = p.bytes.len };
        m.* = .{ .name = p.name, .version = p.version, .files = files };
    }
    return std.json.stringifyAlloc(a, CreateBody{ .members = mems }, .{});
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

/// Run `f` until it returns true or `wait_ms` is over; the last answer's text is the reason.
fn eventually(cx: *Cx, comptime Ctx: type, ctx: Ctx, comptime f: fn (*Cx, Ctx, *[]const u8) anyerror!bool, why: *[]const u8) !bool {
    const Try = struct { cx: *Cx, ctx: Ctx, why: *[]const u8 };
    const once = struct {
        fn call(t: Try) anyerror!bool {
            return f(t.cx, t.ctx, t.why) catch |e| {
                t.why.* = @errorName(e);
                return false;
            };
        }
    }.call;
    return pollUntil(cx.o.clock, cx.o.wait_ms, cx.o.poll_ms, Try, .{ .cx = cx, .ctx = ctx, .why = why }, once);
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
    const now = cx.o.clock.nowSecs();
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

/// The Mojo environment: the one given, or one pixi creates from the manifest. Null (a failed check says why) when there is none.
fn toolchain(cx: *Cx) !?[]const u8 {
    if (cx.mojo_prefix) |p| return p;
    if (cx.o.mojo_env) |p| {
        cx.mojo_prefix = p;
        return p;
    }
    const pixi = cx.o.pixi orelse {
        cx.fail("toolchain: --pixi (or --mojo-env) names the Mojo environment", "neither was given");
        return null;
    };
    const manifest = cx.o.pixi_manifest orelse {
        cx.fail("toolchain: --pixi-manifest names the Mojo environment pixi creates", "no --pixi-manifest");
        return null;
    };
    const dir = try cx.join(&.{ cx.o.work, "mojo-env" });
    const toml = try cx.join(&.{ dir, "pixi.toml" });
    h.writeFile(toml, try h.readFile(cx.a, manifest)) catch |e| {
        cx.fail("toolchain: the pixi manifest is copied", @errorName(e));
        return null;
    };
    const ran = try cx.toolRun(null, &.{ pixi, "install", "--manifest-path", toml });
    cx.check("toolchain: pixi creates the Mojo environment", ran.code == 0 and !ran.signaled, tailOf(ran.text));
    if (ran.code != 0 or ran.signaled) {
        cx.stop = true;
        return null;
    }
    const prefix = try cx.join(&.{ dir, ".pixi", "envs", "default" });
    cx.mojo_prefix = prefix;
    return prefix;
}

/// The `.mojoc` of the three packages (`<dir>/linux-64/<name>.mojoc`): the ones given, or built once with the toolchain. Null (a
/// failed check says why) when they cannot be had.
fn artifacts(cx: *Cx) !?[]const u8 {
    if (cx.art) |p| return p;
    if (cx.o.prebuilt) |p| {
        cx.art = p;
        return p;
    }
    if (cx.art_tried) return null;
    cx.art_tried = true;
    const mojo = (try toolchain(cx)) orelse return null;
    const ws = try cx.join(&.{ cx.o.work, "ws_build" });
    const art = try cx.join(&.{ cx.o.work, "art" });
    try writeWorkspace(cx.a, ws, "0.0.1", &members);
    const why = try precompileAll(cx.a, mojo, cx.parent(), ws, art);
    cx.check("packages: mojo precompile builds the three packages", why == null, why orelse "");
    if (why != null) {
        cx.stop = true;
        return null;
    }
    cx.art = art;
    return art;
}

/// `mopm stage` of the first `names.len` members of the workspace at `ws` into `out`, and the plan it wrote as packages. Null when the
/// set is not as it should be (a failed check says why).
fn stageStep(cx: *Cx, label: []const u8, ws: []const u8, art: []const u8, out: []const u8, names: []const []const u8) !?[]const Pkg {
    const ran = cx.mopmRun(null, &.{ "stage", "--workspace-root", ws, "--artifacts", art, "--compiler", compiler, "--out", out, "--registry", cx.o.base }, false) catch |e| {
        cx.fail(try std.fmt.allocPrint(cx.a, "{s}: mopm stage runs", .{label}), @errorName(e));
        return null;
    };
    const summary = try std.fmt.allocPrint(cx.a, "{d} to upload, 0 skipped, 0 refused", .{names.len});
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: mopm stage packs the workspace, with no token, and every member is an upload", .{label}), ran.code == 0 and h.contains(ran.text, summary), tailOf(ran.text));
    if (ran.code != 0) {
        cx.stop = true;
        return null;
    }
    const plan_text = h.readFile(cx.a, try cx.join(&.{ out, "plan.json" })) catch {
        cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the staged set has a plan.json", .{label}), "no plan.json");
        return null;
    };
    const plan = parse(Plan, cx.a, plan_text) orelse {
        cx.fail(try std.fmt.allocPrint(cx.a, "{s}: plan.json is a plan", .{label}), excerpt(plan_text));
        return null;
    };
    var pkgs = std.ArrayList(Pkg).init(cx.a);
    var ok = plan.members.len == names.len;
    var why: []const u8 = "";
    if (ok) for (names, plan.members) |name, m| {
        const one = m.files.len == 1;
        if (!std.mem.eql(u8, m.name, name) or !std.mem.eql(u8, m.action, "upload") or !one or !std.mem.eql(u8, m.files[0].subdir, subdir) or m.manifest_sha256.len != 64) {
            ok = false;
            why = m.name;
            break;
        }
        const bytes = h.readFile(cx.a, try cx.join(&.{ out, subdir, m.files[0].filename })) catch {
            ok = false;
            why = m.files[0].filename;
            break;
        };
        if (!std.mem.eql(u8, &sha256Hex(bytes), m.files[0].sha256) or bytes.len != m.files[0].size) {
            ok = false;
            why = m.files[0].filename;
            break;
        }
        try pkgs.append(.{
            .name = m.name,
            .version = m.version,
            .file_name = m.files[0].filename,
            .bytes = bytes,
            .sha256 = m.files[0].sha256,
            .manifest_sha256 = m.manifest_sha256,
            .dep = if (depOf(name) != null) m.version else "",
        });
    };
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: the plan lists the members in dependency order, each with one {s} file that hashes as planned", .{ label, subdir }), ok, why);
    if (!ok) {
        cx.stop = true;
        return null;
    }
    return pkgs.items;
}

/// A project that depends on nothing yet, named `consumer`, in `dir`.
fn writeConsumer(cx: *Cx, dir: []const u8) !void {
    try h.writeFile(try cx.join(&.{ dir, "mopm.toml" }), "[package]\nname = \"consumer\"\nversion = \"0.1.0\"\n\n[toolchain]\nmojo = \"" ++ compiler ++ "\"\n\n[dependencies]\n");
}

/// Step 2b. A fresh project locks and installs the staged set (`--overlay`) before the registry holds any of it, and builds and
/// runs the program of the app's README. Returns the lock the overlay made, "" when it made none.
fn overlayStep(cx: *Cx, label: []const u8, staged: []const u8, pkgs: []const Pkg) ![]const u8 {
    const dir = try cx.join(&.{ cx.o.work, "overlay_consumer" });
    try writeConsumer(cx, dir);
    const app = pkgs[pkgs.len - 1];
    const spec = try std.fmt.allocPrint(cx.a, "{s}@={s}", .{ app.name, app.version });
    var ran = try cx.mopmRun(dir, &.{ "add", spec, "--registry", cx.o.base, "--overlay", staged }, false);
    const add_name = try std.fmt.allocPrint(cx.a, "{s}: mopm add --overlay locks the staged set", .{label});
    cx.check(add_name, ran.code == 0, tailOf(ran.text));
    if (ran.code != 0) return "";
    const lock_text = h.readFile(cx.a, try cx.join(&.{ dir, "mopm.lock" })) catch "";
    try lockCheck(cx, "overlay", pkgs, lock_text, false);

    const pixi = cx.o.pixi orelse {
        cx.fail(try std.fmt.allocPrint(cx.a, "{s}: --pixi names pixi, which mopm sync installs through", .{label}), "no --pixi");
        return lock_text;
    };
    const mopm = cx.o.mopm orelse return lock_text;
    ran = try cx.toolRun(dir, &.{ mopm, "sync", "--locked", "--overlay", staged, "--registry", cx.o.base, "--pixi", pixi });
    const want = try std.fmt.allocPrint(cx.a, "read {d} packages from the staged set", .{pkgs.len});
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: mopm sync --overlay installs the whole set from the staged set", .{label}), ran.code == 0 and h.contains(ran.text, want), tailOf(ran.text));
    if (ran.code != 0) return lock_text;
    const env = try cx.join(&.{ dir, ".mopm", ".pixi", "envs", "default" });
    if (cx.o.after_sync) |lay| {
        lay(cx.a, env) catch |e| {
            cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the toolchain is laid into the environment", .{label}), @errorName(e));
            return lock_text;
        };
    }

    // The README of the top package is what a person copies: its program must build against the installed set and print what it says.
    const readme = h.readFile(cx.a, try cx.join(&.{ staged, app.name, "README.md" })) catch "";
    const program = readmeProgram(readme) orelse {
        cx.fail(try std.fmt.allocPrint(cx.a, "{s}: the staged README of {s} holds a mojo program", .{ label, app.name }), excerpt(readme));
        return lock_text;
    };
    try h.writeFile(try cx.join(&.{ dir, "readme_main.mojo" }), program);
    const bin = try cx.join(&.{ cx.o.work, "readme_bin" });
    ran = try cx.toolRun(dir, &.{ mopm, "build", "readme_main.mojo", "-o", bin, "--prefix", env });
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: the README's program builds against the installed set", .{label}), ran.code == 0, tailOf(ran.text));
    if (ran.code == 0) {
        ran = try cx.toolRun(dir, &.{bin});
        cx.check(try std.fmt.allocPrint(cx.a, "{s}: the README's program runs and prints what the README says", .{label}), ran.code == 0 and std.mem.eql(u8, ran.text, readme_output), tailOf(ran.text));
    }
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: after all that the registry still shows none of the set", .{label}), (try cx.shown(pkgs)) == 0, "a member is readable before it was published");
    return lock_text;
}

/// What the publish child did, and what the API showed while it ran.
const Published = struct {
    code: u8 = 255,
    text: []const u8 = "",
    report: ?PublishReport = null,
    group_id: []const u8 = "",
    /// A member was readable while its group was still before its commit.
    early: bool = false,
    /// Some of the members, and not all, were readable at once.
    partial: bool = false,
};

/// `mopm publish --staged` run on its own thread, so that the API can be read while it works.
const PublishJob = struct {
    argv: []const []const u8,
    env: *const std.process.EnvMap,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    code: u8 = 255,
    text: []const u8 = "",

    fn work(self: *PublishJob) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        if (h.run(arena.allocator(), self.argv, self.env, .{})) |ran| {
            self.code = if (ran.signaled) 255 else ran.code;
            self.text = std.heap.page_allocator.dupe(u8, ran.text) catch "";
        } else |_| {}
        self.done.store(true, .release);
    }
};

/// The group a staged directory names in its state.json, once `publish --staged` has written one.
fn stateGroupId(cx: *Cx, staged: []const u8) []const u8 {
    const text = h.readFile(cx.a, cx.join(&.{ staged, "state.json" }) catch return "") catch return "";
    return (parse(StateFile, cx.a, text) orelse return "").group_id;
}

/// `mopm publish --staged <staged>` with the token. With `watch`, the API is read every poll while it runs.
fn publishRun(cx: *Cx, staged: []const u8, pkgs: []const Pkg, watch: bool) !Published {
    const mopm = cx.o.mopm orelse return error.NoMopm;
    const wait_secs = if (cx.o.publish_wait_ms) |ms| ms / 1000 else @max(cx.o.wait_ms / 1000, 1);
    const wait = try std.fmt.allocPrint(cx.a, "{d}", .{wait_secs});
    const argv = [_][]const u8{ mopm, "publish", "--staged", staged, "--registry", cx.o.base, "--wait", wait };
    var env = try childEnv(cx.a, cx.parent(), try cx.home());
    try env.put("MOPM_TOKEN", cx.token);
    var out = Published{};
    if (!watch) {
        const ran = try h.run(cx.a, &argv, &env, .{});
        out.code = if (ran.signaled) 255 else ran.code;
        out.text = ran.text;
    } else {
        var job = PublishJob{ .argv = &argv, .env = &env };
        const thread = try std.Thread.spawn(.{}, PublishJob.work, .{&job});
        var id: []const u8 = "";
        while (!job.done.load(.acquire)) {
            if (id.len == 0) id = stateGroupId(cx, staged);
            const g1: ?Group = if (id.len > 0) (cx.getGroup(id) catch null) else null;
            const n = cx.shown(pkgs) catch pkgs.len + 1;
            const g2: ?Group = if (id.len > 0) (cx.getGroup(id) catch null) else null;
            // The members are read one after the other, so a commit that lands between two reads shows some of them in the sweep
            // and all of them in the next one. A sweep counts as partial only when the group was on the same side of its commit
            // before and after it (a group moves forward only): then nothing was committed meanwhile, and some members and
            // not all were readable at once.
            if (g1 != null and g2 != null and n > 0 and n < pkgs.len and
                isOneOf(g1.?.status, &pre_commit) == isOneOf(g2.?.status, &pre_commit)) out.partial = true;
            if (n > 0 and n <= pkgs.len and g1 != null and g2 != null and isOneOf(g1.?.status, &pre_commit) and isOneOf(g2.?.status, &pre_commit)) out.early = true;
            cx.o.clock.sleepMs(cx.o.poll_ms);
        }
        thread.join();
        out.code = job.code;
        out.text = job.text;
    }
    const report_text = h.readFile(cx.a, try cx.join(&.{ staged, "report.json" })) catch "";
    out.report = parse(PublishReport, cx.a, report_text);
    out.group_id = if (out.report) |r| r.group_id else "";
    if (out.group_id.len == 0) out.group_id = stateGroupId(cx, staged);
    return out;
}

/// Abort a group that a failed publish left open, so it does not hold one of the actor's open slots until its deadline. An ended
/// group refuses (409), which is fine.
fn abort(cx: *Cx, id: []const u8) void {
    if (id.len == 0) return;
    const p = std.fmt.allocPrint(cx.a, "/groups/{s}", .{id}) catch return;
    _ = cx.api(.DELETE, p, null) catch return;
}

const Chain = struct { id: []const u8, pkgs: []const Pkg, overlay_lock: []const u8 };

/// Step 2. The chain: stage, the overlay and the README, and one group published; null when it did not get as far as a visible group.
fn chainStep(cx: *Cx) !?Chain {
    const L = "chain";
    if (cx.o.mopm == null) {
        cx.fail("chain: --mopm names the CLI", "no --mopm");
        return null;
    }
    const art = (try artifacts(cx)) orelse return null;
    const ver = try versionOf(cx.a, .chain, cx.o.run_id, cx.o.attempt);
    const ws = try cx.join(&.{ cx.o.work, "ws_chain" });
    const staged = try cx.join(&.{ cx.o.work, "staged_chain" });
    try writeWorkspace(cx.a, ws, ver, &members);
    const pkgs = (try stageStep(cx, L, ws, art, staged, &members)) orelse return null;
    const overlay_lock = try overlayStep(cx, L, staged, pkgs);
    cx.stop = false;

    const res = try publishRun(cx, staged, pkgs, true);
    cx.check("chain: mopm publish --staged publishes the set", res.code == 0, tailOf(res.text));
    cx.check("chain: the token is not in what publish printed", std.mem.indexOf(u8, res.text, cx.token) == null, "the output holds the token");
    const status = if (res.report) |r| r.group_status else "(no report.json)";
    cx.check("chain: the group becomes visible", res.code == 0 and std.mem.eql(u8, status, "visible"), try std.fmt.allocPrint(cx.a, "status {s}", .{status}));
    if (res.code != 0 or !std.mem.eql(u8, status, "visible")) {
        abort(cx, res.group_id);
        cx.stop = true;
        return null;
    }
    const id = res.group_id;
    cx.check("chain: the group id has the contract's shape", validGroupId(id), id);
    cx.check("chain: no member is readable before the commit", !res.early, "a member was readable while the group was still before its commit");
    cx.check("chain: the members appear all at once, never some of them", !res.partial, "some of the members, and not all, were readable at once");
    reportCheck(cx, L, res.report.?, pkgs);
    // The API shows a committed group's members at once, all of them.
    const live = try cx.shown(pkgs);
    cx.check("chain: once committed, all three members are readable at once", live == pkgs.len, try std.fmt.allocPrint(cx.a, "{d} of {d}", .{ live, pkgs.len }));
    if (try cx.getGroup(id)) |g| {
        cx.check("chain: the group names its three members", g.member_count == pkgs.len and g.members.len == pkgs.len, "member_count");
        var all_pub = true;
        for (g.members) |m| {
            if (!std.mem.eql(u8, m.state, "published")) all_pub = false;
        }
        cx.check("chain: every member is published", all_pub, "a member is not published");
    } else {
        cx.check("chain: the group can be read", false, "GET /groups/{id} did not answer 200");
    }
    try readBack(cx, L, pkgs, "published");
    return .{ .id = id, .pkgs = pkgs, .overlay_lock = overlay_lock };
}

/// report.json says the set was published: the run, the group and every member with the files the plan named.
fn reportCheck(cx: *Cx, label: []const u8, report: PublishReport, pkgs: []const Pkg) void {
    var ok = std.mem.eql(u8, report.outcome, "published") and report.members.len == pkgs.len;
    if (ok) for (pkgs, report.members) |p, m| {
        if (!std.mem.eql(u8, m.name, p.name) or !std.mem.eql(u8, m.version, p.version) or !std.mem.eql(u8, m.outcome, "published") or
            m.files.len != 1 or !std.mem.eql(u8, m.files[0].sha256, p.sha256) or !std.mem.eql(u8, m.files[0].filename, p.file_name))
        {
            ok = false;
        }
    };
    const name = std.fmt.allocPrint(cx.a, "{s}: report.json says every member was published, with the planned file", .{label}) catch return;
    cx.check(name, ok, report.outcome);
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

/// A lock holds the whole chain with the sha256 of each staged file, and the top package's entry names the middle one. With
/// `download`, each locked file is fetched and hashed.
fn lockCheck(cx: *Cx, label: []const u8, pkgs: []const Pkg, text: []const u8, download: bool) !void {
    var why: []const u8 = "";
    const parsed = lock.parse(cx.a, text, &why) catch {
        cx.check(try std.fmt.allocPrint(cx.a, "{s}: the lock is a lock", .{label}), false, why);
        return;
    };
    // A lock may hold one build per Mojo version: the one this check built for.
    const l = try lock.forMojo(cx.a, parsed, compiler);
    for (pkgs) |p| {
        var found: ?lock.Package = null;
        for (l.packages) |lp| {
            if (std.mem.eql(u8, lp.name, p.name)) found = lp;
        }
        const name = try std.fmt.allocPrint(cx.a, "{s}: {s} is locked at the uploaded file", .{ label, p.name });
        const lp = found orelse {
            cx.check(name, false, "not in the lock");
            continue;
        };
        const mine = std.mem.eql(u8, lp.version, p.version);
        // A later run may have published a newer 1.x of a dependency (the range allows it): then it is that run's file.
        const newer = !mine and isNewerSameMajor(lp.version, p.version);
        const sha_ok = if (mine) std.mem.eql(u8, lp.sha256, p.sha256) and lp.size == p.bytes.len else newer;
        cx.check(name, sha_ok and std.mem.eql(u8, lp.subdir, subdir), try std.fmt.allocPrint(cx.a, "version {s}, sha256 {s}", .{ lp.version, lp.sha256 }));
        if (!download) continue;
        // Installing downloads this URL and checks the sha256.
        const file = try cx.send(.GET, lp.url, null, false);
        cx.check(try std.fmt.allocPrint(cx.a, "{s}: the file {s} pins downloads and hashes to the lock's sha256", .{ label, p.name }), file.status == 200 and std.mem.eql(u8, &sha256Hex(file.body), lp.sha256), try std.fmt.allocPrint(cx.a, "HTTP {d}", .{file.status}));
    }
    var app_deps_mid = false;
    for (l.packages) |lp| {
        if (std.mem.eql(u8, lp.name, pkg_app)) {
            for (lp.deps) |d| {
                if (std.mem.eql(u8, d, pkg_mid)) app_deps_mid = true;
            }
        }
    }
    cx.check(try std.fmt.allocPrint(cx.a, "{s}: the top package's entry names the middle one as its dependency", .{label}), app_deps_mid, "no dependency edge");
}

/// `mopm add` of the top package against the registry resolves the whole chain from the index, and the lock pins what was
/// published: the lock the overlay made before the publish.
fn lockStep(cx: *Cx, chain: Chain) !void {
    const dir = try cx.join(&.{ cx.o.work, "consumer" });
    try writeConsumer(cx, dir);
    const app = chain.pkgs[chain.pkgs.len - 1];
    const spec = try std.fmt.allocPrint(cx.a, "{s}@={s}", .{ app.name, app.version });
    const ran = try cx.mopmRun(dir, &.{ "add", spec, "--registry", cx.o.base }, false);
    cx.check("lock: mopm add of the top package resolves", ran.code == 0, tailOf(ran.text));
    if (ran.code != 0) return;
    const text = h.readFile(cx.a, try cx.join(&.{ dir, "mopm.lock" })) catch {
        cx.check("lock: mopm add wrote a lock", false, "no mopm.lock");
        return;
    };
    try lockCheck(cx, "lock", chain.pkgs, text, true);
    if (chain.overlay_lock.len > 0) try sameLockCheck(cx, chain.overlay_lock, text);
}

const lock_same_name = "lock: the lock the staged set made is, byte for byte, the lock the registry gives once the set is published";

fn isMember(name: []const u8) bool {
    for (members) |m| {
        if (std.mem.eql(u8, m, name)) return true;
    }
    return false;
}

/// The lock the overlay made equals, byte for byte, the lock the registry gives once the set is published. The one difference
/// tolerated: a package of the e2e set that another run published in a newer release of the same major between the overlay and
/// the publish (the range of a dependency allows it), which the registry's lock then names instead; that entry is the other run's
/// file, and lockCheck has already held it to a newer same-major version. Everything else, every field of every other entry, the
/// entry of a set package at its own version included, must match exactly.
fn sameLockCheck(cx: *Cx, overlay_text: []const u8, registry_text: []const u8) !void {
    if (std.mem.eql(u8, overlay_text, registry_text)) {
        cx.check(lock_same_name, true, "");
        return;
    }
    var why: []const u8 = "";
    const made = lock.parse(cx.a, overlay_text, &why) catch {
        cx.check(lock_same_name, false, try std.fmt.allocPrint(cx.a, "the overlay's lock is not a lock: {s}", .{why}));
        return;
    };
    const given = lock.parse(cx.a, registry_text, &why) catch {
        cx.check(lock_same_name, false, try std.fmt.allocPrint(cx.a, "the registry's lock is not a lock: {s}", .{why}));
        return;
    };
    const packages = try cx.a.dupe(lock.Package, given.packages);
    var superseded = std.ArrayList([]const u8).init(cx.a);
    for (packages) |*p| {
        if (p.source != .registry or !isMember(p.name)) continue;
        for (made.packages) |q| {
            if (q.source != .registry or !std.mem.eql(u8, q.name, p.name)) continue;
            if (isNewerSameMajor(p.version, q.version)) {
                try superseded.append(p.name);
                p.* = q;
            }
            break;
        }
    }
    // With nothing superseded the texts differ, and that is the failure, whatever the parsed locks say.
    var same = superseded.items.len > 0;
    if (same) {
        var patched = given;
        patched.packages = packages;
        same = std.mem.eql(u8, try lock.render(cx.a, made), try lock.render(cx.a, patched));
    }
    cx.check(lock_same_name, same, "the two locks differ");
    if (same) {
        cx.check(try std.fmt.allocPrint(cx.a, "lock: the locks differ only in a newer release of {s}, which another run published meanwhile", .{try std.mem.join(cx.a, ", ", superseded.items)}), true, "");
    }
}

fn isNewerSameMajor(got: []const u8, want: []const u8) bool {
    const g = semver.parseVersion(got) orelse return false;
    const w = semver.parseVersion(want) orelse return false;
    return g.major == w.major and semver.compare(g, w) == .gt;
}

/// Replace the file of member `index` of a staged set by `bytes`, and say so in plan.json (the file's sha256 and size).
fn replaceStaged(cx: *Cx, staged: []const u8, index: usize, filename: []const u8, bytes: []const u8) !void {
    try h.writeFile(try cx.join(&.{ staged, subdir, filename }), bytes);
    const plan_path = try cx.join(&.{ staged, "plan.json" });
    var doc = try std.json.parseFromSliceLeaky(std.json.Value, cx.a, try h.readFile(cx.a, plan_path), .{});
    const mem = &doc.object.getPtr("members").?.array.items[index];
    const file = &mem.object.getPtr("files").?.array.items[0];
    try file.object.put("sha256", .{ .string = try cx.a.dupe(u8, &sha256Hex(bytes)) });
    try file.object.put("size", .{ .integer = @intCast(bytes.len) });
    try h.writeFile(plan_path, try std.json.stringifyAlloc(cx.a, doc, .{}));
}

/// Step 3. A staged set of two where one file is not a package.
fn rejectedStep(cx: *Cx) !void {
    const L = "rejected";
    if (cx.o.mopm == null) {
        cx.fail("rejected: --mopm names the CLI", "no --mopm");
        return;
    }
    const art = (try artifacts(cx)) orelse return;
    const ver = try versionOf(cx.a, .rejected, cx.o.run_id, cx.o.attempt);
    const names = members[0..2];
    const ws = try cx.join(&.{ cx.o.work, "ws_rejected" });
    const staged = try cx.join(&.{ cx.o.work, "staged_rejected" });
    try writeWorkspace(cx.a, ws, ver, names);
    const staged_pkgs = (try stageStep(cx, L, ws, art, staged, names)) orelse return;
    const bad_bytes = try std.fmt.allocPrint(cx.a, "this is not a conda package: {s} {s}\n", .{ pkg_mid, ver });
    try replaceStaged(cx, staged, 1, staged_pkgs[1].file_name, bad_bytes);
    var pkgs = try cx.a.dupe(Pkg, staged_pkgs);
    pkgs[1].bytes = bad_bytes;
    pkgs[1].sha256 = try cx.a.dupe(u8, &sha256Hex(bad_bytes));

    const res = try publishRun(cx, staged, pkgs, false);
    cx.check("rejected: mopm publish --staged ends 1 and publishes nothing", res.code == 1, try std.fmt.allocPrint(cx.a, "exit {d}: {s}", .{ res.code, tailOf(res.text) }));
    const id = res.group_id;
    const g: ?Group = if (id.len > 0) (try cx.getGroup(id)) else null;
    if (g != null and std.mem.eql(u8, g.?.status, "open")) {
        // The publish stopped before the commit: the group is still open, and must not hold a slot until its deadline.
        cx.check("rejected: the group ends rejected", false, "status open");
        abort(cx, id);
        return;
    }
    const status = if (g) |x| x.status else "(no group)";
    cx.check("rejected: the group ends rejected", std.mem.eql(u8, status, "rejected"), try std.fmt.allocPrint(cx.a, "status {s}", .{status}));
    if (g != null and g.?.failure != null) {
        const f = g.?.failure.?;
        cx.check("rejected: the failure names the member that is not a package", f.member != null and std.mem.eql(u8, f.member.?, pkg_mid) and f.code.len > 0, try std.fmt.allocPrint(cx.a, "code {s}, member {s}", .{ f.code, f.member orelse "(none)" }));
    } else {
        cx.check("rejected: the failure names the member that is not a package", false, "no failure on the group");
    }
    var reported = false;
    if (res.report) |r| {
        reported = r.members.len == 2 and std.mem.eql(u8, r.members[1].name, pkg_mid) and std.mem.eql(u8, r.members[1].outcome, "rejected") and !std.mem.eql(u8, r.members[0].outcome, "published");
    }
    cx.check("rejected: report.json names the rejected member and publishes none", reported, "report.json lacks the rejected member");
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
    if (id.len > 0) {
        const again = try cx.api(.DELETE, try std.fmt.allocPrint(cx.a, "/groups/{s}", .{id}), null);
        cx.check("rejected: an ended group cannot be aborted", again.status == 409, try std.fmt.allocPrint(cx.a, "HTTP {d}", .{again.status}));
    }
}

fn yankState(cx: *Cx, id: []const u8, want: []const u8) !bool {
    const Try = struct { cx: *Cx, id: []const u8, want: []const u8 };
    const once = struct {
        fn call(t: Try) anyerror!bool {
            const g = (try t.cx.getGroup(t.id)) orelse return false;
            return g.yank != null and std.mem.eql(u8, g.yank.?.state, t.want);
        }
    }.call;
    return pollUntil(cx.o.clock, cx.o.wait_ms, cx.o.poll_ms, Try, .{ .cx = cx, .id = id, .want = want }, once);
}

/// Step 4. The chain group, yanked as a whole and restored.
fn yankStep(cx: *Cx, chain: Chain) !void {
    const p = try std.fmt.allocPrint(cx.a, "/groups/{s}/yank", .{chain.id});
    const yank = try cx.api(.PUT, p, "{\"yanked\":true,\"reason\":\"group end-to-end check\"}");
    cx.check("yank: the group yank is accepted", yank.status == 202 or yank.status == 200, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ yank.status, excerpt(yank.body) }));
    if (yank.status != 202 and yank.status != 200) return;
    cx.check("yank: the group reaches yanked", try yankState(cx, chain.id, "yanked"), "yank.state did not reach yanked");
    try readBack(cx, "yank", chain.pkgs, "yanked");
    const restore = try cx.api(.PUT, p, "{\"yanked\":false}");
    cx.check("unyank: the group unyank is accepted", restore.status == 202 or restore.status == 200, try std.fmt.allocPrint(cx.a, "HTTP {d}: {s}", .{ restore.status, excerpt(restore.body) }));
    if (restore.status != 202 and restore.status != 200) return;
    cx.check("unyank: the group reaches restored", try yankState(cx, chain.id, "restored"), "yank.state did not reach restored");
    try readBack(cx, "unyank", chain.pkgs, "published");
}

/// Everything, in order. The result says whether it ran and the one line it ends with.
pub fn run(a: Allocator, rep: *h.Report, given: Opts) !Result {
    // The children start in other directories: every path they are given is absolute.
    var o = given;
    o.work = try absolute(a, o.work);
    if (o.mopm) |p| o.mopm = try absolute(a, p);
    if (o.pixi) |p| o.pixi = try absolute(a, p);
    if (o.mojo_env) |p| o.mojo_env = try absolute(a, p);
    if (o.prebuilt) |p| o.prebuilt = try absolute(a, p);
    var cx = Cx{ .a = a, .rep = rep, .o = o, .notes = std.ArrayList([]const u8).init(a), .empty = std.process.EnvMap.init(a) };
    if (std.mem.eql(u8, o.stage, "prod")) return skipped(a, o, .prod, "this check never runs on prod");
    if (std.mem.trim(u8, o.token, token_separators).len == 0) return skipped(a, o, .no_secret, "the repository secret " ++ secret_name ++ " is not set");
    cx.token = tokenFor(o.token, o.stage);
    if (cx.token.len == 0) {
        return skipped(a, o, .no_stage_token, try std.fmt.allocPrint(a, "the repository secret " ++ secret_name ++ " holds no token for {s}", .{o.stage}));
    }

    const before = rep.failures;
    // An error out of a step (the registry did not answer, an answer was not JSON) is a failed check, not a crash.
    const not_enabled = walk(&cx) catch |e| blk: {
        cx.check("the walk ends without an error", false, @errorName(e));
        break :blk false;
    };
    if (not_enabled) return skipped(a, o, .groups_off, "group publishing is not enabled for the e2e actor on this stage (creating a group answered route_not_found)");
    return finish(&cx, before);
}

/// `p` as an absolute path when it names a file (it has a slash); a bare name is left to the PATH.
pub fn absolute(a: Allocator, p: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, p, '/') == null or std.fs.path.isAbsolute(p)) return p;
    return std.fs.path.resolve(a, &.{ try std.process.getCwdAlloc(a), p });
}

/// The job summary of a run that did nothing: loud, with the reason.
pub fn skipSummary(a: Allocator, stage: []const u8, line: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "### group end-to-end, {s}: SKIPPED\n\n{s}\n\nNothing was published and nothing was checked on this stage. The job is green because it did nothing; it will fail, not skip, once the secret holds a token for {s} and the stage has groups on.\n\n", .{ stage, line, stage });
}

/// A run that did nothing, and says so on one line, in the job summary too.
fn skipped(a: Allocator, o: Opts, reason: SkipReason, why: []const u8) !Result {
    const line = try std.fmt.allocPrint(a, "group-e2e: SKIP {s}: {s}", .{ o.stage, why });
    if (o.summary) |path| try appendTo(path, try skipSummary(a, o.stage, line));
    return .{ .skipped = true, .skip_reason = reason, .line = line, .checks = 0, .failures = 0 };
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

const usage = "usage: mopm-group-e2e --stage beta|gamma --mopm <exe> --work <dir> --run-id <n> --attempt <n> --pixi <exe> [--pixi-manifest <pixi.toml> | --mojo-env <prefix>] [--registry <name|url>] [--summary <file>] [--wait-seconds <n>]\n";

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
    pixi: ?[]const u8 = null,
    pixi_manifest: ?[]const u8 = null,
    mojo_env: ?[]const u8 = null,
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
        } else if (std.mem.eql(u8, flag, "--pixi")) {
            out.pixi = value;
        } else if (std.mem.eql(u8, flag, "--pixi-manifest")) {
            out.pixi_manifest = value;
        } else if (std.mem.eql(u8, flag, "--mojo-env")) {
            out.mojo_env = value;
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
        .pixi = args.pixi,
        .pixi_manifest = args.pixi_manifest,
        .mojo_env = args.mojo_env,
    });
    std.debug.print("{s}\n", .{result.line});
    // A skip is loud: a workflow annotation names the reason, so a green job that did nothing is not mistaken for a pass.
    if (result.skipped) std.io.getStdOut().writer().print("::warning title=group-e2e SKIPPED on {s}::{s}\n", .{ args.stage, result.line }) catch {};
    if (result.failures != 0) std.process.exit(1);
}

fn usageExit() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
