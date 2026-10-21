//! //:hygiene: the repository hygiene scan (tests/drivers/hygiene.zig),
//! run by Buck2 over every file of the repository (the target's `data`), and
//! shown able to fail: one planted sample per rule must be flagged, and a near
//! miss of each must not be.
//!
//! Samples hold key-shaped values built from pieces at run time: hygiene scans
//! this file too, and has no allow-list.

const std = @import("std");
const c = @import("lint_common.zig");
const hyg = @import("hygiene.zig");
const Allocator = std.mem.Allocator;

test "every file of the repository passes the text rules, and every workflow the structure rules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);

    // The target's data must be the whole repository: these are the files a
    // glob drops by default (dotfiles) or a package boundary hides.
    for ([_][]const u8{
        ".buckconfig",
        ".gitignore",
        ".github/workflows/ci.yml",
        "BUCK",
        "tests/new/bin/.gitignore",
        "tests/discovery/tree/tests/.hidden/test_hidden.mojo",
        "service/api/BUCK",
        "service/api/.gitignore",
        "service/infra/stacks/BUCK",
        "site/buildrules.lock.bzl",
        "tools/node/BUCK",
        "tests/lint/fixtures/clean.yml.fixture",
    }) |must| {
        if (!c.hasFile(tree, must)) {
            std.debug.print("the hygiene data lacks {s}: BUCK does not list every file\n", .{must});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(tree.files.len > 500);

    var out = c.Out.init(a);
    for (tree.files) |f| try hyg.textProblems(a, f, try tree.read(a, f), &out);
    for (try c.workflowFiles(a, tree)) |f| try hyg.structureProblems(a, f, try tree.read(a, f), &out);
    try hyg.kpinSetsProblems(a, try tree.read(a, ".github/workflows/kpin-update.yml"), tree.files, &out);
    try hyg.farmExclusionProblems(a, try tree.read(a, "BUCK"), try tree.read(a, ".github/workflows/farm.yml"), &out);
    try hyg.dependabotProblems(a, try tree.read(a, ".github/dependabot.yml"), tree.files, &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

fn text(a: Allocator, data: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    try hyg.textProblems(a, "sample.txt", data, &out);
    return out.items;
}

/// `data` is flagged by the rule `name` and by no other.
fn flagged(name: []const u8, data: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const want = try std.fmt.allocPrint(a, "hygiene: sample.txt: {s}", .{name});
    try c.expectLines(name, try text(a, data), &.{want});
}

fn clean(what: []const u8, data: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try c.expectLines(what, try text(arena.allocator(), data), &.{});
}

test "AWS access key id" {
    const key = "AKIA" ++ "ABCDEFGHIJKLMNOP";
    try flagged("AWS access key id", "key = " ++ key ++ "\n");
    try flagged("AWS access key id", "ASIA" ++ "0123456789ABCDEF");
    try flagged("AWS access key id", "(" ++ key ++ ")");
    try clean("one character short", "AKIA" ++ "ABCDEFGHIJKLMNO ");
    try clean("one character long", key ++ "Q");
    try clean("glued to a word before", "x" ++ key);
    try clean("a lower case tail", "AKIA" ++ "abcdefghijklmnop");
}

test "AWS secret key assignment and session token" {
    const twenty = "abcdefghijklmnopqrst";
    try flagged("AWS secret key assignment", "aws_secret_access_ke" ++ "y = " ++ twenty);
    try flagged("AWS secret key assignment", "AWS_SECRET_ACCESS_KE" ++ "Y: \"" ++ twenty);
    try flagged("AWS secret key assignment", "aws_secret_access_ke" ++ "y\t=\n" ++ twenty);
    try clean("a 19 character value", "aws_secret_access_ke" ++ "y = " ++ twenty[1..]);
    try clean("no separator", "aws_secret_access_ke" ++ "y " ++ twenty);
    try flagged("AWS session token", "aws_session_toke" ++ "n=" ++ twenty);
    try clean("a short session token", "aws_session_toke" ++ "n=short");
}

test "private key block" {
    try flagged("private key block", "-----BEGIN RSA PRIVATE " ++ "KEY-----\n");
    try flagged("private key block", "-----BEGIN PRIVATE " ++ "KEY-----");
    try flagged("private key block", "-----BEGIN OPENSSH PRIVATE " ++ "KEY-----");
    try clean("a certificate", "-----BEGIN CERTIFICATE-----");
    try clean("an unclosed header", "-----BEGIN PRIVATE " ++ "KEY");
    try clean("four dashes", "----BEGIN PRIVATE " ++ "KEY----");
}

test "GitHub token" {
    const thirty = "abcdefghijklmnopqrstuvwxyz0123";
    try flagged("GitHub token", "ghp_" ++ thirty);
    try flagged("GitHub token", "token: gho_" ++ thirty ++ "\n");
    try flagged("GitHub token", "github_pat_" ++ "abcdefghij_klmnopqrst");
    try clean("29 characters", "ghp_" ++ thirty[1..]);
    try clean("a word character after", "ghp_" ++ thirty ++ "_x");
    try clean("glued to a word before", "my" ++ "ghp_" ++ thirty);
    try clean("a short fine grained token", "github_pat_" ++ "abcdefghij_klmnopqr");
}

test "Slack token" {
    try flagged("Slack token", "xoxb-" ++ "1234567890");
    try flagged("Slack token", "SLACK=xoxp-" ++ "12345-67890-abc");
    try clean("nine characters", "xoxb-" ++ "123456789");
    try clean("an unknown kind", "xoxz-" ++ "1234567890");
}

test "JWT" {
    const part = "abcdefghij";
    try flagged("JWT", "eyJ" ++ part ++ ".eyJ" ++ part ++ ".sig");
    try flagged("JWT", "Bearer eyJ" ++ part ++ "_-.eyJ" ++ part ++ ".");
    try clean("no second dot", "eyJ" ++ part ++ ".eyJ" ++ part);
    try clean("a short header", "eyJ" ++ part[1..] ++ ".eyJ" ++ part ++ ".");
}

test "ARN carrying an account id" {
    const acct = ("1234" ** 3);
    const arn = "arn:aws:iam::" ++ acct ++ ":role/x";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // the account id inside it is a finding of its own
    try c.expectLines("arn", try text(a, arn), &.{ "ARN carrying an account id", "12-digit number" });
    try c.expectLines("govcloud arn", try text(a, "arn:aws-us-gov:s3:us-gov-west-1:" ++ acct ++ ":x"), &.{ "ARN carrying an account id", "12-digit number" });
    try clean("an AWS managed policy", "arn:aws:iam::aws:policy/ReadOnlyAccess");
    try clean("a placeholder", "arn:aws:iam::<account>:role/x");
}

test "privileged PR-target trigger" {
    try flagged("privileged PR-target trigger", "on: pull_request_" ++ "target\n");
    try clean("the ordinary trigger", "on: pull_request\n");
}

test "12-digit number that looks like an account id" {
    const rule = "12-digit number that looks like an account id";
    try flagged(rule, "ACCT=" ++ ("1234" ** 3));
    try flagged(rule, "\"" ++ ("1234" ** 3) ++ "\"");
    try flagged(rule, "-" ++ ("1234" ** 3) ++ "-");
    try clean("eleven digits", "12345678901");
    try clean("thirteen digits", "1234567890123");
    try clean("a letter before", "a" ++ ("1234" ** 3));
    try clean("a letter after", ("1234" ** 3) ++ "a");
    try clean("a number with a digit before", "9" ++ ("1234" ** 3) ++ "9");
}

test "a file with a NUL byte is binary and is not scanned" {
    try clean("binary", "AKIA" ++ "ABCDEFGHIJKLMNOP\x00");
}

// ---- the workflow structure rules ---------------------------------------------------

fn structure(a: Allocator, name: []const u8, yaml: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    try hyg.structureProblems(a, name, yaml, &out);
    return out.items;
}

fn expectStructure(name: []const u8, yaml: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try c.expectLines(name, try structure(arena.allocator(), name, yaml), want);
}

const header =
    \\name: t
    \\permissions:
    \\  contents: read
    \\
;

test "id-token and environments are for the deploy workflows only" {
    try expectStructure("ci.yml", header ++
        \\on: [push]
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{"an id-token permission is only allowed in deploy.yml, e2e.yml, promote.yml"});
    try expectStructure("ci.yml", header ++
        \\on: [push]
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    environment: beta
        \\
    , &.{"only deploy.yml, e2e.yml, promote.yml may use a deployment environment"});
    try expectStructure("ci.yml", header ++
        \\on: [pull_request]
        \\jobs:
        \\  test:
        \\    runs-on: x
        \\    environment: beta
        \\    permissions:
        \\      id-token: write
        \\
    , &.{ "an id-token permission is only allowed", "may use a deployment environment", "must not run on pull_request" });
    try expectStructure("ci.yml", header ++
        \\on: [push, pull_request]
        \\jobs:
        \\  test:
        \\    runs-on: x
        \\
    , &.{});
}

test "the pull-request tier: unit on a pull request, beta only after the merge" {
    // Mutant: the release dry run is back (release-check.yml on pull_request).
    try expectStructure("release-check.yml", header ++
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  package:
        \\    runs-on: x
        \\
    , &.{"a pull request runs build and unit tests only"});
    // Mutant: an e2e workflow gains a pull_request trigger.
    try expectStructure("e2e-extra.yml", header ++ "on: [pull_request]\njobs:\n  j:\n    runs-on: x\n", &.{"a pull request runs build and unit tests only"});
    // The same trigger is fine in a unit workflow (lint.yml, farm.yml and ci.yml have rules of their own).
    for ([_][]const u8{"service-ci.yml"}) |ok| {
        try expectStructure(ok, header ++ "on: [pull_request]\njobs:\n  j:\n    runs-on: x\n", &.{});
    }
    // Mutant: a guard with a clause that lets the beta job run on a pull request (the whole `if:` is compared, not a substring).
    const guard_head = header ++ "on: [pull_request, push]\njobs:\n  test:\n    runs-on: x\n  registry-build:\n    runs-on: x\n  pack-conformance:\n    runs-on: x\n    if: ";
    try expectStructure("ci.yml", guard_head ++ "github.event_name != 'pull_request' || true\n", &.{"job pack-conformance is not a unit job"});
    try expectStructure("ci.yml", guard_head ++ "github.event_name != 'pull_request' || github.ref == 'refs/heads/main'\n", &.{"job pack-conformance is not a unit job"});
    // The exact guard passes, bare or in ${{ }}.
    try expectStructure("ci.yml", guard_head ++ "github.event_name != 'pull_request'\n", &.{});
    try expectStructure("ci.yml", guard_head ++ "${{ github.event_name != 'pull_request' }}\n", &.{});
    // lint.yml must run the release lint test on every pull request.
    const lint_head = header ++ "on: [pull_request, push]\njobs:\n  lint:\n    runs-on: x\n    steps:\n";
    const lint_step = "      - run: zig test tests/drivers/release_lint_test.zig\n";
    try expectStructure("lint.yml", lint_head ++ lint_step, &.{});
    try expectStructure("lint.yml", lint_head ++ "      - if: ${{ !cancelled() }}\n        run: zig test tests/drivers/release_lint_test.zig\n", &.{});
    // Mutants: the step is gone, conditional on something else, may fail, is in a job that may fail, or the trigger is gone.
    const no_release_lint = "release_lint_test.zig` unconditionally";
    try expectStructure("lint.yml", lint_head ++ "      - run: zig test tests/drivers/hygiene_test.zig\n", &.{no_release_lint});
    try expectStructure("lint.yml", lint_head ++ "      - if: github.event_name == 'push'\n        run: zig test tests/drivers/release_lint_test.zig\n", &.{no_release_lint});
    try expectStructure("lint.yml", lint_head ++ "      - continue-on-error: true\n        run: zig test tests/drivers/release_lint_test.zig\n", &.{no_release_lint});
    try expectStructure("lint.yml", header ++ "on: [pull_request]\njobs:\n  lint:\n    runs-on: x\n    continue-on-error: true\n    steps:\n" ++ lint_step, &.{no_release_lint});
    try expectStructure("lint.yml", header ++ "on: [push]\njobs:\n  lint:\n    runs-on: x\n    steps:\n" ++ lint_step, &.{"the lints must run on pull_request"});
    // Mutant: a beta job of ci.yml loses its guard, or is new and unguarded.
    try expectStructure("ci.yml", header ++
        \\on: [pull_request, push]
        \\jobs:
        \\  test:
        \\    runs-on: x
        \\  registry-build:
        \\    runs-on: x
        \\  mojo-e2e:
        \\    if: github.event_name != 'pull_request'
        \\    runs-on: x
        \\  pack-conformance:
        \\    runs-on: x
        \\
    , &.{"job pack-conformance is not a unit job"});
    try expectStructure("ci.yml", header ++
        \\on: [pull_request]
        \\jobs:
        \\  installer:
        \\    if: github.event_name == 'push'
        \\    runs-on: x
        \\
    , &.{"job installer is not a unit job"});
    // With no pull_request trigger every job of ci.yml is free.
    try expectStructure("ci.yml", header ++ "on: [push]\njobs:\n  mojo-e2e:\n    runs-on: x\n", &.{});
}

const deploy_ok = header ++
    \\on:
    \\  workflow_dispatch:
    \\  push:
    \\    branches: [main]
    \\jobs:
    \\  j:
    \\    if: github.ref == 'refs/heads/main'
    \\    environment: beta
    \\    runs-on: x
    \\    permissions:
    \\      id-token: write
    \\
;

test "a deploy workflow: triggers, push branches, guarded credential jobs" {
    try expectStructure("deploy.yml", deploy_ok, &.{});
    try expectStructure("deploy.yml", header ++
        \\on: [pull_request]
        \\jobs:
        \\  j:
        \\    if: github.ref == 'refs/heads/main'
        \\    environment: beta
        \\    runs-on: x
        \\
    , &.{ "triggers [\"pull_request\"] are not allowed in a workflow that can use id-token", "must not run on pull_request" });
    try expectStructure("deploy.yml", header ++
        \\on:
        \\  push:
        \\    branches: [main, dev]
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\
    , &.{"push must be limited to branches: [main]"});
    try expectStructure("deploy.yml", header ++
        \\on:
        \\  push:
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\
    , &.{"push must be limited to branches: [main]"});
    try expectStructure("deploy.yml", header ++
        \\on: [push]
        \\jobs:
        \\  j:
        \\    if: github.ref == 'refs/heads/main'
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{ "push must be limited to branches: [main]", "job j grants id-token without an environment" });
    try expectStructure("deploy.yml", header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  j:
        \\    environment: beta
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{"job j grants id-token but is not restricted to refs/heads/main"});
    // a reusable-workflow call is checked in the file it calls
    try expectStructure("promote.yml", header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  j:
        \\    uses: ./.github/workflows/deploy.yml
        \\    permissions: { id-token: write, contents: read }
        \\
    , &.{});
}

test "oidc-subject-check.yml: manual, main only, beta at most, no AWS" {
    const ok = header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  a:
        \\    if: github.ref == 'refs/heads/main'
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\  b:
        \\    if: github.ref == 'refs/heads/main'
        \\    environment: beta
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    ;
    try expectStructure("oidc-subject-check.yml", ok, &.{});
    try expectStructure("oidc-subject-check.yml", header ++
        \\on: [workflow_dispatch, push]
        \\jobs:
        \\  a:
        \\    runs-on: x
        \\
    , &.{"triggers must be exactly workflow_dispatch"});
    try expectStructure("oidc-subject-check.yml", header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  a:
        \\    if: github.ref == 'refs/heads/main'
        \\    environment: prod
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{"job a: environment must be absent or beta, not \"prod\""});
    try expectStructure("oidc-subject-check.yml", header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  a:
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{"job a grants id-token but is not restricted to refs/heads/main"});
    // each spelling of AWS the rule looks for, outside comments
    for ([_][]const u8{ "uses: aws-actions/x@1", "run: echo ${{ secrets.X }}", "run: aws s3 ls", "run: echo $AWS_REGION", "with: { role-to-assume: x }", "uses: foo/configure-aws@1" }) |step| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const yaml = try std.fmt.allocPrint(a, "{s}on:\n  workflow_dispatch:\njobs:\n  a:\n    runs-on: x\n    steps:\n      - {s}\n", .{ header, step });
        try c.expectLines(step, try structure(a, "oidc-subject-check.yml", yaml), &.{"must not use AWS or secrets"});
    }
    try expectStructure("oidc-subject-check.yml", header ++
        \\on:
        \\  workflow_dispatch:
        \\jobs:
        \\  a:
        \\    runs-on: x
        \\    steps:
        \\      # aws s3 ls is only a comment, and a paws is not a command
        \\      - run: echo paws
        \\
    , &.{});
}

test "farm.yml: a push to main or a pull request from this repository, no secret, no environment" {
    const farm = header ++
        \\on:
        \\  pull_request:
        \\    branches: [main]
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  build:
        \\    if: github.event.pull_request.head.repo.full_name == github.repository
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    ;
    try expectStructure("farm.yml", farm, &.{});
    // A push to any branch, a push without branches, a pull request alone and a third trigger are refused.
    inline for ([_][]const u8{
        "on:\n  pull_request:\n  push:\n    branches: ['*']\n",
        "on: [pull_request, push]\n",
        "on:\n  pull_request:\n    branches: [main]\n",
        "on:\n  push:\n    branches: [main]\n",
        "on:\n  pull_request:\n  push:\n    branches: [main]\n  workflow_dispatch:\n",
    }) |on| {
        try expectStructure("farm.yml", header ++ on ++
            \\jobs:
            \\  build:
            \\    runs-on: x
            \\
        , &.{"triggers must be exactly pull_request and push of branches [main]"});
    }
    try expectStructure("farm.yml", header ++
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  build:
        \\    environment: beta
        \\    runs-on: x
        \\
    , &.{"must not use secrets or an environment"});
    try expectStructure("farm.yml", header ++
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  build:
        \\    runs-on: x
        \\    steps:
        \\      - run: echo ${{ secrets.X }}
        \\
    , &.{"must not use secrets or an environment"});
    try expectStructure("farm.yml", header ++
        \\on:
        \\  pull_request:
        \\  push:
        \\    branches: [main]
        \\jobs:
        \\  build:
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    , &.{"job build grants id-token but does not skip pull requests from forks"});
}

test "a workflow that cannot be read is a finding, not a pass" {
    try expectStructure("ci.yml", "on: [push\n", &.{"not readable as YAML"});
}

test "release.yml may name the release bot's key exactly three times (tag, tap, bump), and no other secret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const release = header ++
        \\on:
        \\  push:
        \\    branches: [main]
        \\  workflow_dispatch:
        \\jobs:
        \\  tag:
        \\    environment: release
        \\    runs-on: x
        \\    steps:
        \\      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510
        \\        with:
        \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
        \\  tap:
        \\    environment: release
        \\    runs-on: x
        \\    steps:
        \\      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510
        \\        with:
        \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
        \\  bump:
        \\    environment: release
        \\    runs-on: x
        \\    steps:
        \\      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510
        \\        with:
        \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
        \\
    ;
    try expectStructure("release.yml", release, &.{});
    // Mutant: a fourth reference to the key.
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "        env:\n          K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n" }), &.{"must not use secrets or an environment"});
    // Mutants: the key under another name (the jobs then read nothing, so their environment is a finding too); another
    // secret beside the allowed one.
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, "RELEASE_BOT_PRIVATE_KEY", "OTHER_KEY"), &.{ "must not use secrets or an environment", "job tag: must not use secrets or an environment", "job tap: must not use secrets or an environment", "job bump: must not use secrets or an environment" });
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "        env:\n          X: ${{ secrets.ANOTHER }}\n" }), &.{"must not use secrets or an environment"});
    // The environment of the jobs that read the key is `release`, and only theirs.
    const tag_env = "  tag:\n    environment: release\n";
    const bump_env = "  bump:\n    environment: release\n";
    const tap_env = "  tap:\n    environment: release\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tag_env, "  tag:\n"), &.{"job tag reads RELEASE_BOT_* so it must declare environment release, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, bump_env, "  bump:\n"), &.{"job bump reads RELEASE_BOT_* so it must declare environment release, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tap_env, "  tap:\n"), &.{"job tap reads RELEASE_BOT_* so it must declare environment release, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tap_env, "  tap:\n    environment: prod\n"), &.{"job tap reads RELEASE_BOT_* so it must declare environment release, got \"prod\""});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tag_env, "  tag:\n    environment: relase\n"), &.{"job tag reads RELEASE_BOT_* so it must declare environment release, got \"relase\""});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, bump_env, "  bump:\n    environment: prod\n"), &.{"job bump reads RELEASE_BOT_* so it must declare environment release, got \"prod\""});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: release\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: prod\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
}

test "release.yml: the signing key is read only in the apt-signing environment and the publish role only in apt-publish, each a fixed number of times" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const release = header ++
        \\on:
        \\  push:
        \\    branches: [main]
        \\  workflow_dispatch:
        \\jobs:
        \\  apt-index:
        \\    environment: apt-signing
        \\    runs-on: x
        \\    steps:
        \\      - id: gate
        \\        env:
        \\          HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}
        \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
        \\        run: 'true'
        \\      - id: sign
        \\        env:
        \\          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}
        \\          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}
        \\          APT_GPG_FINGERPRINT: ${{ secrets.APT_GPG_FINGERPRINT || vars.APT_GPG_FINGERPRINT }}
        \\        run: 'true'
        \\  apt-deploy-write:
        \\    environment: apt-publish
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\    steps:
        \\      - env:
        \\          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}
        \\        run: 'true'
        \\
    ;
    try expectStructure("release.yml", release, &.{});
    // Mutants: more references than the three apt-index attempts make (the key three times, the passphrase three times, the fingerprint six).
    const extra = "      - env:\n          K: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n          L: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n          M: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n        run: 'true'\n";
    const publish_job = "  apt-deploy-write:\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, publish_job, extra ++ publish_job), &.{"must not use secrets or an environment"});
    const extra_pass = "      - env:\n          P: ${{ secrets.APT_GPG_PASSPHRASE }}\n          Q: ${{ secrets.APT_GPG_PASSPHRASE }}\n          R: ${{ secrets.APT_GPG_PASSPHRASE }}\n        run: 'true'\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, publish_job, extra_pass ++ publish_job), &.{"must not use secrets or an environment"});
    // Another secret beside the allowed ones, and the key's name with another shape.
    const extra_other = "      - env:\n          X: ${{ secrets.APT_GPG_OTHER }}\n        run: 'true'\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, publish_job, extra_other ++ publish_job), &.{"must not use secrets or an environment"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, "secrets.APT_GPG_PASSPHRASE }}", "secrets.APT_GPG_PASSPHRASE || secrets.X }}"), &.{"must not use secrets or an environment"});
    // The environments: the key's jobs are in apt-signing, the role's jobs in apt-publish, and no other job in any.
    const sign_env = "  apt-index:\n    environment: apt-signing\n";
    const publish_env = "  apt-deploy-write:\n    environment: apt-publish\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, sign_env, "  apt-index:\n"), &.{"job apt-index reads APT_GPG_* so it must declare environment apt-signing, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, sign_env, "  apt-index:\n    environment: apt-publish\n"), &.{"job apt-index reads APT_GPG_* so it must declare environment apt-signing, got \"apt-publish\""});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, publish_env, "  apt-deploy-write:\n"), &.{"job apt-deploy-write reads APT_PUBLISH_* so it must declare environment apt-publish, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, publish_env, "  apt-deploy-write:\n    environment: release\n"), &.{"job apt-deploy-write reads APT_PUBLISH_* so it must declare environment apt-publish, got \"release\""});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: apt-publish\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: apt-signing\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
}

test "kpin-update.yml: KPIN_SETS has a line for every pins.lock.bzl, and only for those" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const wf =
        \\jobs:
        \\  update:
        \\    env:
        \\      KPIN_SETS: |
        \\        tools/node/pins.toml tools/node/pins.lock.bzl
        \\        site/pins.toml site/pins.lock.bzl site/package-lock.json
        \\
        \\      KPIN_CARGO_SETS: ""
        \\    steps: []
        \\
    ;
    const tree = [_][]const u8{ "site/pins.lock.bzl", "site/BUCK", "tools/node/pins.lock.bzl", "README.md" };
    var out = c.Out.init(a);
    try hyg.kpinSetsProblems(a, wf, &tree, &out);
    try c.expectLines("matching", out.items, &.{});
    // Mutant: a lock in the tree with no line (what turned the 19 October run red).
    out = c.Out.init(a);
    try hyg.kpinSetsProblems(a, wf, &(tree ++ [_][]const u8{"service/new/pins.lock.bzl"}), &out);
    try c.expectLines("unlisted", out.items, &.{"KPIN_SETS has no line for service/new/pins.lock.bzl"});
    // Mutant: a line for a lock the tree does not have.
    out = c.Out.init(a);
    try hyg.kpinSetsProblems(a, wf, tree[1..], &out);
    try c.expectLines("gone", out.items, &.{"KPIN_SETS names site/pins.lock.bzl, which is not in the repository"});
    // A block that cannot be found is a finding, not a pass.
    out = c.Out.init(a);
    try hyg.kpinSetsProblems(a, "jobs: {}\n", &tree, &out);
    try c.expectLines("no block", out.items, &.{"no `KPIN_SETS: |` block"});
}

// ---- the farm's pull request exclusion list, against BUCK's _MOJO_TOOLS targets -----------------

fn farmProblems(a: Allocator, buck: []const u8, farm: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    try hyg.farmExclusionProblems(a, buck, farm, &out);
    return out.items;
}

test "farm.yml's exclusion list is exactly the targets BUCK builds with _MOJO_TOOLS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The parser on a sample: plain, dict(), a rule that does not use the tools, a comment, a name that is not at the rule's level.
    const buck =
        \\_MOJO_TOOLS = {
        \\    "CC_SHIM": ":zigcc",
        \\}
        \\zig_test(  # a
        \\    name = "one",
        \\    exec_tools = _MOJO_TOOLS,
        \\)
        \\zig_test(  # b
        \\    name = "two",
        \\    exec_tools = dict(_MOJO_TOOLS, MOPM = ":mopm"),
        \\)
        \\zig_test(  # c
        \\    name = "three",
        \\    exec_tools = {"MOPM": ":mopm"},
        \\)
        \\zig_test(  # d
        \\    name = "four",
        \\    # exec_tools = _MOJO_TOOLS,
        \\)
        \\
    ;
    const got = try hyg.mojoToolTargets(a, buck);
    try c.expectLines("parsed", got, &.{ "one", "two" });
    const farm_ok = "          ./buck2 uquery '//... - set(//:one //:two)' > \"$RUNNER_TEMP/targets\"\n";
    try c.expectLines("equal", try farmProblems(a, buck, farm_ok), &.{});
    // Mutants: a target dropped from the list, one added to it, and a list that is gone.
    try c.expectLines("dropped", try farmProblems(a, buck, "x '//... - set(//:one)' y\n"), &.{"//:two is built with _MOJO_TOOLS in BUCK (a beta target) but is not excluded"});
    try c.expectLines("added", try farmProblems(a, buck, "x '//... - set(//:one //:two //:five)' y\n"), &.{"//:five is excluded from the pull request build but BUCK does not build it with _MOJO_TOOLS"});
    try c.expectLines("no list", try farmProblems(a, buck, "x ./buck2 build //...\n"), &.{"no `//... - set(` exclusion list"});
    try c.expectLines("no tools in BUCK", try farmProblems(a, "zig_test(\n    name = \"x\",\n)\n", farm_ok), &.{ "no target is built with _MOJO_TOOLS", "//:one is excluded", "//:two is excluded" });
}

/// `text` with `from` replaced by `to` (it must occur once).
fn replaced(a: Allocator, haystack: []const u8, from: []const u8, to: []const u8) ![]u8 {
    const at = std.mem.indexOf(u8, haystack, from) orelse {
        std.debug.print("the mutant does not apply: {s} is not in the file\n", .{from});
        return error.TestUnexpectedResult;
    };
    return std.mem.concat(a, u8, &.{ haystack[0..at], to, haystack[at + from.len ..] });
}

test "the real farm.yml and BUCK: a planted beta target or a dropped exclusion goes red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const buck = try tree.read(a, "BUCK");
    const farm = try tree.read(a, ".github/workflows/farm.yml");
    try c.expectLines("real", try farmProblems(a, buck, farm), &.{});
    // The seven beta targets are the ones the farm excludes today.
    try std.testing.expectEqual(@as(usize, 7), (try hyg.mojoToolTargets(a, buck)).len);
    // Mutant: a new Mojo test target in BUCK that farm.yml does not exclude.
    const planted_buck = try replaced(a, buck, "zig_test(  # buck-only: komira's Mojo toolchain works from this cell\n    name = \"mojo_probe\",", "zig_test(\n    name = \"planted\",\n    exec_tools = _MOJO_TOOLS,\n)\nzig_test(  # buck-only: komira's Mojo toolchain works from this cell\n    name = \"mojo_probe\",");
    try c.expectLines("planted target", try farmProblems(a, planted_buck, farm), &.{"//:planted is built with _MOJO_TOOLS in BUCK"});
    // Mutant: farm.yml stops excluding one.
    try c.expectLines("dropped", try farmProblems(a, buck, try replaced(a, farm, " //:flaky", "")), &.{"//:flaky is built with _MOJO_TOOLS in BUCK"});
    // Mutant: farm.yml excludes a unit target.
    try c.expectLines("unit target excluded", try farmProblems(a, buck, try replaced(a, farm, " //:user_beta)", " //:user_beta //:mopm)")), &.{"//:mopm is excluded"});
}

// ---- lint.yml and ci.yml: no skipped check ---------------------------------------------------------

test "lint.yml and ci.yml: no pull_request filter, and no job-level if on a lint job" {
    const lint_job = "jobs:\n  lint:\n    runs-on: x\n";
    // The unfiltered triggers pass, and so do the default types with more added (ci.yml's `labeled`).
    try expectStructure("lint.yml", header ++ "on:\n  pull_request:\n  push:\n    branches: [main]\n" ++ lint_job ++ "    steps:\n      - run: zig test tests/drivers/release_lint_test.zig\n", &.{});
    try expectStructure("ci.yml", header ++ "on:\n  pull_request:\n    types: [opened, synchronize, reopened, labeled]\njobs:\n  test:\n    runs-on: x\n", &.{});
    // Mutants: each filter key, on each file.
    const run_step = "    steps:\n      - run: zig test tests/drivers/release_lint_test.zig\n";
    inline for ([_][]const u8{ "lint.yml", "ci.yml" }) |f| {
        const jobs = comptime if (std.mem.eql(u8, f, "lint.yml")) lint_job ++ run_step else "jobs:\n  test:\n    runs-on: x\n";
        try expectStructure(f, header ++ "on:\n  pull_request:\n    paths: ['src/**']\n" ++ jobs, &.{"the pull_request trigger must have no paths filter"});
        try expectStructure(f, header ++ "on:\n  pull_request:\n    paths-ignore: ['docs/**']\n" ++ jobs, &.{"the pull_request trigger must have no paths-ignore filter"});
        try expectStructure(f, header ++ "on:\n  pull_request:\n    branches: [main]\n" ++ jobs, &.{"the pull_request trigger must have no branches filter"});
        try expectStructure(f, header ++ "on:\n  pull_request:\n    branches-ignore: [wip]\n" ++ jobs, &.{"the pull_request trigger must have no branches-ignore filter"});
        try expectStructure(f, header ++ "on:\n  pull_request:\n    types: [labeled]\n" ++ jobs, &.{ "types must keep opened", "types must keep synchronize", "types must keep reopened" });
        try expectStructure(f, header ++ "on:\n  pull_request:\n    types: [opened, reopened]\n" ++ jobs, &.{"types must keep synchronize"});
    }
    // A job-level `if:` on a lint job can skip the check; only `!cancelled()` is allowed.
    const with_if = "on: [pull_request]\njobs:\n  lint:\n    runs-on: x\n    if: ";
    try expectStructure("lint.yml", header ++ with_if ++ "github.event_name == 'push'\n" ++ run_step, &.{"job lint has an `if:` (github.event_name == 'push')"});
    try expectStructure("lint.yml", header ++ with_if ++ "${{ !cancelled() || false }}\n" ++ run_step, &.{"job lint has an `if:`"});
    try expectStructure("lint.yml", header ++ with_if ++ "false\n" ++ run_step, &.{"job lint has an `if:`"});
    try expectStructure("lint.yml", header ++ with_if ++ "'!cancelled()'\n" ++ run_step, &.{});
    try expectStructure("lint.yml", header ++ with_if ++ "${{ !cancelled() }}\n" ++ run_step, &.{});
}

// ---- dependabot.yml: the cooldown and the coverage of every npm package ----------------------------

/// `real` with the first `from` replaced by `to`; the anchor must exist in the real file, so a mutant cannot go stale.
fn mutate(a: Allocator, real: []const u8, from: []const u8, to: []const u8) ![]u8 {
    if (std.mem.indexOf(u8, real, from) == null) {
        std.debug.print("the mutant anchor `{s}` is not in .github/dependabot.yml\n", .{from});
        return error.TestUnexpectedResult;
    }
    const at = std.mem.indexOf(u8, real, from).?;
    return std.mem.concat(a, u8, &.{ real[0..at], to, real[at + from.len ..] });
}

test "dependabot.yml: every npm entry waits 7 days, and every package-lock.json has an entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const real = try tree.read(a, ".github/dependabot.yml");

    var out = c.Out.init(a);
    try hyg.dependabotProblems(a, real, tree.files, &out);
    try c.expectLines("the real file", out.items, &.{});

    // Mutant: one entry's cooldown is 6 days.
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, try mutate(a, real, "default-days: 7", "default-days: 6"), tree.files, &out);
    try c.expectLines("6 days", out.items, &.{"npm entry /service/api: needs `cooldown: default-days:` of at least 7, got 6"});
    // Mutant: a quoted number is a string, not a day count.
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, try mutate(a, real, "default-days: 7", "default-days: \"7\""), tree.files, &out);
    try c.expectLines("a string", out.items, &.{"npm entry /service/api: needs"});
    // Mutant: the cooldown key of one entry is misspelled (Dependabot would ignore it).
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, try mutate(a, real, "default-days: 7", "default_days: 7"), tree.files, &out);
    try c.expectLines("a misspelled key", out.items, &.{"npm entry /service/api: needs"});
    // Mutant: an entry without a cooldown block at all (the one for /site, the last).
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, try mutate(a, real, "    directory: /site\n    schedule:\n      interval: weekly\n    cooldown:\n      default-days: 7\n", "    directory: /site\n    schedule:\n      interval: weekly\n"), tree.files, &out);
    try c.expectLines("no cooldown", out.items, &.{"npm entry /site: needs"});
    // Mutant: a package with a lockfile and no entry (/service/api renamed to a directory without one).
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, try mutate(a, real, "directory: /service/api\n", "directory: /service/other\n"), tree.files, &out);
    try c.expectLines("no entry", out.items, &.{"no npm entry for /service/api (it has a package-lock.json)"});
    // Mutant: an unreadable document, and one without updates, are findings and not passes.
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, "version: 2\n", tree.files, &out);
    try c.expectLines("no updates", out.items, &.{"no `updates` list"});
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, "version: 2\nupdates: x\n", tree.files, &out);
    try c.expectLines("updates not a list", out.items, &.{"`updates` is not a list"});
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, "version: 2\nupdates:\n\t- x\n", tree.files, &out);
    try c.expectLines("not YAML", out.items, &.{"not readable as YAML"});
    // Mutant: an npm entry with no directory is named as such, and still needs its cooldown.
    out = c.Out.init(a);
    try hyg.dependabotProblems(a, "version: 2\nupdates:\n  - package-ecosystem: npm\n", &.{}, &out);
    try c.expectLines("no directory", out.items, &.{"npm entry (no directory): needs"});
}
