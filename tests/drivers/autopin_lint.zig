//! The lint of the Dependabot autopin workflows, run by Buck2 (//:autopin_workflows) and by lint.yml. Its messages read
//! (`autopin-lint: <file>: ...`).
//!
//! Three workflows keep the pin tables of a Dependabot pull request current without a person:
//!   autopin-compute.yml  pull_request, unprivileged: regenerates the tables with the released `buildrules` and uploads them;
//!   autopin-commit.yml   workflow_run, privileged:   re-checks the artifact as untrusted bytes, then commits with the App's token;
//!   pin-verify.yml       pull_request, secretless:   the required check that the tables agree with the lockfiles.
//! `fileProblems` holds each of them to its own rules (the gate, the scope of every token, the order of the steps, the artifact's
//! name). `repoProblems` holds the rules that need the other files: R1-R4 over every workflow (which triggers may exist, what a
//! pull_request workflow may touch, the farm's Dependabot skip), M2/M2b (what the lints can read), no workflow that merges or
//! approves a Dependabot pull request, unique workflow names, and one tool pin and one SETS list across the three files.
//!
//! autopin_lint_test.zig runs every rule on the real files and on a planted mutant that must turn it red.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

pub const prefix = "autopin-lint: ";

pub const compute_file = "autopin-compute.yml";
pub const commit_file = "autopin-commit.yml";
pub const verify_file = "pin-verify.yml";
const autopin_files = [_][]const u8{ compute_file, commit_file, verify_file };

pub const compute_name = "autopin-compute";
pub const artifact_name = "autopin-${{ github.run_id }}-${{ github.run_attempt }}";
const environment_name = "autopin";
const key_secret = "AUTOPIN_APP_PRIVATE_KEY";
const farm_file = "farm.yml";
/// The autopin App's bot: its login and the noreply address of its user (the id is the bot user's, not the App's).
const bot_login = "komira-autopin[bot]";
const bot_email = "345942487+komira-autopin[bot]@users.noreply.github.com";

/// The job-level gate of autopin-compute.yml: Dependabot's pull request, run for Dependabot, from a branch of this repository.
/// The actor conjunct is the one that stops the loop (the App's push has the pull request's author but not its actor).
pub const compute_gate = [_][]const u8{
    "github.event.pull_request.user.login == 'dependabot[bot]'",
    "github.actor == 'dependabot[bot]'",
    "github.triggering_actor == 'dependabot[bot]'",
    "github.event.pull_request.head.repo.id == github.event.repository.id",
    "github.event.pull_request.head.repo.full_name == github.repository",
};

/// The job-level gate of autopin-commit.yml, evaluated before the environment is entered.
pub const commit_gate = [_][]const u8{
    "github.event.workflow_run.conclusion == 'success'",
    "github.event.workflow_run.event == 'pull_request'",
    "github.event.workflow_run.path == '.github/workflows/autopin-compute.yml'",
    "github.event.workflow_run.head_repository.id == github.event.repository.id",
    "github.event.workflow_run.head_repository.full_name == github.repository",
    "github.event.workflow_run.actor.login == 'dependabot[bot]'",
    "github.event.workflow_run.triggering_actor.login == 'dependabot[bot]'",
};

// ---- small readers ------------------------------------------------------------------------

const KV = struct { k: []const u8, v: []const u8 };

fn isHex(s: []const u8, n: usize) bool {
    if (s.len != n) return false;
    for (s) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    return true;
}

/// `<name>@<40 hex digits>`.
fn pinnedUses(u: []const u8, name: []const u8) bool {
    return std.mem.startsWith(u8, u, name) and u.len == name.len + 41 and u[name.len] == '@' and isHex(u[name.len + 1 ..], 40);
}

fn isFalse(v: ?Value) bool {
    const n = v orelse return false;
    return switch (n) {
        .bool => |b| !b,
        .string => |s| std.mem.eql(u8, s, "false"),
        else => false,
    };
}

fn isInt(v: ?Value, want: i64) bool {
    const n = v orelse return false;
    return n == .integer and n.integer == want;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Both lists hold the same strings, in any order.
fn sameSet(a: Allocator, x: []const []const u8, y: []const []const u8) !bool {
    const sx = try a.dupe([]const u8, x);
    const sy = try a.dupe([]const u8, y);
    std.mem.sort([]const u8, sx, {}, lessThan);
    std.mem.sort([]const u8, sy, {}, lessThan);
    return c.eqlList(sx, sy);
}

/// A mapping with exactly these keys and string values.
fn mapIs(v: ?Value, want: []const KV) bool {
    const n = v orelse return false;
    if (n != .object or n.object.count() != want.len) return false;
    for (want) |kv| if (!c.isStr(n.object.get(kv.k), kv.v)) return false;
    return true;
}

fn stepsOf(job: Value) []const Value {
    const s = c.get(job, "steps") orelse return &.{};
    if (s != .array) return &.{};
    return s.array.items;
}

fn runOf(st: Value) ?[]const u8 {
    return c.str(c.get(st, "run"));
}

fn usesOf(st: Value) ?[]const u8 {
    return c.str(c.get(st, "uses"));
}

fn nth(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, needle)) |i| : (from = i + 1) n += 1;
    return n;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// `--flag` as a word of its own: `--auto` is not `--author-name`.
fn hasFlag(s: []const u8, flag: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, flag)) |i| : (from = i + 1) {
        const j = i + flag.len;
        if (j >= s.len or !(c.isAlnum(s[j]) or s[j] == '-' or s[j] == '_')) return true;
    }
    return false;
}

const Job = struct { name: []const u8, node: Value };

fn jobList(a: Allocator, doc: Value) ![]const Job {
    var out = std.ArrayList(Job).init(a);
    const jobs = c.get(doc, "jobs") orelse return out.items;
    if (jobs != .object) return out.items;
    var it = jobs.object.iterator();
    while (it.next()) |e| try out.append(.{ .name = e.key_ptr.*, .node = e.value_ptr.* });
    return out.items;
}

/// The one job of a workflow whose jobs must be exactly one.
fn soleJob(a: Allocator, f: []const u8, doc: Value, out: *Out) !?Job {
    const jobs = try jobList(a, doc);
    if (jobs.len != 1) {
        try c.problem(a, out, prefix ++ "{s}: expected exactly one job, found {d}", .{ f, jobs.len });
        return null;
    }
    return jobs[0];
}

// ---- the gate ---------------------------------------------------------------------------------

/// `${{ a && b && c }}` as its conjuncts.
fn conjuncts(a: Allocator, expr: []const u8) ![]const []const u8 {
    var e = std.mem.trim(u8, expr, " \r\n\t");
    if (std.mem.startsWith(u8, e, "${{") and std.mem.endsWith(u8, e, "}}")) e = std.mem.trim(u8, e[3 .. e.len - 2], " \r\n\t");
    var parts = std.ArrayList([]const u8).init(a);
    var it = std.mem.splitSequence(u8, e, " && ");
    while (it.next()) |p| try parts.append(std.mem.trim(u8, p, " "));
    return parts.items;
}

/// The job-level `if:` is exactly the conjunction `want`: each conjunct there, none extra, no `||`. At JOB level, so that a run that
/// fails it never starts a step (for the commit job: never enters the environment that holds the App's key).
fn gateProblems(a: Allocator, f: []const u8, job: Job, want: []const []const u8, out: *Out) !void {
    const expr = c.str(c.get(job.node, "if")) orelse {
        try c.problem(a, out, prefix ++ "{s}: job {s} has no job-level `if:`: the gate must be at job level, where a failing run starts no step", .{ f, job.name });
        return;
    };
    if (contains(expr, "||")) try c.problem(a, out, prefix ++ "{s}: job {s}: the gate must be a conjunction, but it has `||`", .{ f, job.name });
    const got = try conjuncts(a, expr);
    for (want) |w| {
        if (!c.containsStr(got, w)) try c.problem(a, out, prefix ++ "{s}: job {s}: the gate lacks `{s}`", .{ f, job.name, w });
    }
    for (got) |g| {
        if (!c.containsStr(want, g)) try c.problem(a, out, prefix ++ "{s}: job {s}: the gate has the extra clause `{s}`", .{ f, job.name, g });
    }
}

// ---- the tool pin ----------------------------------------------------------------------------------

pub const Pin = struct { version: []const u8, sha256: []const u8 };

fn semver3(s: []const u8) bool {
    var parts: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        parts += 1;
        if (p.len == 0) return false;
        for (p) |ch| if (ch < '0' or ch > '9') return false;
    }
    return parts == 3;
}

const download_prefix = "https://github.com/komira-ai/buildrules/releases/download/v${BUILDRULES_VERSION}/";

/// The step that fetches the released tool: a literal version and sha256 in its env, the download from buildrules' releases by that
/// version, `sha256sum -c` between the download and the unpacking, and nothing that builds the tool. Exactly one such step per file.
fn toolPin(a: Allocator, f: []const u8, doc: Value, out: *Out) !?Pin {
    var found: ?Pin = null;
    var count: usize = 0;
    for (try jobList(a, doc)) |job| {
        for (stepsOf(job.node), 0..) |st, i| {
            const run = runOf(st) orelse continue;
            if (!contains(run, "releases/download")) continue;
            count += 1;
            const env = c.get(st, "env");
            const version = c.str(c.get(env, "BUILDRULES_VERSION")) orelse "";
            const sha = c.str(c.get(env, "BUILDRULES_SHA256")) orelse "";
            if (!semver3(version)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: env BUILDRULES_VERSION must be a literal X.Y.Z, got \"{s}\"", .{ f, job.name, i, version });
            if (!isHex(sha, 64)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: env BUILDRULES_SHA256 must be a literal of 64 lowercase hex digits", .{ f, job.name, i });
            if (!contains(run, download_prefix)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the download must be `{s}...` (buildrules' release of the pinned version)", .{ f, job.name, i, download_prefix });
            const curl = std.mem.indexOf(u8, run, "curl ");
            const check = std.mem.indexOf(u8, run, "sha256sum -c");
            const tar = std.mem.indexOf(u8, run, "tar ");
            if (curl == null) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the tool is not fetched with curl", .{ f, job.name, i });
            if (check == null) {
                try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the tool is fetched without `sha256sum -c`", .{ f, job.name, i });
            } else {
                if (curl != null and check.? < curl.?) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: `sha256sum -c` comes before the download", .{ f, job.name, i });
                if (tar != null and tar.? < check.?) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the tool is unpacked before `sha256sum -c`", .{ f, job.name, i });
            }
            for ([_][]const u8{ "cargo ", "zig build", "buck2", "git clone", "make " }) |builder| {
                if (contains(run, builder)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the tool is fetched, never built (`{s}`)", .{ f, job.name, i, std.mem.trim(u8, builder, " ") });
            }
            found = .{ .version = version, .sha256 = sha };
        }
    }
    if (count != 1) try c.problem(a, out, prefix ++ "{s}: expected exactly one step that fetches the tool from buildrules' releases, found {d}", .{ f, count });
    return found;
}

// ---- what a run script may hold ------------------------------------------------------------------

const unprivileged_words = [_][]const u8{ "npm", "node", "npx", "buck2" };
const commit_words = [_][]const u8{ "npm", "node", "npx", "buck2", "git", "gh", "jq", "unzip" };

/// Event data and the head ref reach a script through env, never by name; and no word of the list (the pull request's code must never be
/// run, and in the commit job nothing but the tool touches the artifact).
fn runProblems(a: Allocator, f: []const u8, jn: []const u8, i: usize, run: []const u8, words: []const []const u8, out: *Out) !void {
    if (contains(run, "github.event") or contains(run, "github.head_ref")) {
        try c.problem(a, out, prefix ++ "{s}: {s} step {d}: a run script reads github.event or github.head_ref; they do not reach a script", .{ f, jn, i });
    }
    if (c.hasAnyWord(run, words)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: a run script uses one of {s}", .{ f, jn, i, try c.inspectList(a, words) });
}

/// The files a step may append to are the way a pull request's strings reach later steps: the compute job writes none.
fn envFileProblems(a: Allocator, f: []const u8, jn: []const u8, i: usize, run: []const u8, out: *Out) !void {
    for ([_][]const u8{ "GITHUB_ENV", "GITHUB_OUTPUT", "GITHUB_PATH", "GITHUB_STEP_SUMMARY" }) |name| {
        if (contains(run, name)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: writes {s}; no string derived from a pull request may reach a later step", .{ f, jn, i, name });
    }
}

/// What neither the compute job nor the pin-verify job holds: a secret, an environment, an id-token, a cache, a step that may fail
/// quietly.
fn unprivilegedProblems(a: Allocator, f: []const u8, doc: Value, text: []const u8, out: *Out) !void {
    if (c.findKey(doc, "environment")) try c.problem(a, out, prefix ++ "{s}: an environment is for autopin-commit.yml alone", .{f});
    if (c.findKey(doc, "id-token")) try c.problem(a, out, prefix ++ "{s}: no id-token", .{f});
    const body = try c.nonCommentLines(a, text);
    if (c.mentionsSecretsDot(body) or c.hasSecretsInherit(body)) try c.problem(a, out, prefix ++ "{s}: no secrets (this job runs for a pull request)", .{f});
    if (c.findKey(doc, "cache") or c.findKey(doc, "cache-dependency-path") or contains(body, "actions/cache") or contains(body, "/setup-")) {
        try c.problem(a, out, prefix ++ "{s}: no cache and no setup-* action (a poisoned cache would outlive the run)", .{f});
    }
    if (c.findKey(doc, "continue-on-error")) try c.problem(a, out, prefix ++ "{s}: no continue-on-error: a step that fails must fail the check", .{f});
}

fn triggerIs(a: Allocator, f: []const u8, doc: Value, want: []const u8, out: *Out) !void {
    const on = try c.onKeys(a, doc);
    if (!c.eqlList(on, &.{want})) try c.problem(a, out, prefix ++ "{s}: the trigger must be exactly {s}, got {s}", .{ f, want, try c.inspectList(a, on) });
}

fn timeoutProblem(a: Allocator, f: []const u8, job: Job, out: *Out) !void {
    if (!isInt(c.get(job.node, "timeout-minutes"), 15)) try c.problem(a, out, prefix ++ "{s}: job {s} needs `timeout-minutes: 15`", .{ f, job.name });
}

// ---- the per-file rules ---------------------------------------------------------------------------

/// What a file says that another file must agree with.
pub const Facts = struct {
    pin: ?Pin = null,
    /// One list of `--set` arguments for each run script that has any (compute: 1, commit: 2, pin-verify: 1).
    sets: []const []const []const u8 = &.{},
};

/// The `--set` arguments of the run scripts of a document, one list per script that has any.
fn setsOf(a: Allocator, doc: Value) ![]const []const []const u8 {
    var lists = std.ArrayList([]const []const u8).init(a);
    for (try jobList(a, doc)) |job| {
        for (stepsOf(job.node)) |st| {
            const run = runOf(st) orelse continue;
            var one = std.ArrayList([]const u8).init(a);
            var words = std.mem.tokenizeAny(u8, run, " \t\r\n");
            var after = false;
            while (words.next()) |w| {
                if (after) try one.append(w);
                after = std.mem.eql(u8, w, "--set");
            }
            if (one.items.len != 0) try lists.append(one.items);
        }
    }
    return lists.items;
}

/// A step that uses `name` (a full-SHA pin) and its index.
fn stepUsing(job: Value, name: []const u8) ?struct { i: usize, st: Value } {
    for (stepsOf(job), 0..) |st, i| {
        const u = usesOf(st) orelse continue;
        if (std.mem.startsWith(u8, u, name)) return .{ .i = i, .st = st };
    }
    return null;
}

fn computeFile(a: Allocator, f: []const u8, doc: Value, text: []const u8, out: *Out) !Facts {
    try triggerIs(a, f, doc, "pull_request", out);
    const pr = c.get(c.onValue(doc), "pull_request");
    if (pr == null or pr.? != .object or pr.?.object.count() != 1 or !(try sameSet(a, try c.arrayOf(a, c.get(pr, "types")), &.{ "opened", "synchronize", "reopened" }))) {
        try c.problem(a, out, prefix ++ "{s}: pull_request must have exactly `types: opened, synchronize, reopened` and no filter", .{f});
    }
    if (!c.isStr(c.get(doc, "name"), compute_name)) try c.problem(a, out, prefix ++ "{s}: the workflow's name must be {s} (autopin-commit.yml names it)", .{ f, compute_name });
    if (!mapIs(c.get(doc, "permissions"), &.{.{ .k = "contents", .v = "read" }})) try c.problem(a, out, prefix ++ "{s}: the top-level permissions must be exactly `contents: read`", .{f});
    try unprivilegedProblems(a, f, doc, text, out);

    const job = (try soleJob(a, f, doc, out)) orelse return .{};
    if (!mapIs(c.get(job.node, "permissions"), &.{.{ .k = "contents", .v = "read" }})) try c.problem(a, out, prefix ++ "{s}: job {s}: permissions must be exactly `contents: read`", .{ f, job.name });
    try timeoutProblem(a, f, job, out);
    try gateProblems(a, f, job, &compute_gate, out);

    // The checkout is the pull request's head, read through `with:`, and keeps no credential.
    const steps = stepsOf(job.node);
    const first = if (steps.len > 0) steps[0] else Value{ .null = {} };
    const co = usesOf(first) orelse "";
    if (!pinnedUses(co, "actions/checkout")) {
        try c.problem(a, out, prefix ++ "{s}: job {s}: the first step must be actions/checkout pinned by full SHA", .{ f, job.name });
    } else {
        const with = c.get(first, "with");
        if (!c.isStr(c.get(with, "ref"), "${{ github.event.pull_request.head.sha }}")) {
            try c.problem(a, out, prefix ++ "{s}: job {s}: the checkout's `with: ref` must be `${{{{ github.event.pull_request.head.sha }}}}`", .{ f, job.name });
        }
        if (!isFalse(c.get(with, "persist-credentials"))) try c.problem(a, out, prefix ++ "{s}: job {s}: the checkout must set `persist-credentials: false`", .{ f, job.name });
    }
    for (steps, 0..) |st, i| {
        if (i > 0) if (usesOf(st)) |u| if (std.mem.startsWith(u8, u, "actions/checkout")) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: one checkout only", .{ f, job.name, i });
        const run = runOf(st) orelse continue;
        try runProblems(a, f, job.name, i, run, &unprivileged_words, out);
        try envFileProblems(a, f, job.name, i, run, out);
    }

    // The artifact: named by run and attempt, never overwritten, an empty upload an error.
    if (stepUsing(job.node, "actions/upload-artifact")) |up| {
        if (!pinnedUses(usesOf(up.st).?, "actions/upload-artifact")) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: upload-artifact must be pinned by full SHA", .{ f, job.name, up.i });
        const with = c.get(up.st, "with");
        if (!c.isStr(c.get(with, "name"), artifact_name)) {
            try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the artifact's name must be `{s}` (the run and its attempt)", .{ f, job.name, up.i, artifact_name });
        }
        if (!isFalse(c.get(with, "overwrite"))) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the artifact must be uploaded with `overwrite: false` (a clash fails the step)", .{ f, job.name, up.i });
        if (!c.isStr(c.get(with, "if-no-files-found"), "error")) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: the upload needs `if-no-files-found: error`", .{ f, job.name, up.i });
    } else {
        try c.problem(a, out, prefix ++ "{s}: job {s} uploads no artifact", .{ f, job.name });
    }
    var runs_tool = false;
    for (steps) |st| if (runOf(st)) |r| {
        if (contains(r, "autopin compute")) runs_tool = true;
    };
    if (!runs_tool) try c.problem(a, out, prefix ++ "{s}: no step runs `buildrules autopin compute`", .{f});
    return .{ .pin = try toolPin(a, f, doc, out), .sets = try setsOf(a, doc) };
}

fn commitFile(a: Allocator, f: []const u8, doc: Value, text: []const u8, out: *Out) !Facts {
    // The trigger: the end of the compute workflow, and nothing else.
    try triggerIs(a, f, doc, "workflow_run", out);
    const wr = c.get(c.onValue(doc), "workflow_run");
    if (wr == null or wr.? != .object or wr.?.object.count() != 2 or !c.eqlList(try c.arrayOf(a, c.get(wr, "workflows")), &.{compute_name}) or !c.eqlList(try c.arrayOf(a, c.get(wr, "types")), &.{"completed"})) {
        try c.problem(a, out, prefix ++ "{s}: workflow_run must be exactly `workflows: [{s}]` and `types: [completed]`", .{ f, compute_name });
    }
    // Nothing by default: the top level grants no permission.
    const top = c.get(doc, "permissions");
    var top_none = top != null and top.? == .object;
    if (top_none) for (top.?.object.values()) |v| {
        if (!c.isStr(v, "none")) top_none = false;
    };
    if (!top_none) try c.problem(a, out, prefix ++ "{s}: the top-level permissions must grant nothing (every value `none`)", .{f});

    const job = (try soleJob(a, f, doc, out)) orelse return .{};
    try timeoutProblem(a, f, job, out);
    try gateProblems(a, f, job, &commit_gate, out);
    if (!c.isStr(c.get(job.node, "environment"), environment_name)) try c.problem(a, out, prefix ++ "{s}: job {s} must declare `environment: {s}` (the App's key and id live there)", .{ f, job.name, environment_name });
    if (!mapIs(c.get(job.node, "permissions"), &.{ .{ .k = "actions", .v = "read" }, .{ .k = "contents", .v = "read" }, .{ .k = "pull-requests", .v = "read" } })) {
        try c.problem(a, out, prefix ++ "{s}: job {s}: permissions must be exactly actions, contents and pull-requests, all read (the writes are the App token's)", .{ f, job.name });
    }
    if (c.findKey(doc, "id-token")) try c.problem(a, out, prefix ++ "{s}: no id-token", .{f});
    if (c.findKey(doc, "continue-on-error")) try c.problem(a, out, prefix ++ "{s}: no continue-on-error: a failed commit must fail the job, loudly", .{f});

    // One commit at a time per pull request, never cancelled; the branch name stays in the expression.
    const conc = c.get(job.node, "concurrency");
    const group = c.str(c.get(conc, "group")) orelse "";
    if (!contains(group, "${{ github.event.workflow_run.head_branch }}") or !std.mem.startsWith(u8, group, "autopin-commit-") or !isFalse(c.get(conc, "cancel-in-progress"))) {
        try c.problem(a, out, prefix ++ "{s}: job {s}: concurrency must be `group: autopin-commit-${{{{ github.event.workflow_run.head_branch }}}}` with `cancel-in-progress: false` (one commit at a time per pull request)", .{ f, job.name });
    }
    const body = try c.nonCommentLines(a, text);
    if (nth(body, "head_branch") != 1) try c.problem(a, out, prefix ++ "{s}: head_branch may appear only in the concurrency group's expression, never in a script or an env", .{f});

    // No checkout of any code, no local action.
    for (stepsOf(job.node), 0..) |st, i| {
        const u = usesOf(st) orelse continue;
        if (std.mem.startsWith(u8, u, "actions/checkout") or std.mem.startsWith(u8, u, "./")) {
            try c.problem(a, out, prefix ++ "{s}: {s} step {d}: no checkout and no local action: nothing from the pull request runs here", .{ f, job.name, i });
        }
    }

    // The order: check (default token), mint (only if there is something to commit), push (the App token).
    var check_i: ?usize = null;
    var mint_i: ?usize = null;
    var push_i: ?usize = null;
    var mints: usize = 0;
    for (stepsOf(job.node), 0..) |st, i| {
        if (usesOf(st)) |u| if (std.mem.startsWith(u8, u, "actions/create-github-app-token")) {
            mints += 1;
            mint_i = i;
        };
        if (runOf(st)) |r| {
            try runProblems(a, f, job.name, i, r, &commit_words, out);
            if (contains(r, "autopin commit-check")) check_i = i;
            if (contains(r, "autopin commit-push")) push_i = i;
        }
    }
    if (mints != 1) try c.problem(a, out, prefix ++ "{s}: job {s}: the App token is minted by exactly one step, found {d}", .{ f, job.name, mints });
    if (check_i == null) try c.problem(a, out, prefix ++ "{s}: no step runs `buildrules autopin commit-check`", .{f});
    if (push_i == null) try c.problem(a, out, prefix ++ "{s}: no step runs `buildrules autopin commit-push`", .{f});
    if (check_i != null and mint_i != null and mint_i.? < check_i.?) try c.problem(a, out, prefix ++ "{s}: the App token is minted before `commit-check`; it may only be minted after the check passed", .{f});
    if (push_i != null and mint_i != null and push_i.? < mint_i.?) try c.problem(a, out, prefix ++ "{s}: `commit-push` runs before the App token is minted", .{f});

    const steps = stepsOf(job.node);
    var check_id: []const u8 = "";
    var mint_id: []const u8 = "";
    if (check_i) |ci| {
        const st = steps[ci];
        check_id = c.str(c.get(st, "id")) orelse "";
        if (check_id.len == 0) try c.problem(a, out, prefix ++ "{s}: the commit-check step needs an `id:` (the later steps read its has_change)", .{f});
        if (!c.isStr(c.get(c.get(st, "env"), "GH_TOKEN"), "${{ github.token }}")) try c.problem(a, out, prefix ++ "{s}: commit-check holds the default token alone: `GH_TOKEN: ${{{{ github.token }}}}`", .{f});
        if (c.truthy(c.get(st, "if"))) try c.problem(a, out, prefix ++ "{s}: the commit-check step has no condition", .{f});
    }
    if (mint_i) |mi| {
        const st = steps[mi];
        mint_id = c.str(c.get(st, "id")) orelse "";
        if (mint_id.len == 0) try c.problem(a, out, prefix ++ "{s}: the mint step needs an `id:`", .{f});
        if (!pinnedUses(usesOf(st).?, "actions/create-github-app-token")) try c.problem(a, out, prefix ++ "{s}: the mint step must be pinned by full SHA", .{f});
        const with = c.get(st, "with");
        if (!c.isStr(c.get(with, "permission-contents"), "write")) try c.problem(a, out, prefix ++ "{s}: the token is minted with `permission-contents: write`", .{f});
        for (c.keys(with)) |k| {
            if (std.mem.startsWith(u8, k, "permission-") and !std.mem.eql(u8, k, "permission-contents")) try c.problem(a, out, prefix ++ "{s}: the token is minted with contents write only, not {s}", .{ f, k });
        }
        if (!c.isStr(c.get(with, "repositories"), "${{ github.event.repository.name }}")) try c.problem(a, out, prefix ++ "{s}: the token is for this repository alone: `repositories: ${{{{ github.event.repository.name }}}}`", .{f});
        if (!c.isStr(c.get(with, "private-key"), "${{ secrets." ++ key_secret ++ " }}")) try c.problem(a, out, prefix ++ "{s}: the mint step reads the key as `${{{{ secrets.{s} }}}}`", .{ f, key_secret });
        if (nth(body, "secrets.") != 1) try c.problem(a, out, prefix ++ "{s}: the key is named by the mint step alone", .{f});
        const want_if = try std.fmt.allocPrint(a, "${{{{ steps.{s}.outputs.has_change == 'true' }}}}", .{check_id});
        if (check_i != null and !c.isStr(c.get(st, "if"), want_if)) try c.problem(a, out, prefix ++ "{s}: the mint step runs only `if: {s}`", .{ f, want_if });
    }
    if (push_i) |pi| {
        const st = steps[pi];
        const want_if = try std.fmt.allocPrint(a, "${{{{ steps.{s}.outputs.has_change == 'true' }}}}", .{check_id});
        if (check_i != null and !c.isStr(c.get(st, "if"), want_if)) try c.problem(a, out, prefix ++ "{s}: the commit-push step runs only `if: {s}`", .{ f, want_if });
        // The author and committer of the commit are the App's bot, written out: its real user id, not derived from a variable.
        const run = runOf(st) orelse "";
        if (!contains(run, "--author-name \"" ++ bot_login ++ "\"") or !contains(run, "--author-email \"" ++ bot_email ++ "\"")) {
            try c.problem(a, out, prefix ++ "{s}: commit-push must set `--author-name \"{s}\"` and `--author-email \"{s}\"` as literals", .{ f, bot_login, bot_email });
        }
        const want_token = try std.fmt.allocPrint(a,"${{{{ steps.{s}.outputs.token }}}}", .{mint_id});
        if (!c.isStr(c.get(c.get(st, "env"), "GH_TOKEN"), want_token)) try c.problem(a, out, prefix ++ "{s}: commit-push holds the App token: `GH_TOKEN: {s}`", .{ f, want_token });
    }
    // The token is a step's own env, never the job's or the workflow's.
    if (c.get(c.get(doc, "env"), "GH_TOKEN") != null or c.get(c.get(job.node, "env"), "GH_TOKEN") != null) {
        try c.problem(a, out, prefix ++ "{s}: GH_TOKEN is set on a step alone, not on the job or the workflow", .{f});
    }
    return .{ .pin = try toolPin(a, f, doc, out), .sets = try setsOf(a, doc) };
}

fn verifyFile(a: Allocator, f: []const u8, doc: Value, text: []const u8, out: *Out) !Facts {
    try triggerIs(a, f, doc, "pull_request", out);
    const pr = c.get(c.onValue(doc), "pull_request");
    if (pr != null and !(pr.? == .null or (pr.? == .object and pr.?.object.count() == 0))) {
        try c.problem(a, out, prefix ++ "{s}: pull_request has no filter and no types: every pull request gets this check", .{f});
    }
    if (!mapIs(c.get(doc, "permissions"), &.{.{ .k = "contents", .v = "read" }})) try c.problem(a, out, prefix ++ "{s}: the top-level permissions must be exactly `contents: read`", .{f});
    try unprivilegedProblems(a, f, doc, text, out);
    if (contains(try c.nonCommentLines(a, text), "github.actor")) try c.problem(a, out, prefix ++ "{s}: the check must not look at the actor: the App's push runs it too", .{f});

    const job = (try soleJob(a, f, doc, out)) orelse return .{};
    // The required check is named by its job: the ruleset asks for the context `pin-verify`.
    if (!std.mem.eql(u8, job.name, "pin-verify") or !c.isStr(c.get(job.node, "name"), "pin-verify")) {
        try c.problem(a, out, prefix ++ "{s}: the job must be `pin-verify` with `name: pin-verify` (the context the ruleset requires)", .{f});
    }
    if (c.get(job.node, "if") != null) try c.problem(a, out, prefix ++ "{s}: job {s} has an `if:`; a skipped check is a check that did not run", .{ f, job.name });
    if (!mapIs(c.get(job.node, "permissions"), &.{.{ .k = "contents", .v = "read" }})) try c.problem(a, out, prefix ++ "{s}: job {s}: permissions must be exactly `contents: read`", .{ f, job.name });
    try timeoutProblem(a, f, job, out);
    var runs_tool = false;
    var fails = false;
    for (stepsOf(job.node), 0..) |st, i| {
        if (c.get(st, "if") != null) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: no step condition: a skipped step is a check that did not run", .{ f, job.name, i });
        const run = runOf(st) orelse continue;
        try runProblems(a, f, job.name, i, run, &unprivileged_words, out);
        try envFileProblems(a, f, job.name, i, run, out);
        if (contains(run, "autopin compute")) runs_tool = true;
        if (runs_tool and contains(run, "exit 1")) fails = true;
    }
    if (!runs_tool) try c.problem(a, out, prefix ++ "{s}: no step runs `buildrules autopin compute`", .{f});
    if (!fails) try c.problem(a, out, prefix ++ "{s}: no step after the tool fails (`exit 1`) when it would write a table", .{f});
    const co = if (stepsOf(job.node).len > 0) usesOf(stepsOf(job.node)[0]) orelse "" else "";
    if (!pinnedUses(co, "actions/checkout")) try c.problem(a, out, prefix ++ "{s}: the first step must be actions/checkout pinned by full SHA", .{f});
    return .{ .pin = try toolPin(a, f, doc, out), .sets = try setsOf(a, doc) };
}

/// The rules of one of the three autopin files; `text` is the file, `f` the name the messages show. The facts it returns (the tool
/// pin, the SETS lists) are what `repoProblems` compares across the three.
pub fn fileProblems(a: Allocator, f: []const u8, text: []const u8, out: *Out) !Facts {
    const base = c.basename(f);
    const doc = c.load(a, text) catch |err| {
        try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ f, @errorName(err) });
        return .{};
    };
    if (std.mem.eql(u8, base, compute_file)) return computeFile(a, f, doc, text, out);
    if (std.mem.eql(u8, base, commit_file)) return commitFile(a, f, doc, text, out);
    return verifyFile(a, f, doc, text, out);
}

// ---- M2: what the lints can read -----------------------------------------------------------------

const top_keys = [_][]const u8{ "name", "run-name", "on", "permissions", "env", "defaults", "concurrency", "jobs" };

/// The tracked files under .github/workflows and .github/actions. The lints read `.yml` files directly under .github/workflows and
/// nothing else, so anything else there (a `.yaml` twin, a subdirectory, a composite action) is a workflow they would not see.
pub fn treeProblems(a: Allocator, files: []const []const u8, out: *Out) !void {
    const dir = ".github/workflows/";
    for (files) |f| {
        if (std.mem.startsWith(u8, f, dir)) {
            const rest = f[dir.len..];
            if (std.mem.indexOfScalar(u8, rest, '/') != null) {
                try c.problem(a, out, prefix ++ "{s}: a subdirectory of .github/workflows is not read by the lints", .{f});
            } else if (!std.mem.endsWith(u8, rest, ".yml")) {
                try c.problem(a, out, prefix ++ "{s}: a workflow file must end in .yml: the lints read nothing else, and GitHub runs the other spellings too", .{f});
            }
        }
        if (std.mem.startsWith(u8, f, ".github/actions/")) {
            try c.problem(a, out, prefix ++ "{s}: a composite action is not read by the lints, and none is listed", .{f});
        }
    }
}

/// M2: a symbolic link under .github/workflows or .github/actions is refused: the lints read the file it points to by the link's
/// name and the runner reads the target, which may be anywhere in the checkout.
pub fn linkProblems(a: Allocator, links: []const []const u8, out: *Out) !void {
    for (links) |l| {
        if (std.mem.startsWith(u8, l, ".github/workflows/") or std.mem.startsWith(u8, l, ".github/actions/")) {
            try c.problem(a, out, prefix ++ "{s}: a symbolic link under .github/workflows or .github/actions is not allowed", .{l});
        }
    }
}

/// A document's top-level keys are the ones GitHub defines; a key spelled another way (`true:` for `on:`, as YAML 1.1 reads it) would hide
/// the triggers from every lint, so it is refused by name.
fn topKeyProblems(a: Allocator, f: []const u8, doc: Value, out: *Out) !void {
    if (doc != .object) {
        try c.problem(a, out, prefix ++ "{s}: the document is not a mapping", .{f});
        return;
    }
    for (doc.object.keys()) |k| {
        if (!c.containsStr(&top_keys, k)) try c.problem(a, out, prefix ++ "{s}: top-level key `{s}` is not one the lints read (name, run-name, on, permissions, env, defaults, concurrency, jobs)", .{ f, k });
    }
    if (c.get(doc, "on") == null) try c.problem(a, out, prefix ++ "{s}: no `on:` (spelled `true:` or otherwise, it would hide the triggers)", .{f});
    if (oddKey(doc)) |k| try c.problem(a, out, prefix ++ "{s}: the key `{s}` is an anchor, an alias, a tag or a merge key; the lints do not read those", .{ f, k });
}

/// A mapping key anywhere in `node` that is an anchor, alias, tag or merge key: the YAML reader refuses those as values, and this
/// closes the key position.
fn oddKey(node: Value) ?[]const u8 {
    switch (node) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                const k = e.key_ptr.*;
                if (k.len > 0 and (k[0] == '&' or k[0] == '*' or k[0] == '!')) return k;
                if (std.mem.eql(u8, k, "<<")) return k;
                if (oddKey(e.value_ptr.*)) |bad| return bad;
            }
            return null;
        },
        .array => |arr| {
            for (arr.items) |v| if (oddKey(v)) |bad| return bad;
            return null;
        },
        else => return null,
    }
}

/// `content` starts with `key:` (also `"key":` and `'key':`); what follows the colon, comment and spaces dropped, or null.
fn keyRest(content: []const u8, key: []const u8) ?[]const u8 {
    var rest = content;
    if (rest.len > 0 and (rest[0] == '"' or rest[0] == '\'')) {
        const q = rest[0];
        if (rest.len < key.len + 3 or !std.mem.eql(u8, rest[1 .. 1 + key.len], key) or rest[1 + key.len] != q) return null;
        rest = rest[key.len + 2 ..];
    } else {
        if (!std.mem.startsWith(u8, rest, key)) return null;
        rest = rest[key.len..];
    }
    if (rest.len == 0 or rest[0] != ':') return null;
    rest = rest[1..];
    if (rest.len != 0 and rest[0] != ' ') return null;
    var v = std.mem.trim(u8, rest, " ");
    if (std.mem.indexOf(u8, v, " #")) |h| v = std.mem.trimRight(u8, v[0..h], " ");
    if (v.len > 0 and v[0] == '#') v = "";
    return v;
}

fn indentOf(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and line[n] == ' ') n += 1;
    return n;
}

/// M2b. `on:` and `permissions:` are read as BLOCK mappings: a flow mapping or sequence, a block scalar or an inline value there is
/// refused, naming the line, so a form the readers might understand differently never decides a trigger or a permission. For every
/// file the keys at column 0 are checked; for the autopin files (`strict`) also everything inside `on:` and inside any `permissions:`.
/// (A multi-line scalar, a tab and anything else the reader cannot parse exactly are refused by the YAML reader itself.)
pub fn blockStyleProblems(a: Allocator, f: []const u8, text: []const u8, strict: bool, out: *Out) !void {
    var in_on = false;
    var perm_indent: ?usize = null;
    var lineno: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        lineno += 1;
        const line = std.mem.trimRight(u8, raw, "\r ");
        const ind = indentOf(line);
        const content = line[ind..];
        if (content.len == 0 or content[0] == '#') continue;
        if (ind == 0) {
            in_on = false;
            perm_indent = null;
            for ([_][]const u8{ "on", "permissions" }) |key| {
                if (keyRest(content, key)) |rest| {
                    if (rest.len != 0) try c.problem(a, out, prefix ++ "{s}: line {d}: `{s}:` must be a block mapping (an inline value, a flow collection or a block scalar is not read)", .{ f, lineno, key });
                    if (std.mem.eql(u8, key, "on")) in_on = true;
                    if (std.mem.eql(u8, key, "permissions")) perm_indent = 0;
                }
            }
            continue;
        }
        if (!strict) continue;
        if (perm_indent) |pi| {
            if (ind <= pi) perm_indent = null;
        }
        if (keyRest(content, "permissions")) |rest| {
            if (rest.len != 0) try c.problem(a, out, prefix ++ "{s}: line {d}: `permissions:` must be a block mapping", .{ f, lineno });
            perm_indent = ind;
            continue;
        }
        if (in_on or perm_indent != null) {
            var item = content;
            if (std.mem.startsWith(u8, item, "- ")) item = std.mem.trimLeft(u8, item[2..], " ");
            var v = item;
            if (std.mem.indexOf(u8, item, ": ")) |k| v = std.mem.trimLeft(u8, item[k + 2 ..], " ");
            if (v.len > 0 and (v[0] == '[' or v[0] == '{' or v[0] == '|' or v[0] == '>')) {
                try c.problem(a, out, prefix ++ "{s}: line {d}: a flow collection or block scalar inside `on:` or `permissions:` is not read; write it as a block", .{ f, lineno });
            }
        }
    }
}

// ---- R1-R4 ---------------------------------------------------------------------------------------

const never_triggers = [_][]const u8{ "create", "status", "check_suite", "check_run", "deployment_status" };

/// R1. `workflow_run` is allowed in autopin-commit.yml alone; `create`, `status`, `check_suite`, `check_run` and `deployment_status` in
/// no file (an App's push or a status it posts must not start a workflow); `push` only for branches [main] (with paths filters) or tags.
fn triggerProblems(a: Allocator, f: []const u8, doc: Value, out: *Out) !void {
    const base = c.basename(f);
    const on = try c.onKeys(a, doc);
    for (never_triggers) |t| {
        if (c.containsStr(on, t)) try c.problem(a, out, prefix ++ "{s}: trigger {s} is not allowed: a status or a push by an App must not start a workflow", .{ f, t });
    }
    if (c.containsStr(on, "workflow_run") and !std.mem.eql(u8, base, commit_file)) {
        try c.problem(a, out, prefix ++ "{s}: workflow_run is allowed in {s} alone", .{ f, commit_file });
    }
    if (!c.containsStr(on, "push")) return;
    const onv = c.onValue(doc);
    const push: Value = if (onv != null and onv.? == .object) (onv.?.object.get("push") orelse Value{ .null = {} }) else Value{ .null = {} };
    if (push != .object) {
        try c.problem(a, out, prefix ++ "{s}: push without `branches: [main]` or `tags` runs for every branch, an App's included", .{f});
        return;
    }
    for (push.object.keys()) |k| {
        if (!c.containsStr(&.{ "branches", "paths", "paths-ignore", "tags" }, k)) try c.problem(a, out, prefix ++ "{s}: push may carry branches, paths, paths-ignore and tags only, not {s}", .{ f, k });
    }
    if (push.object.get("branches")) |br| {
        if (!c.eqlList(try c.arrayOf(a, br), &.{"main"})) try c.problem(a, out, prefix ++ "{s}: push must be limited to branches [main]", .{f});
    } else if (push.object.get("tags") == null) {
        try c.problem(a, out, prefix ++ "{s}: push needs `branches: [main]` or `tags`", .{f});
    }
}

fn localCallee(s: []const u8) ?[]const u8 {
    const head = "./.github/workflows/";
    if (!std.mem.startsWith(u8, s, head) or !std.mem.endsWith(u8, s, ".yml")) return null;
    const name = s[head.len..];
    if (name.len <= 4 or std.mem.indexOfScalar(u8, name, '/') != null) return null;
    return name;
}

/// R2: what a workflow reachable from a pull request may not hold, followed through local reusable workflows to a depth of four.
fn calleeProblems(a: Allocator, ctx: anytype, f: []const u8, chain: []const u8, name: []const u8, depth: usize, seen: *std.ArrayList([]const u8), out: *Out) !void {
    // Each called workflow is checked once per caller, however many jobs call it.
    if (c.containsStr(seen.items, name)) return;
    try seen.append(name);
    if (depth > 4) {
        try c.problem(a, out, prefix ++ "{s}: {s}: reusable workflows nest deeper than the lint follows", .{ f, chain });
        return;
    }
    const text = ctx.read(a, name) catch {
        try c.problem(a, out, prefix ++ "{s}: {s}: cannot read the called workflow {s}", .{ f, chain, name });
        return;
    };
    const doc = c.load(a, text) catch {
        try c.problem(a, out, prefix ++ "{s}: {s}: the called workflow {s} is not readable as YAML", .{ f, chain, name });
        return;
    };
    const here = try std.fmt.allocPrint(a, "{s} -> {s}", .{ chain, name });
    if (c.findKey(doc, "environment") or c.findKey(doc, "secrets") or c.findKey(doc, "id-token") or c.mentionsSecretsDot(try c.nonCommentLines(a, text))) {
        try c.problem(a, out, prefix ++ "{s}: {s} declares an environment, secrets or an id-token: a pull request must not reach it", .{ f, here });
    }
    for (try jobList(a, doc)) |job| {
        const u = c.str(c.get(job.node, "uses")) orelse continue;
        if (localCallee(u)) |next| {
            try calleeProblems(a, ctx, f, here, next, depth + 1, seen, out);
        } else {
            try c.problem(a, out, prefix ++ "{s}: {s}: job {s} calls {s}, which is not a local workflow", .{ f, here, job.name, u });
        }
    }
}

/// R2, R3 and R4 for a workflow that runs on pull_request. A pull request (a fork's, or the App's push to a Dependabot branch) must
/// reach no secret, no environment and no id-token but the farm's, and no farm login for a Dependabot branch.
fn pullRequestProblems(a: Allocator, ctx: anytype, f: []const u8, doc: Value, text: []const u8, out: *Out) !void {
    const base = c.basename(f);
    const on = try c.onKeys(a, doc);
    if (!c.containsStr(on, "pull_request")) return;
    // R2
    var seen = std.ArrayList([]const u8).init(a);
    if (c.findKey(doc, "environment")) try c.problem(a, out, prefix ++ "{s}: a pull_request workflow must not declare an environment", .{f});
    for (try jobList(a, doc)) |job| {
        const u = c.str(c.get(job.node, "uses")) orelse continue;
        if (localCallee(u)) |callee| {
            try calleeProblems(a, ctx, f, job.name, callee, 1, &seen, out);
        } else {
            try c.problem(a, out, prefix ++ "{s}: job {s} calls {s}: a pull_request workflow may call only a local reusable workflow", .{ f, job.name, u });
        }
    }
    // R3
    const body = try c.nonCommentLines(a, text);
    if (c.mentionsSecretsDot(body) or c.hasSecretsInherit(body)) try c.problem(a, out, prefix ++ "{s}: a pull_request workflow must not reference secrets", .{f});
    if (!mapIs(c.get(doc, "permissions"), &.{.{ .k = "contents", .v = "read" }})) try c.problem(a, out, prefix ++ "{s}: a pull_request workflow's top-level permissions must be exactly `contents: read`", .{f});
    // id-token only in the farm workflow, and there per job; R4: the farm job is skipped for a Dependabot branch before any step.
    for (try jobList(a, doc)) |job| {
        const perms = c.get(job.node, "permissions");
        if (!c.isStr(c.get(perms, "id-token"), "write")) continue;
        if (!std.mem.eql(u8, base, farm_file)) {
            try c.problem(a, out, prefix ++ "{s}: job {s}: id-token write on a pull_request workflow is for {s} alone", .{ f, job.name, farm_file });
            continue;
        }
        const cond = c.str(c.get(job.node, "if")) orelse "";
        if (!contains(cond, "!startsWith(github.head_ref, 'dependabot/')")) {
            try c.problem(a, out, prefix ++ "{s}: job {s} holds id-token write but its job-level `if:` does not skip a Dependabot branch (`!startsWith(github.head_ref, 'dependabot/')`)", .{ f, job.name });
        }
    }
}

// ---- no workflow merges or approves a Dependabot pull request -------------------------------------

const merge_markers = [_][]const u8{ "pr merge", "auto-merge", "automerge", "auto_merge", "pr review", "approve" };

/// A job that names Dependabot (or any job of the autopin files) must hold no word that merges or approves: not `gh pr merge`, not
/// `--auto`, not an auto-merge or auto-approve action. A Dependabot pull request is merged by a person who has read its lockfile diff.
fn mergeProblems(a: Allocator, f: []const u8, doc: Value, out: *Out) !void {
    const base = c.basename(f);
    const autopin = c.containsStr(&autopin_files, base);
    for (try jobList(a, doc)) |job| {
        const body = try c.lower(a, try c.inspect(a, job.node));
        if (!autopin and !contains(body, "dependabot")) continue;
        for (merge_markers) |m| {
            if (contains(body, m)) try c.problem(a, out, prefix ++ "{s}: job {s}: `{s}` in a job that handles Dependabot pull requests: a workflow never merges or approves one", .{ f, job.name, m });
        }
        if (hasFlag(body, "--auto")) try c.problem(a, out, prefix ++ "{s}: job {s}: `--auto` in a job that handles Dependabot pull requests: a workflow never merges or approves one", .{ f, job.name });
    }
}

// ---- the whole repository --------------------------------------------------------------------------

/// The rules that need more than one file. `names` are the workflow files directly under .github/workflows (`.yml` or `.yaml`);
/// `ctx.read(a, name)` returns one. The three autopin files must be there.
pub fn repoProblems(a: Allocator, ctx: anytype, names: []const []const u8, out: *Out) !void {
    var seen_names = std.ArrayList([]const u8).init(a);
    var seen_files = std.ArrayList([]const u8).init(a);
    var facts = std.ArrayList(Facts).init(a);
    var fact_files = std.ArrayList([]const u8).init(a);
    for (autopin_files) |want| {
        if (!c.containsStr(names, want)) try c.problem(a, out, prefix ++ "{s}: missing: the Dependabot pin update needs all three of {s}, {s} and {s}", .{ want, compute_file, commit_file, verify_file });
    }
    for (names) |n| {
        const text = try ctx.read(a, n);
        const doc = c.load(a, text) catch |err| {
            try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ n, @errorName(err) });
            continue;
        };
        try topKeyProblems(a, n, doc, out);
        try blockStyleProblems(a, n, text, c.containsStr(&autopin_files, n), out);
        try triggerProblems(a, n, doc, out);
        try pullRequestProblems(a, ctx, n, doc, text, out);
        try mergeProblems(a, n, doc, out);

        // Unique names: autopin-commit.yml's trigger names the compute workflow, and a second workflow of that name would also match.
        if (c.str(c.get(doc, "name"))) |wn| {
            for (seen_names.items, seen_files.items) |other, other_file| {
                if (std.mem.eql(u8, other, wn)) try c.problem(a, out, prefix ++ "{s}: the workflow name `{s}` is also {s}'s; workflow_run matches by name", .{ n, wn, other_file });
            }
            try seen_names.append(wn);
            try seen_files.append(n);
        } else {
            try c.problem(a, out, prefix ++ "{s}: no `name:`", .{n});
        }

        if (c.containsStr(&autopin_files, n)) {
            try facts.append(try fileProblems(a, n, text, out));
            try fact_files.append(n);
        } else {
            // The environment and its key are autopin-commit.yml's alone.
            const body = try c.nonCommentLines(a, text);
            if (contains(body, key_secret) or contains(body, "AUTOPIN_APP_ID")) try c.problem(a, out, prefix ++ "{s}: the autopin App's key and id are named by {s} alone", .{ n, commit_file });
            if (contains(try c.inspect(a, c.get(doc, "jobs")), "\"environment\"=>\"" ++ environment_name ++ "\"")) {
                try c.problem(a, out, prefix ++ "{s}: the environment `{s}` is {s}'s alone", .{ n, environment_name, commit_file });
            }
        }
    }

    // One tool pin and one SETS list across the three files.
    // (autopin-compute.yml is the reference: it is the file a pull request's Dependabot run reads first.)
    for (facts.items, fact_files.items) |fa, fname| {
        if (fa.sets.len == 0) try c.problem(a, out, prefix ++ "{s}: no run script carries `--set DIR=KIND`", .{fname});
    }
    var ref: ?Facts = null;
    for (facts.items, fact_files.items) |fa, fname| {
        if (std.mem.eql(u8, fname, compute_file)) ref = fa;
    }
    const want = ref orelse return;
    for (facts.items, fact_files.items) |fa, fname| {
        if (std.mem.eql(u8, fname, compute_file)) continue;
        if (fa.pin) |pin| if (want.pin) |p| {
            if (!std.mem.eql(u8, p.version, pin.version)) try c.problem(a, out, prefix ++ "{s}: the tool version {s} differs from {s}'s {s}", .{ fname, pin.version, compute_file, p.version });
            if (!std.mem.eql(u8, p.sha256, pin.sha256)) try c.problem(a, out, prefix ++ "{s}: the tool sha256 differs from {s}'s: the three workflows run one pinned binary", .{ fname, compute_file });
        };
        if (want.sets.len == 0) continue;
        for (fa.sets) |sets| {
            if (!try sameSet(a, want.sets[0], sets)) try c.problem(a, out, prefix ++ "{s}: a --set list differs from {s}'s: all of them name the same directories", .{ fname, compute_file });
        }
    }
}
