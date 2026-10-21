//! The workflow lint, run by Buck2 (//:workflows). Its messages read (`workflow-lint: <file>: ...`).
//!
//! `fileProblems` is the per-file half (what runs for every workflow, and for the
//! fixtures): read-only token, no `write` outside
//! the id-token grants, secrets reach a step only through env, only
//! GitHub-owned actions pinned by SHA, no step that prints a secret-bearing
//! variable, and a syntax check of every `run:` script. `repoProblems` is the
//! whole-repository half: the promotion chain, the guard jobs of deploy.yml and
//! e2e.yml, and oidc-subject-check.yml.
//!
//! One check is a stand-in: a shell has no place on the farm, so `run:` scripts are
//! syntax-checked without bash. shell_syntax.zig is the stand-in
//! and says what it does and does not catch.

const std = @import("std");
const c = @import("lint_common.zig");
const rl = @import("release_lint.zig");
const sh = @import("shell_syntax.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

pub const prefix = "workflow-lint: ";

const oidc_files = [_][]const u8{ "deploy.yml", "e2e.yml", "promote.yml", "oidc-subject-check.yml" };
/// farm.yml may also hold the id-token grant, and one action outside GitHub's own
/// (komira's farm-connect, pinned by commit); hygiene.zig holds it to its conditions.
const farm_file = "farm.yml";
/// kpin-update.yml (the weekly pin update) holds the two write grants it needs to push its branch
/// and open its pull request with the default token, nothing else, and only on a schedule or a
/// manual run: checked below.
const kpin_file = "kpin-update.yml";
const kpin_writes = [_][]const u8{ "contents", "pull-requests" };
/// release.yml (a push to main releases) holds the three write grants a release with
/// build-provenance attestations needs, on its jobs only (the top level stays read-only); release_lint.zig
/// holds each of them to the one job that may have it, and hygiene holds its triggers.
const release_file = "release.yml";
const release_writes = [_][]const u8{ "contents", "id-token", "attestations" };
/// Names whose values must never reach a log: no echo/printf/cat/tee of them.
const secret_names = [_][]const u8{ "AWS_ACCOUNT_ID", "AWS_REGION", "ROLE_ARN", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN" };
const owned_actions = [_][]const u8{ "checkout", "setup-node", "upload-artifact", "download-artifact", "attest-build-provenance" };

// ---- secret-bearing variables -----------------------------------------------

/// The length of the secret name at the start of `s` (the first alternative of
/// the Ruby alternation that matches), or null.
fn secretNameAt(s: []const u8) ?usize {
    for (secret_names) |n| if (std.mem.startsWith(u8, s, n)) return n.len;
    return null;
}

/// /\$(?:\{NAME[^}]*\}|NAME\b)/ with NAME one of the secret names.
fn secretRef(s: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, s, i, '$')) |d| : (i = d + 1) {
        const rest = s[d + 1 ..];
        if (rest.len == 0) continue;
        if (rest[0] == '{') {
            const n = secretNameAt(rest[1..]) orelse continue;
            // [^}]* then }: a closing brace somewhere after the name
            if (std.mem.indexOfScalarPos(u8, rest, 1 + n, '}') != null) return true;
        } else if (secretNameAt(rest)) |n| {
            if (c.boundaryAfter(s, d + 1 + n)) return true;
        }
    }
    return false;
}

/// The heredoc tag of /\b(?:cat|tee)\b.*<<-?\s*['"]?(\w+)['"]?/ on one line:
/// the leftmost cat or tee, then the LAST `<<` after it that is followed by a
/// word (`.*` is greedy), and that word.
pub fn heredocTag(line: []const u8) ?[]const u8 {
    var word_end: ?usize = null;
    var i: usize = 0;
    while (i + 3 <= line.len) : (i += 1) {
        const w = line[i .. i + 3];
        if ((std.mem.eql(u8, w, "cat") or std.mem.eql(u8, w, "tee")) and c.boundaryBefore(line, i) and c.boundaryAfter(line, i + 3)) {
            word_end = i + 3;
            break;
        }
    }
    const from = word_end orelse return null;
    // The line, as Ruby's `.` sees it, stops before its newline.
    const body = if (std.mem.indexOfScalar(u8, line, '\n')) |n| line[0..n] else line;
    var p = body.len;
    while (p >= from + 2) : (p -= 1) {
        if (!std.mem.eql(u8, body[p - 2 .. p], "<<")) continue;
        var q = p;
        if (q < line.len and line[q] == '-') q += 1;
        while (q < line.len and c.isSpace(line[q])) q += 1;
        if (q < line.len and (line[q] == '\'' or line[q] == '"')) q += 1;
        const start = q;
        while (q < line.len and c.isWord(line[q])) q += 1;
        if (q > start) return line[start..q];
    }
    return null;
}

/// The next segment of `line` split at `;`, `&&`, `||` and `|`.
const Segments = struct {
    line: []const u8,
    i: usize = 0,
    done: bool = false,

    fn next(self: *Segments) ?[]const u8 {
        if (self.done) return null;
        const start = self.i;
        var j = start;
        while (j < self.line.len) : (j += 1) {
            const ch = self.line[j];
            if (ch == ';' or ch == '|' or (ch == '&' and j + 1 < self.line.len and self.line[j + 1] == '&')) {
                const seg = self.line[start..j];
                self.i = if (ch == ';') j + 1 else if (ch == '|' and j + 1 < self.line.len and self.line[j + 1] == '|') j + 2 else if (ch == '|') j + 1 else j + 2;
                return seg;
            }
        }
        self.done = true;
        return self.line[start..];
    }
};

/// The offending logical lines of a run script. `::add-mask::` lines are the one allowed use.
pub fn leakyLines(a: Allocator, script: []const u8) ![]const []const u8 {
    var out = std.ArrayList([]const u8).init(a);
    // gsub(/\\\n/, " "): a backslash-newline joins two lines
    const joined = try std.mem.replaceOwned(u8, a, script, "\\\n", " ");
    var heredoc_tag: ?[]const u8 = null;
    var start: usize = 0;
    while (start < joined.len) {
        const end = if (std.mem.indexOfScalarPos(u8, joined, start, '\n')) |n| n + 1 else joined.len;
        const line = joined[start..end];
        start = end;
        const stripped = std.mem.trim(u8, line, " \t\r\n\x0b\x0c\x00");
        if (heredoc_tag) |tag| {
            if (std.mem.eql(u8, stripped, tag)) heredoc_tag = null;
            if (heredoc_tag != null and secretRef(line)) try out.append(stripped);
            continue;
        }
        if (heredocTag(line)) |tag| heredoc_tag = tag;
        if (std.mem.indexOf(u8, line, "::add-mask::") != null) continue;
        var segs = Segments{ .line = line };
        while (segs.next()) |seg| {
            if (c.hasAnyWord(seg, &.{ "echo", "printf", "cat", "tee" }) and secretRef(seg)) {
                try out.append(std.mem.trim(u8, seg, " \t\r\n\x0b\x0c\x00"));
            }
        }
    }
    return out.items;
}

// ---- per-file rules -------------------------------------------------------------

fn isOidc(base: []const u8) bool {
    return c.containsStr(&oidc_files, base);
}

fn joinPath(a: Allocator, path: []const []const u8) ![]u8 {
    return std.mem.join(a, ".", path);
}

fn checkPerm(a: Allocator, f: []const u8, base: []const u8, path: []const []const u8, value: Value, out: *Out) !void {
    switch (value) {
        .string => |s| {
            if (std.mem.indexOf(u8, s, "write") != null) try c.problem(a, out, prefix ++ "{s}: {s} = {s}", .{ f, try joinPath(a, path), s });
        },
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                if (!c.isStr(e.value_ptr.*, "write")) continue;
                const k = e.key_ptr.*;
                if (std.mem.eql(u8, base, kpin_file) and c.containsStr(&kpin_writes, k) and path.len == 3 and std.mem.eql(u8, path[0], "jobs")) continue;
                if (std.mem.eql(u8, base, release_file) and c.containsStr(&release_writes, k) and path.len == 3 and std.mem.eql(u8, path[0], "jobs")) continue;
                if (!(std.mem.eql(u8, k, "id-token") and (isOidc(base) or std.mem.eql(u8, base, farm_file)))) {
                    try c.problem(a, out, prefix ++ "{s}: {s}.{s}: write is not allowed", .{ f, try joinPath(a, path), k });
                }
            }
        },
        else => {},
    }
}

/// each_perm: every `permissions` key anywhere in the document, with its path.
fn eachPerm(a: Allocator, f: []const u8, base: []const u8, node: Value, path: *std.ArrayList([]const u8), out: *Out) !void {
    switch (node) {
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |e| {
                try path.append(e.key_ptr.*);
                if (std.mem.eql(u8, e.key_ptr.*, "permissions")) try checkPerm(a, f, base, path.items, e.value_ptr.*, out);
                try eachPerm(a, f, base, e.value_ptr.*, path, out);
                _ = path.pop();
            }
        },
        .array => |arr| {
            for (arr.items, 0..) |v, i| {
                try path.append(try std.fmt.allocPrint(a, "{d}", .{i}));
                try eachPerm(a, f, base, v, path, out);
                _ = path.pop();
            }
        },
        else => {},
    }
}

/// The variable (lower case) that holds the publish role of the shared apt repository; release.yml may read it.
const apt_role_variable = "apt_publish_role_arn";

/// /\bvars\.\w*(?:ACCOUNT|REGION|ARN)\w*/i, each match (non-overlapping) reported.
fn varsProblems(a: Allocator, f: []const u8, text: []const u8, out: *Out) !void {
    const low = try c.lower(a, text);
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, low, i, "vars.")) |p| {
        if (!c.boundaryBefore(low, p)) {
            i = p + 1;
            continue;
        }
        var j = p + 5;
        while (j < low.len and c.isWord(low[j])) j += 1;
        const w = low[p + 5 .. j];
        // The one role ARN that is a variable: the apt repository's publish role, which its owner sets as a variable of the environment
        // `apt-publish` (the role's name is public, the trust policy is what protects it). Only release.yml reads it.
        if (std.mem.eql(u8, w, apt_role_variable) and std.mem.eql(u8, c.basename(f), release_file)) {
            i = j;
            continue;
        }
        if (std.mem.indexOf(u8, w, "account") != null or std.mem.indexOf(u8, w, "region") != null or std.mem.indexOf(u8, w, "arn") != null) {
            try c.problem(a, out, prefix ++ "{s}: {s}: account, region and role ARNs come from environment secrets, not vars", .{ f, text[p..j] });
            i = j;
        } else {
            i = p + 1;
        }
    }
}

/// \A\./\.github/workflows/[a-z0-9_-]+\.yml\z
fn localWorkflow(s: []const u8) bool {
    const head = "./.github/workflows/";
    const tail = ".yml";
    if (!std.mem.startsWith(u8, s, head) or !std.mem.endsWith(u8, s, tail)) return false;
    if (s.len < head.len + tail.len + 1) return false;
    for (s[head.len .. s.len - tail.len]) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or (ch >= '0' and ch <= '9') or ch == '_' or ch == '-')) return false;
    }
    return true;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |ch| if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return false;
    return true;
}

/// \A<head>@[0-9a-f]{40}\z
fn pinned(s: []const u8, head: []const u8) bool {
    if (!std.mem.startsWith(u8, s, head) or s.len != head.len + 1 + 40 or s[head.len] != '@') return false;
    return isHex40(s[head.len + 1 ..]);
}

fn ownedActionPinned(s: []const u8) bool {
    inline for (owned_actions) |n| {
        if (pinned(s, "actions/" ++ n)) return true;
    }
    return false;
}

/// The per-file rules for one workflow. `f` is the path as the messages show it.
pub fn fileProblems(a: Allocator, f: []const u8, text: []const u8, out: *Out) !void {
    const base = c.basename(f);
    const doc = c.load(a, text) catch |err| {
        try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ f, @errorName(err) });
        return;
    };
    const jobs = c.get(doc, "jobs");

    // Default token is read-only and stated at the top.
    const top = c.get(doc, "permissions");
    if (c.isNil(top)) try c.problem(a, out, prefix ++ "{s}: top-level permissions must be set", .{f});
    if (top) |t| {
        if (t == .object) {
            var read_only = true;
            for (t.object.values()) |v| {
                if (!c.isStr(v, "read") and !c.isStr(v, "none")) read_only = false;
            }
            if (!read_only) try c.problem(a, out, prefix ++ "{s}: top-level permissions must be read-only", .{f});
        }
        if (t == .string) try c.problem(a, out, prefix ++ "{s}: top-level permissions must not be {s}", .{ f, try c.inspect(a, t) });
    }

    // Only id-token: write, and only in the deploy workflows. Never write-all or contents: write.
    var path = std.ArrayList([]const u8).init(a);
    try eachPerm(a, f, base, doc, &path, out);

    try varsProblems(a, f, text, out);

    // Only promote.yml passes secrets to its reusable calls, and it must do so on every call.
    if (std.mem.eql(u8, base, "promote.yml")) {
        // Automated by CEO decision: exactly a push to main plus a manual run, serialized by a concurrency group.
        const pkeys = try c.onKeys(a, doc);
        const sorted = try a.dupe([]const u8, pkeys);
        std.mem.sort([]const u8, sorted, {}, lessThan);
        if (!c.eqlList(sorted, &.{ "push", "workflow_dispatch" })) {
            try c.problem(a, out, prefix ++ "{s}: triggers must be exactly push and workflow_dispatch, got {s}", .{ f, try c.inspectList(a, pkeys) });
        }
        const pon = c.onValue(doc);
        if (pon != null and pon.? == .object) {
            const push = c.get(pon, "push");
            const branches = c.get(if (c.truthy(push)) push else null, "branches");
            const only_main = branches != null and branches.? == .array and branches.?.array.items.len == 1 and c.isStr(branches.?.array.items[0], "main");
            if (!only_main) try c.problem(a, out, prefix ++ "{s}: push must be limited to branches [main]", .{f});
        }
        const pconc = c.get(doc, "concurrency");
        const group = c.get(pconc, "group");
        const conc_ok = pconc != null and pconc.? == .object and !(c.isNil(group) or c.isStr(group, "")) and
            (if (c.get(pconc, "cancel-in-progress")) |v| (v == .bool and !v.bool) else false);
        if (!conc_ok) try c.problem(a, out, prefix ++ "{s}: needs a concurrency group with cancel-in-progress: false", .{f});
        if (jobs) |js| if (js == .object) {
            var it = js.object.iterator();
            while (it.next()) |e| {
                if (!c.truthy(c.get(e.value_ptr.*, "uses"))) continue;
                if (!c.isStr(c.get(e.value_ptr.*, "secrets"), "inherit")) {
                    try c.problem(a, out, prefix ++ "{s}: job {s} must set secrets: inherit (the called workflow reads environment secrets)", .{ f, e.key_ptr.* });
                }
            }
        };
    } else if (c.hasSecretsInherit(text)) {
        try c.problem(a, out, prefix ++ "{s}: secrets: inherit is not allowed outside promote.yml", .{f});
    }

    if (std.mem.eql(u8, base, kpin_file)) {
        const kkeys = try c.onKeys(a, doc);
        const sorted = try a.dupe([]const u8, kkeys);
        std.mem.sort([]const u8, sorted, {}, lessThan);
        if (!c.eqlList(sorted, &.{ "schedule", "workflow_dispatch" })) {
            try c.problem(a, out, prefix ++ "{s}: triggers must be exactly schedule and workflow_dispatch, got {s}", .{ f, try c.inspectList(a, kkeys) });
        }
        // The write grants are the jobs' own (the top level stays read-only, checked above).
        if (jobs) |js| if (js == .object) {
            var it = js.object.iterator();
            while (it.next()) |e| {
                var extra = std.ArrayList([]const u8).init(a);
                const perms = c.get(e.value_ptr.*, "permissions");
                if (perms != null and perms.? == .object) {
                    for (perms.?.object.keys()) |k| if (!c.containsStr(&kpin_writes, k)) try extra.append(k);
                }
                if (extra.items.len != 0) {
                    try c.problem(a, out, prefix ++ "{s}: job {s} may hold only contents and pull-requests permissions, not {s}", .{ f, e.key_ptr.*, try c.inspectList(a, extra.items) });
                }
            }
        };
    }
    // The privileged PR trigger is spelled in two pieces so hygiene does not flag this file.
    const on = try c.onKeys(a, doc);
    for ([_][]const u8{ "pull_request_" ++ "target", "workflow_run", "issue_comment" }) |t| {
        if (c.containsStr(on, t)) try c.problem(a, out, prefix ++ "{s}: trigger {s} is not allowed", .{ f, t });
    }

    const js = jobs orelse return;
    if (js != .object) return;
    var jit = js.object.iterator();
    while (jit.next()) |je| {
        const jn = je.key_ptr.*;
        const job = je.value_ptr.*;
        if (c.get(job, "uses")) |u| if (c.truthy(u)) {
            const us = c.str(u) orelse "";
            if (!localWorkflow(us)) try c.problem(a, out, prefix ++ "{s}: job {s} may only call a local workflow, not {s}", .{ f, jn, us });
        };
        const steps = c.get(job, "steps") orelse continue;
        if (steps != .array) continue;
        for (steps.array.items, 0..) |st, i| {
            const uses = c.str(c.get(st, "uses"));
            const farm_connect = std.mem.eql(u8, base, farm_file) and uses != null and pinned(uses.?, "komira-ai/komira/.github/actions/farm-connect");
            if (uses) |u| {
                // release.yml signs with Sigstore's installer (not GitHub-owned), pinned by commit like the rest.
                const cosign_installer = std.mem.eql(u8, base, release_file) and pinned(u, "sigstore/cosign-installer");
                // ... and so is the action that mints the release bot's App token (release_lint.zig holds that only the bump job uses it).
                const app_token = std.mem.eql(u8, base, release_file) and pinned(u, "actions/create-github-app-token");
                if (!farm_connect and !cosign_installer and !app_token and !ownedActionPinned(u)) {
                    try c.problem(a, out, prefix ++ "{s}: {s} step {d}: only GitHub-owned actions pinned by full SHA are allowed: {s}", .{ f, jn, i, u });
                }
            }
            const run = c.str(c.get(st, "run")) orelse continue;
            for (try leakyLines(a, run)) |l| {
                try c.problem(a, out, prefix ++ "{s}: {s} step {d}: prints a secret-bearing variable: {s}", .{ f, jn, i, l });
            }
            if (c.refsSecrets(run)) try c.problem(a, out, prefix ++ "{s}: {s} step {d}: run script references secrets.*", .{ f, jn, i });
            // Event fields and inputs reach scripts through env:, never by interpolation.
            if (std.mem.indexOf(u8, run, "${{") != null) {
                try c.problem(a, out, prefix ++ "{s}: {s} step {d}: run script interpolates an expression; pass it through env:", .{ f, jn, i });
            }
            switch (try sh.check(a, run)) {
                .ok => {},
                .bad => |why| {
                    std.debug.print("{s}: {s} step {d}: {s}\n", .{ f, jn, i, why });
                    try c.problem(a, out, prefix ++ "{s}: {s} step {d}: bash -n failed", .{ f, jn, i });
                },
            }
        }
    }
}

fn lessThan(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

// ---- whole-repository rules ---------------------------------------------------------

const Step = struct { job: []const u8, needs: ?[]const u8, uses: []const u8, stage: []const u8 };

/// promote.yml: beta deploy, e2e, gamma deploy, e2e, prod deploy, prod smoke; each needs the one before.
const chain = [_]Step{
    .{ .job = "beta-deploy", .needs = null, .uses = "deploy", .stage = "beta" },
    .{ .job = "beta-e2e", .needs = "beta-deploy", .uses = "e2e", .stage = "beta" },
    .{ .job = "gamma-deploy", .needs = "beta-e2e", .uses = "deploy", .stage = "gamma" },
    .{ .job = "gamma-e2e", .needs = "gamma-deploy", .uses = "e2e", .stage = "gamma" },
    .{ .job = "prod-deploy", .needs = "gamma-e2e", .uses = "deploy", .stage = "prod" },
    .{ .job = "prod-smoke", .needs = "prod-deploy", .uses = "e2e", .stage = "prod" },
};

fn idTokenWrite(job: Value) bool {
    return c.isStr(c.get(c.get(job, "permissions"), "id-token"), "write");
}

fn sortedKeys(a: Allocator, v: ?Value) ![]const []const u8 {
    const s = try a.dupe([]const u8, c.keys(v));
    std.mem.sort([]const u8, s, {}, lessThan);
    return s;
}

/// The checks that run only without path arguments. The workflows
/// are read by name through `read` (the repository's .github/workflows).
pub fn repoProblems(a: Allocator, ctx: anytype, out: *Out) !void {
    // release.yml: who may write, what each stage needs, the triggers and the path filter.
    try rl.problems(a, try ctx.read(a, "release.yml"), out);
    try rl.userBetaProblems(a, try ctx.read(a, "release-beta-user.yml"), out);
    try rl.buildDebProblems(a, try ctx.read(a, "release-build.yml"), out);

    // promote.yml
    {
        const pdoc = c.load(a, try ctx.read(a, "promote.yml")) catch |err| return c.problem(a, out, prefix ++ "promote.yml: not readable as YAML: {s}", .{@errorName(err)});
        const pj = c.get(pdoc, "jobs");
        var expected = std.ArrayList([]const u8).init(a);
        for (chain) |s| try expected.append(s.job);
        std.mem.sort([]const u8, expected.items, {}, lessThan);
        const have = try sortedKeys(a, pj);
        if (!c.eqlList(have, expected.items)) {
            try c.problem(a, out, prefix ++ "promote.yml: jobs {s} differ from expected {s}", .{ try c.inspectList(a, have), try c.inspectList(a, expected.items) });
        }
        for (chain) |s| {
            const job = c.get(pj, s.job) orelse continue;
            const need = try c.arrayOf(a, c.get(job, "needs"));
            const want: []const []const u8 = if (s.needs) |n| &.{n} else &.{};
            if (!c.eqlList(need, want)) {
                try c.problem(a, out, prefix ++ "promote.yml: {s} needs {s}, expected {s}", .{ s.job, try c.inspectList(a, need), try c.inspectList(a, want) });
            }
            const want_uses = try std.fmt.allocPrint(a, "./.github/workflows/{s}.yml", .{s.uses});
            if (!c.isStr(c.get(job, "uses"), want_uses)) {
                try c.problem(a, out, prefix ++ "promote.yml: {s} must call ./.github/workflows/{s}.yml", .{ s.job, s.uses });
            }
            if (!c.isStr(c.get(c.get(job, "with"), "stage"), s.stage)) {
                try c.problem(a, out, prefix ++ "promote.yml: {s} must target stage {s}", .{ s.job, s.stage });
            }
        }
        if (pj) |js| if (js == .object) {
            var it = js.object.iterator();
            while (it.next()) |e| {
                for ([_][]const u8{ "if", "continue-on-error" }) |k| {
                    if (e.value_ptr.* == .object and e.value_ptr.object.contains(k)) {
                        try c.problem(a, out, prefix ++ "promote.yml: {s} must not set {s}", .{ e.key_ptr.*, k });
                    }
                }
            }
        };
    }

    // deploy.yml and e2e.yml: the guard job gates the credential job.
    for ([_][]const u8{ "deploy", "e2e" }) |w| {
        const name = try std.fmt.allocPrint(a, "{s}.yml", .{w});
        const doc = c.load(a, try ctx.read(a, name)) catch |err| {
            try c.problem(a, out, prefix ++ "{s}: not readable as YAML: {s}", .{ name, @errorName(err) });
            continue;
        };
        var cred = std.ArrayList(Value).init(a);
        var cred_names = std.ArrayList([]const u8).init(a);
        if (c.get(doc, "jobs")) |js| if (js == .object) {
            var it = js.object.iterator();
            while (it.next()) |e| {
                if (idTokenWrite(e.value_ptr.*)) {
                    try cred.append(e.value_ptr.*);
                    try cred_names.append(e.key_ptr.*);
                }
            }
        };
        if (cred.items.len != 1) try c.problem(a, out, prefix ++ "{s}.yml: expected exactly one job with id-token", .{w});
        for (cred.items, cred_names.items) |j, jn| {
            if (!c.containsStr(try c.arrayOf(a, c.get(j, "needs")), "guard")) try c.problem(a, out, prefix ++ "{s}.yml: {s} must need the guard job", .{ w, jn });
            if (!c.truthy(c.get(j, "environment"))) try c.problem(a, out, prefix ++ "{s}.yml: {s} must declare an environment", .{ w, jn });
        }
    }

    // oidc-subject-check.yml: manual, main only, no environment except beta, no AWS.
    {
        const sc = c.load(a, try ctx.read(a, "oidc-subject-check.yml")) catch |err| return c.problem(a, out, prefix ++ "oidc-subject-check.yml: not readable as YAML: {s}", .{@errorName(err)});
        const scon = c.onValue(sc);
        const only_dispatch = scon != null and scon.? == .object and scon.?.object.count() == 1 and scon.?.object.contains("workflow_dispatch");
        if (!only_dispatch) try c.problem(a, out, prefix ++ "oidc-subject-check.yml: only workflow_dispatch is allowed", .{});
        const jobs = c.get(sc, "jobs");
        if (jobs) |js| if (js == .object) {
            var it = js.object.iterator();
            while (it.next()) |e| {
                const j = e.value_ptr.*;
                const jn = e.key_ptr.*;
                if (!idTokenWrite(j)) continue;
                if (!c.containsStr(try c.arrayOf(a, c.get(j, "needs")), "guard")) try c.problem(a, out, prefix ++ "oidc-subject-check.yml: {s} must need the guard job", .{jn});
                const env = c.get(j, "environment");
                if (!(c.isNil(env) or c.isStr(env, "beta"))) {
                    try c.problem(a, out, prefix ++ "oidc-subject-check.yml: {s} must not use environment {s}", .{ jn, try c.inspect(a, env) });
                }
                const perms = c.get(j, "permissions");
                const exact = perms != null and perms.? == .object and perms.?.object.count() == 2 and
                    c.isStr(c.get(perms, "id-token"), "write") and c.isStr(c.get(perms, "contents"), "read");
                if (!exact) try c.problem(a, out, prefix ++ "oidc-subject-check.yml: {s} must grant exactly id-token and contents read", .{jn});
            }
        };
        var envs = std.ArrayList([]const u8).init(a);
        var any_without_env = false;
        if (jobs) |js| if (js == .object) {
            for (js.object.values()) |j| {
                const env = c.get(j, "environment");
                if (!c.isNil(env)) try envs.append(try c.toS(a, env));
                if (idTokenWrite(j) and c.isNil(env)) any_without_env = true;
            }
        };
        std.mem.sort([]const u8, envs.items, {}, lessThan);
        if (!(c.eqlList(envs.items, &.{"beta"}) and any_without_env)) {
            try c.problem(a, out, prefix ++ "oidc-subject-check.yml: needs one job without an environment and one in beta", .{});
        }
    }
}
