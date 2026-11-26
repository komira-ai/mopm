//! //:merge_group_workflows: the workflows of main's required checks, held to what GitHub's merge queue needs of them.
//!
//! The merge queue builds each queued pull request merged on top of main and the pull requests ahead of it, on a branch of its
//! own (refs/heads/gh-readonly-queue/main/...), and merges the group when every required check of main is green on the group's
//! head commit. A required check therefore has to report on that event, `merge_group`, under the name the ruleset asks for:
//!   - every workflow in `required_checks` runs on `merge_group` of type `checks_requested` into main, and on `pull_request`
//!     (so the pull request rules of hygiene.zig, workflow_lint.zig and autopin_lint.zig hold it: no secret, no environment,
//!     Linux x86_64 runners), and no other workflow runs on `merge_group` (nothing that publishes, deploys or bumps a version);
//!   - every required job is there, reports under its context on a merge group, and cannot be skipped there: the merge queue
//!     counts a skipped required check as passed, so a job-level `if:` has a top-level `||` term `github.event_name == 'merge_group'`;
//!   - a required job checks out the commit the event names (no `ref:`), the merge group's head;
//!   - no concurrency group cancels a merge group's run, or puts two merge groups in one group (a newer pending run cancels an
//!     older pending one even with `cancel-in-progress: false`);
//!   - farm.yml fails, and never skips green, when a merge group finds no farm configured, and builds the pull request tier (its
//!     build step is handed the merge group as `pull_request`, so the step's script is the pull request's).
//!
//! `required_checks` is the list of contexts main's ruleset requires: the ruleset change reads it from this file on main (one
//! `.{ .file = ..., .job = ..., .context = ... }` entry per line), so the lint and the ruleset name the same checks.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

const prefix = "merge_group: ";

pub const RequiredCheck = struct {
    /// The workflow file, under .github/workflows.
    file: []const u8,
    /// The job id.
    job: []const u8,
    /// The check's name as GitHub reports it on a merge group: the job's `name` (its matrix filled in), or the job id.
    context: []const u8,
};

/// The checks main's ruleset requires, one per line.
pub const required_checks = [_]RequiredCheck{
    .{ .file = "ci.yml", .job = "test", .context = "test (ubuntu-24.04)" },
    .{ .file = "ci.yml", .job = "registry-build", .context = "build cli and fake registry (ubuntu-24.04)" },
    .{ .file = "lint.yml", .job = "lint", .context = "lint (hygiene, workflows, self-test)" },
    .{ .file = "farm.yml", .job = "build", .context = "build" },
    .{ .file = "service-ci.yml", .job = "stacks", .context = "stacks" },
    .{ .file = "service-ci.yml", .job = "api", .context = "api" },
    .{ .file = "service-ci.yml", .job = "site", .context = "site" },
    .{ .file = "service-ci.yml", .job = "dns", .context = "dns" },
    .{ .file = "service-ci.yml", .job = "access", .context = "access" },
    .{ .file = "pin-verify.yml", .job = "pin-verify", .context = "pin-verify" },
};

/// One workflow file: its base name and its bytes.
pub const Workflow = struct { name: []const u8, text: []const u8 };

/// The values of `cancel-in-progress` that never cancel a merge group's run (absent and `false` are the others).
const cancel_ok = [_][]const u8{
    "${{ github.event_name == 'pull_request' }}",
    "${{ github.event_name != 'merge_group' }}",
};

/// What a concurrency group must mention to be a merge group's own: its commit, its ref (gh-readonly-queue/main/pr-<n>-<base>) or
/// its run. `github.event.pull_request.number` alone is empty on every merge group, and so is `github.head_ref`.
const own_group = [_][]const u8{ "github.sha", "github.ref", "github.run_id" };

const merge_group_term = "github.event_name == 'merge_group'";

/// farm.yml's two steps for a farm that is not configured: the notice that skips (a pull request alone) and the error (anything else).
pub const farm_skip_if = "${{ vars.FARM_ADDRESS == '' && github.event_name == 'pull_request' }}";
pub const farm_refuse_if = "${{ vars.FARM_ADDRESS == '' && github.event_name != 'pull_request' }}";
/// The event farm.yml's build step hands its script: a merge group is handed over as a pull request, so it builds the pull request
/// tier and the script itself has no branch for it.
pub const farm_tier_env = "${{ github.event_name == 'merge_group' && 'pull_request' || github.event_name }}";

fn isRequiredFile(name: []const u8) bool {
    for (required_checks) |r| if (std.mem.eql(u8, r.file, name)) return true;
    return false;
}

/// The expression inside `${{ }}`, or the text itself, trimmed.
fn unwrap(expr: []const u8) []const u8 {
    var e = std.mem.trim(u8, expr, " \r\n\t");
    if (std.mem.startsWith(u8, e, "${{") and std.mem.endsWith(u8, e, "}}")) e = std.mem.trim(u8, e[3 .. e.len - 2], " ");
    return e;
}

/// The terms of `expr` joined by `||` outside parentheses and quotes, trimmed. `&&` binds tighter than `||`, so the expression is
/// true when any one term is.
pub fn topLevelOr(a: Allocator, expr: []const u8) ![]const []const u8 {
    var terms = std.ArrayList([]const u8).init(a);
    var depth: usize = 0;
    var quoted = false;
    var start: usize = 0;
    var i: usize = 0;
    while (i < expr.len) : (i += 1) {
        const ch = expr[i];
        if (ch == '\'') {
            quoted = !quoted;
        } else if (!quoted and ch == '(') {
            depth += 1;
        } else if (!quoted and ch == ')') {
            depth -|= 1;
        } else if (!quoted and depth == 0 and ch == '|' and i + 1 < expr.len and expr[i + 1] == '|') {
            try terms.append(std.mem.trim(u8, expr[start..i], " \r\n\t"));
            i += 1;
            start = i + 1;
        }
    }
    try terms.append(std.mem.trim(u8, expr[start..], " \r\n\t"));
    return terms.items;
}

/// A job-level condition that is true on every merge group: none, `!cancelled()`, or a top-level `||` term that is exactly
/// `github.event_name == 'merge_group'`.
pub fn runsOnMergeGroup(a: Allocator, cond: ?Value) !bool {
    const v = cond orelse return true;
    if (v == .null) return true;
    const s = c.str(v) orelse return false;
    const e = unwrap(s);
    if (std.mem.eql(u8, e, "!cancelled()")) return true;
    for (try topLevelOr(a, e)) |t| if (std.mem.eql(u8, t, merge_group_term)) return true;
    return false;
}

/// The runners a merge group gets in a matrix job: the list of `matrix.os`, or for an expression the list after
/// `(github.event_name == 'pull_request' || github.event_name == 'merge_group') && '[`. Null when the lint cannot read it.
fn mergeGroupRunners(a: Allocator, job: Value) !?[]const []const u8 {
    const os = c.get(c.get(c.get(job, "strategy"), "matrix"), "os") orelse return null;
    if (c.str(os)) |expr| {
        const key = "(github.event_name == 'pull_request' || github.event_name == 'merge_group') && '[";
        const at = std.mem.indexOf(u8, expr, key) orelse return null;
        const end = std.mem.indexOfPos(u8, expr, at + key.len, "]'") orelse return null;
        var found = std.ArrayList([]const u8).init(a);
        var parts = std.mem.splitScalar(u8, expr[at + key.len .. end], '"');
        var in_quotes = false;
        while (parts.next()) |part| : (in_quotes = !in_quotes) {
            if (in_quotes) try found.append(part);
        }
        return found.items;
    }
    return try c.arrayOf(a, os);
}

/// The name a job's check reports under on a merge group, or a problem and null.
fn contextOf(a: Allocator, f: []const u8, job_name: []const u8, job: Value, out: *Out) !?[]const u8 {
    const name = c.str(c.get(job, "name")) orelse return job_name;
    const slot = "${{ matrix.os }}";
    if (std.mem.indexOf(u8, name, slot) == null) {
        if (std.mem.indexOf(u8, name, "${{") != null) {
            try c.problem(a, out, prefix ++ "{s}: job {s}: its name {s} has an expression the lint cannot fill in", .{ f, job_name, name });
            return null;
        }
        return name;
    }
    const runners = (try mergeGroupRunners(a, job)) orelse {
        try c.problem(a, out, prefix ++ "{s}: job {s}: the runners of a merge group cannot be read from matrix.os; write it as fromJSON((github.event_name == 'pull_request' || github.event_name == 'merge_group') && '[\"ubuntu-24.04\"]' || '[...]')", .{ f, job_name });
        return null;
    };
    if (runners.len != 1) {
        try c.problem(a, out, prefix ++ "{s}: job {s}: a merge group gets {d} runners, {s}; a required check is one context, so it must get exactly one", .{ f, job_name, runners.len, try c.inspectList(a, runners) });
        return null;
    }
    const at = std.mem.indexOf(u8, name, slot).?;
    return try std.mem.concat(a, u8, &.{ name[0..at], runners[0], name[at + slot.len ..] });
}

/// `concurrency:` (top-level, or a job's) that neither cancels a merge group's run nor shares a group between merge groups.
fn concurrencyProblems(a: Allocator, f: []const u8, where: []const u8, conc: ?Value, out: *Out) !void {
    const v = conc orelse return;
    const group: []const u8 = switch (v) {
        .null => return,
        .string => |s| s,
        .object => c.str(c.get(v, "group")) orelse "",
        else => "",
    };
    var own = false;
    for (own_group) |g| {
        if (std.mem.indexOf(u8, group, g) != null) own = true;
    }
    if (!own) try c.problem(a, out, prefix ++ "{s}: {s}: the concurrency group {s} names neither github.sha, github.ref nor github.run_id, so every merge group shares it and a newer one cancels the older one waiting", .{ f, where, try c.inspectStr(a, group) });
    if (v != .object) return;
    const cancel = c.get(v, "cancel-in-progress") orelse return;
    switch (cancel) {
        .null => return,
        .bool => |b| if (!b) return,
        .string => |s| if (c.containsStr(&cancel_ok, std.mem.trim(u8, s, " "))) return,
        else => {},
    }
    try c.problem(a, out, prefix ++ "{s}: {s}: cancel-in-progress is {s}; it must be false, absent, `{s}` or `{s}`: a cancelled required check takes the merge group out of the queue", .{ f, where, try c.inspect(a, cancel), cancel_ok[0], cancel_ok[1] });
}

/// The `merge_group` trigger: exactly `types: [checks_requested]` and `branches: [main]`.
fn triggerShapeProblems(a: Allocator, f: []const u8, doc: Value, out: *Out) !void {
    const mg = c.get(c.onValue(doc), "merge_group");
    const ok = blk: {
        const v = mg orelse break :blk false;
        if (v != .object or v.object.count() != 2) break :blk false;
        break :blk c.eqlList(try c.arrayOf(a, c.get(v, "types")), &.{"checks_requested"}) and
            c.eqlList(try c.arrayOf(a, c.get(v, "branches")), &.{"main"});
    };
    if (!ok) try c.problem(a, out, prefix ++ "{s}: the merge_group trigger must be exactly `types: [checks_requested]` and `branches: [main]`, got {s}", .{ f, try c.inspect(a, mg) });
}

fn steps(job: Value) []const Value {
    const s = c.get(job, "steps") orelse return &.{};
    return if (s == .array) s.array.items else &.{};
}

fn stepRunning(job: Value, needle: []const u8) ?Value {
    for (steps(job)) |st| {
        const run = c.str(c.get(st, "run")) orelse continue;
        if (std.mem.indexOf(u8, run, needle) != null) return st;
    }
    return null;
}

/// farm.yml's build job on a merge group: no farm is an error, never a green skip, and the build is the pull request tier.
fn farmProblems(a: Allocator, f: []const u8, job: Value, out: *Out) !void {
    if (stepRunning(job, "::notice title=farm::")) |st| {
        if (!c.isStr(c.get(st, "if"), farm_skip_if)) try c.problem(a, out, prefix ++ "{s}: job build: the step that skips with a notice has if: {s}, expected {s} (a merge group with no farm must fail, not pass green)", .{ f, try c.inspect(a, c.get(st, "if")), farm_skip_if });
    }
    if (stepRunning(job, "::error title=farm::")) |st| {
        if (!c.isStr(c.get(st, "if"), farm_refuse_if)) try c.problem(a, out, prefix ++ "{s}: job build: the step that refuses has if: {s}, expected {s}", .{ f, try c.inspect(a, c.get(st, "if")), farm_refuse_if });
        if (!std.mem.endsWith(u8, std.mem.trimRight(u8, c.str(c.get(st, "run")) orelse "", "\n "), "exit 1")) try c.problem(a, out, prefix ++ "{s}: job build: the step that refuses must end with exit 1", .{f});
        if (c.get(st, "continue-on-error") != null) try c.problem(a, out, prefix ++ "{s}: job build: the step that refuses must not set continue-on-error", .{f});
    } else try c.problem(a, out, prefix ++ "{s}: job build: no step fails, with an ::error, when a merge group or a push to main finds no farm configured", .{f});
    if (stepRunning(job, "./buck2 uquery")) |st| {
        if (!c.isStr(c.get(c.get(st, "env"), "EVENT"), farm_tier_env)) try c.problem(a, out, prefix ++ "{s}: job build: the build step's EVENT is {s}, expected {s} (a merge group builds the pull request tier)", .{ f, try c.inspect(a, c.get(c.get(st, "env"), "EVENT")), farm_tier_env });
    } else try c.problem(a, out, prefix ++ "{s}: job build: no step builds the pull request tier (`./buck2 uquery`)", .{f});
}

/// Every problem of the workflow files `workflows` (base names) against the merge queue's needs.
pub fn problems(a: Allocator, workflows: []const Workflow, out: *Out) !void {
    var docs = std.StringArrayHashMap(Value).init(a);
    for (workflows) |w| {
        const doc = c.load(a, w.text) catch |err| {
            try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ w.name, @errorName(err) });
            continue;
        };
        try docs.put(w.name, doc);
    }
    // No workflow but those of the required checks runs on a merge group, and each of those runs on a pull request too.
    var it = docs.iterator();
    while (it.next()) |e| {
        const f = e.key_ptr.*;
        const on = try c.onKeys(a, e.value_ptr.*);
        if (!c.containsStr(on, "merge_group")) continue;
        if (!isRequiredFile(f)) try c.problem(a, out, prefix ++ "{s}: runs on merge_group but holds no required check: only the workflows of main's required checks run on a merge group", .{f});
        if (!c.containsStr(on, "pull_request")) try c.problem(a, out, prefix ++ "{s}: runs on merge_group but not on pull_request: a merge group's check is the pull request's check", .{f});
        try triggerShapeProblems(a, f, e.value_ptr.*, out);
    }
    var seen = std.StringArrayHashMap(void).init(a);
    for (required_checks) |r| {
        // An unreadable file was reported above; a missing one is reported once, with the first check it held.
        const doc = docs.get(r.file) orelse {
            if (!seen.contains(r.file)) {
                try seen.put(r.file, {});
                if (!c.containsStr(try workflowNames(a, workflows), r.file)) try c.problem(a, out, prefix ++ "{s}: missing, but main requires its check {s}", .{ r.file, r.context });
            }
            continue;
        };
        if (!seen.contains(r.file)) {
            try seen.put(r.file, {});
            if (!c.containsStr(try c.onKeys(a, doc), "merge_group")) try c.problem(a, out, prefix ++ "{s}: does not run on merge_group: its required checks would never report on a merge group, and the merge queue would wait for them until its timeout", .{r.file});
            try concurrencyProblems(a, r.file, "the workflow", c.get(doc, "concurrency"), out);
        }
        const job = c.get(c.get(doc, "jobs"), r.job) orelse {
            try c.problem(a, out, prefix ++ "{s}: job {s} is gone, but main requires its check {s}", .{ r.file, r.job, r.context });
            continue;
        };
        if (try contextOf(a, r.file, r.job, job, out)) |got| {
            if (!std.mem.eql(u8, got, r.context)) try c.problem(a, out, prefix ++ "{s}: job {s} reports as {s} on a merge group, but main requires {s}", .{ r.file, r.job, try c.inspectStr(a, got), try c.inspectStr(a, r.context) });
        }
        if (!try runsOnMergeGroup(a, c.get(job, "if"))) try c.problem(a, out, prefix ++ "{s}: job {s} can be skipped on a merge group (if: {s}), and the merge queue counts a skipped required check as passed; give it a top-level `|| " ++ merge_group_term ++ "`", .{ r.file, r.job, try c.toS(a, c.get(job, "if")) });
        try concurrencyProblems(a, r.file, try std.fmt.allocPrint(a, "job {s}", .{r.job}), c.get(job, "concurrency"), out);
        for (steps(job), 0..) |st, i| {
            const uses = c.str(c.get(st, "uses")) orelse continue;
            if (!std.mem.startsWith(u8, uses, "actions/checkout@")) continue;
            if (c.get(c.get(st, "with"), "ref") != null) try c.problem(a, out, prefix ++ "{s}: job {s} step {d}: checks out a ref of its own; a required check tests the commit its event names (on a merge group, the group's head)", .{ r.file, r.job, i });
        }
        if (std.mem.eql(u8, r.file, "farm.yml") and std.mem.eql(u8, r.job, "build")) try farmProblems(a, r.file, job, out);
    }
}

fn workflowNames(a: Allocator, workflows: []const Workflow) ![]const []const u8 {
    var names = std.ArrayList([]const u8).init(a);
    for (workflows) |w| try names.append(w.name);
    return names.items;
}
