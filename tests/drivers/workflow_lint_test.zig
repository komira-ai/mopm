//! //:workflows: the workflow lint
//! (tests/drivers/workflow_lint.zig), run by Buck2 over the repository's
//! workflows, and shown able to fail: each rule has a planted defect that must
//! be flagged, with its message.
//!
//! The syntax check of `run:` scripts is a stand-in for `bash -n` (the farm has
//! no bash); the scripts it accepts and refuses are listed below, the gaps too.

const std = @import("std");
const c = @import("lint_common.zig");
const wl = @import("workflow_lint.zig");
const sh = @import("shell_syntax.zig");
const Allocator = std.mem.Allocator;

// ---- the repository's workflows ---------------------------------------------------

const Repo = struct {
    tree: c.Tree,
    /// A workflow to change before it is read, and the change (it must apply).
    name: []const u8 = "",
    from: []const u8 = "",
    to: []const u8 = "",

    pub fn read(self: Repo, a: Allocator, name: []const u8) ![]u8 {
        const text = try self.tree.read(a, try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name}));
        if (!std.mem.eql(u8, name, self.name)) return text;
        if (std.mem.indexOf(u8, text, self.from) == null) {
            std.debug.print("the planted change does not apply to {s}: {s} is not in it\n", .{ name, self.from });
            return error.TestUnexpectedResult;
        }
        return std.mem.replaceOwned(u8, a, text, self.from, self.to);
    }
};

test "every workflow of the repository passes, and so does the promotion chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const files = try c.workflowFiles(a, tree);
    try std.testing.expect(files.len >= 8);
    var out = c.Out.init(a);
    for (files) |f| try wl.fileProblems(a, f, try tree.read(a, f), &out);
    try wl.repoProblems(a, Repo{ .tree = tree }, &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

fn expectRepo(name: []const u8, from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    var out = c.Out.init(a);
    try wl.repoProblems(a, Repo{ .tree = tree, .name = name, .from = from, .to = to }, &out);
    try c.expectLines(name, out.items, want);
}

test "promote.yml: the chain, the stages, no if and no continue-on-error" {
    try expectRepo("promote.yml", "needs: beta-deploy", "needs: gamma-e2e", &.{"promote.yml: beta-e2e needs [\"gamma-e2e\"], expected [\"beta-deploy\"]"});
    try expectRepo("promote.yml", "  gamma-e2e:\n    needs: gamma-deploy\n", "  gamma-e2e:\n", &.{"promote.yml: gamma-e2e needs [], expected [\"gamma-deploy\"]"});
    try expectRepo("promote.yml", "  beta-deploy:\n", "  beta-deploy:\n    continue-on-error: true\n", &.{"promote.yml: beta-deploy must not set continue-on-error"});
    try expectRepo("promote.yml", "  beta-deploy:\n", "  beta-deploy:\n    if: always()\n", &.{"promote.yml: beta-deploy must not set if"});
    try expectRepo("promote.yml", "  prod-smoke:\n", "  prod-smok:\n", &.{"promote.yml: jobs [\"beta-deploy\", \"beta-e2e\", \"gamma-deploy\", \"gamma-e2e\", \"prod-deploy\", \"prod-smok\"] differ from expected"});
    try expectRepo("promote.yml", "with: { stage: beta }", "with: { stage: gamma }", &.{"promote.yml: beta-deploy must target stage beta"});
    try expectRepo("promote.yml", "  gamma-deploy:\n    needs: beta-e2e\n    uses: ./.github/workflows/deploy.yml", "  gamma-deploy:\n    needs: beta-e2e\n    uses: ./.github/workflows/e2e.yml", &.{"promote.yml: gamma-deploy must call ./.github/workflows/deploy.yml"});
}

test "deploy.yml and e2e.yml: the guard gates the one credential job" {
    try expectRepo("deploy.yml", "    needs: guard\n", "    needs: other\n", &.{"deploy.yml: deploy must need the guard job"});
    try expectRepo("deploy.yml", "    environment: ${{ inputs.stage }}\n", "", &.{"deploy.yml: deploy must declare an environment"});
    try expectRepo("deploy.yml", "      id-token: write\n", "      id-token: read\n", &.{"deploy.yml: expected exactly one job with id-token"});
    try expectRepo("e2e.yml", "    needs: guard\n", "    needs: other\n", &.{ "e2e.yml: smoke-linux must need the guard job", "e2e.yml: index-gate must need the guard job", "e2e.yml: group-e2e must need the guard job" });
    try expectRepo("e2e.yml", "    environment: ${{ inputs.stage }}\n", "", &.{"e2e.yml: smoke-linux must declare an environment"});
    try expectRepo("e2e.yml", "      id-token: write\n", "      id-token: read\n", &.{"e2e.yml: expected exactly one job with id-token"});
}

test "e2e.yml: the index gate stays curl only, guarded, and asserts its three answers exactly" {
    try expectRepo("e2e.yml", "  index-gate:\n    needs: guard\n", "  index-gate:\n    needs: other\n", &.{"e2e.yml: index-gate must need the guard job"});
    try expectRepo("e2e.yml", "    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n    timeout-minutes: 10\n", "    runs-on: ubuntu-24.04\n    timeout-minutes: 10\n", &.{"e2e.yml: index-gate must run on main only"});
    try expectRepo("e2e.yml", "    timeout-minutes: 10\n    permissions:\n      contents: read\n", "    timeout-minutes: 10\n    environment: ${{ inputs.stage }}\n    permissions:\n      contents: read\n", &.{"e2e.yml: index-gate must not declare an environment"});
    try expectRepo("e2e.yml", "    timeout-minutes: 10\n    permissions:\n      contents: read\n", "    timeout-minutes: 10\n    permissions:\n      contents: read\n      id-token: write\n", &.{ "e2e.yml: expected exactly one job with id-token", "e2e.yml: index-gate must declare an environment", "e2e.yml: index-gate must grant exactly contents read" });
    try expectRepo("e2e.yml", "code=$(get /takedowns.json)", "code=$(get /takedowns)", &.{"e2e.yml: index-gate script lost `get /takedowns.json`"});
    try expectRepo("e2e.yml", "[ \"$code\" = \"404\" ]", "[ \"$code\" = \"403\" ]", &.{ "e2e.yml: index-gate script lost `= \"404\"`", "e2e.yml: index-gate script lost `if [ \"$code\" = \"404\" ]; then`" });
    try expectRepo("e2e.yml", "          [ \"$failed\" = \"0\" ] || { echo \"sparse index gate failed on stage ${STAGE}\" >&2; exit 1; }\n", "", &.{"e2e.yml: index-gate script lost `\n[ \"$failed\" = \"0\" ] || { echo \"sparse index gate failed on stage ${STAGE}\" >&2; exit 1; }\n`"});
    try expectRepo("e2e.yml", "                 and .stage == $stage\n", "", &.{"e2e.yml: index-gate script lost `and .stage == $stage`"});
    try expectRepo("e2e.yml", "                 and .channel_url == $ch\n", "", &.{"e2e.yml: index-gate script lost `and .channel_url == $ch`"});
    try expectRepo("e2e.yml", "(.index_version | type == \"number\" and . == 1) and (.takedowns", "(.index_version | type == \"number\") and (.takedowns", &.{"e2e.yml: index-gate script lost `(.index_version | type == \"number\" and . == 1)` (config.json and takedowns.json both need it)"});
    try expectRepo("e2e.yml", "if [ \"$code\" = \"404\" ]; then", "if [ \"$code\" = \"404\" ] || [ \"$code\" = \"403\" ]; then", &.{ "e2e.yml: index-gate script lost `if [ \"$code\" = \"404\" ]; then`", "e2e.yml: index-gate must accept only 404 for the absent package" });
}

/// The workflow `name` of the repository with `from` replaced by `to`, linted file by file.
fn expectFile(name: []const u8, from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const text = try tree.read(a, try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name}));
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the change does not apply to {s}: {s} is not in it\n", .{ name, from });
        return error.TestUnexpectedResult;
    }
    try c.expectLines(name, try lint(a, name, try std.mem.replaceOwned(u8, a, text, from, to)), want);
}

const group_secret_line = "          MOPM_E2E_TOKEN: ${{ secrets.MOPM_E2E_GROUP_TOKEN }}\n";
const group_checkout = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n      - name: Validate stage\n        env:\n          STAGE: ${{ inputs.stage }}\n        run: |\n          case \"$STAGE\" in beta|gamma) ;;";

test "e2e.yml: the group e2e job never runs for a pull request, and runs only after a deploy or by hand" {
    try expectRepo("e2e.yml", "on:\n  workflow_call:\n", "on:\n  pull_request:\n  workflow_call:\n", &.{"e2e.yml: triggers must be exactly workflow_call and workflow_dispatch (a pull request must not hold the group e2e token), got [\"pull_request\", \"workflow_call\", \"workflow_dispatch\"]"});
    try expectRepo("e2e.yml", "on:\n  workflow_call:\n", "on:\n  push:\n  workflow_call:\n", &.{"e2e.yml: triggers must be exactly workflow_call and workflow_dispatch (a pull request must not hold the group e2e token), got [\"push\", \"workflow_call\", \"workflow_dispatch\"]"});
    try expectRepo("e2e.yml", "  workflow_dispatch:\n    inputs:", "  workflow_dispatch:\n  schedule:\n    inputs:", &.{"e2e.yml: triggers must be exactly workflow_call and workflow_dispatch"});
    try expectRepo("e2e.yml", "  group-e2e:\n    needs: guard\n", "  group-e2e:\n    needs: other\n", &.{"e2e.yml: group-e2e must need the guard job"});
    try expectRepo("e2e.yml", " && inputs.stage != 'prod'\n", "\n", &.{"e2e.yml: group-e2e must run on main only, and never for prod"});
    try expectRepo("e2e.yml", "    if: github.ref == 'refs/heads/main' && inputs.stage != 'prod'\n", "", &.{"e2e.yml: group-e2e must run on main only, and never for prod"});
}

test "e2e.yml: the group e2e job holds a read-only token, no environment, no id-token, and the pinned checkout alone" {
    try expectRepo("e2e.yml", "    timeout-minutes: 45\n", "    timeout-minutes: 45\n    environment: ${{ inputs.stage }}\n", &.{"e2e.yml: group-e2e must not declare an environment"});
    try expectRepo("e2e.yml", "    timeout-minutes: 45\n", "    timeout-minutes: 45\n    continue-on-error: true\n", &.{"e2e.yml: group-e2e must not set continue-on-error"});
    try expectRepo("e2e.yml", "    timeout-minutes: 45\n", "    timeout-minutes: 45\n    env:\n      X: y\n", &.{"e2e.yml: group-e2e must not set env at job level"});
    try expectRepo("e2e.yml", "    timeout-minutes: 45\n    permissions:\n      contents: read\n", "    timeout-minutes: 45\n    permissions:\n      contents: read\n      id-token: write\n", &.{ "e2e.yml: expected exactly one job with id-token", "e2e.yml: group-e2e must declare an environment", "e2e.yml: group-e2e must grant exactly contents read" });
    try expectRepo("e2e.yml", "    timeout-minutes: 45\n    permissions:\n      contents: read\n", "    timeout-minutes: 45\n    permissions:\n      contents: read\n      issues: read\n", &.{"e2e.yml: group-e2e must grant exactly contents read"});
    try expectRepo("e2e.yml", "      - name: Install Zig 0.12.0 (sha256-pinned)\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n", "      - uses: actions/setup-node@3d3c42e5aac5ba805825da76410c181273ba90b1\n", &.{"e2e.yml: group-e2e step 2: only actions/checkout pinned by full SHA is allowed here: actions/setup-node@3d3c42e5aac5ba805825da76410c181273ba90b1"});
    try expectRepo("e2e.yml", group_checkout, "      - uses: actions/checkout@v4\n        with:\n          persist-credentials: false\n      - name: Validate stage\n        env:\n          STAGE: ${{ inputs.stage }}\n        run: |\n          case \"$STAGE\" in beta|gamma) ;;", &.{"e2e.yml: group-e2e step 0: only actions/checkout pinned by full SHA is allowed here: actions/checkout@v4"});
    // The same unpinned action is refused by the per-file rule that holds every workflow.
    try expectFile("e2e.yml", group_checkout, "      - uses: actions/checkout@v4\n        with:\n          persist-credentials: false\n      - name: Validate stage\n        env:\n          STAGE: ${{ inputs.stage }}\n        run: |\n          case \"$STAGE\" in beta|gamma) ;;", &.{"e2e.yml: group-e2e step 0: only GitHub-owned actions pinned by full SHA are allowed: actions/checkout@v4"});
}

test "e2e.yml: the repository secret is read once, as MOPM_E2E_TOKEN, by the step that runs the check" {
    // A second reader: another step of another job.
    try expectRepo("e2e.yml", "          EXPECTED_IMPL: ts\n", "          EXPECTED_IMPL: ts\n          LEAK: ${{ secrets.MOPM_E2E_GROUP_TOKEN }}\n", &.{ "e2e.yml: secrets.MOPM_E2E_GROUP_TOKEN must be referenced exactly once, on the step that runs the check, got 2", "e2e.yml: job smoke-linux reads MOPM_E2E_GROUP_TOKEN; only group-e2e may" });
    // A second reader in the same job, and the step before the check.
    try expectRepo("e2e.yml", "        env:\n          STAGE: ${{ inputs.stage }}\n        run: |\n          case \"$STAGE\" in beta|gamma) ;;", "        env:\n          STAGE: ${{ inputs.stage }}\n" ++ group_secret_line ++ "        run: |\n          case \"$STAGE\" in beta|gamma) ;;", &.{ "e2e.yml: secrets.MOPM_E2E_GROUP_TOKEN must be referenced exactly once, on the step that runs the check, got 2", "e2e.yml: exactly one step of group-e2e must read the token, got 2" });
    // Another name for the variable.
    try expectRepo("e2e.yml", group_secret_line, "          TOKEN: ${{ secrets.MOPM_E2E_GROUP_TOKEN }}\n", &.{"e2e.yml: group-e2e step 4: the secret goes in as the variable MOPM_E2E_TOKEN, set to secrets.MOPM_E2E_GROUP_TOKEN and nothing around it, not as TOKEN"});
    // Wrapped in something else.
    try expectRepo("e2e.yml", group_secret_line, "          MOPM_E2E_TOKEN: x-${{ secrets.MOPM_E2E_GROUP_TOKEN }}\n", &.{"e2e.yml: group-e2e step 4: the secret goes in as the variable MOPM_E2E_TOKEN"});
    // Another secret in the job.
    try expectRepo("e2e.yml", "          RUN_ID: ${{ github.run_id }}\n", "          RUN_ID: ${{ github.run_id }}\n          AWS_REGION: ${{ secrets.AWS_REGION }}\n", &.{"e2e.yml: group-e2e step 4: reads AWS_REGION from secrets; the job reads no secret but MOPM_E2E_GROUP_TOKEN"});
    // The secret through with:, and at the top of the workflow.
    try expectRepo("e2e.yml", "      - name: Build the CLI and the group check\n        run: zig build -Doptimize=ReleaseSafe\n", "      - name: Build the CLI and the group check\n        with:\n          t: ${{ secrets.AWS_REGION }}\n        run: zig build -Doptimize=ReleaseSafe\n", &.{"e2e.yml: group-e2e step 3: passes a secret through with:"});
    try expectRepo("e2e.yml", "permissions:\n  contents: read\n\njobs:\n", "permissions:\n  contents: read\n\nenv:\n  X: ${{ secrets.AWS_REGION }}\n\njobs:\n", &.{"e2e.yml: the workflow must not set env from secrets"});
    // The step that holds it must run the check, and the check must say why it skipped.
    try expectRepo("e2e.yml", "./zig-out/bin/mopm-group-e2e --stage", "./zig-out/bin/other --stage", &.{"e2e.yml: the step of group-e2e that holds the token must run mopm-group-e2e"});
    try expectRepo("e2e.yml", " --summary \"$GITHUB_STEP_SUMMARY\"\n", "\n", &.{"e2e.yml: the step of group-e2e that holds the token must pass --summary"});
    // The job itself is missing (renamed): its secret is then read by a job that may not.
    try expectRepo("e2e.yml", "  group-e2e:\n    needs: guard\n", "  group-e2f:\n    needs: guard\n", &.{ "e2e.yml: job group-e2f reads MOPM_E2E_GROUP_TOKEN; only group-e2e may", "e2e.yml: the group-e2e job is missing" });
}

test "the group e2e token is read by e2e.yml and no other workflow, and no step prints it" {
    try expectLint("ci.yml", head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    steps:
        \\      - run: ./t
        \\        env:
        \\          T: ${{ secrets.MOPM_E2E_GROUP_TOKEN }}
        \\
    , &.{"ci.yml: secrets.MOPM_E2E_GROUP_TOKEN is for the group-e2e job of e2e.yml alone"});
    try expectLint("e2e.yml", head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    steps:
        \\      - run: ./t
        \\        env:
        \\          T: ${{ secrets.MOPM_E2E_GROUP_TOKEN }}
        \\
    , &.{});
    try expectRun("echo \"$MOPM_E2E_TOKEN\"", &.{"ci.yml: j step 0: prints a secret-bearing variable: echo \"$MOPM_E2E_TOKEN\""});
    try expectRun("printf '%s' \"${MOPM_E2E_GROUP_TOKEN}\"", &.{"prints a secret-bearing variable"});
}

test "oidc-subject-check.yml: manual, guarded, beta or no environment, exact permissions" {
    try expectRepo("oidc-subject-check.yml", "    environment: beta\n", "    environment: prod\n", &.{
        "oidc-subject-check.yml: claims-environment-beta must not use environment \"prod\"",
        "oidc-subject-check.yml: needs one job without an environment and one in beta",
    });
    try expectRepo("oidc-subject-check.yml", "      id-token: write\n      contents: read\n", "      id-token: write\n      contents: write\n", &.{
        "claims-no-environment must grant exactly id-token and contents read",
        "claims-environment-beta must grant exactly id-token and contents read",
    });
    try expectRepo("oidc-subject-check.yml", "  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n", &.{"oidc-subject-check.yml: only workflow_dispatch is allowed"});
    try expectRepo("oidc-subject-check.yml", "    needs: guard\n", "    needs: nothing\n", &.{
        "claims-no-environment must need the guard job",
        "claims-environment-beta must need the guard job",
    });
    try expectRepo("oidc-subject-check.yml", "    environment: beta\n", "", &.{"oidc-subject-check.yml: needs one job without an environment and one in beta"});
}

// ---- the per-file rules --------------------------------------------------------------

fn lint(a: Allocator, name: []const u8, yaml: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    try wl.fileProblems(a, name, yaml, &out);
    return out.items;
}

fn expectLint(name: []const u8, yaml: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try c.expectLines(name, try lint(arena.allocator(), name, yaml), want);
}

const head =
    \\name: t
    \\on: [push]
    \\permissions:
    \\  contents: read
    \\
;

const job_head =
    \\jobs:
    \\  j:
    \\    runs-on: x
    \\
;

test "a clean workflow" {
    try expectLint("ci.yml", head ++ job_head ++
        \\    steps:
        \\      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1
        \\      - run: echo hello
        \\
    , &.{});
}

test "the default token is read-only and stated" {
    try expectLint("ci.yml",
        \\name: t
        \\on: [push]
    ++ "\n" ++ job_head, &.{"ci.yml: top-level permissions must be set"});
    try expectLint("ci.yml",
        \\name: t
        \\on: [push]
        \\permissions: write-all
        \\
    ++ job_head, &.{ "top-level permissions must not be \"write-all\"", "permissions = write-all" });
    try expectLint("ci.yml",
        \\name: t
        \\on: [push]
        \\permissions: read-all
        \\
    ++ job_head, &.{"top-level permissions must not be \"read-all\""});
    try expectLint("ci.yml",
        \\name: t
        \\on: [push]
        \\permissions:
        \\  contents: write
        \\
    ++ job_head, &.{ "top-level permissions must be read-only", "permissions.contents: write is not allowed" });
    try expectLint("ci.yml",
        \\name: t
        \\on: [push]
        \\permissions:
        \\  contents: none
        \\
    ++ job_head, &.{});
}

test "write permissions: only id-token, and only in the deploy workflows" {
    const job_write = head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    permissions:
        \\      contents: write
        \\
    ;
    try expectLint("ci.yml", job_write, &.{"ci.yml: jobs.j.permissions.contents: write is not allowed"});
    try expectLint("deploy.yml", job_write, &.{"deploy.yml: jobs.j.permissions.contents: write is not allowed"});
    try expectLint("ci.yml", head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    permissions: write-all
        \\
    , &.{"ci.yml: jobs.j.permissions = write-all"});
    const id_token = head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    permissions:
        \\      id-token: write
        \\
    ;
    try expectLint("ci.yml", id_token, &.{"ci.yml: jobs.j.permissions.id-token: write is not allowed"});
    try expectLint("deploy.yml", id_token, &.{});
    try expectLint("e2e.yml", id_token, &.{});
    try expectLint("promote.yml", id_token ++ "concurrency:\n  group: g\n  cancel-in-progress: false\n", &.{"triggers must be exactly push and workflow_dispatch"});
    try expectLint("oidc-subject-check.yml", id_token, &.{});
    try expectLint("farm.yml", id_token, &.{});
}

test "account, region and role ARNs are not repository variables" {
    try expectLint("ci.yml", head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    env:
        \\      A: ${{ vars.AWS_ACCOUNT_ID }}
        \\      B: ${{ vars.my_region }}
        \\      C: ${{ vars.ROLE_ARN }}
        \\      D: ${{ vars.FARM_ADDRESS }}
        \\
    , &.{
        "ci.yml: vars.AWS_ACCOUNT_ID: account, region and role ARNs come from environment secrets, not vars",
        "ci.yml: vars.my_region: account",
        "ci.yml: vars.ROLE_ARN: account",
    });
}

test "the publish role of the apt repository is the one role ARN that release.yml may read from a variable" {
    const role = head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    env:
        \\      A: ${{ vars.APT_PUBLISH_ROLE_ARN }}
        \\
    ;
    try expectLint("release.yml", role, &.{});
    try expectLint("ci.yml", role, &.{"ci.yml: vars.APT_PUBLISH_ROLE_ARN: account, region and role ARNs come from environment secrets, not vars"});
    try expectLint("release.yml", head ++
        \\jobs:
        \\  j:
        \\    runs-on: x
        \\    env:
        \\      A: ${{ vars.APT_PUBLISH_ROLE_ARN_2 }}
        \\      B: ${{ vars.OTHER_ROLE_ARN }}
        \\
    , &.{ "release.yml: vars.APT_PUBLISH_ROLE_ARN_2: account", "release.yml: vars.OTHER_ROLE_ARN: account" });
}

const promote_ok =
    \\name: p
    \\on:
    \\  push: { branches: [main] }
    \\  workflow_dispatch:
    \\concurrency:
    \\  group: promote
    \\  cancel-in-progress: false
    \\permissions:
    \\  contents: read
    \\jobs:
    \\  gate:
    \\    uses: ./.github/workflows/deploy.yml
    \\    with: { stage: beta }
    \\    permissions: { id-token: write, contents: read }
    \\    secrets: inherit
    \\
;

fn expectPromote(from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (std.mem.indexOf(u8, promote_ok, from) == null) return error.TestUnexpectedResult;
    const yaml = try std.mem.replaceOwned(u8, a, promote_ok, from, to);
    try c.expectLines(to, try lint(a, "promote.yml", yaml), want);
}

test "promote.yml: exactly a push to main and a manual run, serialized, secrets inherited" {
    try expectLint("promote.yml", promote_ok, &.{});
    try expectPromote("  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n", &.{"triggers must be exactly push and workflow_dispatch, got [\"push\", \"workflow_dispatch\", \"pull_request\"]"});
    try expectPromote("  workflow_dispatch:\n", "", &.{"triggers must be exactly push and workflow_dispatch, got [\"push\"]"});
    try expectPromote("[main]", "[main, dev]", &.{"promote.yml: push must be limited to branches [main]"});
    try expectPromote("cancel-in-progress: false", "cancel-in-progress: true", &.{"needs a concurrency group with cancel-in-progress: false"});
    try expectPromote("concurrency:\n  group: promote\n  cancel-in-progress: false\n", "", &.{"needs a concurrency group with cancel-in-progress: false"});
    try expectPromote("  group: promote\n", "", &.{"needs a concurrency group"});
    try expectPromote("    secrets: inherit\n", "", &.{"job gate must set secrets: inherit"});
}

test "secrets: inherit is for promote.yml only" {
    try expectLint("ci.yml", head ++
        \\jobs:
        \\  j:
        \\    uses: ./.github/workflows/x.yml
        \\    secrets: inherit
        \\
    , &.{"ci.yml: secrets: inherit is not allowed outside promote.yml"});
}

test "no privileged trigger, no workflow_run, no issue_comment" {
    for ([_][]const u8{ "pull_request_" ++ "target", "workflow_run", "issue_comment" }) |t| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const yaml = try std.fmt.allocPrint(a, "name: t\non: [{s}]\npermissions:\n  contents: read\n{s}", .{ t, job_head });
        const want = try std.fmt.allocPrint(a, "ci.yml: trigger {s} is not allowed", .{t});
        try c.expectLines(t, try lint(a, "ci.yml", yaml), &.{want});
    }
}

test "only local workflows are called, only GitHub-owned actions pinned by SHA are used" {
    try expectLint("ci.yml", head ++
        \\jobs:
        \\  a:
        \\    uses: ./.github/workflows/x.yml
        \\  b:
        \\    uses: other/repo/.github/workflows/x.yml@main
        \\  c:
        \\    uses: ./.github/workflows/Bad.yml
        \\
    , &.{
        "ci.yml: job b may only call a local workflow, not other/repo/.github/workflows/x.yml@main",
        "ci.yml: job c may only call a local workflow, not ./.github/workflows/Bad.yml",
    });
    const sha = "3d3c42e5aac5ba805825da76410c181273ba90b1";
    for ([_][]const u8{ "checkout", "setup-node", "upload-artifact", "download-artifact" }) |n| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const ok = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: actions/{s}@{s}\n", .{ head, job_head, n, sha });
        try c.expectLines(n, try lint(a, "ci.yml", ok), &.{});
    }
    const steps = [_][]const u8{
        "actions/checkout@v4",
        "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b",
        "actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1",
        "actions/cache@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "third/party@3d3c42e5aac5ba805825da76410c181273ba90b1",
        "komira-ai/komira/.github/actions/farm-connect@3d3c42e5aac5ba805825da76410c181273ba90b1",
    };
    for (steps) |u| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const yaml = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: {s}\n", .{ head, job_head, u });
        const want = try std.fmt.allocPrint(a, "ci.yml: j step 0: only GitHub-owned actions pinned by full SHA are allowed: {s}", .{u});
        try c.expectLines(u, try lint(a, "ci.yml", yaml), &.{want});
    }
    // komira's farm-connect, pinned by commit, is for farm.yml alone
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const connect = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: komira-ai/komira/.github/actions/farm-connect@{s}\n", .{ head, job_head, sha });
    try c.expectLines("farm", try lint(a, "farm.yml", connect), &.{});
    const other = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: komira-ai/komira/.github/actions/other@{s}\n", .{ head, job_head, sha });
    try c.expectLines("farm other", try lint(a, "farm.yml", other), &.{"only GitHub-owned actions pinned by full SHA"});
}

test "actions/create-github-app-token is for release.yml alone, pinned by commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const pinned_use = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n", .{ head, job_head });
    try c.expectLines("release.yml", try lint(a, "release.yml", pinned_use), &.{});
    // Mutants: another workflow, and a tag instead of a commit.
    try c.expectLines("ci.yml", try lint(a, "ci.yml", pinned_use), &.{"only GitHub-owned actions pinned by full SHA"});
    const tagged = try std.fmt.allocPrint(a, "{s}{s}    steps:\n      - uses: actions/create-github-app-token@v3\n", .{ head, job_head });
    try c.expectLines("release.yml tag", try lint(a, "release.yml", tagged), &.{"only GitHub-owned actions pinned by full SHA"});
}

// ---- run scripts ------------------------------------------------------------------------

fn withRun(a: Allocator, script: []const u8) ![]u8 {
    var out = std.ArrayList(u8).init(a);
    try out.appendSlice(head ++ job_head ++ "    steps:\n      - run: |\n");
    var lines = std.mem.splitScalar(u8, script, '\n');
    while (lines.next()) |l| {
        if (l.len == 0) continue;
        try out.appendSlice("          ");
        try out.appendSlice(l);
        try out.append('\n');
    }
    return out.items;
}

fn expectRun(script: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try c.expectLines(script, try lint(a, "ci.yml", try withRun(a, script)), want);
}

test "a step does not print a secret-bearing variable" {
    try expectRun("echo \"$ROLE_ARN\"", &.{"ci.yml: j step 0: prints a secret-bearing variable: echo \"$ROLE_ARN\""});
    try expectRun("echo ${AWS_REGION:-us-east-1}", &.{"prints a secret-bearing variable: echo ${AWS_REGION:-us-east-1}"});
    try expectRun("printf '%s' \"$AWS_SESSION_TOKEN\"", &.{"prints a secret-bearing variable"});
    try expectRun("cat \"$AWS_SECRET_ACCESS_KEY\"", &.{"prints a secret-bearing variable"});
    try expectRun("tee out <<< \"$AWS_ACCOUNT_ID\"", &.{"prints a secret-bearing variable"});
    try expectRun("true && echo $AWS_ACCOUNT_ID", &.{"prints a secret-bearing variable: echo $AWS_ACCOUNT_ID"});
    try expectRun("echo a; echo $AWS_REGION", &.{"prints a secret-bearing variable: echo $AWS_REGION"});
    try expectRun("echo a | tee $ROLE_ARN", &.{"prints a secret-bearing variable: tee $ROLE_ARN"});
    // two segments, two findings
    try expectRun("echo $ROLE_ARN; echo $AWS_REGION", &.{ "echo $ROLE_ARN", "echo $AWS_REGION" });
    // a backslash-newline joins the lines
    try expectRun("echo \\\n  $ROLE_ARN", &.{"prints a secret-bearing variable: echo    $ROLE_ARN"});
    // ::add-mask:: is the one allowed use
    try expectRun("echo \"::add-mask::$ROLE_ARN\"", &.{});
    // not the variable: a longer name, a name without $, a command that is not a printer
    try expectRun("echo $AWS_REGIONS", &.{});
    try expectRun("echo 'AWS_REGION is not set'", &.{});
    try expectRun("export X=$ROLE_ARN", &.{});
    try expectRun("echo ${ROLE_ARN", &.{"bash -n failed"});
}

test "a here-document that cats a secret-bearing variable" {
    try expectRun("cat <<EOF\nrole is $ROLE_ARN\nEOF", &.{"prints a secret-bearing variable: role is $ROLE_ARN"});
    try expectRun("cat <<-'EOT'\n  $AWS_REGION\nEOT", &.{"prints a secret-bearing variable: $AWS_REGION"});
    try expectRun("cat <<EOF\nok\nEOF\nexport X=$ROLE_ARN", &.{});
    try expectRun("cat <<EOF\n$ROLE_ARN\nEOF\n: $ROLE_ARN", &.{"prints a secret-bearing variable: $ROLE_ARN"});
    // only cat and tee are looked at, not other readers of a here-document
    try expectRun("bash <<EOF\n$ROLE_ARN\nEOF", &.{});
}

test "heredocTag is the last << after the first cat or tee" {
    const got = wl.heredocTag;
    try std.testing.expectEqualStrings("EOF", got("cat <<EOF\n").?);
    try std.testing.expectEqualStrings("EOF", got("cat << EOF\n").?);
    try std.testing.expectEqualStrings("EOT", got("tee out <<-\"EOT\"\n").?);
    try std.testing.expectEqualStrings("B", got("cat <<A <<B\n").?);
    try std.testing.expect(got("echo <<EOF\n") == null);
    try std.testing.expect(got("cat file\n") == null);
    try std.testing.expect(got("cat <<\n") == null);
    try std.testing.expect(got("concatenate <<EOF\n") == null);
}

test "a step does not name secrets.* or interpolate an expression" {
    try expectRun("echo ${{ secrets.TOKEN }}", &.{ "run script references secrets.*", "run script interpolates an expression; pass it through env:" });
    try expectRun("echo ${{ github.head_ref }}", &.{"run script interpolates an expression; pass it through env:"});
    try expectRun("echo $HOME $(date)", &.{});
}

test "bash -n failed" {
    try expectRun("echo \"open", &.{"ci.yml: j step 0: bash -n failed"});
    try expectRun("if true; then echo a", &.{"bash -n failed"});
}

// ---- the stand-in for bash -n ------------------------------------------------------------

fn syntaxOk(script: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    return switch (try sh.check(arena.allocator(), script)) {
        .ok => true,
        .bad => false,
    };
}

fn expectAccepted(script: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (try sh.check(arena.allocator(), script)) {
        .ok => {},
        .bad => |why| {
            std.debug.print("refused a valid script ({s}):\n{s}\n", .{ why, script });
            return error.TestUnexpectedResult;
        },
    }
}

fn expectRefused(script: []const u8, why: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    switch (try sh.check(arena.allocator(), script)) {
        .ok => {
            std.debug.print("accepted a broken script (wanted: {s}):\n{s}\n", .{ why, script });
            return error.TestUnexpectedResult;
        },
        .bad => |got| {
            if (std.mem.indexOf(u8, got, why) == null) {
                std.debug.print("refused for the wrong reason: wanted {s}, got {s}\n", .{ why, got });
                return error.TestUnexpectedResult;
            }
        },
    }
}

test "scripts bash accepts, the scanner accepts" {
    try expectAccepted("echo hello");
    try expectAccepted("");
    try expectAccepted(
        \\set -euo pipefail
        \\resp=$(curl -sSf -H "Authorization: Bearer ${TOKEN}" \
        \\  "${URL}&audience=x")
        \\echo "::add-mask::$jwt"
        \\while [ $(( ${#payload} % 4 )) -ne 0 ]; do payload="${payload}="; done
        \\printf '%s' "$payload" | base64 -d | jq '{sub, job_workflow_ref}'
    );
    try expectAccepted(
        \\case "$EVENT" in push|workflow_dispatch) ;; *) echo "no $EVENT" >&2; exit 1 ;; esac
    );
    try expectAccepted(
        \\case "$X" in
        \\  a)
        \\    if [ -n "$Y" ]; then echo y; fi
        \\    ;;
        \\  b|c) echo bc ;;
        \\  *) ;;
        \\esac
    );
    try expectAccepted(
        \\cat <<EOF
        \\it's "broken fi done esac ) } $(
        \\EOF
        \\echo ok
    );
    try expectAccepted("cat <<EOF\nan unterminated body\n"); // bash warns and goes on
    try expectAccepted("f() { echo a; }\nf");
    try expectAccepted("function g { echo a; }; g");
    try expectAccepted("(cd x && make) | tee log; echo \"${PIPESTATUS[0]}\"");
    try expectAccepted("for ((i=0;i<3;i++)); do echo $i; done");
    try expectAccepted("for ((;;)); do break; done");
    try expectAccepted("for f in a b c; do echo \"$f\"; done");
    try expectAccepted("while read -r l; do echo \"$l\"; done < file");
    try expectAccepted("until false; do break; done");
    try expectAccepted("if [[ $x =~ ^(a|b)$ ]]; then echo yes; elif true; then echo no; else echo e; fi");
    try expectAccepted("echo 'it'\"'\"'s'");
    try expectAccepted("# an unbalanced ' in a comment\necho ok");
    try expectAccepted("echo $#; echo $?; echo $$; echo ${#arr[@]}; echo \"$@\"");
    try expectAccepted("exec 3>&1; echo hi >&3 2>/dev/null; cmd &>/dev/null");
    try expectAccepted("cmd <<< \"$X\"");
    try expectAccepted("echo `date`");
    try expectAccepted("[ -z \"$X\" ] && { echo no; exit 1; }");
    try expectAccepted("echo a &\nwait");
    try expectAccepted("diff <(echo a) <(echo b)");
    try expectAccepted("x=$(if true; then echo a; fi)");
    try expectAccepted("echo \"$(echo \"nested $(echo deep)\")\"");
    try expectAccepted("echo \"${x:-\"default\"}\" ${y:-'q'}");
    try expectAccepted("echo done fi esac }");
    try expectAccepted("a=1 b=2 cmd\n! false\ntime ls");
    try expectAccepted("cmd \\\n  --flag \\\n  arg");
    try expectAccepted("{\n  echo a\n  echo b\n} > out");
}

test "scripts bash refuses, the scanner refuses" {
    try expectRefused("echo \"unterminated", "matching `\"'");
    try expectRefused("echo 'unterminated", "matching `''");
    try expectRefused("echo `unterminated", "matching ``'");
    try expectRefused("echo $(date", "looking for `)'");
    try expectRefused("echo $(echo \"a)\"", "looking for `)'");
    try expectRefused("echo ${HOME", "matching `}'");
    try expectRefused("echo $(( 1 + 2 )", "matching `))'");
    try expectRefused("if true; then echo a", "compound command is not closed");
    try expectRefused("for i in 1 2; do echo $i", "compound command is not closed");
    try expectRefused("while true; do echo $i; fi", "`fi' without an if");
    try expectRefused("case x in a) echo ;;", "compound command is not closed");
    try expectRefused("{ echo a", "compound command is not closed");
    try expectRefused("fi", "`fi' without an if");
    try expectRefused("done", "`done' without a loop");
    try expectRefused("esac", "`esac' without a case");
    try expectRefused("}", "`}' without a `{'");
    try expectRefused("echo a )", "unexpected `)'");
    try expectRefused("then echo a", "outside an if");
    try expectRefused("else echo a", "outside an if");
    try expectRefused("do echo a", "`do' outside a loop");
    try expectRefused("echo a ;; echo b", "`;;' outside a case");
    try expectRefused("; echo a", "empty command");
    try expectRefused("echo a && && echo b", "empty command");
    try expectRefused("(echo a", "looking for `)'");
    try expectRefused("x=$(if true; then echo a)", "not closed before `)'");
    try expectRefused("if true; then\n  echo \"a\n  echo b\nfi", "matching `\"'");
}

test "what bash refuses and the scanner does not (the gaps; gaps of a farm with no bash)" {
    try std.testing.expect(try syntaxOk("if true; then fi"));
    try std.testing.expect(try syntaxOk("echo a &&"));
    try std.testing.expect(try syntaxOk("echo a |"));
    try std.testing.expect(try syntaxOk("if true then echo a; fi"));
}

test "kpin-update.yml: job-level contents and pull-requests write, schedule and workflow_dispatch only" {
    const ok =
        \\name: k
        \\on:
        \\  workflow_dispatch:
        \\  schedule:
        \\    - cron: "23 5 * * 1"
        \\permissions:
        \\  contents: read
        \\jobs:
        \\  u:
        \\    runs-on: x
        \\    permissions:
        \\      contents: write
        \\      pull-requests: write
        \\
    ;
    try expectLint("kpin-update.yml", ok, &.{});
    // the same job elsewhere is refused
    try expectLint("ci.yml", ok, &.{ "contents: write is not allowed", "pull-requests: write is not allowed" });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const with_pr = try std.mem.replaceOwned(u8, a, ok, "  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n");
    try c.expectLines("pull_request", try lint(a, "kpin-update.yml", with_pr), &.{"triggers must be exactly schedule and workflow_dispatch, got [\"workflow_dispatch\", \"pull_request\", \"schedule\"]"});
    const with_issues = try std.mem.replaceOwned(u8, a, ok, "      pull-requests: write\n", "      pull-requests: write\n      issues: write\n");
    try c.expectLines("issues", try lint(a, "kpin-update.yml", with_issues), &.{ "issues: write is not allowed", "job u may hold only contents and pull-requests permissions, not [\"issues\"]" });
    // top level stays read-only, and the allowance is for the job's own permissions only
    const top = try std.mem.replaceOwned(u8, a, ok, "permissions:\n  contents: read\n", "permissions:\n  contents: write\n");
    try c.expectLines("top", try lint(a, "kpin-update.yml", top), &.{ "top-level permissions must be read-only", "permissions.contents: write is not allowed" });
}

// ---- advisories.yml: the daily scan reports and never gates --------------------------------

const advisories_path = ".github/workflows/advisories.yml";
const installer_path = "tools/install_osv_scanner.zig";

/// advisories.yml as the repository has it, with `from` replaced by `to` (it must apply), through both the per-file rules and its own.
fn expectAdvisories(from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const text = try tree.read(a, advisories_path);
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the planted change does not apply to advisories.yml: {s} is not in it\n", .{from});
        return error.TestUnexpectedResult;
    }
    const mutated = try std.mem.replaceOwned(u8, a, text, from, to);
    var out = c.Out.init(a);
    try wl.fileProblems(a, "advisories.yml", mutated, &out);
    try wl.advisoriesProblems(a, "advisories.yml", mutated, &out);
    try c.expectLines(from, out.items, want);
}

fn expectInstaller(from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    const text = try tree.read(a, installer_path);
    if (std.mem.indexOf(u8, text, from) == null) {
        std.debug.print("the planted change does not apply to {s}: {s} is not in it\n", .{ installer_path, from });
        return error.TestUnexpectedResult;
    }
    var out = c.Out.init(a);
    try wl.installerProblems(a, try std.mem.replaceOwned(u8, a, text, from, to), &out);
    try c.expectLines(from, out.items, want);
}

test "advisories.yml and its installer, as the repository has them, pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tree = try c.loadTree(a);
    var out = c.Out.init(a);
    const text = try tree.read(a, advisories_path);
    try wl.fileProblems(a, "advisories.yml", text, &out);
    try wl.advisoriesProblems(a, "advisories.yml", text, &out);
    try wl.installerProblems(a, try tree.read(a, installer_path), &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "advisories.yml: never pull_request, push or workflow_call; schedule and workflow_dispatch only" {
    const want: []const []const u8 = &.{"triggers must be exactly schedule and workflow_dispatch"};
    try expectAdvisories("  workflow_dispatch:\n", "  workflow_dispatch:\n  pull_request:\n", want);
    try expectAdvisories("  workflow_dispatch:\n", "  workflow_dispatch:\n  push:\n    branches: [main]\n", want);
    try expectAdvisories("  workflow_dispatch:\n", "  workflow_dispatch:\n  workflow_call:\n", want);
    try expectAdvisories("  schedule:\n    - cron: \"17 4 * * *\"\n", "", want);
}

test "advisories.yml: contents read and issues write on the job, nothing else" {
    try expectAdvisories("      issues: write\n", "      issues: write\n      pull-requests: write\n", &.{ "pull-requests: write is not allowed", "may hold only contents and issues permissions" });
    try expectAdvisories("      issues: write\n", "      issues: write\n      id-token: write\n", &.{ "id-token: write is not allowed", "may hold only contents and issues permissions" });
    try expectAdvisories("      contents: read\n      issues: write\n", "      contents: write\n      issues: write\n", &.{"contents: write is not allowed"});
    try expectAdvisories("permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: read\n  issues: write\n\nconcurrency", &.{ "top-level permissions must be read-only", "permissions.issues: write is not allowed" });
}

test "advisories.yml: the scanner is the pinned, verified release, fetched by nothing else" {
    try expectAdvisories("bin=\"$(zig run tools/install_osv_scanner.zig -- ", "bin=\"$(curl -sL https://example.invalid/osv-scanner -o ", &.{ "fetches a tool with `curl`", "no step runs `zig run tools/install_osv_scanner.zig`" });
    try expectAdvisories("zig run tools/install_osv_scanner.zig", "zig run tools/install_osv_scanner2.zig", &.{"no step runs `zig run tools/install_osv_scanner.zig`"});
    try expectAdvisories("run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"", "run: echo nothing", &.{"no step runs tools/install_zig.sh"});
    try expectAdvisories("          set --\n", "          npm audit --package-lock-only\n          set --\n", &.{"fetches a tool with `npm`"});
}

test "tools/install_osv_scanner.zig: an exact version, a sha256 constant, compared before anything is written" {
    try expectInstaller("const version = \"2.7.0\";", "const version = \"latest\";", &.{"`const version` must be an exact release"});
    try expectInstaller("const sha256_hex = \"160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b\";", "const sha256_hex = \"160c\";", &.{"`const sha256_hex` must be 64 lowercase hex digits"});
    try expectInstaller("/releases/download/v\" ++ version", "/releases/latest/download/v\" ++ version", &.{"the url must be a release download of the pinned version"});
    try expectInstaller("if (!std.mem.eql(u8, &hex, sha256_hex)) die(", "if (std.mem.eql(u8, &hex, \"\")) die(", &.{"the digest of the download is not compared"});
    try expectInstaller("    var digest: [32]u8 = undefined;\n", "    _ = try std.fs.cwd().createFile(\"early\", .{});\n    var digest: [32]u8 = undefined;\n", &.{"written only after the sha256 comparison"});
}

test "advisories.yml: report only, a finding is never a failure" {
    try expectAdvisories("[ \"$rc\" -gt 1 ]", "[ \"$rc\" -gt 0 ]", &.{"the scan step must fail only on"});
    try expectAdvisories("|| echo \"::warning::could not create the Advisories issue\"", "|| true", &.{"`|| true` would hide a scan that could not run"});
    try expectAdvisories("echo \"::warning::could not list issues, so the Advisories issue was not touched (creating one blind could duplicate it)\"", "exit 1", &.{"only the scan step may exit nonzero"});
    try expectAdvisories("    timeout-minutes: 15\n", "    timeout-minutes: 15\n    continue-on-error: true\n", &.{"job scan: continue-on-error is not allowed"});
    try expectAdvisories("      - name: Install Zig 0.12.0 (sha256-pinned)\n", "      - name: Install Zig 0.12.0 (sha256-pinned)\n        continue-on-error: true\n", &.{"continue-on-error is not allowed"});
    try expectAdvisories("cat \"$body\" >> \"$GITHUB_STEP_SUMMARY\"", "cat \"$body\"", &.{"findings must go to the job summary"});
    try expectAdvisories("gh issue create --title Advisories", "gh issue create --title Other", &.{"findings must go to one issue titled Advisories"});
    try expectAdvisories("gh issue close \"$number\"", "gh issue view \"$number\"", &.{"closed when there are no findings"});
}

test "advisories.yml: set +e before the scanner and set -e after it (bash -e would turn findings red)" {
    try expectAdvisories("          set +e\n", "", &.{"`set +e` must come before the scanner call"});
    try expectAdvisories("          set -e\n          if [ \"$rc\"", "          if [ \"$rc\"", &.{"`set -e` must come back after the scanner call"});
}

test "advisories.yml: GH_TOKEN only on the report step, never at job or workflow level" {
    try expectAdvisories("      GH_REPO: ${{ github.repository }}\n", "      GH_REPO: ${{ github.repository }}\n      GH_TOKEN: ${{ github.token }}\n", &.{"GH_TOKEN must not be set at job level"});
    try expectAdvisories("name: advisories\n", "name: advisories\nenv:\n  GH_TOKEN: ${{ github.token }}\n", &.{"GH_TOKEN must not be set at workflow level"});
    try expectAdvisories("        env:\n          GH_TOKEN: ${{ github.token }}\n", "", &.{"must set GH_TOKEN in its own env"});
    try expectAdvisories("      - name: Install Zig 0.12.0 (sha256-pinned)\n", "      - name: Install Zig 0.12.0 (sha256-pinned)\n        env:\n          GH_TOKEN: ${{ github.token }}\n", &.{"GH_TOKEN belongs on the step that runs `gh issue` alone"});
}

test "advisories.yml: a failed issue list never creates an issue" {
    try expectAdvisories("if [ \"$listed\" = 1 ]; then", "if true; then", &.{"must sit inside `if [ \"$listed\" = 1 ]; then`"});
    try expectAdvisories("            listed=1\n", "", &.{"`listed=0` then `listed=1`"});
}

test "no other workflow may call advisories.yml" {
    try expectLint("ci.yml", head ++ "jobs:\n  j:\n    uses: ./.github/workflows/advisories.yml\n", &.{"calls ./.github/workflows/advisories.yml: the advisory scan must never run as part of another workflow"});
}
