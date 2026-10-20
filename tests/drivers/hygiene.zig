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
/// when a pushed v* tag is the sole trigger, with no environment, no secret and no id-token on a job
/// that calls another workflow.
const release_file = "release.yml";

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
        // on.keys == ["push"] && on["push"] == { "tags" => ["v*"] }
        const push = c.get(c.onValue(doc), "push");
        const only_tag = on.len == 1 and std.mem.eql(u8, on[0], "push") and push != null and push.? == .object and
            push.?.object.count() == 1 and blk: {
            const tags = c.get(push, "tags") orelse break :blk false;
            break :blk tags == .array and tags.array.items.len == 1 and c.isStr(tags.array.items[0], "v*");
        };
        if (!only_tag) try c.problem(a, out, prefix ++ "{s}: triggers must be exactly push of tags [v*], with no branches", .{f});
        if (c.findKey(doc, "environment") or c.mentionsSecretsDot(try c.nonCommentLines(a, text))) {
            try c.problem(a, out, prefix ++ "{s}: must not use secrets or an environment", .{f});
        }
        for (jobs) |j| {
            if (j.node == .object and j.node.object.contains("uses") and c.findKey(j.node, "id-token")) {
                try c.problem(a, out, prefix ++ "{s}: job {s} calls a workflow and grants id-token", .{ f, j.name });
            }
        }
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
