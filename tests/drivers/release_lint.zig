//! What .github/workflows/release.yml must keep: the release pipeline's scopes and gates as lint rules.
//! `problems` reads the workflow and reports each way it differs; the real file must report none
//! (workflow_lint.zig runs it over release.yml, //:workflows), and release_lint_test.zig plants each
//! defect on it and requires the matching message.
//!
//! The pipeline (RELEASING.md): a push to main that changes more than docs or CI runs `beta` (the
//! whole of ci.yml), then `tag` (the annotated tag v<version>, the one write before the build), `build`
//! (four targets), `attest` (SHA256SUMS and build provenance), `verify` (the checks of the built
//! files) and `publish` (the release, from exactly the verified files). A manual run does `beta` and
//! `plan` only, and publishes nothing.
//!
//! - **Who may write.** `contents: write` only in `tag` and `publish`, each under the exact
//!   push-to-main `if:`; `id-token: write` and `attestations: write` only in `attest`. No other job holds
//!   any write scope, and no job may set `permissions` to a bare string such as write-all.
//! - **The order.** `tag` needs `beta`, `build` needs `tag`, `attest` needs `build`, `verify` needs
//!   `build` and `attest`, `publish` needs `verify` and `tag`: a red stage stops everything after it.
//!   No job may set `continue-on-error`, and only `tag`, `publish` and `plan` have an `if:`.
//! - **The triggers.** A push to main, with the `paths-ignore` below, and `workflow_dispatch`; one run
//!   at a time (`concurrency` group `release`, never cancelled).
//! - **The path filter.** A push that changes only docs or CI does not release. The filter is checked
//!   by matching sample paths against it as GitHub does: sources, the VERSION file, the build and the
//!   tools release; docs and workflows skip.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

pub const prefix = "release-lint: ";

/// The jobs, in the order they run.
pub const jobs = [_][]const u8{ "beta", "plan", "tag", "build", "attest", "verify", "publish" };

/// The `if:` of `tag` and `publish`: a push to main, never a manual run.
pub const push_to_main = "${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}";
/// The `if:` of `plan`: a manual run only.
pub const manual_run = "${{ github.event_name == 'workflow_dispatch' }}";

/// The `(job, scope)` pairs that may be `write`.
pub const writers = [_][2][]const u8{
    .{ "tag", "contents" },
    .{ "attest", "id-token" },
    .{ "attest", "attestations" },
    .{ "publish", "contents" },
};

/// What each job must (directly) need.
const needs = [_]struct { job: []const u8, needs: []const []const u8 }{
    .{ .job = "plan", .needs = &.{"beta"} },
    .{ .job = "tag", .needs = &.{"beta"} },
    .{ .job = "build", .needs = &.{"tag"} },
    .{ .job = "attest", .needs = &.{ "tag", "build" } },
    .{ .job = "verify", .needs = &.{ "tag", "build", "attest" } },
    .{ .job = "publish", .needs = &.{ "tag", "verify" } },
};

/// The paths a push may change without releasing: documentation and CI.
pub const paths_ignore = [_][]const u8{ "**.md", "docs/**", ".github/**" };

/// Paths that are part of what a release builds or how: a push changing one of them must release.
pub const releases = [_][]const u8{
    "src/cli/main.zig",
    "src/cli/build_options.zig",
    "src/core/semver.zig",
    "VERSION",
    "build.zig",
    "build.zig.zon",
    "BUCK",
    "LICENSE",
    "tools/release.zig",
    "tools/cut_release.zig",
    "tests/drivers/golden_test.zig",
    "site/static/install.sh",
    "registry/fake/main.zig",
};

/// Paths that are documentation or CI: a push changing only these must not release.
pub const skips = [_][]const u8{
    "README.md",
    "CONTRIBUTING.md",
    "RELEASING.md",
    "docs/design/overview.txt",
    "spec/mopm-toml.md",
    "service/docs/pipelines.md",
    ".github/workflows/ci.yml",
    ".github/workflows/release.yml",
    ".github/scripts/anything.rb",
};

/// Does the GitHub filter `pattern` match `path`? `*` is any run of characters but `/`, `**` any run of
/// characters including `/`; the pattern must match the whole path.
pub fn globMatch(pattern: []const u8, path: []const u8) bool {
    if (pattern.len == 0) return path.len == 0;
    if (std.mem.startsWith(u8, pattern, "**")) {
        const rest = pattern[2..];
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (globMatch(rest, path[i..])) return true;
        }
        return false;
    }
    if (pattern[0] == '*') {
        const rest = pattern[1..];
        var i: usize = 0;
        while (true) : (i += 1) {
            if (globMatch(rest, path[i..])) return true;
            if (i >= path.len or path[i] == '/') return false;
        }
    }
    if (path.len == 0 or pattern[0] != path[0]) return false;
    return globMatch(pattern[1..], path[1..]);
}

/// A push whose changed files all match a `paths-ignore` pattern does not run the workflow.
pub fn skipped(patterns: []const []const u8, path: []const u8) bool {
    for (patterns) |p| {
        if (globMatch(p, path)) return true;
    }
    return false;
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

fn isWriter(job: []const u8, scope: []const u8) bool {
    for (writers) |w| {
        if (std.mem.eql(u8, w[0], job) and std.mem.eql(u8, w[1], scope)) return true;
    }
    return false;
}

fn ifIs(a: Allocator, job: Value, want: ?[]const u8) !bool {
    const have = c.get(job, "if");
    if (want == null) return c.isNil(have);
    return std.mem.eql(u8, try c.toS(a, have), want.?) and !c.isNil(have);
}

/// What differs between release.yml and the rules above, one line each.
pub fn problems(a: Allocator, text: []const u8, out: *Out) !void {
    const doc = c.load(a, text) catch |err| return c.problem(a, out, prefix ++ "release.yml: not readable as YAML: {s}", .{@errorName(err)});

    // Triggers and the path filter.
    const on = try c.onKeys(a, doc);
    const sorted_on = try a.dupe([]const u8, on);
    std.mem.sort([]const u8, sorted_on, {}, lessThan);
    if (!c.eqlList(sorted_on, &.{ "push", "workflow_dispatch" })) {
        try c.problem(a, out, prefix ++ "release.yml: runs on {s}, not exactly push and workflow_dispatch", .{try c.inspectList(a, on)});
    }
    const push = c.get(c.onValue(doc), "push");
    if (push != null and push.? == .object) {
        for (push.?.object.keys()) |k| {
            if (!std.mem.eql(u8, k, "branches") and !std.mem.eql(u8, k, "paths-ignore")) {
                try c.problem(a, out, prefix ++ "release.yml: push has the key `{s}`; only branches [main] and paths-ignore are allowed (a tag push would release without a version bump)", .{k});
            }
        }
        const branches = try c.arrayOf(a, c.get(push, "branches"));
        if (!c.eqlList(branches, &.{"main"})) try c.problem(a, out, prefix ++ "release.yml: push must be limited to branches [main], got {s}", .{try c.inspectList(a, branches)});
    }
    const ignore = try c.arrayOf(a, c.get(push, "paths-ignore"));
    if (push != null and push.? == .object and push.?.object.contains("paths")) {
        try c.problem(a, out, prefix ++ "release.yml: push uses `paths`; use paths-ignore {s}, so that only docs and CI skip", .{try c.inspectList(a, &paths_ignore)});
    }
    if (!c.eqlList(ignore, &paths_ignore)) {
        try c.problem(a, out, prefix ++ "release.yml: push paths-ignore is {s}, expected exactly {s}", .{ try c.inspectList(a, ignore), try c.inspectList(a, &paths_ignore) });
    }
    for (releases) |p| {
        if (skipped(ignore, p)) try c.problem(a, out, prefix ++ "release.yml: paths-ignore skips {s}, a change to which must release", .{p});
    }
    for (skips) |p| {
        if (!skipped(ignore, p)) try c.problem(a, out, prefix ++ "release.yml: paths-ignore does not skip {s}, a docs or CI change that must not release", .{p});
    }

    // One run at a time, none cancelled: a cancelled run could leave a tag without its release.
    const conc = c.get(doc, "concurrency");
    if (!c.isStr(c.get(conc, "group"), "release") or c.truthy(c.get(conc, "cancel-in-progress"))) {
        try c.problem(a, out, prefix ++ "release.yml: concurrency must be group `release` with cancel-in-progress false", .{});
    }

    // The jobs.
    const jv = c.get(doc, "jobs");
    const have = try a.dupe([]const u8, c.keys(jv));
    std.mem.sort([]const u8, have, {}, lessThan);
    const want = try a.dupe([]const u8, &jobs);
    std.mem.sort([]const u8, want, {}, lessThan);
    if (!c.eqlList(have, want)) {
        try c.problem(a, out, prefix ++ "release.yml: jobs are {s}, expected {s}", .{ try c.inspectList(a, have), try c.inspectList(a, want) });
    }
    for (jobs) |name| {
        const job = c.get(jv, name) orelse continue;

        // Write scopes.
        const perms = c.get(job, "permissions");
        if (perms) |p| {
            if (p == .string and std.mem.indexOf(u8, p.string, "write") != null) {
                try c.problem(a, out, prefix ++ "release.yml: {s}: permissions {s} grants every scope", .{ name, p.string });
            }
            if (p == .object) {
                var it = p.object.iterator();
                while (it.next()) |e| {
                    if (!c.isStr(e.value_ptr.*, "write")) continue;
                    if (!isWriter(name, e.key_ptr.*)) {
                        try c.problem(a, out, prefix ++ "release.yml: {s}: {s}: write is not allowed here (only tag and publish hold contents: write; only attest holds id-token and attestations)", .{ name, e.key_ptr.* });
                    }
                }
            }
        }
        for (writers) |w| {
            if (!std.mem.eql(u8, w[0], name)) continue;
            if (!c.isStr(c.get(perms, w[1]), "write")) try c.problem(a, out, prefix ++ "release.yml: {s}: needs {s}: write", .{ name, w[1] });
        }

        // The `if:` of each job.
        if (std.mem.eql(u8, name, "tag") or std.mem.eql(u8, name, "publish")) {
            if (!try ifIs(a, job, push_to_main)) {
                try c.problem(a, out, prefix ++ "release.yml: {s} must run only under if: {s} (a push to main, never a manual run), got {s}", .{ name, push_to_main, try c.inspect(a, c.get(job, "if")) });
            }
        } else if (std.mem.eql(u8, name, "plan")) {
            if (!try ifIs(a, job, manual_run)) {
                try c.problem(a, out, prefix ++ "release.yml: plan must run only under if: {s}, got {s}", .{ manual_run, try c.inspect(a, c.get(job, "if")) });
            }
        } else if (!try ifIs(a, job, null)) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not have an if: (only tag, publish and plan do)", .{name});
        }
        if (job == .object and job.object.contains("continue-on-error")) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not set continue-on-error: a red stage stops the release", .{name});
        }
        if (job == .object and job.object.contains("environment")) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not use an environment: every gate is automated", .{name});
        }
    }

    // The order.
    for (needs) |n| {
        const job = c.get(jv, n.job) orelse continue;
        const have_needs = try c.arrayOf(a, c.get(job, "needs"));
        for (n.needs) |w| {
            if (!c.containsStr(have_needs, w)) {
                try c.problem(a, out, prefix ++ "release.yml: {s} must need {s}", .{ n.job, w });
            }
        }
    }
    // beta is the whole of ci.yml, and build the reusable build.
    if (c.get(jv, "beta")) |beta| {
        if (!c.isStr(c.get(beta, "uses"), "./.github/workflows/ci.yml")) try c.problem(a, out, prefix ++ "release.yml: beta must call ./.github/workflows/ci.yml", .{});
    }
    if (c.get(jv, "build")) |build| {
        if (!c.isStr(c.get(build, "uses"), "./.github/workflows/release-build.yml")) try c.problem(a, out, prefix ++ "release.yml: build must call ./.github/workflows/release-build.yml", .{});
    }
}
