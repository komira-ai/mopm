//! What .github/workflows/release.yml must keep: the release pipeline's scopes and gates as lint rules.
//! `problems` reads the workflow and reports each way it differs; the real file must report none
//! (workflow_lint.zig runs it over release.yml, //:workflows), and release_lint_test.zig plants each
//! defect on it and requires the matching message. `userBetaProblems` does the same for
//! release-beta-user.yml, the matrix of the user-level beta.
//!
//! The pipeline (RELEASING.md): a push to main that changes more than docs or CI runs `beta` (the
//! whole of ci.yml) and `lint` (the whole of lint.yml), then `plan` (the version), `build` (the
//! candidate: four targets, at that version), `beta-user` (the candidate tested as a user on every
//! platform), `attest` (SHA256SUMS, cosign signatures and build provenance), `verify` (the checks of the
//! built files, read-only), `tag` (the annotated tag v<version>, the one write before the release) and
//! `publish` (the release, from exactly the verified files). The tag comes AFTER verify, so a failing
//! attest, signature or verify leaves no orphan tag. A manual run does everything up to `verify` and
//! tags and publishes nothing.
//!
//! - **Who may write.** `contents: write` only in `tag` and `publish`, each under the exact
//!   push-to-main `if:`; `id-token: write` and `attestations: write` only in `attest`. No other job holds
//!   any write scope, and no job may set `permissions` to a bare string such as write-all.
//! - **The order.** `plan` needs `beta` and `lint`, `build` needs `plan`, `beta-user` needs `build`, `attest`
//!   needs `beta-user` (so a red platform leg stops the release before anything is signed), `verify` needs
//!   `build` and `attest`, `tag` needs `beta-user` and `verify` (no tag without verified files), `publish`
//!   needs `verify` and `tag`: a red stage stops everything after it.
//!   No job may set `continue-on-error`, and only `tag` and `publish` have an `if:`.
//! - **The data flow.** `build` and `beta-user` take the planned version (`needs.plan.outputs.version`),
//!   `tag` is told it (`--expect-version`) and the commit (`--sha "$GITHUB_SHA"`), `verify` checks the
//!   planned version (the tag does not exist yet), `publish` uses `needs.tag.outputs.version`, and `publish` releases the artifacts `verified-assets` and
//!   `release-notes` and nothing else.
//! - **The triggers.** A push to main, with the `paths-ignore` below, and `workflow_dispatch`; one run
//!   at a time per group: all pushes share one, a manual run has its own (never cancelled).
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
pub const jobs = [_][]const u8{ "beta", "lint", "plan", "build", "beta-user", "attest", "verify", "tag", "publish" };

/// The `concurrency` group: every push shares one, a manual dry run has a group of its own (its run id),
/// so a dry run cannot displace the one pending push release.
pub const concurrency_group = "release-${{ github.event_name == 'push' && 'push' || github.run_id }}";

/// The platforms of the user-level beta: (target, runner). Every one is required.
pub const user_legs = [_][2][]const u8{
    .{ "linux-x86_64", "ubuntu-24.04" },
    .{ "linux-aarch64", "ubuntu-24.04-arm" },
    .{ "macos-arm64", "macos-14" },
};

/// The candidate the user beta walks, as release-beta-user.yml spells it: the binary inside the unpacked tarball,
/// and the tarball itself. Both under the artifact download of this run.
pub const candidate_binary = "$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET/mopm";
pub const candidate_tarball = "$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET.tar.gz";

/// The `if:` of `tag` and `publish`: a push to main, never a manual run.
pub const push_to_main = "${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}";

/// The `(job, scope)` pairs that may be `write`.
pub const writers = [_][2][]const u8{
    .{ "tag", "contents" },
    .{ "attest", "id-token" },
    .{ "attest", "attestations" },
    .{ "publish", "contents" },
};

/// What each job must (directly) need.
const needs = [_]struct { job: []const u8, needs: []const []const u8 }{
    .{ .job = "plan", .needs = &.{ "beta", "lint" } },
    .{ .job = "build", .needs = &.{"plan"} },
    .{ .job = "beta-user", .needs = &.{ "plan", "build" } },
    .{ .job = "attest", .needs = &.{ "plan", "build", "beta-user" } },
    .{ .job = "verify", .needs = &.{ "plan", "build", "attest" } },
    .{ .job = "tag", .needs = &.{ "plan", "build", "beta-user", "verify" } },
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
    if (!c.isStr(c.get(conc, "group"), concurrency_group) or c.truthy(c.get(conc, "cancel-in-progress"))) {
        try c.problem(a, out, prefix ++ "release.yml: concurrency must be group `{s}` with cancel-in-progress false", .{concurrency_group});
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
        } else if (!try ifIs(a, job, null)) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not have an if: (only tag and publish do)", .{name});
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
    // Each stage that calls another workflow calls the right one.
    const calls = [_][2][]const u8{
        .{ "beta", "./.github/workflows/ci.yml" },
        .{ "lint", "./.github/workflows/lint.yml" },
        .{ "build", "./.github/workflows/release-build.yml" },
        .{ "beta-user", "./.github/workflows/release-beta-user.yml" },
    };
    for (calls) |cl| {
        const job = c.get(jv, cl[0]) orelse continue;
        if (!c.isStr(c.get(job, "uses"), cl[1])) try c.problem(a, out, prefix ++ "release.yml: {s} must call {s}", .{ cl[0], cl[1] });
    }

    // The data flow: the planned version is what is built and user-tested; the candidate is tagged
    // (told the version and the commit) and then released as the tag's version.
    const planned = "${{ needs.plan.outputs.version }}";
    for ([_][]const u8{ "build", "beta-user" }) |name| {
        const job = c.get(jv, name) orelse continue;
        if (!c.isStr(c.get(c.get(job, "with"), "version"), planned)) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must be given version: {s} (the candidate has the planned version), got {s}", .{ name, planned, try c.inspect(a, c.get(c.get(job, "with"), "version")) });
        }
    }
    if (c.get(jv, "plan")) |plan| {
        if (!c.isStr(c.get(c.get(plan, "outputs"), "version"), "${{ steps.plan.outputs.version }}")) {
            try c.problem(a, out, prefix ++ "release.yml: plan must output version: ${{{{ steps.plan.outputs.version }}}}", .{});
        }
    }
    if (c.get(jv, "tag")) |tag| {
        const run = stepRunContaining(tag, "--expect-version") orelse stepRunContaining(tag, " tag --sha") orelse "";
        if (std.mem.indexOf(u8, run, " tag --sha \"$GITHUB_SHA\"") == null) try c.problem(a, out, prefix ++ "release.yml: tag must tag the pushed commit: `tag --sha \"$GITHUB_SHA\"`", .{});
        if (std.mem.indexOf(u8, run, "--expect-version \"$PLANNED\"") == null) try c.problem(a, out, prefix ++ "release.yml: tag must pass --expect-version \"$PLANNED\" (the version that was built and tested)", .{});
        if (!envIs(tag, "PLANNED", planned)) try c.problem(a, out, prefix ++ "release.yml: tag must set PLANNED to {s}", .{planned});
        if (!c.isStr(c.get(c.get(tag, "outputs"), "version"), "${{ steps.tag.outputs.version }}")) try c.problem(a, out, prefix ++ "release.yml: tag must output version: ${{{{ steps.tag.outputs.version }}}}", .{});
    }
    const tag_version = "${{ needs.tag.outputs.version }}";
    // verify runs before the tag exists, so it checks the planned version; publish releases the tag's.
    if (c.get(jv, "verify")) |job| {
        if (!envIs(job, "VERSION", planned)) try c.problem(a, out, prefix ++ "release.yml: verify must set VERSION to {s} (it runs before the tag exists)", .{planned});
    }
    if (c.get(jv, "publish")) |job| {
        if (!envIs(job, "VERSION", tag_version)) try c.problem(a, out, prefix ++ "release.yml: publish must set VERSION to {s}", .{tag_version});
    }
    if (c.get(jv, "publish")) |publish| {
        const got = try downloaded(a, publish);
        if (!c.eqlList(got, &.{ "verified-assets", "release-notes" })) {
            try c.problem(a, out, prefix ++ "release.yml: publish must download exactly the artifacts verified-assets and release-notes, got {s}", .{try c.inspectList(a, got)});
        }
    }
    if (c.get(jv, "verify")) |verify| {
        const got = try downloaded(a, verify);
        if (!c.eqlList(got, &.{"release-assets"})) try c.problem(a, out, prefix ++ "release.yml: verify must download exactly the artifact release-assets, got {s}", .{try c.inspectList(a, got)});
        if (stepRunContaining(verify, "verify-dir") == null) try c.problem(a, out, prefix ++ "release.yml: verify must run cut_release verify-dir", .{});
        if (!usesAction(verify, "sigstore/cosign-installer@")) try c.problem(a, out, prefix ++ "release.yml: verify needs cosign (sigstore/cosign-installer) to check the signatures", .{});
    }
    if (c.get(jv, "attest")) |attest| {
        if (stepRunContaining(attest, "release\" sign dist") == null) try c.problem(a, out, prefix ++ "release.yml: attest must sign the files (`release sign dist`)", .{});
        if (!usesAction(attest, "sigstore/cosign-installer@")) try c.problem(a, out, prefix ++ "release.yml: attest needs cosign (sigstore/cosign-installer) to sign", .{});
        // The tarballs attested are the tarballs the user beta passed.
        const tested_at = stepIndexRunContaining(attest, "release\" tested ");
        const sums_at = stepIndexRunContaining(attest, "release\" sums ");
        if (tested_at == null or !std.mem.eql(u8, stepRunContaining(attest, "release\" tested ").?, "\"$RUNNER_TEMP/release\" tested dist tested")) {
            try c.problem(a, out, prefix ++ "release.yml: attest must run exactly `\"$RUNNER_TEMP/release\" tested dist tested` (the files to attest are the files the user beta recorded)", .{});
        } else if (sums_at == null or tested_at.? > sums_at.?) {
            try c.problem(a, out, prefix ++ "release.yml: attest must check the tested records before it writes SHA256SUMS", .{});
        }
        const steps = c.get(attest, "steps");
        var got_records = false;
        if (steps != null and steps.? == .array) {
            for (steps.?.array.items) |st| {
                const u = c.str(c.get(st, "uses")) orelse continue;
                if (!std.mem.startsWith(u8, u, "actions/download-artifact@")) continue;
                const w = c.get(st, "with");
                if (c.isStr(c.get(w, "pattern"), "tested-*") and c.isStr(c.get(w, "path"), "tested") and c.truthy(c.get(w, "merge-multiple"))) got_records = true;
            }
        }
        if (!got_records) try c.problem(a, out, prefix ++ "release.yml: attest must download the records (pattern tested-*, path tested, merge-multiple) of the user beta", .{});
    }
}

/// The `run:` of the first step of `job` that contains `needle`.
fn stepRunContaining(job: Value, needle: []const u8) ?[]const u8 {
    const steps = c.get(job, "steps") orelse return null;
    if (steps != .array) return null;
    for (steps.array.items) |st| {
        const run = c.str(c.get(st, "run")) orelse continue;
        if (std.mem.indexOf(u8, run, needle) != null) return run;
    }
    return null;
}

/// The index of the first step of `job` whose `run:` contains `needle`.
fn stepIndexRunContaining(job: Value, needle: []const u8) ?usize {
    const steps = c.get(job, "steps") orelse return null;
    if (steps != .array) return null;
    for (steps.array.items, 0..) |st, i| {
        const run = c.str(c.get(st, "run")) orelse continue;
        if (std.mem.indexOf(u8, run, needle) != null) return i;
    }
    return null;
}

/// The index of the first step of `job` that uses an action starting with `prefix_text`.
fn stepIndexUsing(job: Value, prefix_text: []const u8) ?usize {
    const steps = c.get(job, "steps") orelse return null;
    if (steps != .array) return null;
    for (steps.array.items, 0..) |st, i| {
        const u = c.str(c.get(st, "uses")) orelse continue;
        if (std.mem.startsWith(u8, u, prefix_text)) return i;
    }
    return null;
}

/// Does `line` hold the words `words` (space-separated, in this order) as whole words?
fn hasWords(line: []const u8, words: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, words)) |at| {
        const before = at == 0 or line[at - 1] == ' ';
        const end = at + words.len;
        const after = end == line.len or line[end] == ' ';
        if (before and after) return true;
        from = at + 1;
    }
    return false;
}

/// Does some step of `job` use an action starting with `prefix_text`?
fn usesAction(job: Value, prefix_text: []const u8) bool {
    const steps = c.get(job, "steps") orelse return false;
    if (steps != .array) return false;
    for (steps.array.items) |st| {
        const u = c.str(c.get(st, "uses")) orelse continue;
        if (std.mem.startsWith(u8, u, prefix_text)) return true;
    }
    return false;
}

/// Some step of `job` sets `env.<name>` to `value`.
fn envIs(job: Value, name: []const u8, value: []const u8) bool {
    const steps = c.get(job, "steps") orelse return false;
    if (steps != .array) return false;
    for (steps.array.items) |st| {
        if (c.isStr(c.get(c.get(st, "env"), name), value)) return true;
    }
    return false;
}

/// The `name:` of every actions/download-artifact step of `job`, in order.
fn downloaded(a: Allocator, job: Value) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const steps = c.get(job, "steps") orelse return out.items;
    if (steps != .array) return out.items;
    for (steps.array.items) |st| {
        const u = c.str(c.get(st, "uses")) orelse continue;
        if (!std.mem.startsWith(u8, u, "actions/download-artifact@")) continue;
        try out.append(c.str(c.get(c.get(st, "with"), "name")) orelse "(a pattern, not a name)");
    }
    return out.items;
}

/// What differs between release-beta-user.yml and its rules, one line each: the matrix holds exactly
/// the three platforms and none can be skipped, optional or allowed to fail, the candidate comes from
/// the build's artifact, and the walk is the driver run with the version.
pub fn userBetaProblems(a: Allocator, text: []const u8, out: *Out) !void {
    const f = "release-beta-user.yml: ";
    const doc = c.load(a, text) catch |err| return c.problem(a, out, prefix ++ f ++ "not readable as YAML: {s}", .{@errorName(err)});
    const on = try c.onKeys(a, doc);
    if (!c.eqlList(on, &.{"workflow_call"})) try c.problem(a, out, prefix ++ f ++ "runs on {s}, not exactly workflow_call", .{try c.inspectList(a, on)});
    const jv = c.get(doc, "jobs");
    const names = c.keys(jv);
    if (!c.eqlList(names, &.{"user"})) {
        try c.problem(a, out, prefix ++ f ++ "jobs are {s}, expected exactly user", .{try c.inspectList(a, names)});
        return;
    }
    const job = c.get(jv, "user").?;
    for ([_][]const u8{ "if", "continue-on-error", "environment" }) |k| {
        if (job == .object and job.object.contains(k)) try c.problem(a, out, prefix ++ f ++ "user must not set {s}: every platform leg is required", .{k});
    }
    const matrix = c.get(c.get(job, "strategy"), "matrix");
    for (c.keys(matrix)) |k| {
        if (!std.mem.eql(u8, k, "include")) try c.problem(a, out, prefix ++ f ++ "the matrix has the key {s}; only include (the three legs) is allowed, so no leg can be excluded or added", .{k});
    }
    const include = c.get(matrix, "include");
    const items: []const Value = if (include != null and include.? == .array) include.?.array.items else &.{};
    if (items.len != user_legs.len) try c.problem(a, out, prefix ++ f ++ "the matrix has {d} legs, expected exactly {d}", .{ items.len, user_legs.len });
    for (user_legs) |leg| {
        var found = false;
        for (items) |it| {
            if (c.isStr(c.get(it, "target"), leg[0]) and c.isStr(c.get(it, "os"), leg[1])) found = true;
        }
        if (!found) try c.problem(a, out, prefix ++ f ++ "the matrix lacks the leg {s} on {s}", .{ leg[0], leg[1] });
    }
    if (!c.isStr(c.get(job, "runs-on"), "${{ matrix.os }}")) try c.problem(a, out, prefix ++ f ++ "user must run on ${{{{ matrix.os }}}}", .{});

    const steps = c.get(job, "steps");
    if (steps == null or steps.? != .array) return c.problem(a, out, prefix ++ f ++ "user has no steps", .{});
    for (steps.?.array.items, 0..) |st, i| {
        for ([_][]const u8{ "if", "continue-on-error" }) |k| {
            if (st == .object and st.object.contains(k)) try c.problem(a, out, prefix ++ f ++ "step {d} must not set {s}: no step of a leg may be skipped or allowed to fail", .{ i, k });
        }
    }
    // The candidate is the build's artifact for this leg, not a rebuild.
    const got = try downloaded(a, job);
    if (!c.eqlList(got, &.{"release-${{ matrix.target }}"})) try c.problem(a, out, prefix ++ f ++ "user must download exactly the build's artifact release-${{{{ matrix.target }}}}, got {s}", .{try c.inspectList(a, got)});
    const walk = stepRunContaining(job, "user_beta\" ") orelse "";
    if (walk.len == 0) try c.problem(a, out, prefix ++ f ++ "user must run the walk (tests/drivers/user_beta.zig)", .{});
    for ([_][]const u8{ "--version \"$VERSION\"", "--tarball \"" ++ candidate_tarball ++ "\"", "--install-sh site/static/install.sh", "--fake-registry", "--mojo-env", "--pixi pixi", "--ci" }) |need| {
        if (walk.len != 0 and !hasWords(walk, need)) try c.problem(a, out, prefix ++ f ++ "the walk must be given {s}", .{need});
    }
    // The walk is the candidate binary (not a `mopm` found on PATH), and nothing on its line can swallow its exit status.
    if (walk.len != 0 and !std.mem.startsWith(u8, walk, "\"$RUNNER_TEMP/user_beta\" \"" ++ candidate_binary ++ "\" ")) {
        try c.problem(a, out, prefix ++ f ++ "the walk's first argument must be the candidate binary \"" ++ candidate_binary ++ "\"", .{});
    }
    if (walk.len != 0) {
        for ([_][]const u8{ "|", ";", "&", "\n", "`", "$(" }) |bad| {
            if (std.mem.indexOf(u8, std.mem.trimRight(u8, walk, "\n"), bad) != null) {
                try c.problem(a, out, prefix ++ f ++ "the walk's line must not contain {s} (no `|| true`, no pipe, no chain: nothing may hide its exit status)", .{if (std.mem.eql(u8, bad, "\n")) "a newline" else bad});
            }
        }
    }
    if (stepRunContaining(job, "zig build-exe tests/drivers/user_beta.zig") == null) try c.problem(a, out, prefix ++ f ++ "user must build tests/drivers/user_beta.zig", .{});
    // What passed is what is recorded: attest compares the files it attests with these records.
    const walk_at = stepIndexRunContaining(job, "user_beta\" ");
    const record_at = stepIndexRunContaining(job, "release\" record ");
    if (stepRunContaining(job, "zig build-exe tools/release.zig") == null) try c.problem(a, out, prefix ++ f ++ "user must build tools/release.zig (it records the tested tarball)", .{});
    if (record_at == null or !std.mem.eql(u8, stepRunContaining(job, "release\" record ").?, "\"$RUNNER_TEMP/release\" record \"" ++ candidate_tarball ++ "\" \"$RUNNER_TEMP/tested\"")) {
        try c.problem(a, out, prefix ++ f ++ "user must run exactly `\"$RUNNER_TEMP/release\" record \"" ++ candidate_tarball ++ "\" \"$RUNNER_TEMP/tested\"` (the sha256 of the tarball the walk passed)", .{});
    } else if (walk_at == null or record_at.? < walk_at.?) {
        try c.problem(a, out, prefix ++ f ++ "user must record the tarball after the walk passed, not before", .{});
    }
    const up_at = stepIndexUsing(job, "actions/upload-artifact@");
    if (up_at == null or !std.mem.eql(u8, c.str(c.get(c.get(steps.?.array.items[up_at.?], "with"), "name")) orelse "", "tested-${{ matrix.target }}") or !std.mem.eql(u8, c.str(c.get(c.get(steps.?.array.items[up_at.?], "with"), "path")) orelse "", "${{ runner.temp }}/tested/")) {
        try c.problem(a, out, prefix ++ f ++ "user must upload the record as the artifact tested-${{{{ matrix.target }}}} from ${{{{ runner.temp }}}}/tested/", .{});
    } else if (record_at == null or up_at.? < record_at.?) {
        try c.problem(a, out, prefix ++ f ++ "user must upload the record after making it", .{});
    }
    if (c.get(job, "permissions")) |p| {
        if (p == .object) {
            for (p.object.values()) |v| if (!c.isStr(v, "read")) try c.problem(a, out, prefix ++ f ++ "user holds a permission other than read", .{});
        } else try c.problem(a, out, prefix ++ f ++ "permissions must be a read-only mapping", .{});
    }
}
