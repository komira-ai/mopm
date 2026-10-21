//! The repository hygiene scan, run by Buck2 (//:hygiene). Its messages read (`hygiene: <file>: <rule>`).
//!
//! Two halves:
//!   - `textProblems`: the secret and identifier patterns over the bytes of
//!     every tracked text file (a file holding a NUL byte is binary and skipped);
//!   - `structureProblems`: which workflows may hold an id-token grant or a
//!     deployment environment, and how they may be triggered.
//!
//! Each Ruby regular expression is a hand-written matcher below, named by the
//! rule it implements; tests/drivers/hygiene_test.zig plants one sample per
//! rule and one near miss, so a matcher that stops matching fails the build.
//! There is no allow-list: a sample that needs a key-shaped value builds it at
//! run time, and so must any new test.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

pub const prefix = "hygiene: ";

// ---- the text rules --------------------------------------------------------

/// \b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ABIA|ACCA)[0-9A-Z]{16}\b
fn awsAccessKeyId(s: []const u8) bool {
    const heads = [_][]const u8{ "AKIA", "ASIA", "AGPA", "AIDA", "AROA", "ANPA", "ABIA", "ACCA" };
    var i: usize = 0;
    while (i + 20 <= s.len) : (i += 1) {
        if (!c.boundaryBefore(s, i)) continue;
        var head = false;
        for (heads) |h| {
            if (std.mem.startsWith(u8, s[i..], h)) head = true;
        }
        if (!head) continue;
        var ok = true;
        for (s[i + 4 .. i + 20]) |ch| {
            if (!((ch >= '0' and ch <= '9') or (ch >= 'A' and ch <= 'Z'))) ok = false;
        }
        if (ok and c.boundaryAfter(s, i + 20)) return true;
    }
    return false;
}

/// <key>\s*[=:]\s*\S{20,} (case-insensitive; `key` is lower case): the value
/// is at least 20 characters of non-space after the separator.
fn assignment(a: Allocator, s: []const u8, key: []const u8) !bool {
    const low = try c.lower(a, s);
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, low, from, key)) |i| : (from = i + 1) {
        var j = i + key.len;
        while (j < s.len and c.isSpace(s[j])) j += 1;
        if (j >= s.len or (s[j] != '=' and s[j] != ':')) continue;
        j += 1;
        while (j < s.len and c.isSpace(s[j])) j += 1;
        var chars: usize = 0;
        while (j < s.len and !c.isSpace(s[j])) : (j += 1) {
            if (s[j] & 0xC0 != 0x80) chars += 1;
        }
        if (chars >= 20) return true;
    }
    return false;
}

/// -{5}BEGIN [A-Z ]*PRIVATE KEY-{5}
fn privateKeyBlock(s: []const u8) bool {
    const head = "-----BEGIN ";
    const tail = "PRIVATE KEY";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, head)) |i| : (from = i + 1) {
        const body = i + head.len;
        var j = body;
        while (j < s.len and ((s[j] >= 'A' and s[j] <= 'Z') or s[j] == ' ')) j += 1;
        // The run of capitals and spaces must end in PRIVATE KEY, then five dashes.
        if (j - body >= tail.len and std.mem.eql(u8, s[j - tail.len .. j], tail) and std.mem.startsWith(u8, s[j..], "-----")) return true;
    }
    return false;
}

fn runOf(s: []const u8, from: usize, comptime class: fn (u8) bool) usize {
    var j = from;
    while (j < s.len and class(s[j])) j += 1;
    return j - from;
}

fn isAlnumOnly(ch: u8) bool {
    return c.isAlnum(ch);
}

fn isAlnumUnderscore(ch: u8) bool {
    return c.isAlnum(ch) or ch == '_';
}

fn isTokenDash(ch: u8) bool {
    return c.isAlnum(ch) or ch == '-';
}

fn isJwtChar(ch: u8) bool {
    return c.isAlnum(ch) or ch == '_' or ch == '-';
}

/// \b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{20,})\b
fn githubToken(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (!c.boundaryBefore(s, i)) continue;
        if (std.mem.startsWith(u8, s[i..], "gh") and i + 3 < s.len and std.mem.indexOfScalar(u8, "pousr", s[i + 2]) != null and s[i + 3] == '_') {
            const n = runOf(s, i + 4, isAlnumOnly);
            // A longer run would end on a word character, so only the whole run can sit before \b.
            if (n >= 30 and c.boundaryAfter(s, i + 4 + n)) return true;
        }
        if (std.mem.startsWith(u8, s[i..], "github_pat_")) {
            const from = i + "github_pat_".len;
            const n = runOf(s, from, isAlnumUnderscore);
            if (n >= 20 and c.boundaryAfter(s, from + n)) return true;
        }
    }
    return false;
}

/// \bxox[abprs]-[A-Za-z0-9-]{10,}
fn slackToken(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "xox")) |i| : (from = i + 1) {
        if (!c.boundaryBefore(s, i)) continue;
        if (i + 5 >= s.len or std.mem.indexOfScalar(u8, "abprs", s[i + 3]) == null or s[i + 4] != '-') continue;
        if (runOf(s, i + 5, isTokenDash) >= 10) return true;
    }
    return false;
}

/// \beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.
fn jwt(s: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, "eyJ")) |i| : (from = i + 1) {
        if (!c.boundaryBefore(s, i)) continue;
        const n1 = runOf(s, i + 3, isJwtChar);
        var j = i + 3 + n1;
        if (n1 < 10 or j >= s.len or s[j] != '.') continue;
        j += 1;
        if (!std.mem.startsWith(u8, s[j..], "eyJ")) continue;
        const n2 = runOf(s, j + 3, isJwtChar);
        const k = j + 3 + n2;
        if (n2 >= 10 and k < s.len and s[k] == '.') return true;
    }
    return false;
}

fn isLowerDash(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or ch == '-';
}

fn isLowerDigitDash(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '-';
}

fn isDigit(ch: u8) bool {
    return ch >= '0' and ch <= '9';
}

/// arn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:[0-9]{12}:
fn arnWithAccount(s: []const u8) bool {
    const head = "arn:aws";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, s, from, head)) |i| : (from = i + 1) {
        var j = i + head.len;
        j += runOf(s, j, isLowerDash);
        if (j >= s.len or s[j] != ':') continue;
        j += 1;
        j += runOf(s, j, isLowerDigitDash);
        if (j >= s.len or s[j] != ':') continue;
        j += 1;
        j += runOf(s, j, isLowerDigitDash);
        if (j >= s.len or s[j] != ':') continue;
        j += 1;
        if (runOf(s, j, isDigit) >= 12 and j + 12 < s.len and s[j + 12] == ':') return true;
    }
    return false;
}

/// The privileged pull-request trigger, spelled in two pieces so this file does not match itself.
fn privilegedTrigger(s: []const u8) bool {
    return std.mem.indexOf(u8, s, "pull_request_" ++ "target") != null;
}

/// (?<![0-9A-Za-z])[0-9]{12}(?![0-9A-Za-z]): a run of exactly twelve digits
/// with no letter either side. (A longer digit run has a digit before every
/// start but its first, and that start sees a thirteenth digit.)
fn accountIdShaped(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) {
        if (!isDigit(s[i])) {
            i += 1;
            continue;
        }
        const n = runOf(s, i, isDigit);
        const before_ok = i == 0 or !c.isAlnum(s[i - 1]);
        const after_ok = i + n >= s.len or !c.isAlnum(s[i + n]);
        if (n == 12 and before_ok and after_ok) return true;
        i += n;
    }
    return false;
}

/// Every problem the text rules find in one file's bytes, as
/// `hygiene: <file>: <rule>`.
pub fn textProblems(a: Allocator, f: []const u8, data: []const u8, out: *Out) !void {
    if (std.mem.indexOfScalar(u8, data, 0) != null) return;
    const Rule = struct { name: []const u8, hit: bool };
    // Bracket tricks keep the key names in two pieces: this file is scanned too.
    const rules = [_]Rule{
        .{ .name = "AWS access key id", .hit = awsAccessKeyId(data) },
        .{ .name = "AWS secret key assignment", .hit = try assignment(a, data, "aws_secret_access_ke" ++ "y") },
        .{ .name = "AWS session token", .hit = try assignment(a, data, "aws_session_toke" ++ "n") },
        .{ .name = "private key block", .hit = privateKeyBlock(data) },
        .{ .name = "GitHub token", .hit = githubToken(data) },
        .{ .name = "Slack token", .hit = slackToken(data) },
        .{ .name = "JWT", .hit = jwt(data) },
        .{ .name = "ARN carrying an account id", .hit = arnWithAccount(data) },
        .{ .name = "privileged PR-target trigger", .hit = privilegedTrigger(data) },
    };
    for (rules) |r| if (r.hit) try c.problem(a, out, prefix ++ "{s}: {s}", .{ f, r.name });
    if (accountIdShaped(data)) try c.problem(a, out, prefix ++ "{s}: 12-digit number that looks like an account id", .{f});
}

// ---- the workflow structure rules ------------------------------------------

const oidc_files = [_][]const u8{ "deploy.yml", "e2e.yml", "promote.yml" };
/// The one other file allowed an id-token grant: it prints OIDC claims and holds no AWS access.
const subject_check = "oidc-subject-check.yml";
/// farm.yml runs on pull_request and on push to main, and holds an id-token grant for komira's
/// farm-connect action. Allowed only for a push to main or a pull request from a branch of this
/// repository, with no environment and no secret.
const farm_file = "farm.yml";
/// release.yml publishes a release with build-provenance attestations, so its publish job holds an
/// id-token grant (the attestation is signed with the job's OIDC token; no cloud access). Allowed only
/// when the triggers are a push to main and a manual run, with no secret but the release bot's key and the
/// archive signing key (the apt-index jobs), no environment but `release` (on exactly the jobs that read RELEASE_BOT_*),
/// `apt-signing` (APT_GPG_*) and `apt-publish` (APT_PUBLISH_*), and no id-token on a job that calls another workflow.
const release_file = "release.yml";
/// The environment that holds the release bot's key, restricted to main.
const release_environment = "release";
/// The environments of the apt jobs: the variables of the shared repository and the role's trust (publish), the archive signing key (signing).
const apt_publish_environment = "apt-publish";
const apt_signing_environment = "apt-signing";

/// The pull-request tier: a pull request runs build and unit tests only. These four workflows are the only ones that may
/// run on pull_request (ci.yml: its unit jobs; lint.yml: the lints, the release lint included; farm.yml: the unit build on the test farm;
/// service-ci.yml: the unit tests of the service packages). Everything else (the release machinery, the end-to-end runs) runs after the
/// merge. The oidc files and farm.yml, release.yml have rules of their own above.
const pr_files = [_][]const u8{ "ci.yml", "lint.yml", "farm.yml", "service-ci.yml", "autopin-compute.yml", "pin-verify.yml" };
/// autopin-commit.yml is the privileged half of the Dependabot pin update: triggered by the end of autopin-compute alone, never by a
/// pull request, and the one workflow outside the deploy ones that declares an environment (`autopin`, holding the App's key). It has
/// no id-token. autopin_lint.zig holds the rest (the gate, the token's scope, the order of its steps).
const autopin_commit_file = "autopin-commit.yml";
/// The jobs of ci.yml that run on a pull request (the unit tier). Every other job of ci.yml is beta and must say `if: github.event_name != 'pull_request'`.
const ci_unit_jobs = [_][]const u8{ "test", "registry-build" };

fn isOidcFile(base: []const u8) bool {
    return c.containsStr(&oidc_files, base);
}

/// /\bsecrets\.|\baws\s|AWS_|role-to-assume|configure-aws|aws-actions/i over `s`.
fn subjectCheckUsesAws(a: Allocator, s: []const u8) !bool {
    const low = try c.lower(a, s);
    if (c.hasWordStart(low, "secrets.")) return true;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, low, from, "aws")) |i| : (from = i + 1) {
        if (c.boundaryBefore(low, i) and i + 3 < low.len and c.isSpace(low[i + 3])) return true;
    }
    for ([_][]const u8{ "aws_", "role-to-assume", "configure-aws", "aws-actions" }) |needle| {
        if (std.mem.indexOf(u8, low, needle) != null) return true;
    }
    return false;
}

const Job = struct { name: []const u8, node: Value };

fn jobEntries(a: Allocator, doc: Value) ![]const Job {
    var out = std.ArrayList(Job).init(a);
    const jobs = c.get(doc, "jobs") orelse return out.items;
    if (jobs != .object) return out.items;
    var it = jobs.object.iterator();
    while (it.next()) |e| try out.append(.{ .name = e.key_ptr.*, .node = e.value_ptr.* });
    return out.items;
}

/// The whole `if:` is the guard (optionally in `${{ }}`): a substring test would pass `... || true`.
fn isBetaGuard(expr: []const u8) bool {
    var e = std.mem.trim(u8, expr, " \r\n\t");
    if (std.mem.startsWith(u8, e, "${{") and std.mem.endsWith(u8, e, "}}")) e = std.mem.trim(u8, e[3 .. e.len - 2], " ");
    return std.mem.eql(u8, e, "github.event_name != 'pull_request'");
}

fn jobIf(a: Allocator, job: Value) ![]const u8 {
    return c.toS(a, c.get(job, "if"));
}

/// The id-token and trigger rules for one workflow file. `f` is the path as
/// the messages show it; its base name picks the rules, as in the Ruby.
pub fn structureProblems(a: Allocator, f: []const u8, text: []const u8, out: *Out) !void {
    const base = c.basename(f);
    const doc = c.load(a, text) catch |err| {
        try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ f, @errorName(err) });
        return;
    };
    const on = try c.onKeys(a, doc);
    const jobs = try jobEntries(a, doc);

    if (std.mem.eql(u8, base, subject_check)) {
        if (!(on.len == 1 and std.mem.eql(u8, on[0], "workflow_dispatch"))) {
            try c.problem(a, out, prefix ++ "{s}: triggers must be exactly workflow_dispatch", .{f});
        }
        if (try subjectCheckUsesAws(a, try c.nonCommentLines(a, text))) {
            try c.problem(a, out, prefix ++ "{s}: must not use AWS or secrets", .{f});
        }
        for (jobs) |j| {
            if (!c.findKey(j.node, "id-token")) continue;
            const env = c.get(j.node, "environment");
            if (!(c.isNil(env) or c.isStr(env, "beta"))) {
                try c.problem(a, out, prefix ++ "{s}: job {s}: environment must be absent or beta, not {s}", .{ f, j.name, try c.inspect(a, env) });
            }
            if (std.mem.indexOf(u8, try jobIf(a, j.node), "refs/heads/main") == null) {
                try c.problem(a, out, prefix ++ "{s}: job {s} grants id-token but is not restricted to refs/heads/main", .{ f, j.name });
            }
        }
        return;
    }

    if (std.mem.eql(u8, base, farm_file)) {
        // pull_request, and push to main alone (the farm must be configured there: the job fails
        // when it is not, so a merge never goes unbuilt).
        const push = c.get(c.onValue(doc), "push");
        const pr_and_push = on.len == 2 and c.containsStr(on, "pull_request") and c.containsStr(on, "push");
        const push_main = push != null and push.? == .object and push.?.object.count() == 1 and blk: {
            const br = c.get(push, "branches") orelse break :blk false;
            break :blk br == .array and br.array.items.len == 1 and c.isStr(br.array.items[0], "main");
        };
        if (!(pr_and_push and push_main)) {
            try c.problem(a, out, prefix ++ "{s}: triggers must be exactly pull_request and push of branches [main]", .{f});
        }
        if (c.findKey(doc, "environment") or c.mentionsSecretsDot(try c.nonCommentLines(a, text))) {
            try c.problem(a, out, prefix ++ "{s}: must not use secrets or an environment", .{f});
        }
        for (jobs) |j| {
            if (!c.findKey(j.node, "id-token")) continue;
            if (std.mem.indexOf(u8, try jobIf(a, j.node), "github.event.pull_request.head.repo.full_name == github.repository") == null) {
                try c.problem(a, out, prefix ++ "{s}: job {s} grants id-token but does not skip pull requests from forks", .{ f, j.name });
            }
        }
        return;
    }

    if (std.mem.eql(u8, base, release_file)) {
        // on.keys == ["push", "workflow_dispatch"] && push has branches == ["main"] and nothing but paths-ignore
        const sorted_on = try a.dupe([]const u8, on);
        std.mem.sort([]const u8, sorted_on, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        const push = c.get(c.onValue(doc), "push");
        var main_push = c.eqlList(sorted_on, &.{ "push", "workflow_dispatch" }) and push != null and push.? == .object;
        if (main_push) {
            for (push.?.object.keys()) |k| {
                if (!std.mem.eql(u8, k, "branches") and !std.mem.eql(u8, k, "paths-ignore")) main_push = false;
            }
            const branches = c.get(push, "branches");
            if (!(branches != null and branches.? == .array and branches.?.array.items.len == 1 and c.isStr(branches.?.array.items[0], "main"))) main_push = false;
        }
        if (!main_push) try c.problem(a, out, prefix ++ "{s}: triggers must be exactly push to branches [main] (paths-ignore allowed) and workflow_dispatch", .{f});
        if (c.mentionsSecretsDot(try releaseSecretFree(a, text))) {
            try c.problem(a, out, prefix ++ "{s}: must not use secrets or an environment", .{f});
        }
        // The one environment is `release`, on exactly the jobs that read RELEASE_BOT_*; the workflow itself has none.
        if (c.get(doc, "environment") != null) {
            try c.problem(a, out, prefix ++ "{s}: must not use secrets or an environment", .{f});
        }
        for (jobs) |j| {
            const body = try c.inspect(a, j.node);
            const reads_bot = std.mem.indexOf(u8, body, "RELEASE_BOT") != null;
            const reads_signing = std.mem.indexOf(u8, body, "APT_GPG") != null;
            const reads_publish = std.mem.indexOf(u8, body, "APT_PUBLISH") != null;
            const env = c.get(j.node, "environment");
            if (reads_bot and !c.isStr(env, release_environment)) {
                try c.problem(a, out, prefix ++ "{s}: job {s} reads RELEASE_BOT_* so it must declare environment {s}, got {s}", .{ f, j.name, release_environment, try c.inspect(a, env) });
            } else if (reads_signing and !reads_bot and !c.isStr(env, apt_signing_environment)) {
                try c.problem(a, out, prefix ++ "{s}: job {s} reads APT_GPG_* so it must declare environment {s}, got {s}", .{ f, j.name, apt_signing_environment, try c.inspect(a, env) });
            } else if (reads_publish and !reads_bot and !reads_signing and !c.isStr(env, apt_publish_environment)) {
                try c.problem(a, out, prefix ++ "{s}: job {s} reads APT_PUBLISH_* so it must declare environment {s}, got {s}", .{ f, j.name, apt_publish_environment, try c.inspect(a, env) });
            } else if (!reads_bot and !reads_signing and !reads_publish and env != null) {
                try c.problem(a, out, prefix ++ "{s}: job {s}: must not use secrets or an environment (only jobs that read RELEASE_BOT_*, APT_GPG_* or APT_PUBLISH_* declare one)", .{ f, j.name });
            }
        }
        for (jobs) |j| {
            if (j.node == .object and j.node.object.contains("uses") and c.findKey(j.node, "id-token")) {
                try c.problem(a, out, prefix ++ "{s}: job {s} calls a workflow and grants id-token", .{ f, j.name });
            }
        }
        return;
    }

    if (std.mem.eql(u8, base, autopin_commit_file)) {
        if (!(on.len == 1 and std.mem.eql(u8, on[0], "workflow_run"))) {
            try c.problem(a, out, prefix ++ "{s}: triggers must be exactly workflow_run", .{f});
        }
        if (c.findKey(doc, "id-token")) try c.problem(a, out, prefix ++ "{s}: an id-token permission is only allowed in deploy.yml, e2e.yml, promote.yml", .{f});
        return;
    }

    const oidc_list = "deploy.yml, e2e.yml, promote.yml";
    const has_id_token = c.findKey(doc, "id-token");
    const has_environment = c.findKey(doc, "environment");
    if (has_id_token and !isOidcFile(base)) {
        try c.problem(a, out, prefix ++ "{s}: an id-token permission is only allowed in {s}", .{ f, oidc_list });
    }
    if (has_environment and !isOidcFile(base)) {
        try c.problem(a, out, prefix ++ "{s}: only {s} may use a deployment environment", .{ f, oidc_list });
    }
    if (c.containsStr(on, "pull_request") and (has_id_token or has_environment)) {
        try c.problem(a, out, prefix ++ "{s}: a workflow with id-token or an environment must not run on pull_request", .{f});
    }
    if (c.containsStr(on, "pull_request") and !c.containsStr(&pr_files, base) and !isOidcFile(base)) {
        try c.problem(a, out, prefix ++ "{s}: a pull request runs build and unit tests only, so only ci.yml, lint.yml, farm.yml and service-ci.yml may run on pull_request", .{f});
    }
    if (std.mem.eql(u8, base, "ci.yml") and c.containsStr(on, "pull_request")) {
        for (jobs) |j| {
            if (c.containsStr(&ci_unit_jobs, j.name)) continue;
            if (!isBetaGuard(try jobIf(a, j.node))) {
                try c.problem(a, out, prefix ++ "{s}: job {s} is not a unit job, so its `if:` must be exactly `github.event_name != 'pull_request'` (beta runs after the merge, never on a pull request; any `||` clause would let it run)", .{ f, j.name });
            }
        }
    }
    if ((std.mem.eql(u8, base, "lint.yml") or std.mem.eql(u8, base, "ci.yml")) and c.containsStr(on, "pull_request")) {
        // A filter makes the check skip for some pull requests (a docs-only change, another base branch, a label event), and a
        // skipped check is a check that did not run. `types` may only add to the defaults (ci.yml adds `labeled` for the macOS opt-in).
        const pr = c.get(c.onValue(doc), "pull_request");
        for (c.keys(pr)) |k| {
            if (std.mem.eql(u8, k, "types")) {
                const types = try c.arrayOf(a, c.get(pr, "types"));
                for ([_][]const u8{ "opened", "synchronize", "reopened" }) |dflt| {
                    if (!c.containsStr(types, dflt)) try c.problem(a, out, prefix ++ "{s}: the pull_request trigger's types must keep {s} (the defaults are opened, synchronize, reopened; more may be added)", .{ f, dflt });
                }
            } else {
                try c.problem(a, out, prefix ++ "{s}: the pull_request trigger must have no {s} filter: every pull request gets this check", .{ f, k });
            }
        }
    }
    if (std.mem.eql(u8, base, "lint.yml")) {
        if (!c.containsStr(on, "pull_request")) try c.problem(a, out, prefix ++ "{s}: the lints must run on pull_request", .{f});
        // A job-level `if:` can skip the whole job, and the check with it; only `!cancelled()` (run unless the run was cancelled) is allowed.
        for (jobs) |j| {
            if (c.get(j.node, "if") == null) continue;
            var cond = std.mem.trim(u8, try jobIf(a, j.node), " \r\n\t");
            if (std.mem.startsWith(u8, cond, "${{") and std.mem.endsWith(u8, cond, "}}")) cond = std.mem.trim(u8, cond[3 .. cond.len - 2], " ");
            if (!std.mem.eql(u8, cond, "!cancelled()")) try c.problem(a, out, prefix ++ "{s}: job {s} has an `if:` ({s}); a lint job may carry none, or exactly `!cancelled()`, so it cannot be skipped", .{ f, j.name, cond });
        }
        var runs_release_lint = false;
        for (jobs) |j| {
            if (c.truthy(c.get(j.node, "continue-on-error"))) continue;
            const steps = c.get(j.node, "steps") orelse continue;
            if (steps != .array) continue;
            for (steps.array.items) |st| {
                const step_run = c.str(c.get(st, "run")) orelse continue;
                if (!std.mem.eql(u8, std.mem.trim(u8, step_run, " \r\n\t"), "zig test tests/drivers/release_lint_test.zig")) continue;
                if (c.truthy(c.get(st, "continue-on-error"))) continue;
                const cond = std.mem.trim(u8, try jobIf(a, st), " ");
                if (cond.len == 0 or std.mem.eql(u8, cond, "${{ !cancelled() }}")) runs_release_lint = true;
            }
        }
        if (!runs_release_lint) try c.problem(a, out, prefix ++ "{s}: no step runs `zig test tests/drivers/release_lint_test.zig` unconditionally (or under `!cancelled()`) without continue-on-error; the release lint, the .deb wiring included, runs on every pull request", .{f});
    }
    if (!isOidcFile(base)) return;

    var extra = std.ArrayList([]const u8).init(a);
    for (on) |k| {
        if (!c.containsStr(&.{ "workflow_call", "workflow_dispatch", "push" }, k)) try extra.append(k);
    }
    if (extra.items.len != 0) {
        try c.problem(a, out, prefix ++ "{s}: triggers {s} are not allowed in a workflow that can use id-token", .{ f, try c.inspectList(a, extra.items) });
    }
    if (c.containsStr(on, "push")) {
        // (on["push"] || {}).fetch("branches", nil) != ["main"]
        const push = c.get(c.onValue(doc), "push");
        const branches = c.get(if (c.truthy(push)) push else null, "branches");
        const only_main = branches != null and branches.? == .array and branches.?.array.items.len == 1 and c.isStr(branches.?.array.items[0], "main");
        if (!only_main) try c.problem(a, out, prefix ++ "{s}: push must be limited to branches: [main]", .{f});
    }
    for (jobs) |j| {
        if (j.node == .object and j.node.object.contains("uses")) continue; // a reusable-workflow call; the called file is checked on its own
        if (!c.findKey(j.node, "id-token")) continue;
        if (!c.truthy(c.get(j.node, "environment"))) {
            try c.problem(a, out, prefix ++ "{s}: job {s} grants id-token without an environment", .{ f, j.name });
        }
        if (std.mem.indexOf(u8, try jobIf(a, j.node), "refs/heads/main") == null) {
            try c.problem(a, out, prefix ++ "{s}: job {s} grants id-token but is not restricted to refs/heads/main", .{ f, j.name });
        }
    }
}

/// Given paths (the self-test): the text rules over each path, then the
/// structure rules over the paths that end in .yml or .yaml. (Without
/// arguments the structure rules run over .github/workflows only: `repo`.)
pub fn run(a: Allocator, files: []const File, structure: []const File, out: *Out) !void {
    for (files) |f| try textProblems(a, f.path, f.data, out);
    for (structure) |f| try structureProblems(a, f.path, f.data, out);
}

pub const File = struct { path: []const u8, data: []const u8 };

/// One reference to a secret that release.yml may make: how many times, and what it is for.
const AllowedSecret = struct { ref: []const u8, times: usize };

/// The secrets release.yml may reference, each exactly this many times at most. The tag, tap and bump jobs each hand the key of the release
/// bot's GitHub App to actions/create-github-app-token. The apt-index jobs (three attempts, release_lint.zig holds where) read the archive signing
/// key in their signing step (the key and its passphrase), in their gate only whether the key exists (a comparison with the empty string,
/// which puts no secret into the environment), and the fingerprint of the signing subkey, which may be a secret or a variable, in the gate and in the signing step.
const allowed_secrets = [_]AllowedSecret{
    .{ .ref = "${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", .times = 3 },
    .{ .ref = "${{ secrets.APT_GPG_PRIVATE_KEY }}", .times = 3 },
    .{ .ref = "${{ secrets.APT_GPG_PASSPHRASE }}", .times = 3 },
    .{ .ref = "${{ secrets.APT_GPG_PRIVATE_KEY != '' }}", .times = 3 },
    .{ .ref = "${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}", .times = 6 },
};

/// The text of release.yml (comments dropped) without its allowed secret references (`allowed_secrets`). At most that many of each are removed;
/// one more, or any other `secrets.`, is still a finding.
fn releaseSecretFree(a: Allocator, text: []const u8) ![]u8 {
    var s = try c.nonCommentLines(a, text);
    for (allowed_secrets) |allowed| {
        for (0..allowed.times) |_| {
            const at = std.mem.indexOf(u8, s, allowed.ref) orelse break;
            s = try std.mem.concat(a, u8, &.{ s[0..at], s[at + allowed.ref.len ..] });
        }
    }
    return s;
}

/// kpin-update.yml's KPIN_SETS names, one line per lock (`<pins.toml> <pins.lock.bzl> [<package-lock.json>...]`), the
/// weekly update's whole set of npm locks, and the job refuses to start when it differs from the pins.lock.bzl files
/// of the tree. That check runs weekly, so a new lock (site/pins.lock.bzl, which turned the 19 October run red) went
/// unnoticed for days. This is the same comparison on every pull request: one finding per lock the tree has and
/// KPIN_SETS lacks, and per lock KPIN_SETS names that the tree lacks. `workflow` is the text of kpin-update.yml,
/// `files` the repository's paths. The block is read as text: the lines under `KPIN_SETS: |` that are indented
/// deeper than the key, to the first line that is not.
pub fn kpinSetsProblems(a: Allocator, workflow: []const u8, files: []const []const u8, out: *Out) !void {
    const key = "KPIN_SETS: |";
    const at = std.mem.indexOf(u8, workflow, key) orelse {
        try c.problem(a, out, prefix ++ "kpin-update.yml: no `KPIN_SETS: |` block", .{});
        return;
    };
    // The key's own indent: the characters between the start of its line and the key.
    const line_start = if (std.mem.lastIndexOfScalar(u8, workflow[0..at], '\n')) |n| n + 1 else 0;
    const key_indent = at - line_start;
    var listed = std.ArrayList([]const u8).init(a);
    var lines = std.mem.splitScalar(u8, workflow[at + key.len ..], '\n');
    _ = lines.next(); // the rest of the key's own line
    while (lines.next()) |line| {
        var indent: usize = 0;
        while (indent < line.len and line[indent] == ' ') indent += 1;
        if (indent == line.len) continue; // a blank line
        if (indent <= key_indent) break;
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        _ = words.next(); // the pins.toml
        const lock = words.next() orelse continue;
        try listed.append(lock);
    }
    if (listed.items.len == 0) try c.problem(a, out, prefix ++ "kpin-update.yml: KPIN_SETS names no lock", .{});
    for (files) |f| {
        if (!std.mem.eql(u8, c.basename(f), "pins.lock.bzl")) continue;
        if (!c.containsStr(listed.items, f)) {
            try c.problem(a, out, prefix ++ "kpin-update.yml: KPIN_SETS has no line for {s}: the weekly update would fail at its first step", .{f});
        }
    }
    for (listed.items) |l| {
        var present = false;
        for (files) |f| {
            if (std.mem.eql(u8, f, l)) present = true;
        }
        if (!present) try c.problem(a, out, prefix ++ "kpin-update.yml: KPIN_SETS names {s}, which is not in the repository", .{l});
    }
}

/// autopin-compute.yml's `--set DIR=KIND` arguments are SETS, the directories the Dependabot pin update may regenerate (autopin_lint.zig
/// holds that the other autopin workflows carry the same list). A directory with a package-lock.json that SETS lacks is a package whose
/// Dependabot pull requests are left to a person; a SETS entry without a package-lock.json would make every compute run fail. The same
/// comparison as KPIN_SETS, on every pull request. `workflow` is the text of autopin-compute.yml, `files` the repository's paths.
pub fn autopinSetsProblems(a: Allocator, workflow: []const u8, files: []const []const u8, out: *Out) !void {
    var listed = std.ArrayList([]const u8).init(a);
    var words = std.mem.tokenizeAny(u8, try c.nonCommentLines(a, workflow), " \t\r\n");
    var after_set = false;
    while (words.next()) |w| {
        if (after_set) {
            after_set = false;
            const eq = std.mem.lastIndexOfScalar(u8, w, '=') orelse {
                try c.problem(a, out, prefix ++ "autopin-compute.yml: --set {s} is not DIR=KIND", .{w});
                continue;
            };
            try listed.append(w[0..eq]);
            continue;
        }
        after_set = std.mem.eql(u8, w, "--set");
    }
    if (listed.items.len == 0) try c.problem(a, out, prefix ++ "autopin-compute.yml: no `--set DIR=KIND` argument", .{});
    for (files) |f| {
        if (!std.mem.eql(u8, c.basename(f), "package-lock.json")) continue;
        const dir = std.fs.path.dirname(f) orelse ".";
        if (!c.containsStr(listed.items, dir)) {
            try c.problem(a, out, prefix ++ "autopin-compute.yml: no --set for {s} (it has a package-lock.json): its Dependabot pull requests would be left to a person", .{dir});
        }
    }
    for (listed.items) |dir| {
        const lock = if (std.mem.eql(u8, dir, ".")) "package-lock.json" else try std.fmt.allocPrint(a, "{s}/package-lock.json", .{dir});
        if (!c.containsStr(files, lock)) {
            try c.problem(a, out, prefix ++ "autopin-compute.yml: --set names {s}, which has no package-lock.json in the repository", .{dir});
        }
    }
}

/// The targets BUCK builds with `_MOJO_TOOLS` (the real Mojo toolchain): the rules whose `exec_tools` is `_MOJO_TOOLS` or
/// `dict(_MOJO_TOOLS, ...)`. A rule is a block that opens at column 0; its name is the `name = "..."` line at four spaces.
pub fn mojoToolTargets(a: Allocator, buck: []const u8) ![]const []const u8 {
    var found = std.ArrayList([]const u8).init(a);
    var name: []const u8 = "";
    var lines = std.mem.splitScalar(u8, buck, '\n');
    while (lines.next()) |line| {
        if (line.len != 0 and line[0] != ' ' and line[0] != ')' and line[0] != '#') name = "";
        const named = "    name = \"";
        if (std.mem.startsWith(u8, line, named)) {
            const rest = line[named.len..];
            if (std.mem.indexOfScalar(u8, rest, '"')) |end| name = rest[0..end];
        }
        const t = std.mem.trim(u8, line, " ");
        if (name.len != 0 and std.mem.startsWith(u8, t, "exec_tools = ") and std.mem.indexOf(u8, t, "_MOJO_TOOLS") != null) {
            if (!c.containsStr(found.items, name)) try found.append(name);
        }
    }
    return found.items;
}

/// farm.yml's pull request build excludes `set(//:a //:b ...)` from `//...`: the beta targets, which run after the merge.
/// Those must be exactly the targets BUCK builds with `_MOJO_TOOLS`, or a new beta target would run on every pull request (or a
/// unit one would be left out of it) with nothing red. One finding per target on one side only.
pub fn farmExclusionProblems(a: Allocator, buck: []const u8, farm: []const u8, out: *Out) !void {
    const want = try mojoToolTargets(a, buck);
    if (want.len == 0) try c.problem(a, out, prefix ++ "BUCK: no target is built with _MOJO_TOOLS, so the farm.yml exclusion list cannot be checked (did the parser lose the BUCK layout?)", .{});
    const head = "//... - set(";
    const at = std.mem.indexOf(u8, farm, head) orelse {
        try c.problem(a, out, prefix ++ "farm.yml: no `//... - set(` exclusion list in the pull request build", .{});
        return;
    };
    const rest = farm[at + head.len ..];
    const close = std.mem.indexOfScalar(u8, rest, ')') orelse {
        try c.problem(a, out, prefix ++ "farm.yml: the exclusion list has no closing parenthesis", .{});
        return;
    };
    var listed = std.ArrayList([]const u8).init(a);
    var words = std.mem.tokenizeScalar(u8, rest[0..close], ' ');
    while (words.next()) |w| {
        if (!std.mem.startsWith(u8, w, "//:")) {
            try c.problem(a, out, prefix ++ "farm.yml: the exclusion list holds {s}, which is not a root target //:name", .{w});
            continue;
        }
        try listed.append(w[3..]);
    }
    for (want) |n| {
        if (!c.containsStr(listed.items, n)) try c.problem(a, out, prefix ++ "farm.yml: //:{s} is built with _MOJO_TOOLS in BUCK (a beta target) but is not excluded from the pull request build", .{n});
    }
    for (listed.items) |n| {
        if (!c.containsStr(want, n)) try c.problem(a, out, prefix ++ "farm.yml: //:{s} is excluded from the pull request build but BUCK does not build it with _MOJO_TOOLS", .{n});
    }
}

// ---- dependabot.yml -----------------------------------------------------------

/// The cooldown, in days, every npm entry of .github/dependabot.yml must carry at least (`cooldown.default-days`): a
/// newly published version is proposed only after it has been public that long. Version updates only; security updates
/// ignore it.
pub const min_cooldown_days: i64 = 7;

/// The pattern a group must carry for a directory whose package.json depends on any package matching it.
pub const aws_sdk_pattern = "@aws-sdk/*";

/// Some group of `groups` lists `pattern` among its `patterns`.
fn groupCovers(groups: ?Value, pattern: []const u8) bool {
    for (c.keys(groups)) |name| {
        const pats = c.get(c.get(groups, name), "patterns") orelse continue;
        if (pats != .array) continue;
        for (pats.array.items) |p| if (c.isStr(p, pattern)) return true;
    }
    return false;
}

/// `dir`'s package.json (if it has one) lists a dependency whose name starts with "@aws-sdk/".
fn dependsOnAwsSdk(a: Allocator, tree: c.Tree, dir: []const u8) !bool {
    const rel = try std.fs.path.join(a, &.{ if (dir.len > 0 and dir[0] == '/') dir[1..] else dir, "package.json" });
    if (!c.containsStr(tree.files, rel)) return false;
    const pkg = std.json.parseFromSliceLeaky(Value, a, try tree.read(a, rel), .{}) catch return false;
    inline for (.{ "dependencies", "devDependencies", "optionalDependencies", "peerDependencies" }) |section| {
        for (c.keys(c.get(pkg, section))) |name| {
            if (std.mem.startsWith(u8, name, "@aws-sdk/")) return true;
        }
    }
    return false;
}

/// dependabot.yml against the repository's files: every `npm` entry carries `cooldown: default-days: N` with N a
/// number and N >= min_cooldown_days, an entry whose package.json depends on @aws-sdk/* has a group covering
/// "@aws-sdk/*", and every directory holding a package-lock.json has an npm entry (a package
/// Dependabot never looks at is a package whose pins only a human updates). `files` are the repository's paths.
pub fn dependabotProblems(a: Allocator, text: []const u8, tree: c.Tree, out: *Out) !void {
    const files = tree.files;
    const f = ".github/dependabot.yml";
    const doc = c.load(a, text) catch |err| {
        try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ f, @errorName(err) });
        return;
    };
    const updates = c.get(doc, "updates") orelse {
        try c.problem(a, out, prefix ++ "{s}: no `updates` list", .{f});
        return;
    };
    if (updates != .array) {
        try c.problem(a, out, prefix ++ "{s}: `updates` is not a list", .{f});
        return;
    }
    var dirs = std.ArrayList([]const u8).init(a);
    for (updates.array.items) |u| {
        if (!c.isStr(c.get(u, "package-ecosystem"), "npm")) continue;
        const dir = c.str(c.get(u, "directory")) orelse "(no directory)";
        try dirs.append(dir);
        const days = c.get(c.get(u, "cooldown"), "default-days");
        const ok = if (days) |d| switch (d) {
            .integer => |n| n >= min_cooldown_days,
            else => false,
        } else false;
        if (!ok) {
            try c.problem(a, out, prefix ++ "{s}: npm entry {s}: needs `cooldown: default-days:` of at least {d}, got {s}", .{ f, dir, min_cooldown_days, try c.inspect(a, days) });
        }
        if (try dependsOnAwsSdk(a, tree, dir) and !groupCovers(c.get(u, "groups"), aws_sdk_pattern)) {
            try c.problem(a, out, prefix ++ "{s}: npm entry {s}: its package.json depends on {s}, so it needs a `groups` entry whose `patterns` include \"{s}\" (the packages must update together)", .{ f, dir, aws_sdk_pattern, aws_sdk_pattern });
        }
    }
    for (files) |p| {
        if (!std.mem.eql(u8, c.basename(p), "package-lock.json")) continue;
        const dir = try std.mem.concat(a, u8, &.{ "/", std.fs.path.dirname(p) orelse "" });
        if (!c.containsStr(dirs.items, dir)) {
            try c.problem(a, out, prefix ++ "{s}: no npm entry for {s} (it has a package-lock.json)", .{ f, dir });
        }
    }
}
