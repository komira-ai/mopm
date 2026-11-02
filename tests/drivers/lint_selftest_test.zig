//! //:lint_selftest: the self-test of the two repository lints (hygiene.zig, workflow_lint.zig).
//!
//! Each fixture in tests/lint/fixtures is a minimal workflow with exactly one
//! violation; the table says which message each of the two lints must print for
//! it. Every rule has a fixture that breaks only that rule, so a rule broken
//! in a lint turns its own check red.
//!
//! Fixtures carry a .yml.fixture extension so GitHub never treats them as
//! workflows. Values that would trip the real hygiene scan if stored literally
//! are placeholders, replaced here at run time (built from pieces).

const std = @import("std");
const c = @import("lint_common.zig");
const hyg = @import("hygiene.zig");
const wl = @import("workflow_lint.zig");
const Allocator = std.mem.Allocator;

/// What a lint must print for a case: null when the lint is not run on it,
/// empty when it must pass, else one entry per expected line.
const Case = struct {
    name: []const u8,
    lint: ?[]const []const u8 = null,
    hyg: ?[]const []const u8 = null,
};

// fixture => { tool => [expected message substrings, one per expected failure line] }
const cases = [_]Case{
    .{ .name = "clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "echo_secret_expr", .lint = &.{ "run script references secrets.*", "interpolates an expression" } },
    .{ .name = "printf_token", .lint = &.{"prints a secret-bearing variable"} },
    .{ .name = "heredoc_role_arn", .lint = &.{"prints a secret-bearing variable"} },
    .{ .name = "vars_account", .lint = &.{"not vars"} },
    .{ .name = "id_token_write", .lint = &.{"id-token: write is not allowed"}, .hyg = &.{"an id-token permission is only allowed"} },
    .{ .name = "pr_target", .lint = &.{"is not allowed"}, .hyg = &.{"privileged PR-target trigger"} },
    .{ .name = "promote_missing_inherit", .lint = &.{"job gate must set secrets: inherit"} },
    .{ .name = "promote_inherit", .lint = &.{} },
    .{ .name = "promote_auto_ok", .lint = &.{} },
    .{ .name = "promote_no_concurrency", .lint = &.{"needs a concurrency group"} },
    .{ .name = "promote_cancel_true", .lint = &.{"needs a concurrency group"} },
    .{ .name = "promote_pull_request", .lint = &.{"triggers must be exactly push and workflow_dispatch"} },
    .{ .name = "inherit_elsewhere", .lint = &.{"secrets: inherit is not allowed outside promote.yml"} },
    .{ .name = "account_id_literal", .hyg = &.{"12-digit number that looks like an account id"} },
    .{ .name = "farm_clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "farm_fork_unguarded", .lint = &.{}, .hyg = &.{"does not skip pull requests from forks"} },
    .{ .name = "farm_push_any_branch", .lint = &.{}, .hyg = &.{"triggers must be exactly pull_request and push of branches [main]"} },
    .{ .name = "farm_other_action", .lint = &.{"only GitHub-owned actions pinned by full SHA"}, .hyg = &.{} },
    .{ .name = "hyg_aws_key", .hyg = &.{"AWS access key id"} },
    .{ .name = "hyg_secret_key", .hyg = &.{"AWS secret key assignment"} },
    .{ .name = "hyg_session_token", .hyg = &.{"AWS session token"} },
    .{ .name = "hyg_private_key", .hyg = &.{"private key block"} },
    .{ .name = "hyg_github_token", .hyg = &.{"GitHub token"} },
    .{ .name = "hyg_slack_token", .hyg = &.{"Slack token"} },
    .{ .name = "hyg_jwt", .hyg = &.{"JWT"} },
    .{ .name = "hyg_arn", .hyg = &.{ "ARN carrying an account id", "12-digit number that looks like an account id" } },
    .{ .name = "environment_in_ci", .lint = &.{}, .hyg = &.{"may use a deployment environment"} },
    .{ .name = "no_permissions", .lint = &.{"top-level permissions must be set"} },
    .{ .name = "job_write", .lint = &.{"jobs.j.permissions.contents: write is not allowed"} },
    .{ .name = "unpinned_action", .lint = &.{"only GitHub-owned actions pinned by full SHA"} },
    .{ .name = "local_call_other", .lint = &.{"may only call a local workflow"} },
    .{ .name = "workflow_run_trigger", .lint = &.{"trigger workflow_run is not allowed"} },
    .{ .name = "subject_clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "subject_aws", .lint = &.{}, .hyg = &.{"must not use AWS or secrets"} },
    .{ .name = "subject_env_prod", .lint = &.{}, .hyg = &.{"environment must be absent or beta"} },
    .{ .name = "subject_no_main_guard", .lint = &.{}, .hyg = &.{"is not restricted to refs/heads/main"} },
    .{ .name = "subject_push_trigger", .lint = &.{}, .hyg = &.{"triggers must be exactly workflow_dispatch"} },
    .{ .name = "deploy_clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "deploy_push_any_branch", .lint = &.{}, .hyg = &.{"push must be limited to branches: [main]"} },
    .{ .name = "deploy_no_environment", .lint = &.{}, .hyg = &.{"grants id-token without an environment"} },
    .{ .name = "deploy_pull_request", .lint = &.{}, .hyg = &.{ "must not run on pull_request", "are not allowed in a workflow that can use id-token" } },
    .{ .name = "kpin_clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "kpin_elsewhere", .lint = &.{ "contents: write is not allowed", "pull-requests: write is not allowed" } },
    .{ .name = "kpin_pull_request", .lint = &.{"triggers must be exactly schedule and workflow_dispatch"} },
    .{ .name = "kpin_issues_write", .lint = &.{ "issues: write is not allowed", "may hold only contents and pull-requests" } },
    .{ .name = "kpin_top_write", .lint = &.{ "top-level permissions must be read-only", "permissions.contents: write is not allowed" } },
    .{ .name = "release_clean", .lint = &.{}, .hyg = &.{} },
    .{ .name = "release_elsewhere", .lint = &.{ "contents: write is not allowed", "id-token: write is not allowed", "attestations: write is not allowed" }, .hyg = &.{ "an id-token permission is only allowed" } },
    .{ .name = "release_tag_trigger", .lint = &.{}, .hyg = &.{"triggers must be exactly push to branches [main]"} },
    .{ .name = "release_pull_request", .lint = &.{}, .hyg = &.{ "triggers must be exactly push to branches [main]" } },
    .{ .name = "release_environment", .lint = &.{}, .hyg = &.{ "must not use secrets or an environment" } },
    .{ .name = "release_other_write", .lint = &.{ "packages: write is not allowed" }, .hyg = &.{} },
    .{ .name = "release_unpinned_attest", .lint = &.{ "only GitHub-owned actions pinned by full SHA" }, .hyg = &.{} },
    .{ .name = "release_calls_with_idtoken", .lint = &.{}, .hyg = &.{ "calls a workflow and grants id-token" } },
    .{ .name = "release_cosign_pinned", .lint = &.{}, .hyg = &.{} },
    .{ .name = "release_unpinned_cosign", .lint = &.{"only GitHub-owned actions pinned by full SHA"}, .hyg = &.{} },
    .{ .name = "cosign_elsewhere", .lint = &.{"only GitHub-owned actions pinned by full SHA"}, .hyg = &.{} },
};

/// The values of the placeholders, built from pieces: built from pieces so this file does not trip hygiene.
fn substitutions(comptime i: usize) struct { []const u8, []const u8 } {
    const list = [_]struct { []const u8, []const u8 }{
        .{ "@@PRT@@", "pull_request_" ++ "target" },
        .{ "@@ACCT@@", "1234" ** 3 },
        .{ "@@AKID@@", "AKIA" ++ "ABCDEFGHIJKLMNOP" },
        .{ "@@SECRETKEY@@", "aws_secret_access_ke" ++ "y: abcdefghijklmnopqrst" },
        .{ "@@SESSTOKEN@@", "aws_session_toke" ++ "n: abcdefghijklmnopqrst" },
        .{ "@@PRIVKEY@@", "-----BEGIN RSA PRIVATE " ++ "KEY-----" },
        .{ "@@GHTOKEN@@", "ghp_" ++ "abcdefghijklmnopqrstuvwxyz0123" },
        .{ "@@SLACK@@", "xoxb-" ++ "1234567890" },
        .{ "@@JWT@@", "eyJ" ++ "abcdefghij" ++ ".eyJ" ++ "abcdefghij" ++ ".sig" },
        .{ "@@ARN@@", "arn:aws:iam::" ++ "1234" ** 3 ++ ":role/x" },
    };
    return list[i];
}
const n_substitutions = 10;

/// The file name a case is materialized as: promote_* promote.yml, farm_* farm.yml, subject_*
/// oidc-subject-check.yml, deploy_* deploy.yml, kpin_* kpin-update.yml (kpin_elsewhere stays ci.yml), release_* release.yml (release_elsewhere stays ci.yml), anything else ci.yml (a name not allowed id-token).
fn materializedName(name: []const u8) []const u8 {
    if (std.mem.startsWith(u8, name, "promote")) return "promote.yml";
    if (std.mem.startsWith(u8, name, "farm")) return "farm.yml";
    if (std.mem.startsWith(u8, name, "subject")) return "oidc-subject-check.yml";
    if (std.mem.startsWith(u8, name, "deploy")) return "deploy.yml";
    if (std.mem.startsWith(u8, name, "kpin") and !std.mem.eql(u8, name, "kpin_elsewhere")) return "kpin-update.yml";
    if (std.mem.startsWith(u8, name, "release") and !std.mem.eql(u8, name, "release_elsewhere")) return "release.yml";
    return "ci.yml";
}

fn fixtureText(a: Allocator, tree: c.Tree, name: []const u8) ![]u8 {
    var text = try tree.read(a, try std.fmt.allocPrint(a, "tests/lint/fixtures/{s}.yml.fixture", .{name}));
    inline for (0..n_substitutions) |i| {
        const s = comptime substitutions(i);
        text = try std.mem.replaceOwned(u8, a, text, s[0], s[1]);
    }
    return text;
}

/// The comparison: for a case that must pass, success and no output; else
/// output of exactly as many lines as expected, each expected substring in one.
fn verdict(a: Allocator, name: []const u8, tool: []const u8, got: []const []const u8, want: []const []const u8) !bool {
    var ok = got.len == want.len;
    for (want) |w| {
        var found = false;
        for (got) |g| {
            if (std.mem.indexOf(u8, g, w) != null) found = true;
        }
        if (!found) ok = false;
    }
    std.debug.print("{s} {s} / {s}\n", .{ if (ok) "ok  " else "FAIL", name, tool });
    if (!ok) {
        std.debug.print("  expected {s}, got {d} line(s):\n", .{ if (want.len == 0) try a.dupe(u8, "pass") else try c.inspectList(a, want), got.len });
        for (got) |g| std.debug.print("  {s}\n", .{g});
    }
    return ok;
}

test "each fixture gets the verdict of the table from both lints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);

    var bad: usize = 0;
    for (cases) |cs| {
        const text = try fixtureText(a, tree, cs.name);
        const path = materializedName(cs.name);
        if (cs.lint) |want| {
            var out = c.Out.init(a);
            try wl.fileProblems(a, path, text, &out);
            if (!try verdict(a, cs.name, "workflow_lint", out.items, want)) bad += 1;
        }
        if (cs.hyg) |want| {
            var out = c.Out.init(a);
            try hyg.textProblems(a, path, text, &out);
            try hyg.structureProblems(a, path, text, &out);
            if (!try verdict(a, cs.name, "hygiene", out.items, want)) bad += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), bad);
}

test "every fixture has a case, and every case a fixture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    var fixtures: usize = 0;
    for (tree.files) |f| {
        const dir = "tests/lint/fixtures/";
        const ext = ".yml.fixture";
        if (!std.mem.startsWith(u8, f, dir)) continue;
        fixtures += 1;
        if (!std.mem.endsWith(u8, f, ext)) {
            std.debug.print("{s} is not a .yml.fixture\n", .{f});
            return error.TestUnexpectedResult;
        }
        const name = f[dir.len .. f.len - ext.len];
        var known = false;
        for (cases) |cs| {
            if (std.mem.eql(u8, cs.name, name)) known = true;
        }
        if (!known) {
            std.debug.print("fixture {s} has no case in the table\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(cases.len, fixtures);
}

