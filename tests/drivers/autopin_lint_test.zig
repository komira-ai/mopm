//! //:autopin_workflows: the lint of the Dependabot autopin workflows (tests/drivers/autopin_lint.zig), run by Buck2 over the
//! repository's workflows, and shown able to fail: every rule has a real-file check (the three files and the rest of the
//! workflows pass) and a mutant planted in the text of the real files, which must be flagged with its message and by nothing else.
//! A mutant is a text edit anchored on text the real file holds; an edit that does not apply fails the test (so a rewritten
//! workflow cannot leave a mutant that tests nothing).

const std = @import("std");
const c = @import("lint_common.zig");
const ap = @import("autopin_lint.zig");
const Allocator = std.mem.Allocator;

const compute = "autopin-compute.yml";
const commit = "autopin-commit.yml";
const verify = "pin-verify.yml";

// ---- the repository, with edits ---------------------------------------------------------------

const Edit = struct { file: []const u8, from: []const u8, to: []const u8 };

const Repo = struct {
    tree: c.Tree,
    names: []const []const u8,
    edits: []const Edit = &.{},
    /// A workflow the repository does not have.
    extra_name: []const u8 = "",
    extra_text: []const u8 = "",

    pub fn read(self: Repo, a: Allocator, name: []const u8) ![]u8 {
        if (self.extra_name.len != 0 and std.mem.eql(u8, name, self.extra_name)) return a.dupe(u8, self.extra_text);
        var text = try self.tree.read(a, try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name}));
        for (self.edits) |e| {
            if (!std.mem.eql(u8, name, e.file)) continue;
            const at = std.mem.indexOf(u8, text, e.from) orelse {
                std.debug.print("the planted change does not apply to {s}: `{s}` is not in it\n", .{ name, e.from });
                return error.TestUnexpectedResult;
            };
            text = try std.mem.concat(a, u8, &.{ text[0..at], e.to, text[at + e.from.len ..] });
        }
        return text;
    }
};

fn loadRepo(a: Allocator) !Repo {
    const tree = try c.loadTree(a);
    var names = std.ArrayList([]const u8).init(a);
    for (try c.workflowFiles(a, tree)) |f| try names.append(c.basename(f));
    return .{ .tree = tree, .names = names.items };
}

fn problems(a: Allocator, repo: Repo) ![]const []const u8 {
    var out = c.Out.init(a);
    try ap.repoProblems(a, repo, repo.names, &out);
    return out.items;
}

fn expectEdits(what: []const u8, edits: []const Edit, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repo = try loadRepo(a);
    repo.edits = edits;
    try c.expectLines(what, try problems(a, repo), want);
}

/// One edit to one workflow of the repository.
fn expectRepo(file: []const u8, from: []const u8, to: []const u8, want: []const []const u8) !void {
    try expectEdits(file, &.{.{ .file = file, .from = from, .to = to }}, want);
}

/// A workflow added to the repository.
fn expectExtra(name: []const u8, text: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repo = try loadRepo(a);
    var names = std.ArrayList([]const u8).init(a);
    try names.appendSlice(repo.names);
    try names.append(name);
    repo.names = names.items;
    repo.extra_name = name;
    repo.extra_text = text;
    try c.expectLines(name, try problems(a, repo), want);
}

// ---- the real files ---------------------------------------------------------------------------------

test "every workflow of the repository passes the autopin rules, and the three files are there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try loadRepo(a);
    try std.testing.expect(repo.names.len >= 12);
    var out = c.Out.init(a);
    try ap.treeProblems(a, repo.tree.files, &out);
    try ap.repoProblems(a, repo, repo.names, &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "the gates have the conjuncts the design names" {
    try std.testing.expectEqual(@as(usize, 5), ap.compute_gate.len);
    try std.testing.expectEqual(@as(usize, 7), ap.commit_gate.len);
}

test "the pinned tool is a real release: a literal version and 64 hex digits, the same in the three files" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try loadRepo(a);
    for ([_][]const u8{ compute, commit, verify }) |f| {
        const text = try repo.read(a, f);
        const v = try literalAfter(text, "BUILDRULES_VERSION: \"");
        const s = try literalAfter(text, "BUILDRULES_SHA256: \"");
        try std.testing.expect(!std.mem.eql(u8, v, "0.0.0"));
        try std.testing.expectEqual(@as(usize, 64), s.len);
        try std.testing.expect(!std.mem.allEqual(u8, s, '0'));
    }
}

fn literalAfter(text: []const u8, key: []const u8) ![]const u8 {
    const at = std.mem.indexOf(u8, text, key) orelse return error.TestUnexpectedResult;
    const rest = text[at + key.len ..];
    return rest[0 .. std.mem.indexOfScalar(u8, rest, '"') orelse return error.TestUnexpectedResult];
}

// ---- autopin-compute.yml ----------------------------------------------------------------------------------

test "compute: each conjunct of the gate goes red when dropped (the actor one is the loop test)" {
    for (ap.compute_gate, 0..) |g, i| {
        const last = i == ap.compute_gate.len - 1;
        const from = if (last) try std.fmt.allocPrint(std.testing.allocator, " && {s}", .{g}) else try std.fmt.allocPrint(std.testing.allocator, "{s} && ", .{g});
        defer std.testing.allocator.free(from);
        const want = try std.fmt.allocPrint(std.testing.allocator, "the gate lacks `{s}`", .{g});
        defer std.testing.allocator.free(want);
        try expectRepo(compute, from, "", &.{want});
    }
}

test "compute: the gate is at job level, and a clause that lets another run through is refused" {
    // Gate moved from the job to the first step: the job has no `if:`.
    try expectEdits("moved", &.{
        .{ .file = compute, .from = "    if: ${{ github.event.pull_request.user.login", .to = "    xif: ${{ github.event.pull_request.user.login" },
        .{ .file = compute, .from = "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", .to = "      - if: ${{ github.actor == 'dependabot[bot]' }}\n        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n" },
    }, &.{"job compute has no job-level `if:`"});
    try expectRepo(compute, "github.event.pull_request.head.repo.full_name == github.repository }}", "github.event.pull_request.head.repo.full_name == github.repository || true }}", &.{ "the gate must be a conjunction", "the gate lacks `github.event.pull_request.head.repo.full_name == github.repository`", "the gate has the extra clause `github.event.pull_request.head.repo.full_name == github.repository || true`" });
    try expectRepo(compute, " && github.actor == 'dependabot[bot]'", " && github.actor != 'komira-autopin[bot]' && github.actor == 'dependabot[bot]'", &.{"the gate has the extra clause `github.actor != 'komira-autopin[bot]'`"});
}

test "compute: trigger, permissions, no secret, no environment, no cache, nothing that fails quietly" {
    try expectRepo(compute, "  pull_request:\n    types:", "  pull_request_" ++ "target:\n    types:", &.{ "the trigger must be exactly pull_request", "pull_request must have exactly `types" });
    try expectRepo(compute, "      - reopened\n", "      - reopened\n      - labeled\n", &.{"pull_request must have exactly `types"});
    try expectRepo(compute, "permissions:\n  contents: read\n\njobs:", "permissions:\n  contents: write\n\njobs:", &.{ "the top-level permissions must be exactly `contents: read`", "a pull_request workflow's top-level permissions must be exactly" });
    try expectRepo(compute, "    permissions:\n      contents: read\n    steps:", "    permissions:\n      contents: write\n    steps:", &.{"permissions must be exactly `contents: read`"});
    try expectRepo(compute, "          retention-days: 1\n", "          retention-days: 1\n          token: ${{ secrets.GITHUB_TOKEN }}\n", &.{ "no secrets (this job runs for a pull request)", "a pull_request workflow must not reference secrets" });
    try expectRepo(compute, "    runs-on: ubuntu-24.04\n", "    runs-on: ubuntu-24.04\n    environment: autopin\n", &.{ "an environment is for autopin-commit.yml alone", "a pull_request workflow must not declare an environment" });
    try expectRepo(compute, "permissions:\n      contents: read\n    steps:", "permissions:\n      contents: read\n      id-token: write\n    steps:", &.{ "no id-token", "permissions must be exactly `contents: read`", "id-token write on a pull_request workflow is for farm.yml alone" });
    try expectRepo(compute, "      - name: Regenerate", "      - uses: actions/cache@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Regenerate", &.{"no cache and no setup-* action"});
    try expectRepo(compute, "      - name: Regenerate", "      - uses: actions/setup-node@949feb2413d6458794dcd2491c4babbbce0c15c1\n      - name: Regenerate", &.{"no cache and no setup-* action"});
    try expectRepo(compute, "          overwrite: false\n", "          overwrite: false\n        continue-on-error: true\n", &.{"no continue-on-error"});
    try expectRepo(compute, "    timeout-minutes: 15\n", "    timeout-minutes: 60\n", &.{"needs `timeout-minutes: 15`"});
    try expectRepo(compute, "name: autopin-compute\n", "name: autopin-compute-2\n", &.{"the workflow's name must be autopin-compute"});
}

test "compute: the checkout is the pull request's head, through with:, and keeps no credential" {
    try expectRepo(compute, "          ref: ${{ github.event.pull_request.head.sha }}\n", "", &.{"the checkout's `with: ref` must be"});
    try expectRepo(compute, "          ref: ${{ github.event.pull_request.head.sha }}\n", "          ref: ${{ github.event.pull_request.head.ref }}\n", &.{"the checkout's `with: ref` must be"});
    try expectRepo(compute, "          persist-credentials: false\n", "", &.{"must set `persist-credentials: false`"});
    try expectRepo(compute, "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1", "actions/checkout@v4", &.{"the first step must be actions/checkout pinned by full SHA"});
}

test "compute: the tool is fetched and checked, never built; run scripts read no event data" {
    try expectRepo(compute, "          echo \"${BUILDRULES_SHA256}  $RUNNER_TEMP/$name.tar.gz\" | sha256sum -c -\n", "", &.{"the tool is fetched without `sha256sum -c`"});
    try expectRepo(compute,
        \\          echo "${BUILDRULES_SHA256}  $RUNNER_TEMP/$name.tar.gz" | sha256sum -c -
        \\          mkdir "$RUNNER_TEMP/br"
        \\          tar -xzf "$RUNNER_TEMP/$name.tar.gz" -C "$RUNNER_TEMP/br" --strip-components=1
        \\
    ,
        \\          mkdir "$RUNNER_TEMP/br"
        \\          tar -xzf "$RUNNER_TEMP/$name.tar.gz" -C "$RUNNER_TEMP/br" --strip-components=1
        \\          echo "${BUILDRULES_SHA256}  $RUNNER_TEMP/$name.tar.gz" | sha256sum -c -
        \\
    , &.{"the tool is unpacked before `sha256sum -c`"});
    try expectRepo(compute, "https://github.com/komira-ai/buildrules/releases/download/", "https://github.com/evil/buildrules/releases/download/", &.{"the download must be"});
    try expectRepo(compute, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          cargo build\n", &.{"the tool is fetched, never built (`cargo`)"});
    try expectRepo(compute, "BUILDRULES_VERSION: \"", "BUILDRULES_VERSION: \"v", &.{ "BUILDRULES_VERSION must be a literal X.Y.Z", "autopin-commit.yml: the tool version", "pin-verify.yml: the tool version" });
    try expectRepo(compute, "BUILDRULES_SHA256: \"", "BUILDRULES_SHA256: \"0", &.{ "BUILDRULES_SHA256 must be a literal of 64 lowercase hex digits", "autopin-commit.yml: the tool sha256 differs", "pin-verify.yml: the tool sha256 differs" });
    try expectRepo(compute, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          npm ci\n", &.{"a run script uses one of"});
    try expectRepo(compute, "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n", "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n          buck2 build //:x\n", &.{"a run script uses one of"});
    try expectRepo(compute, "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n", "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n          node build.js\n", &.{"a run script uses one of"});
    try expectRepo(compute, "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n", "      - name: Regenerate the pin tables the lockfiles call for\n        run: |\n          npx tsc\n", &.{"a run script uses one of"});
    try expectRepo(compute, "--out \"$RUNNER_TEMP/autopin-out\"", "--out \"$RUNNER_TEMP/autopin-out\" --note github.event.pull_request.title", &.{"reads github.event or github.head_ref"});
    try expectRepo(compute, "--out \"$RUNNER_TEMP/autopin-out\"", "--out \"$RUNNER_TEMP/autopin-out\" --note github.head_ref", &.{"reads github.event or github.head_ref"});
    try expectRepo(compute, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          echo x >> \"$GITHUB_ENV\"\n", &.{"writes GITHUB_ENV"});
    try expectRepo(compute, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          echo x >> \"$GITHUB_OUTPUT\"\n", &.{"writes GITHUB_OUTPUT"});
}

test "compute: the artifact is named by run and attempt, never overwritten, an empty upload is an error" {
    try expectRepo(compute, "autopin-${{ github.run_id }}-${{ github.run_attempt }}", "autopin-${{ github.run_id }}", &.{"the artifact's name must be"});
    try expectRepo(compute, "autopin-${{ github.run_id }}-${{ github.run_attempt }}", "autopin-${{ github.event.pull_request.number }}", &.{"the artifact's name must be"});
    try expectRepo(compute, "          overwrite: false\n", "          overwrite: true\n", &.{"with `overwrite: false`"});
    try expectRepo(compute, "          overwrite: false\n", "", &.{"with `overwrite: false`"});
    try expectRepo(compute, "          if-no-files-found: error\n", "          if-no-files-found: ignore\n", &.{"needs `if-no-files-found: error`"});
    try expectRepo(compute, "actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9", "actions/upload-artifact@v7", &.{"upload-artifact must be pinned by full SHA"});
    try expectRepo(compute, "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        with:\n          name: autopin-${{ github.run_id }}-${{ github.run_attempt }}\n          path: ${{ runner.temp }}/autopin-out\n          if-no-files-found: error\n          retention-days: 1\n          overwrite: false\n", "", &.{"job compute uploads no artifact"});
    try expectRepo(compute, "autopin compute --event", "autopin check --event", &.{"no step runs `buildrules autopin compute`"});
}

// ---- autopin-commit.yml ------------------------------------------------------------------------------------

test "commit: each conjunct of the job-level gate goes red when dropped" {
    for (ap.commit_gate, 0..) |g, i| {
        const last = i == ap.commit_gate.len - 1;
        const from = if (last) try std.fmt.allocPrint(std.testing.allocator, " && {s}", .{g}) else try std.fmt.allocPrint(std.testing.allocator, "{s} && ", .{g});
        defer std.testing.allocator.free(from);
        const want = try std.fmt.allocPrint(std.testing.allocator, "the gate lacks `{s}`", .{g});
        defer std.testing.allocator.free(want);
        try expectRepo(commit, from, "", &.{want});
    }
}

test "commit: the gate is at job level, ahead of the environment" {
    try expectEdits("moved", &.{
        .{ .file = commit, .from = "    if: ${{ github.event.workflow_run.conclusion", .to = "    xif: ${{ github.event.workflow_run.conclusion" },
        .{ .file = commit, .from = "      - name: Fetch the buildrules release", .to = "      - if: ${{ github.event.workflow_run.conclusion == 'success' }}\n        name: Fetch the buildrules release" },
    }, &.{"job commit has no job-level `if:`"});
    try expectRepo(commit, "github.event.workflow_run.triggering_actor.login == 'dependabot[bot]' }}", "github.event.workflow_run.triggering_actor.login == 'dependabot[bot]' || true }}", &.{ "the gate must be a conjunction", "the gate lacks `github.event.workflow_run.triggering_actor.login == 'dependabot[bot]'`", "the gate has the extra clause" });
    try expectRepo(commit, "    environment: autopin\n", "", &.{"must declare `environment: autopin`"});
    try expectRepo(commit, "    environment: autopin\n", "    environment: release\n", &.{"must declare `environment: autopin`"});
}

test "commit: the trigger is the end of the compute workflow, nothing by default, no write but the App's" {
    try expectRepo(commit, "      - completed\n", "      - requested\n", &.{"workflow_run must be exactly"});
    try expectRepo(commit, "      - autopin-compute\n", "      - lint\n", &.{"workflow_run must be exactly"});
    try expectRepo(commit, "  workflow_run:\n", "  workflow_dispatch:\n  workflow_run:\n", &.{ "the trigger must be exactly workflow_run" });
    try expectRepo(commit, "permissions:\n  contents: none\n", "permissions:\n  contents: write\n", &.{"the top-level permissions must grant nothing"});
    try expectRepo(commit, "      pull-requests: read\n", "      pull-requests: write\n", &.{"permissions must be exactly actions, contents and pull-requests, all read"});
    try expectRepo(commit, "      pull-requests: read\n", "      pull-requests: read\n      id-token: write\n", &.{ "permissions must be exactly actions", "no id-token" });
    try expectRepo(commit, "    timeout-minutes: 15\n", "", &.{"needs `timeout-minutes: 15`"});
    try expectRepo(commit, "        id: check\n", "        id: check\n        continue-on-error: true\n", &.{"no continue-on-error"});
}

test "commit: one commit at a time per pull request, and the branch name never reaches a script" {
    try expectRepo(commit, "group: autopin-commit-${{ github.event.workflow_run.head_branch }}", "group: autopin-commit", &.{ "concurrency must be", "head_branch may appear only" });
    try expectRepo(commit, "cancel-in-progress: false", "cancel-in-progress: true", &.{"concurrency must be"});
    try expectRepo(commit, "--app-login \"komira-autopin[bot]\"", "--app-login \"komira-autopin[bot]\" --note head_branch", &.{"head_branch may appear only"});
    try expectRepo(commit, "--app-login \"komira-autopin[bot]\"", "--app-login \"komira-autopin[bot]\" --note github.event.workflow_run.head_branch", &.{ "reads github.event or github.head_ref", "head_branch may appear only" });
}

test "commit: no checkout, no code from the pull request, nothing but the tool touches the artifact" {
    try expectRepo(commit, "    steps:\n      - name: Fetch", "    steps:\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - name: Fetch", &.{"no checkout and no local action"});
    try expectRepo(commit, "    steps:\n      - name: Fetch", "    steps:\n      - uses: ./.github/actions/x\n      - name: Fetch", &.{"no checkout and no local action"});
    try expectRepo(commit, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          git push origin HEAD\n", &.{"a run script uses one of"});
    try expectRepo(commit, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          unzip x.zip\n", &.{"a run script uses one of"});
    try expectRepo(commit, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          jq . x\n", &.{"a run script uses one of"});
    try expectRepo(commit, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          gh api x\n", &.{"a run script uses one of"});
}

test "commit: the App token is minted after the check, for this repository, contents write only, and used by the push alone" {
    const mint =
        \\      - name: Mint the installation token of the autopin App, for this repository only, contents write
        \\        id: mint
        \\        if: ${{ steps.check.outputs.has_change == 'true' }}
        \\        uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0
        \\        with:
        \\          app-id: ${{ vars.AUTOPIN_APP_ID }}
        \\          private-key: ${{ secrets.AUTOPIN_APP_PRIVATE_KEY }}
        \\          owner: ${{ github.repository_owner }}
        \\          repositories: ${{ github.event.repository.name }}
        \\          permission-contents: write
        \\
    ;
    try expectEdits("mint first", &.{
        .{ .file = commit, .from = mint, .to = "" },
        .{ .file = commit, .from = "    steps:\n", .to = "    steps:\n" ++ mint },
    }, &.{"the App token is minted before `commit-check`"});
    try expectRepo(commit, mint, mint ++ mint, &.{ "the App token is minted by exactly one step, found 2", "the key is named by the mint step alone" });
    try expectRepo(commit, "          permission-contents: write\n", "          permission-contents: write\n          permission-" ++ "pull-requests: write\n", &.{"the token is minted with contents write only, not permission-pull-requests"});
    try expectRepo(commit, "          permission-contents: write\n", "          permission-contents: read\n", &.{"the token is minted with `permission-contents: write`"});
    try expectRepo(commit, "          permission-contents: write\n", "", &.{"the token is minted with `permission-contents: write`"});
    try expectRepo(commit, "repositories: ${{ github.event.repository.name }}", "repositories: other", &.{"the token is for this repository alone"});
    try expectRepo(commit, "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@v3", &.{"the mint step must be pinned by full SHA"});
    try expectRepo(commit, "        id: mint\n", "", &.{ "the mint step needs an `id:`", "commit-push holds the App token" });
    try expectRepo(commit, "        if: ${{ steps.check.outputs.has_change == 'true' }}\n        uses: actions/create-github-app-token", "        uses: actions/create-github-app-token", &.{"the mint step runs only `if:"});
    try expectRepo(commit, "        if: ${{ steps.check.outputs.has_change == 'true' }}\n        env:\n          GH_TOKEN: ${{ steps.mint.outputs.token }}", "        env:\n          GH_TOKEN: ${{ steps.mint.outputs.token }}", &.{"the commit-push step runs only `if:"});
    try expectRepo(commit, "          GH_TOKEN: ${{ github.token }}", "          GH_TOKEN: ${{ steps.mint.outputs.token }}", &.{"commit-check holds the default token alone"});
    try expectRepo(commit, "          GH_TOKEN: ${{ steps.mint.outputs.token }}", "          GH_TOKEN: ${{ github.token }}", &.{"commit-push holds the App token"});
    try expectRepo(commit, "    permissions:\n      actions: read", "    env:\n      GH_TOKEN: ${{ github.token }}\n    permissions:\n      actions: read", &.{"GH_TOKEN is set on a step alone"});
    try expectRepo(commit, "private-key: ${{ secrets.AUTOPIN_APP_PRIVATE_KEY }}", "private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", &.{"the mint step reads the key as"});
    try expectRepo(commit, "          AUTOPIN_APP_ID: ${{ vars.AUTOPIN_APP_ID }}\n", "          AUTOPIN_APP_ID: ${{ vars.AUTOPIN_APP_ID }}\n          EXTRA: ${{ secrets.OTHER }}\n", &.{"the key is named by the mint step alone"});
    try expectRepo(commit, "        id: check\n", "", &.{ "the commit-check step needs an `id:`", "the mint step runs only", "the commit-push step runs only" });
    try expectRepo(commit, "buildrules\" autopin commit-check", "buildrules\" autopin commit-x", &.{"no step runs `buildrules autopin commit-check`"});
    try expectRepo(commit, "buildrules\" autopin commit-push", "buildrules\" autopin commit-y", &.{"no step runs `buildrules autopin commit-push`"});
}

test "commit: the environment, the key and the id belong to this file alone" {
    const other_head =
        \\name: other
        \\on:
        \\  workflow_dispatch:
        \\permissions:
        \\  contents: read
        \\jobs:
        \\  j:
        \\    runs-on: ubuntu-24.04
        \\
    ;
    try expectExtra("other.yml", other_head ++ "    environment: autopin\n", &.{"the environment `autopin` is autopin-commit.yml's alone"});
    try expectExtra("other.yml", other_head ++ "    env:\n      K: ${{ vars.AUTOPIN_APP_ID }}\n", &.{"the autopin App's key and id are named by autopin-commit.yml alone"});
    try expectExtra("other.yml", other_head ++ "    steps:\n      - run: echo AUTOPIN_APP_PRIVATE_KEY\n", &.{"the autopin App's key and id are named by autopin-commit.yml alone"});
}

// ---- pin-verify.yml -------------------------------------------------------------------------------------------

test "pin-verify: every pull request, no condition, no secret, the required context, fails when a table would change" {
    try expectRepo(verify, "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    if: github.actor != 'x'\n", &.{ "has an `if:`", "must not look at the actor" });
    try expectRepo(verify, "      - name: No table would change\n", "      - if: always()\n        name: No table would change\n", &.{"no step condition"});
    try expectRepo(verify, "  pull_request:\n", "  pull_request:\n    paths:\n      - site/**\n", &.{"pull_request has no filter and no types"});
    try expectRepo(verify, "  pull_request:\n", "  pull_request:\n    branches:\n      - main\n", &.{"pull_request has no filter and no types"});
    try expectRepo(verify, "    name: pin-verify\n", "    name: pin verify\n", &.{"the job must be `pin-verify` with `name: pin-verify`"});
    try expectRepo(verify, "  pin-verify:\n", "  verify:\n", &.{"the job must be `pin-verify` with `name: pin-verify`"});
    try expectRepo(verify, "    runs-on: ubuntu-24.04\n", "    runs-on: ubuntu-24.04\n    environment: autopin\n", &.{ "an environment is for autopin-commit.yml alone", "a pull_request workflow must not declare an environment" });
    try expectRepo(verify, "        run: |\n          \"$RUNNER_TEMP/br/buildrules\" autopin compute", "        env:\n          T: ${{ secrets.T }}\n        run: |\n          \"$RUNNER_TEMP/br/buildrules\" autopin compute", &.{ "no secrets (this job runs for a pull request)", "a pull_request workflow must not reference secrets" });
    try expectRepo(verify, "            exit 1\n", "", &.{"no step after the tool fails"});
    try expectRepo(verify, "autopin compute --event", "autopin check --event", &.{ "no step runs `buildrules autopin compute`", "no step after the tool fails" });
    try expectRepo(verify, "permissions:\n  contents: read\n\njobs:", "permissions:\n  contents: write\n\njobs:", &.{ "the top-level permissions must be exactly `contents: read`", "a pull_request workflow's top-level permissions must be exactly" });
    try expectRepo(verify, "        run: |\n          set -eu\n", "        continue-on-error: true\n        run: |\n          set -eu\n", &.{"no continue-on-error"});
    try expectRepo(verify, "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", "      - uses: actions/cache@3d3c42e5aac5ba805825da76410c181273ba90b1\n      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", &.{ "no cache and no setup-* action", "the first step must be actions/checkout pinned by full SHA" });
}

// ---- the tool pin and SETS across the three files ----------------------------------------------------------

/// The 64 digits after `BUILDRULES_SHA256: "` in `text`, and the same with the last digit changed.
fn flipped(a: Allocator, text: []const u8) !Edit {
    const s = try literalAfter(text, "BUILDRULES_SHA256: \"");
    const other = try a.dupe(u8, s);
    other[other.len - 1] = if (s[s.len - 1] == 'a') 'b' else 'a';
    return .{ .file = "", .from = try std.fmt.allocPrint(a, "BUILDRULES_SHA256: \"{s}\"", .{s}), .to = try std.fmt.allocPrint(a, "BUILDRULES_SHA256: \"{s}\"", .{other}) };
}

test "one pinned tool in the three files: a differing sha256 or version in any is red" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const repo = try loadRepo(a);
    // The first file read (compute) is the reference, so a differing compute shows as the other two differing from it.
    var e = try flipped(a, try repo.read(a, compute));
    e.file = compute;
    try expectEdits("compute", &.{e}, &.{ "autopin-commit.yml: the tool sha256 differs from autopin-compute.yml's", "pin-verify.yml: the tool sha256 differs from autopin-compute.yml's" });
    e = try flipped(a, try repo.read(a, commit));
    e.file = commit;
    try expectEdits("commit", &.{e}, &.{"autopin-commit.yml: the tool sha256 differs from autopin-compute.yml's"});
    e = try flipped(a, try repo.read(a, verify));
    e.file = verify;
    try expectEdits("verify", &.{e}, &.{"pin-verify.yml: the tool sha256 differs from autopin-compute.yml's"});
    // The version, in the last file read.
    const v = try literalAfter(try repo.read(a, verify), "BUILDRULES_VERSION: \"");
    try expectRepo(verify, try std.fmt.allocPrint(a, "BUILDRULES_VERSION: \"{s}\"", .{v}), "BUILDRULES_VERSION: \"9.9.9\"", &.{"pin-verify.yml: the tool version 9.9.9 differs from"});
}

test "one SETS list in the four invocations: a directory dropped from any is red" {
    try expectRepo(commit, " --set service/api=buildrules-lock", "", &.{"autopin-commit.yml: a --set list differs from autopin-compute.yml's"});
    try expectRepo(commit, " --set service/api=buildrules-lock\n      - name: Mint", " --set service/api=buildrules-lock --set extra=pins-lock\n      - name: Mint", &.{"autopin-commit.yml: a --set list differs from autopin-compute.yml's"});
    try expectRepo(verify, " --set service/api=buildrules-lock", "", &.{"pin-verify.yml: a --set list differs from autopin-compute.yml's"});
    try expectRepo(compute, " --set site=buildrules-lock", "", &.{ "autopin-commit.yml: a --set list differs from", "autopin-commit.yml: a --set list differs from", "pin-verify.yml: a --set list differs from" });
}

// ---- R1: triggers -----------------------------------------------------------------------------------------------------

const other_pre =
    \\name: other
    \\
;
const other_post =
    \\permissions:
    \\  contents: read
    \\jobs:
    \\  j:
    \\    runs-on: ubuntu-24.04
    \\
;

test "R1: workflow_run in one file, no create/status/check triggers, push only for main or tags" {
    const wr =
        \\on:
        \\  workflow_run:
        \\    workflows:
        \\      - autopin-compute
        \\    types:
        \\      - completed
        \\
    ;
    try expectExtra("other.yml", other_pre ++ wr ++ other_post, &.{"workflow_run is allowed in autopin-commit.yml alone"});
    for ([_][]const u8{ "create", "status", "check_suite", "check_run", "deployment_status" }) |t| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const want = try std.fmt.allocPrint(a, "trigger {s} is not allowed", .{t});
        try expectExtra("other.yml", try std.fmt.allocPrint(a, "{s}on:\n  {s}:\n{s}", .{ other_pre, t, other_post }), &.{want});
    }
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n" ++ other_post, &.{"push without `branches: [main]` or `tags` runs for every branch"});
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    branches:\n      - main\n" ++ other_post, &.{});
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    branches:\n      - main\n    paths-ignore:\n      - docs/**\n" ++ other_post, &.{});
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    tags:\n      - v*\n" ++ other_post, &.{});
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    branches:\n      - main\n      - dev\n" ++ other_post, &.{"push must be limited to branches [main]"});
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    branches-ignore:\n      - main\n" ++ other_post, &.{ "push may carry branches, paths, paths-ignore and tags only, not branches-ignore", "push needs `branches: [main]` or `tags`" });
    try expectExtra("other.yml", other_pre ++ "on:\n  push:\n    paths:\n      - x\n" ++ other_post, &.{"push needs `branches: [main]` or `tags`"});
    // `"on":` quoted is read, so a bad push under it is found; so is `on: push`, which is a push for every branch.
    try expectExtra("other.yml", other_pre ++ "\"on\":\n  push:\n    branches:\n      - dev\n" ++ other_post, &.{"push must be limited to branches [main]"});
    try expectExtra("other.yml", other_pre ++ "'on':\n  push:\n" ++ other_post, &.{"push without `branches: [main]` or `tags`"});
    try expectExtra("other.yml", other_pre ++ "on: push\n" ++ other_post, &.{ "line 2: `on:` must be a block mapping", "push without `branches: [main]` or `tags`" });
    // A real workflow loses its branch filter.
    try expectRepo("ci.yml", "  push:\n    branches: [main]\n", "  push:\n", &.{"push without `branches: [main]` or `tags`"});
    try expectRepo("ci.yml", "  push:\n    branches: [main]\n", "  push:\n    branches: [main, dev]\n", &.{"push must be limited to branches [main]"});
}

// ---- R2, R3, R4: what a pull request can reach ----------------------------------------------------------------------

test "R2: a pull_request workflow reaches no environment, and calls only local workflows that hold none" {
    const pr = "on:\n  pull_request:\n";
    try expectExtra("other.yml", other_pre ++ pr ++ "permissions:\n  contents: read\njobs:\n  j:\n    uses: ./.github/workflows/deploy.yml\n", &.{"other.yml: j -> deploy.yml declares an environment, secrets or an id-token"});
    try expectExtra("other.yml", other_pre ++ pr ++ "permissions:\n  contents: read\njobs:\n  j:\n    uses: ./.github/workflows/promote.yml\n", &.{ "other.yml: j -> promote.yml declares an environment, secrets or an id-token", "other.yml: j -> promote.yml -> deploy.yml declares an environment", "other.yml: j -> promote.yml -> e2e.yml declares an environment" });
    try expectExtra("other.yml", other_pre ++ pr ++ "permissions:\n  contents: read\njobs:\n  j:\n    uses: someone/else/.github/workflows/x.yml@main\n", &.{"a pull_request workflow may call only a local reusable workflow"});
    try expectExtra("other.yml", other_pre ++ pr ++ "permissions:\n  contents: read\njobs:\n  j:\n    uses: ./.github/workflows/lint.yml\n", &.{});
    try expectExtra("other.yml", other_pre ++ pr ++ "permissions:\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-24.04\n    environment: beta\n", &.{"a pull_request workflow must not declare an environment"});
    // The same call from a workflow with no pull_request trigger is promote.yml's business, not this rule's.
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  j:\n    uses: ./.github/workflows/deploy.yml\n", &.{});
}

test "R3: a pull_request workflow holds no secret, a read-only default token, and an id-token only in the farm workflow" {
    try expectRepo("lint.yml", "    timeout-minutes: 15\n", "    timeout-minutes: 15\n    env:\n      T: ${{ secrets.T }}\n", &.{"a pull_request workflow must not reference secrets"});
    try expectRepo("lint.yml", "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: write\n\nconcurrency", &.{"a pull_request workflow's top-level permissions must be exactly `contents: read`"});
    try expectRepo("lint.yml", "permissions:\n  contents: read\n\nconcurrency", "permissions:\n  contents: read\n  issues: read\n\nconcurrency", &.{"a pull_request workflow's top-level permissions must be exactly `contents: read`"});
    try expectRepo("lint.yml", "    permissions:\n      contents: read\n    steps:", "    permissions:\n      contents: read\n      id-token: write\n    steps:", &.{"id-token write on a pull_request workflow is for farm.yml alone"});
    try expectRepo("service-ci.yml", "  group: service-ci-${{ github.ref }}", "  group: service-ci-${{ secrets.X }}", &.{"a pull_request workflow must not reference secrets"});
    try expectExtra("other.yml", other_pre ++ "on:\n  pull_request:\npermissions:\n  contents: read\njobs:\n  j:\n    uses: ./.github/workflows/lint.yml\n    secrets: inherit\n", &.{"a pull_request workflow must not reference secrets"});
}

test "R4: the farm job skips a Dependabot branch before any step" {
    try expectRepo("farm.yml", " && !startsWith(github.head_ref, 'dependabot/')", "", &.{"does not skip a Dependabot branch"});
    try expectRepo("farm.yml", "!startsWith(github.head_ref, 'dependabot/')", "!startsWith(github.head_ref, 'renovate/')", &.{"does not skip a Dependabot branch"});
    try expectRepo("farm.yml", "    if: github.event_name == 'push'", "    xif: github.event_name == 'push'", &.{"does not skip a Dependabot branch"});
}

// ---- M2: what the lints can read; M2b: block style -----------------------------------------------------------------------

test "M2: only .yml files directly under .github/workflows, no composite action, no top-level key the lints do not read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const good = [_][]const u8{ ".github/workflows/ci.yml", ".github/dependabot.yml", "README.md" };
    var out = c.Out.init(a);
    try ap.treeProblems(a, &good, &out);
    try c.expectLines("good", out.items, &.{});
    out = c.Out.init(a);
    try ap.treeProblems(a, &(good ++ [_][]const u8{".github/workflows/twin.yaml"}), &out);
    try c.expectLines("yaml twin", out.items, &.{"twin.yaml: a workflow file must end in .yml"});
    out = c.Out.init(a);
    try ap.treeProblems(a, &(good ++ [_][]const u8{".github/workflows/YML.YML"}), &out);
    try c.expectLines("upper case", out.items, &.{"YML.YML: a workflow file must end in .yml"});
    out = c.Out.init(a);
    try ap.treeProblems(a, &(good ++ [_][]const u8{".github/workflows/sub/x.yml"}), &out);
    try c.expectLines("subdirectory", out.items, &.{"a subdirectory of .github/workflows is not read by the lints"});
    out = c.Out.init(a);
    try ap.treeProblems(a, &(good ++ [_][]const u8{".github/workflows/notes.md"}), &out);
    try c.expectLines("other file", out.items, &.{"notes.md: a workflow file must end in .yml"});
    out = c.Out.init(a);
    try ap.treeProblems(a, &(good ++ [_][]const u8{".github/actions/x/action.yml"}), &out);
    try c.expectLines("composite", out.items, &.{"a composite action is not read by the lints, and none is listed"});

    // `true:` for `on:` (YAML 1.1) hides the triggers: refused by name. The quoted spellings are read as `on`.
    try expectExtra("other.yml", other_pre ++ "true:\n  push:\n" ++ other_post, &.{ "top-level key `true` is not one the lints read", "no `on:`" });
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\nsecrets:\n  x: y\n" ++ other_post, &.{"top-level key `secrets` is not one the lints read"});
    // The reader refuses what it cannot read exactly: anchor, alias, merge key, tag, second document, repeated key, a tab.
    const ok_on = other_pre ++ "on:\n  workflow_dispatch:\n";
    try expectExtra("other.yml", ok_on ++ "x: &a 1\n" ++ other_post, &.{"other.yml: not readable as YAML"});
    try expectExtra("other.yml", ok_on ++ "x: *a\n" ++ other_post, &.{"other.yml: not readable as YAML"});
    try expectExtra("other.yml", ok_on ++ "x: !tag 1\n" ++ other_post, &.{"other.yml: not readable as YAML"});
    // ... and the key position, which the reader takes for text: an anchored, aliased or tagged key, or a merge key, nested anywhere.
    try expectExtra("other.yml", ok_on ++ other_post ++ "    &a env: 1\n", &.{"the key `&a env` is an anchor, an alias, a tag or a merge key"});
    try expectExtra("other.yml", ok_on ++ other_post ++ "    *a: 1\n", &.{"the key `*a` is an anchor"});
    try expectExtra("other.yml", ok_on ++ other_post ++ "    !t env: 1\n", &.{"the key `!t env` is an anchor"});
    try expectExtra("other.yml", ok_on ++ other_post ++ "    <<: x\n", &.{"the key `<<` is an anchor"});
    try expectExtra("other.yml", ok_on ++ "---\n" ++ other_post, &.{"other.yml: not readable as YAML"});
    try expectExtra("other.yml", ok_on ++ "name: again\n" ++ other_post, &.{"other.yml: not readable as YAML"});
    try expectExtra("other.yml", ok_on ++ "\tx: 1\n" ++ other_post, &.{"other.yml: not readable as YAML"});
}

test "M2b: on and permissions are block mappings; a form the readers might split on is refused, naming the line" {
    // At column 0, in every workflow.
    try expectExtra("other.yml", other_pre ++ "on: { push: { branches: [main] } }\n" ++ other_post, &.{"line 2: `on:` must be a block mapping"});
    try expectExtra("other.yml", other_pre ++ "on: [push, pull_request]\n" ++ other_post, &.{ "line 2: `on:` must be a block mapping", "push without `branches: [main]` or `tags`" });
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\npermissions: { contents: read }\njobs:\n  j:\n    runs-on: ubuntu-24.04\n", &.{"line 4: `permissions:` must be a block mapping"});
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\npermissions: read-all\njobs:\n  j:\n    runs-on: ubuntu-24.04\n", &.{"line 4: `permissions:` must be a block mapping"});
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\npermissions: |\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-24.04\n", &.{"line 4: `permissions:` must be a block mapping"});
    try expectExtra("other.yml", other_pre ++ "on:\n  workflow_dispatch:\npermissions: # a comment\n  contents: read\njobs:\n  j:\n    runs-on: ubuntu-24.04\n", &.{});
    // Inside on: and permissions: of the autopin files.
    try expectRepo(compute, "    types:\n      - opened\n      - synchronize\n      - reopened\n", "    types: [opened, synchronize, reopened]\n", &.{"a flow collection or block scalar inside `on:` or `permissions:` is not read"});
    try expectRepo(compute, "    types:\n      - opened\n      - synchronize\n      - reopened\n", "    types:\n      - [opened]\n      - synchronize\n      - reopened\n", &.{ "a flow collection or block scalar inside `on:`", "pull_request must have exactly `types" });
    try expectRepo(compute, "    permissions:\n      contents: read\n    steps:", "    permissions: { contents: read }\n    steps:", &.{"`permissions:` must be a block mapping"});
    try expectRepo(compute, "permissions:\n  contents: read\n\njobs:", "permissions: |\n  contents: read\n\njobs:", &.{ "`permissions:` must be a block mapping", "the top-level permissions must be exactly `contents: read`", "a pull_request workflow's top-level permissions must be exactly" });
    try expectRepo(commit, "permissions:\n  contents: none\n", "permissions: {}\n", &.{"`permissions:` must be a block mapping"});
    // What the YAML reader itself cannot read is refused, and a refusal is a finding, never a pass.
    try expectRepo(compute, "permissions:\n  contents: read\n\njobs:", "permissions:\n  contents: read\n    and more\n\njobs:", &.{"autopin-compute.yml: not readable as YAML"});
    try expectRepo(compute, "permissions:\n  contents: read\n\njobs:", "permissions:\n\tcontents: read\n\njobs:", &.{"autopin-compute.yml: not readable as YAML"});
    try expectRepo(compute, "permissions:\n  contents: read\n\njobs:", "permissions:\n  contents: read\nthis is not yaml\njobs:", &.{"autopin-compute.yml: not readable as YAML"});
}

// ---- no workflow merges or approves a Dependabot pull request --------------------------------------------------------------

test "no workflow merges or approves a Dependabot pull request" {
    const on_post = "on:\n  workflow_dispatch:\npermissions:\n  contents: read\njobs:\n  j:\n";
    // A job that names Dependabot.
    try expectExtra("other.yml", other_pre ++ on_post ++ "    if: github.actor == 'dependabot[bot]'\n    runs-on: ubuntu-24.04\n    steps:\n      - run: gh pr merge --auto \"$N\"\n", &.{ "`pr merge` in a job that handles Dependabot", "`--auto` in a job that handles Dependabot" });
    try expectExtra("other.yml", other_pre ++ on_post ++ "    if: github.actor == 'dependabot[bot]'\n    runs-on: ubuntu-24.04\n    steps:\n      - run: gh pr review --approve \"$N\"\n", &.{ "`pr review` in a job that handles Dependabot", "`approve` in a job that handles Dependabot" });
    try expectExtra("other.yml", other_pre ++ on_post ++ "    if: github.actor == 'dependabot[bot]'\n    runs-on: ubuntu-24.04\n    steps:\n      - uses: hmarr/auto-approve-action@f0939ea97e9205ef24d872e76833fa908a770363\n", &.{"`approve` in a job that handles Dependabot"});
    try expectExtra("other.yml", other_pre ++ on_post ++ "    runs-on: ubuntu-24.04\n    steps:\n      - uses: peter-evans/enable-pull-request-automerge@a660677d5469627102a1c1e11409dd063606628d\n        if: github.event.pull_request.user.login == 'dependabot[bot]'\n", &.{"`automerge` in a job that handles Dependabot"});
    try expectExtra("other.yml", other_pre ++ on_post ++ "    runs-on: ubuntu-24.04\n    steps:\n      - run: gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'\n        env:\n          WHO: dependabot\n", &.{"`automerge` in a job that handles Dependabot"});
    // Jobs that never mention Dependabot may merge (release.yml opens pull requests with auto-merge), and `--author-name` is not `--auto`.
    try expectExtra("other.yml", other_pre ++ on_post ++ "    runs-on: ubuntu-24.04\n    steps:\n      - run: gh pr merge --auto \"$N\" --author-name x\n", &.{});
    // The autopin files hold none of it, with or without the word.
    try expectRepo(compute, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          gh pr merge --auto 1\n", &.{ "`pr merge` in a job", "`--auto` in a job" });
    try expectRepo(commit, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          gh pr review --approve 1\n", &.{ "`pr review` in a job", "`approve` in a job", "a run script uses one of" });
    try expectRepo(verify, "          mkdir \"$RUNNER_TEMP/br\"\n", "          mkdir \"$RUNNER_TEMP/br\"\n          echo auto-merge\n", &.{"`auto-merge` in a job"});
}

// ---- unique names, all three files present ------------------------------------------------------------------------------------

test "workflow names are unique, and the three files are all there" {
    try expectExtra("other.yml", "name: autopin-compute\non:\n  workflow_dispatch:\n" ++ other_post, &.{"other.yml: the workflow name `autopin-compute` is also autopin-compute.yml's"});
    try expectExtra("other.yml", "on:\n  workflow_dispatch:\n" ++ other_post, &.{"other.yml: no `name:`"});
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var repo = try loadRepo(a);
    var names = std.ArrayList([]const u8).init(a);
    for (repo.names) |n| {
        if (!std.mem.eql(u8, n, commit)) try names.append(n);
    }
    repo.names = names.items;
    var out = c.Out.init(a);
    try ap.repoProblems(a, repo, repo.names, &out);
    // The commit workflow is gone: it is reported missing, and the other two lose the SETS and tool comparisons only if they differ.
    try c.expectLines("missing", out.items, &.{"autopin-commit.yml: missing: the Dependabot pin update needs all three"});
}
