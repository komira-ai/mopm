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
//! - **Who may write.** `contents: write` only in `publish` (under the exact push-to-main `if:`; it creates the
//!   release of an existing tag, and the tool passes `--verify-tag`, `publishToolProblems`); `id-token: write` and
//!   `attestations: write` only in `attest`. No other job holds any write scope, and no job may set `permissions`
//!   to a bare string such as write-all.
//! - **The tokens.** `tag` creates the tag, and `bump` (after `publish`, under the same `if:`) opens the
//!   komira-internal pull request that moves its `mopm` submodule; both write through a token of the App
//!   komira-release-bot, so each holds exactly `contents: read` here. They are the only jobs that may name an App
//!   token (the action, `RELEASE_BOT_*`, `steps.tagapp`, `steps.app`), one token step each, the action pinned by
//!   commit: `tag`'s for `repositories: mopm` with contents write only (the tag ruleset admits the App alone),
//!   `bump`'s for komira-internal with contents and pull-requests write; each token is minted after the tool is
//!   built and goes only to the last step of its job, as GH_TOKEN, never an argument; and no job needs `bump`, so a
//!   failed bump goes red and un-releases nothing.
//! - **The order.** `plan` needs `beta` and `lint`, `build` needs `plan`, `beta-user` needs `build`, `attest`
//!   needs `beta-user` (so a red platform leg stops the release before anything is signed), `verify` needs
//!   `build` and `attest`, `tag` needs `beta-user` and `verify` (no tag without verified files), `publish`
//!   needs `verify` and `tag`: a red stage stops everything after it.
//!   No job may set `continue-on-error`, and only `attest` (`github.ref == 'refs/heads/main'`: an unmerged
//!   commit is never signed or attested; the stages after it are skipped with it), `tag`, `publish` and `bump` have an `if:`.
//! - **The data flow.** `build` and `beta-user` take the planned version (`needs.plan.outputs.version`),
//!   `tag` is told it (`--expect-version`) and the commit (`--sha "$GITHUB_SHA"`), `verify` checks the
//!   planned version (the tag does not exist yet), `publish` uses `needs.tag.outputs.version`, and `publish` releases the artifacts `verified-assets` and
//!   `notes-pin` and nothing else. `verify` passes `--trigger "$GITHUB_EVENT_NAME"`, so the signatures are pinned to the
//!   event that made them (a dry run signs as workflow_dispatch); `publish` runs only under the push-to-main `if:`, so a
//!   dispatch-signed file is never published. No artifact of `attest` or `verify` is named `release-*`: attest downloads
//!   the build's artifacts by that pattern, and a re-run of all jobs would merge a stale one into dist.
//! - **The actions.** No `uses:` of a release workflow (this one, release-build.yml, release-beta-user.yml, release-check.yml)
//!   may be an action the org's Actions policy refuses: only GitHub-owned actions and `tailscale/github-action`. One such
//!   action makes the whole run fail at startup (`startup_failure`), as sigstore/cosign-installer did. cosign is installed by
//!   `release install-cosign`, pinned by sha256 in tools/release.zig, in `attest` and `verify` before the first use.
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
pub const jobs = [_][]const u8{ "beta", "lint", "plan", "build", "beta-user", "attest", "verify", "tag", "publish", "bump" };

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

/// The `if:` of `attest`: only a commit on main is signed and attested (a dispatch from another branch stops there).
pub const main_only = "github.ref == 'refs/heads/main'";

/// The `(job, scope)` pairs that may be `write`.
pub const writers = [_][2][]const u8{
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
    .{ .job = "bump", .needs = &.{ "tag", "publish" } },
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
    try actionProblems(a, "release.yml", text, out);

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
                        try c.problem(a, out, prefix ++ "release.yml: {s}: {s}: write is not allowed here (only publish holds contents: write; only attest holds id-token and attestations; tag and bump hold contents: read: their writes go through the App tokens)", .{ name, e.key_ptr.* });
                    }
                }
            }
        }
        for (writers) |w| {
            if (!std.mem.eql(u8, w[0], name)) continue;
            if (!c.isStr(c.get(perms, w[1]), "write")) try c.problem(a, out, prefix ++ "release.yml: {s}: needs {s}: write", .{ name, w[1] });
        }

        // The `if:` of each job.
        if (std.mem.eql(u8, name, "tag") or std.mem.eql(u8, name, "publish") or std.mem.eql(u8, name, "bump")) {
            if (!try ifIs(a, job, push_to_main)) {
                try c.problem(a, out, prefix ++ "release.yml: {s} must run only under if: {s} (a push to main, never a manual run), got {s}", .{ name, push_to_main, try c.inspect(a, c.get(job, "if")) });
            }
        } else if (std.mem.eql(u8, name, "attest")) {
            if (!try ifIs(a, job, main_only)) {
                try c.problem(a, out, prefix ++ "release.yml: attest must run only under if: {s} (an unmerged commit is never signed or attested), got {s}", .{ main_only, try c.inspect(a, c.get(job, "if")) });
            }
        } else if (!try ifIs(a, job, null)) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not have an if: (only attest, tag, publish and bump do)", .{name});
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
    // verify runs before the tag exists, so it checks the planned version; publish and bump use the tag's.
    if (c.get(jv, "verify")) |job| {
        if (!envIs(job, "VERSION", planned)) try c.problem(a, out, prefix ++ "release.yml: verify must set VERSION to {s} (it runs before the tag exists)", .{planned});
    }
    for ([_][]const u8{ "publish", "bump" }) |name| {
        const job = c.get(jv, name) orelse continue;
        if (!envIs(job, "VERSION", tag_version)) try c.problem(a, out, prefix ++ "release.yml: {s} must set VERSION to {s}", .{ name, tag_version });
    }
    if (c.get(jv, "publish")) |publish| {
        const got = try downloaded(a, publish);
        if (!c.eqlList(got, &.{ "verified-assets", "notes-pin" })) {
            try c.problem(a, out, prefix ++ "release.yml: publish must download exactly the artifacts verified-assets and notes-pin, got {s}", .{try c.inspectList(a, got)});
        }
    }
    // No job uploads an artifact that attest's `release-*` download (the build's per-target artifacts) would
    // match: a re-run of all jobs would merge the stale upload into dist and wedge the run.
    for (jobs) |name| {
        const job = c.get(jv, name) orelse continue;
        for (try uploadedNames(a, job)) |up| {
            if (std.mem.startsWith(u8, up, "release-")) {
                try c.problem(a, out, prefix ++ "release.yml: {s} uploads the artifact {s}, which attest's download pattern release-* would also match (a re-run would merge it into dist); name it otherwise", .{ name, up });
            }
        }
    }
    if (c.get(jv, "attest")) |attest| {
        const up = try uploadedNames(a, attest);
        if (!c.eqlList(up, &.{"signed-assets"})) try c.problem(a, out, prefix ++ "release.yml: attest must upload exactly the artifact signed-assets, got {s}", .{try c.inspectList(a, up)});
    }
    if (c.get(jv, "verify")) |verify| {
        const up = try uploadedNames(a, verify);
        if (!c.eqlList(up, &.{ "notes-pin", "verified-assets" })) try c.problem(a, out, prefix ++ "release.yml: verify must upload exactly the artifacts notes-pin and verified-assets, got {s}", .{try c.inspectList(a, up)});
        // The signatures are pinned to the event of this run (push for a release, workflow_dispatch for a dry run).
        const run = stepRunContaining(verify, "verify-dir") orelse "";
        if (std.mem.indexOf(u8, run, " --trigger \"$GITHUB_EVENT_NAME\"") == null) try c.problem(a, out, prefix ++ "release.yml: verify must pass --trigger \"$GITHUB_EVENT_NAME\" to verify-dir (the signatures carry the event of the run that made them)", .{});
        const got = try downloaded(a, verify);
        if (!c.eqlList(got, &.{"signed-assets"})) try c.problem(a, out, prefix ++ "release.yml: verify must download exactly the artifact signed-assets, got {s}", .{try c.inspectList(a, got)});
        if (stepRunContaining(verify, "verify-dir") == null) try c.problem(a, out, prefix ++ "release.yml: verify must run cut_release verify-dir", .{});
        try cosignInstalledBefore(a, out, "verify", verify, "verify-dir");
    }
    if (c.get(jv, "attest")) |attest| {
        if (stepRunContaining(attest, "release\" sign dist") == null) try c.problem(a, out, prefix ++ "release.yml: attest must sign the files (`release sign dist`)", .{});
        try cosignInstalledBefore(a, out, "attest", attest, "release\" sign dist");
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
    try bumpProblems(a, doc, out);
}

/// The action that mints an App token: used in `bump` and `tag` alone, one step each, both of the release bot App.
pub const app_action = "actions/create-github-app-token";

/// What `bump` runs: the tool, with the version the tag took, the pushed commit, and no token (it is in the
/// environment of the step). The internal repository and its submodule are spelled out.
pub const bump_run = "\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" bump-internal --version \"$VERSION\" --sha \"$GITHUB_SHA\" --internal-repo komira-ai/komira-internal --submodule mopm --workdir \"$RUNNER_TEMP/bump\"";

/// What `tag` runs: the tool, told the commit and the planned version, and no token (it is in the environment).
pub const tag_run = "\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" tag --sha \"$GITHUB_SHA\" --expect-version \"$PLANNED\" --out \"$GITHUB_OUTPUT\"";

/// A job that mints the installation token of a GitHub App, and what is held of it.
const TokenJob = struct {
    job: []const u8,
    /// The `id:` of the token step (and so the `steps.<id>.` of its output).
    id: []const u8,
    /// Whose App, as the messages say it ("the release bot's App token").
    who: []const u8,
    /// Anything that names this App's token besides the action: its variable and secret, the step's output.
    needles: []const []const u8,
    /// The inputs of the token step, exactly.
    want: []const [2][]const u8,
    /// A `run:` containing this is the step that runs the tool; it must equal `run`.
    marker: []const u8,
    run: []const u8,
    gh_token: []const u8,
    /// What the job's write is, for the message about its permissions.
    note: []const u8,
};

const token_jobs = [_]TokenJob{
    .{
        .job = "bump",
        .id = "app",
        .who = "release bot",
        .needles = &.{"steps.app."},
        .want = &.{
            .{ "app-id", "${{ vars.RELEASE_BOT_APP_ID }}" },
            .{ "private-key", "${{ secrets.RELEASE_BOT_PRIVATE_KEY }}" },
            .{ "owner", "komira-ai" },
            .{ "repositories", "komira-internal" },
            // The token carries these two scopes and no other, not everything the App holds on the repository.
            .{ "permission-contents", "write" },
            .{ "permission-pull-requests", "write" },
        },
        .marker = "bump-internal",
        .run = bump_run,
        .gh_token = "${{ steps.app.outputs.token }}",
        .note = "its write is on the internal repository, through the App token",
    },
    .{
        .job = "tag",
        .id = "tagapp",
        .who = "release bot",
        .needles = &.{"steps.tagapp."},
        .want = &.{
            .{ "app-id", "${{ vars.RELEASE_BOT_APP_ID }}" },
            .{ "private-key", "${{ secrets.RELEASE_BOT_PRIVATE_KEY }}" },
            .{ "owner", "komira-ai" },
            .{ "repositories", "mopm" },
            // The tag ruleset admits this App alone; the token carries contents write and nothing else.
            .{ "permission-contents", "write" },
        },
        .marker = " tag --sha",
        .run = tag_run,
        .gh_token = "${{ steps.tagapp.outputs.token }}",
        .note = "the tag is written through the release bot's App token, the only creator the tag ruleset admits",
    },
};

/// The App's variable and secret (`RELEASE_BOT_APP_ID`, `RELEASE_BOT_PRIVATE_KEY`): named by the token steps of
/// `bump` and `tag` and nowhere else. hygiene.zig allows the secret exactly twice.
const bot_names = [_][]const u8{"RELEASE_BOT"};

fn mentionsAny(v: Value, needles: []const []const u8) bool {
    for (needles) |n| {
        if (mentions(v, n)) return true;
    }
    return false;
}

/// Does a string, key or value anywhere in `v` hold `needle`?
fn mentions(v: Value, needle: []const u8) bool {
    switch (v) {
        .string => |s| return std.mem.indexOf(u8, s, needle) != null,
        .array => |arr| {
            for (arr.items) |x| {
                if (mentions(x, needle)) return true;
            }
            return false;
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (std.mem.indexOf(u8, e.key_ptr.*, needle) != null or mentions(e.value_ptr.*, needle)) return true;
            }
            return false;
        },
        else => return false,
    }
}

/// Does `v` name any App token: the action, the App's variable or secret, or the output of a token step?
fn mentionsApp(v: Value) bool {
    if (mentions(v, "create-github-app-token") or mentionsAny(v, &bot_names)) return true;
    for (token_jobs) |t| {
        if (mentionsAny(v, t.needles)) return true;
    }
    return false;
}

/// `uses` is `<action>@<40 hex digits>`.
fn usesPinned(u: []const u8, action: []const u8) bool {
    if (!std.mem.startsWith(u8, u, action) or u.len != action.len + 41 or u[action.len] != '@') return false;
    for (u[action.len + 1 ..]) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    }
    return true;
}

/// The two jobs that mint a token of the App komira-release-bot, `tag` and `bump`, each with ONE token step.
/// Neither writes through its own GITHUB_TOKEN here (`contents: read`): `tag` creates the tag with a token for
/// this repository alone (contents write; the tag ruleset admits only the App), `bump` opens the pull request on
/// komira-internal with a token for that repository alone (contents and pull-requests write). Each token is
/// minted after the tool is built, by a pinned action, handed to the one step that runs the tool (as GH_TOKEN,
/// never an argument), and named nowhere else; no other job, nor the workflow's own keys, names an App token;
/// and nothing needs `bump`, so that a failed bump goes red without un-releasing or stopping anything.
fn bumpProblems(a: Allocator, doc: Value, out: *Out) !void {
    const jv = c.get(doc, "jobs");
    // Only tag and bump may name a token: not another job, nor the workflow's own keys.
    if (doc == .object) {
        var it = doc.object.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "jobs")) continue;
            if (mentionsApp(e.value_ptr.*)) try c.problem(a, out, prefix ++ "release.yml: {s} names the release bot's App token; only the tag and bump jobs may use it", .{e.key_ptr.*});
        }
    }
    for (jobs) |name| {
        const job = c.get(jv, name) orelse continue;
        var minter = false;
        for (token_jobs) |t| {
            if (std.mem.eql(u8, name, t.job)) minter = true;
        }
        if (!minter and mentionsApp(job)) {
            try c.problem(a, out, prefix ++ "release.yml: {s} names the release bot's App token (create-github-app-token, RELEASE_BOT_*, steps.app, steps.tagapp): only the tag and bump jobs may use it, each in its own token step", .{name});
        }
        // Each token is used in its own job: bump never names tag's output, tag never names bump's.
        for (token_jobs) |t| {
            if (!std.mem.eql(u8, name, t.job) and mentionsAny(job, t.needles)) {
                try c.problem(a, out, prefix ++ "release.yml: {s} names the token of {s} (steps.{s}): a token is used only in its own job", .{ name, t.job, t.id });
            }
        }
        if (c.containsStr(try c.arrayOf(a, c.get(job, "needs")), "bump")) {
            try c.problem(a, out, prefix ++ "release.yml: {s} must not need bump: a failed bump goes red and changes nothing else (it does not un-release)", .{name});
        }
    }
    for (token_jobs) |t| try tokenJobProblems(a, jv, t, out);
}

fn tokenJobProblems(a: Allocator, jv: ?Value, t: TokenJob, out: *Out) !void {
    const bump = c.get(jv, t.job) orelse return;
    const jn = t.job;

    // Read-only here: contents: read and nothing else.
    const perms = c.get(bump, "permissions");
    const pk = c.keys(perms);
    if (perms == null or perms.? != .object or pk.len != 1 or !c.isStr(c.get(perms, "contents"), "read")) {
        try c.problem(a, out, prefix ++ "release.yml: {s}: permissions must be exactly contents: read ({s}), got {s}", .{ jn, t.note, try c.inspect(a, perms) });
    }

    const steps = c.get(bump, "steps");
    if (steps == null or steps.? != .array) return try c.problem(a, out, prefix ++ "release.yml: {s} has no steps", .{jn});
    const items = steps.?.array.items;

    var app_at: ?usize = null;
    var apps: usize = 0;
    var run_at: ?usize = null;
    var build_at: ?usize = null;
    for (items, 0..) |st, i| {
        if (c.str(c.get(st, "uses"))) |u| {
            if (std.mem.indexOf(u8, u, "create-github-app-token") != null) {
                apps += 1;
                app_at = i;
                if (!usesPinned(u, app_action)) try c.problem(a, out, prefix ++ "release.yml: {s} must use {s}@<full commit sha>, got {s}", .{ jn, app_action, u });
            }
        }
        if (c.str(c.get(st, "run"))) |r| {
            if (std.mem.indexOf(u8, r, t.marker) != null and run_at == null) run_at = i;
            if (std.mem.indexOf(u8, r, "zig build-exe tools/cut_release.zig") != null and build_at == null) build_at = i;
        }
    }
    if (apps != 1) {
        try c.problem(a, out, prefix ++ "release.yml: {s} must mint the token with exactly one {s} step, has {d}", .{ jn, app_action, apps });
    }
    if (app_at) |at| {
        const st = items[at];
        const w = c.get(st, "with");
        for (t.want) |wv| {
            if (!c.isStr(c.get(w, wv[0]), wv[1])) try c.problem(a, out, prefix ++ "release.yml: {s}: the token step must set {s}: {s} (the token is for one repository and the scopes named, no more), got {s}", .{ jn, wv[0], wv[1], try c.inspect(a, c.get(w, wv[0])) });
        }
        if (c.keys(w).len != t.want.len) try c.problem(a, out, prefix ++ "release.yml: {s}: the token step takes exactly the inputs {s}, got {s}", .{ jn, try wantNames(a, t), try c.inspectList(a, c.keys(w)) });
        if (!c.isStr(c.get(st, "id"), t.id)) try c.problem(a, out, prefix ++ "release.yml: {s}: the token step must have id: {s}", .{ jn, t.id });
    }
    if (run_at == null) {
        try c.problem(a, out, prefix ++ "release.yml: {s} must run the tool step containing `{s}`", .{ jn, t.marker });
        return;
    }
    const ri = run_at.?;
    const run = c.str(c.get(items[ri], "run")) orelse "";
    if (!std.mem.eql(u8, run, t.run)) {
        try c.problem(a, out, prefix ++ "release.yml: {s} must run exactly `{s}` (the token is in the environment, never an argument), got `{s}`", .{ jn, t.run, run });
    }
    if (!envIs(bump, "GH_TOKEN", t.gh_token) or !c.isStr(c.get(c.get(items[ri], "env"), "GH_TOKEN"), t.gh_token)) {
        try c.problem(a, out, prefix ++ "release.yml: {s}: the step that runs the tool must set GH_TOKEN to {s}", .{ jn, t.gh_token });
    }
    if (ri != items.len - 1) try c.problem(a, out, prefix ++ "release.yml: {s}: the step that runs the tool must be the last (nothing else may run with the token)", .{jn});
    // The tool is built before the token exists, and the token is minted right before it is used.
    if (build_at == null or (app_at != null and build_at.? > app_at.?)) {
        try c.problem(a, out, prefix ++ "release.yml: {s}: build the tool (zig build-exe tools/cut_release.zig) before the token step, so that no build runs beside the token", .{jn});
    }
    if (app_at != null and app_at.? > ri) try c.problem(a, out, prefix ++ "release.yml: {s}: the token step must come before the step that runs the tool", .{jn});
    // No other step may take the token.
    for (items, 0..) |st, i| {
        if (i == ri or (app_at != null and i == app_at.?)) continue;
        if (mentionsApp(st)) try c.problem(a, out, prefix ++ "release.yml: {s} step {d} names the App token; only the token step and the step that runs the tool may", .{ jn, i });
    }
}

fn wantNames(a: Allocator, t: TokenJob) ![]const u8 {
    var s = std.ArrayList(u8).init(a);
    for (t.want, 0..) |w, i| {
        if (i != 0) try s.appendSlice(", ");
        try s.appendSlice(w[0]);
    }
    return s.items;
}

/// `publish` creates the release of the EXISTING tag: the tool passes `--verify-tag` to `gh release create`, which
/// then refuses to create a tag (the job holds contents: write, and the tag ruleset admits the App alone), and no
/// other call of the tool creates a release. `src` is tools/cut_release.zig.
pub fn publishToolProblems(a: Allocator, src: []const u8, out: *Out) !void {
    const create = "\"release\", \"create\"";
    const at = std.mem.indexOf(u8, src, create) orelse return c.problem(a, out, prefix ++ "tools/cut_release.zig: publish no longer calls `gh release create`", .{});
    if (std.mem.indexOfPos(u8, src, at + 1, create) != null) try c.problem(a, out, prefix ++ "tools/cut_release.zig: more than one `gh release create` call; the one in publish carries --verify-tag", .{});
    const end = std.mem.indexOfPos(u8, src, at, "gh.must(") orelse src.len;
    if (std.mem.indexOf(u8, src[at..end], "\"--verify-tag\"") == null) {
        try c.problem(a, out, prefix ++ "tools/cut_release.zig: `gh release create` must be given --verify-tag, so that it can never create a tag", .{});
    }
}


/// The actions that are not GitHub-owned and that the org's Actions policy allows (`tailscale/github-action@*`).
/// Any other action outside `actions/` and `github/` makes the whole run fail at startup (`startup_failure`),
/// before a single job runs; a pull request's checks never use the release workflows, so only a push to main shows it.
pub const allowed_third_party = [_][]const u8{"tailscale/github-action"};

/// Does the org's Actions policy allow `uses`? A local path (`./...`), a GitHub-owned action (`actions/`, `github/`)
/// and the `allowed_third_party` list pass; anything else does not.
pub fn actionAllowed(uses: []const u8) bool {
    if (std.mem.startsWith(u8, uses, "./")) return true;
    if (std.mem.startsWith(u8, uses, "actions/") or std.mem.startsWith(u8, uses, "github/")) return true;
    const at = std.mem.indexOfScalar(u8, uses, '@') orelse uses.len;
    for (allowed_third_party) |p| {
        if (std.mem.eql(u8, uses[0..at], p)) return true;
    }
    return false;
}

/// The release workflows (release.yml, release-build.yml, release-beta-user.yml, release-check.yml) may use no
/// action the org's policy refuses, at the job level (a reusable workflow) or in a step. One line each.
pub fn actionProblems(a: Allocator, file: []const u8, text: []const u8, out: *Out) !void {
    const doc = c.load(a, text) catch |err| return c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ file, @errorName(err) });
    const jv = c.get(doc, "jobs");
    for (c.keys(jv)) |name| {
        const job = c.get(jv, name) orelse continue;
        if (c.str(c.get(job, "uses"))) |u| {
            if (!actionAllowed(u)) try c.problem(a, out, prefix ++ "{s}: {s} uses {s}, which the org's Actions policy does not allow (only GitHub-owned actions and {s}; the run would fail at startup)", .{ file, name, u, allowed_third_party[0] });
        }
        const steps = c.get(job, "steps") orelse continue;
        if (steps != .array) continue;
        for (steps.array.items, 0..) |st, i| {
            const u = c.str(c.get(st, "uses")) orelse continue;
            if (!actionAllowed(u)) try c.problem(a, out, prefix ++ "{s}: {s} step {d} uses {s}, which the org's Actions policy does not allow (only GitHub-owned actions and {s}; the run would fail at startup)", .{ file, name, i, u, allowed_third_party[0] });
        }
    }
}

/// The step that puts cosign on the PATH: the release tool, built just before, downloads the pinned binary.
pub const install_cosign_run = "echo \"$(\"$RUNNER_TEMP/release\" install-cosign \"$RUNNER_TEMP/cosign\")\" >> \"$GITHUB_PATH\"";

/// `job` must build the release tool, then install cosign with `install_cosign_run`, and only then run the step
/// whose `run:` contains `user` (the first use of cosign).
fn cosignInstalledBefore(a: Allocator, out: *Out, name: []const u8, job: Value, user: []const u8) !void {
    const built = stepIndexRunContaining(job, "zig build-exe tools/release.zig");
    const installed = stepIndexRunContaining(job, "install-cosign");
    const used = stepIndexRunContaining(job, user);
    if (installed == null or !std.mem.eql(u8, stepRunContaining(job, "install-cosign").?, install_cosign_run)) {
        return c.problem(a, out, prefix ++ "release.yml: {s} must install cosign with exactly `{s}` (sha256-pinned in tools/release.zig; no third-party action is allowed)", .{ name, install_cosign_run });
    }
    if (built == null or built.? > installed.?) try c.problem(a, out, prefix ++ "release.yml: {s} must build tools/release.zig before it installs cosign with it", .{name});
    if (used != null and installed.? > used.?) try c.problem(a, out, prefix ++ "release.yml: {s} must install cosign before the step that uses it (`{s}`)", .{ name, user });
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

/// The `name:` of every actions/upload-artifact step of `job`, in order.
fn uploadedNames(a: Allocator, job: Value) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    const steps = c.get(job, "steps") orelse return out.items;
    if (steps != .array) return out.items;
    for (steps.array.items) |st| {
        const u = c.str(c.get(st, "uses")) orelse continue;
        if (!std.mem.startsWith(u8, u, "actions/upload-artifact@")) continue;
        try out.append(c.str(c.get(c.get(st, "with"), "name")) orelse "(no name)");
    }
    return out.items;
}

/// What differs between release-beta-user.yml and its rules, one line each: the matrix holds exactly
/// the three platforms and none can be skipped, optional or allowed to fail, the candidate comes from
/// the build's artifact, and the walk is the driver run with the version.
pub fn userBetaProblems(a: Allocator, text: []const u8, out: *Out) !void {
    const f = "release-beta-user.yml: ";
    const doc = c.load(a, text) catch |err| return c.problem(a, out, prefix ++ f ++ "not readable as YAML: {s}", .{@errorName(err)});
    try actionProblems(a, "release-beta-user.yml", text, out);
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
