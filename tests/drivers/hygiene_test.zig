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
        "site/pins.lock.bzl",
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
    // The same trigger is fine in the four unit workflows.
    for ([_][]const u8{ "lint.yml", "service-ci.yml" }) |ok| {
        try expectStructure(ok, header ++ "on: [pull_request]\njobs:\n  j:\n    runs-on: x\n", &.{});
    }
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

test "release.yml may name the release bot's key exactly twice (tag, bump), and no other secret" {
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
        \\      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1
        \\        with:
        \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
        \\  bump:
        \\    environment: release
        \\    runs-on: x
        \\    steps:
        \\      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1
        \\        with:
        \\          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}
        \\
    ;
    try expectStructure("release.yml", release, &.{});
    // Mutant: a third reference to the key.
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "        env:\n          K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n" }), &.{"must not use secrets or an environment"});
    // Mutants: the key under another name (the jobs then read nothing, so their environment is a finding too); another
    // secret beside the allowed one.
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, "RELEASE_BOT_PRIVATE_KEY", "OTHER_KEY"), &.{ "must not use secrets or an environment", "job tag: must not use secrets or an environment", "job bump: must not use secrets or an environment" });
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "        env:\n          X: ${{ secrets.ANOTHER }}\n" }), &.{"must not use secrets or an environment"});
    // The environment of the jobs that read the key is `release`, and only theirs.
    const tag_env = "  tag:\n    environment: release\n";
    const bump_env = "  bump:\n    environment: release\n";
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tag_env, "  tag:\n"), &.{"job tag reads RELEASE_BOT_* so it must declare environment release, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, bump_env, "  bump:\n"), &.{"job bump reads RELEASE_BOT_* so it must declare environment release, got nil"});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, tag_env, "  tag:\n    environment: relase\n"), &.{"job tag reads RELEASE_BOT_* so it must declare environment release, got \"relase\""});
    try expectStructure("release.yml", try std.mem.replaceOwned(u8, a, release, bump_env, "  bump:\n    environment: prod\n"), &.{"job bump reads RELEASE_BOT_* so it must declare environment release, got \"prod\""});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: release\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
    try expectStructure("release.yml", try std.mem.concat(a, u8, &.{ release, "  publish:\n    environment: prod\n    runs-on: x\n" }), &.{"job publish: must not use secrets or an environment"});
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
