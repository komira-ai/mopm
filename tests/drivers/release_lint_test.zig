//! //:release_workflow: the release pipeline's lint rules (tests/drivers/release_lint.zig) over the
//! real .github/workflows/release.yml, release-beta-user.yml, and release-build.yml, and each rule shown able to fail: a
//! copy of the real file with one planted defect must report the matching message.
//!
//! What the rules protect: only `publish` holds `contents: write` (to create the release of an existing tag, with
//! `--verify-tag`), and `tag` creates the tag through a token of the release bot App for this repository alone,
//! both under the exact push-to-main `if:`, so a manual run cannot tag or publish; only `attest` may write the attestation
//! scopes; `attest` needs `beta-user`, which needs `build`, so a red platform leg of the user-level beta stops
//! the release before anything is signed, and `tag` needs `verify`, so a failing attest, signature or verify
//! leaves no orphan tag; `publish` needs `verify`, `verify` needs `build`; the version
//! that is built and tested is the version that is tagged and released; `publish` releases the verified
//! files and nothing else; every platform leg of the user beta is required; and the path filter skips
//! docs and CI only.
//!
//! The last stage, `bump`, writes to komira-internal through an App token: it holds `contents: read` here, is the
//! only job that names the token, pins the action, and nothing needs it (a failed bump un-releases nothing); the
//! mutants at the end of this file plant each way of breaking that.

const std = @import("std");
const c = @import("lint_common.zig");
const rl = @import("release_lint.zig");
const Allocator = std.mem.Allocator;

const release_path = ".github/workflows/release.yml";
const user_path = ".github/workflows/release-beta-user.yml";
const build_path = ".github/workflows/release-build.yml";

fn real(a: Allocator, path: []const u8) ![]u8 {
    const tree = try c.loadTree(a);
    return tree.read(a, path);
}

fn problemsOf(a: Allocator, path: []const u8, text: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    if (std.mem.eql(u8, path, user_path)) {
        try rl.userBetaProblems(a, text, &out);
    } else if (std.mem.eql(u8, path, build_path)) {
        try rl.buildDebProblems(a, text, &out);
    } else try rl.problems(a, text, &out);
    return out.items;
}

test "the real release.yml, release-beta-user.yml, and release-build.yml pass every rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ release_path, user_path, build_path }) |p| {
        const got = try problemsOf(a, p, try real(a, p));
        for (got) |l| std.debug.print("{s}\n", .{l});
        try std.testing.expectEqual(@as(usize, 0), got.len);
    }
}

/// Plants `to` where `from` is in `path` (it must apply, once) and requires a problem containing `needle`.
fn mutantIn(path: []const u8, name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantAfter(path, "", name, from, to, needle);
}

/// Like mutantIn, but `from` is looked for after `anchor` (a job's header); with no anchor it is the LAST
/// occurrence, which is `bump`'s when its token step spells what `tag`'s does (`bump` is the last job), and it
/// must apply at least once. With an anchor it is the first occurrence after it.
fn mutantAfter(path: []const u8, anchor: []const u8, name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a, path);
    const start = if (anchor.len == 0) 0 else (std.mem.indexOf(u8, text, anchor) orelse {
        std.debug.print("mutant '{s}' does not apply: the anchor {s} is not in {s}\n", .{ name, anchor, path });
        return error.TestUnexpectedResult;
    });
    const at = (if (anchor.len == 0) std.mem.lastIndexOf(u8, text, from) else std.mem.indexOfPos(u8, text, start, from)) orelse {
        std.debug.print("mutant '{s}' does not apply: {s} is not in {s}\n", .{ name, from, path });
        return error.TestUnexpectedResult;
    };
    const planted = try std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
    const got = try problemsOf(a, path, planted);
    var found = false;
    for (got) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) found = true;
    }
    std.debug.print("{s} mutant: {s} ({d} problem(s))\n", .{ if (found) "red " else "NOT RED", name, got.len });
    if (!found) {
        for (got) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
}

fn mutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantIn(release_path, name, from, to, needle);
}

/// A mutant inside the `tag` job (the first occurrence after its header).
fn tagMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantAfter(release_path, "\n  tag:\n", name, from, to, needle);
}

fn userMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantIn(user_path, name, from, to, needle);
}

const push_main = "if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}";
const tag_head = "  tag:\n    needs: [plan, build, beta-user, verify]\n    ";
/// The headers of build and beta-user as release.yml spells them, with the `if:` that skips them for a release that is complete.
const not_complete_if = "    if: ${{ needs.plan.outputs.complete != 'true' }}\n";
const build_if_head = "  build:\n    needs: plan\n" ++ not_complete_if;
const user_if_head = "  beta-user:\n    needs: [plan, build]\n" ++ not_complete_if;

test "mutant: publish does not need verify" {
    try mutant("publish without verify", "  publish:\n    needs: [tag, verify]", "  publish:\n    needs: [tag]", "publish must need verify");
}

test "mutant: verify does not need build" {
    try mutant("verify without build", "    needs: [plan, build, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "    needs: [plan, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "verify must need build");
}

test "mutant: tag does not need the user-level beta, or the plan" {
    try mutant("tag without beta-user", tag_head, "  tag:\n    needs: [plan, build]\n    ", "tag must need beta-user");
    try mutant("tag without verify (an orphan tag when attest, sign or verify fails)", tag_head, "  tag:\n    needs: [plan, build, beta-user]\n    ", "tag must need verify");
    try mutant("tag without plan", tag_head, "  tag:\n    needs: [build, beta-user]\n    ", "tag must need plan");
    try mutant("tag without any need", tag_head, "  tag:\n    needs: []\n    ", "tag must need beta-user");
}

test "mutant: the user-level beta does not gate on the build, or the plan on the lint" {
    try mutant("beta-user without build", "  beta-user:\n    needs: [plan, build]", "  beta-user:\n    needs: [plan]", "beta-user must need build");
    try mutant("plan without lint", "    needs: [beta, lint]", "    needs: [beta]", "plan must need lint");
    try mutant("plan without beta", "    needs: [beta, lint]", "    needs: [lint]", "plan must need beta");
}

test "mutant: the stages call the right workflows" {
    try mutant("beta-user calls the build", "    uses: ./.github/workflows/release-beta-user.yml", "    uses: ./.github/workflows/release-build.yml", "beta-user must call ./.github/workflows/release-beta-user.yml");
    try mutant("lint calls ci", "    uses: ./.github/workflows/lint.yml", "    uses: ./.github/workflows/ci.yml", "lint must call ./.github/workflows/lint.yml");
    try mutant("beta calls lint", "    uses: ./.github/workflows/ci.yml", "    uses: ./.github/workflows/lint.yml", "beta must call ./.github/workflows/ci.yml");
}

test "mutant: contents: write in verify" {
    try mutant("verify writes contents", "      contents: read\n      attestations: read", "      contents: write\n      attestations: read", "verify: contents: write is not allowed here");
}

test "mutant: tag runs on a manual run" {
    try mutant("tag on dispatch", tag_head ++ push_main, "  tag:\n    needs: [plan, build, beta-user, verify]\n    if: ${{ github.event_name == 'push' || github.event_name == 'workflow_dispatch' }}", "tag must run only under if");
    try mutant("tag with no if", tag_head ++ push_main ++ "\n", "  tag:\n    needs: [plan, build, beta-user, verify]\n", "tag must run only under if");
}

test "mutant: publish runs on a manual run, or has no if" {
    try mutant("publish with no if", "    needs: [tag, verify]\n    " ++ push_main ++ "\n", "    needs: [tag, verify]\n", "publish must run only under if");
    try mutant("publish on any branch", "    needs: [tag, verify]\n    " ++ push_main, "    needs: [tag, verify]\n    if: ${{ github.event_name == 'push' }}", "publish must run only under if");
}

test "mutant: publish behind an approval, or with more scopes than contents" {
    try mutant("publish with an environment", "    needs: [tag, verify]\n    " ++ push_main ++ "\n", "    needs: [tag, verify]\n    " ++ push_main ++ "\n    environment: prod\n", "publish must not use an environment");
    try mutant("publish with id-token", "    timeout-minutes: 15\n    permissions:\n      contents: write\n", "    timeout-minutes: 15\n    permissions:\n      contents: write\n      id-token: write\n", "publish: id-token: write is not allowed here");
    try mutant("publish without contents write", "    timeout-minutes: 15\n    permissions:\n      contents: write\n", "    timeout-minutes: 15\n    permissions:\n      contents: read\n", "publish: needs contents: write");
}

test "mutant: attest loses or gains a scope" {
    try mutant("attest without attestations", "      id-token: write\n      attestations: write\n", "      id-token: write\n", "attest: needs attestations: write");
    try mutantAfter(release_path, "\n  attest:\n", "attest with contents write", "    permissions:\n      contents: read\n      id-token: write", "    permissions:\n      contents: write\n      id-token: write", "attest: contents: write is not allowed here");
    try mutant("the user-level beta with a scope", user_if_head ++ "    permissions:\n      contents: read\n", user_if_head ++ "    permissions:\n      contents: read\n      id-token: write\n", "beta-user: id-token: write is not allowed here");
}

test "mutant: a bare write-all, a continue-on-error, an if where none belongs" {
    try mutant("verify with write-all", "    permissions:\n      contents: read\n      attestations: read\n", "    permissions: write-all\n", "grants every scope");
    try mutant("beta continue-on-error", "  beta:\n    permissions:\n      contents: read\n", "  beta:\n    continue-on-error: true\n    permissions:\n      contents: read\n", "beta must not set continue-on-error");
    try mutant("beta-user continue-on-error", "  beta-user:\n    needs: [plan, build]\n", "  beta-user:\n    needs: [plan, build]\n    continue-on-error: true\n", "beta-user must not set continue-on-error");
    try mutant("build with another if", build_if_head, "  build:\n    needs: plan\n    if: ${{ always() }}\n", "build must run only under if:");
    try mutant("beta-user with another if", user_if_head, "  beta-user:\n    needs: [plan, build]\n    if: ${{ github.event_name == 'push' }}\n", "beta-user must run only under if:");
    try mutant("plan with an if", "  plan:\n    needs: [beta, lint]\n", "  plan:\n    needs: [beta, lint]\n    if: ${{ github.event_name == 'workflow_dispatch' }}\n", "plan must not have an if:");
}

test "mutant: the order of the stages" {
    try mutant("build without plan", "  build:\n    needs: plan", "  build:\n    needs: beta", "build must need plan");
    try mutant("attest without build", "  attest:\n    needs: [plan, build, beta-user]", "  attest:\n    needs: [plan, beta-user]", "attest must need build");
    try mutant("attest without beta-user (it would sign untested files)", "  attest:\n    needs: [plan, build, beta-user]", "  attest:\n    needs: [plan, build]", "attest must need beta-user");
}

test "release.yml: a release the plan found complete is not built or tested again, and the stages after the build wait for it" {
    // build and beta-user: that `if:` exactly, so neither runs for a complete release nor is skipped for another reason
    try mutant("build without the if", build_if_head, "  build:\n    needs: plan\n", "build must run only under if:");
    try mutant("beta-user without the if", user_if_head, "  beta-user:\n    needs: [plan, build]\n", "beta-user must run only under if:");
    try mutant("build skipped for an incomplete release", build_if_head, "  build:\n    needs: plan\n    if: ${{ needs.plan.outputs.complete == 'true' }}\n", "build must run only under if:");
    try mutant("beta-user skipped for an incomplete release", user_if_head, "  beta-user:\n    needs: [plan, build]\n    if: ${{ needs.plan.outputs.complete == 'false' }}\n", "beta-user must run only under if:");
    // the plan says whether the release is complete, and is able to find out
    try mutant("plan does not output complete", "      complete: ${{ steps.plan.outputs.complete }}\n", "", "plan must output complete");
    try mutant("plan is not given the directory to hold the release in", " --held-dir \"$RUNNER_TEMP/held\"", "", "plan must pass --held-dir");
    // nothing after the build can run without it: each stage waits for the one before, and none has an if: that could run it anyway
    try mutant("attest without build", "  attest:\n    needs: [plan, build, beta-user]", "  attest:\n    needs: [plan, beta-user]", "attest must need build");
    try mutant("verify without attest", "  verify:\n    needs: [plan, build, attest]", "  verify:\n    needs: [plan, build]", "verify must need attest");
    try mutantAfter(release_path, "\n  publish:\n", "publish with an if of its own", push_main, "if: ${{ always() }}", "publish must run only under if:");
}

test "mutant: the data flow (the tested version is the tagged and released version)" {
    // The build is given another version than the plan's, so the tested bytes would not be the released ones.
    try mutant("build given the tag's version", "    uses: ./.github/workflows/release-build.yml\n    with:\n      version: ${{ needs.plan.outputs.version }}", "    uses: ./.github/workflows/release-build.yml\n    with:\n      version: ${{ needs.tag.outputs.version }}", "build must be given version");
    try mutant("beta-user given a literal version", "    uses: ./.github/workflows/release-beta-user.yml\n    with:\n      version: ${{ needs.plan.outputs.version }}", "    uses: ./.github/workflows/release-beta-user.yml\n    with:\n      version: 0.0.0", "beta-user must be given version");
    try mutant("tag not told the planned version", " --expect-version \"$PLANNED\"", "", "tag must pass --expect-version");
    try mutant("tag at another commit", " tag --sha \"$GITHUB_SHA\"", " tag --sha \"$GITHUB_REF\"", "tag must tag the pushed commit");
    try mutant("tag planned from another job", "          PLANNED: ${{ needs.plan.outputs.version }}", "          PLANNED: 0.0.1", "tag must set PLANNED");
    try mutant("verify with another version", "          VERSION: ${{ needs.plan.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "verify must set VERSION");
    try mutant("plan outputs nothing", "      version: ${{ steps.plan.outputs.version }}", "      other: ${{ steps.plan.outputs.version }}", "plan must output version");
}

test "mutant: publish releases something other than the verified files" {
    try mutantAfter(release_path, "\n  publish:\n", "publish downloads the unverified assets", "          name: verified-assets\n          path: dist\n", "          name: signed-assets\n          path: dist\n", "publish must download exactly the artifacts verified-assets and notes-pin");
    try mutant("publish downloads other notes", "          name: notes-pin\n          path: notes\n", "          name: signed-assets\n          path: notes\n", "publish must download exactly the artifacts verified-assets and notes-pin");
    try mutant("verify downloads a build artifact", "          name: signed-assets\n          path: dist\n      - name: Install Zig 0.12.0 (sha256-pinned)\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n      - uses: sigstore", "          name: release-linux-x86_64\n          path: dist\n      - name: Install Zig 0.12.0 (sha256-pinned)\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n      - uses: sigstore", "verify must download exactly the artifact signed-assets");
}

test "mutant: attest signs an unmerged commit" {
    const guard = "    if: github.ref == 'refs/heads/main'\n";
    // A dispatch from a branch would sign and attest a commit nobody merged, and publish a Sigstore entry for it.
    try mutant("attest with no main guard", guard, "", "attest must run only under if");
    try mutant("attest guarded by the event only", guard, "    if: github.event_name == 'push'\n", "attest must run only under if");
    try mutant("attest guarded on any ref", guard, "    if: github.ref != ''\n", "attest must run only under if");
    try mutant("an if on verify", "  verify:\n    needs: [plan, build, attest]\n", "  verify:\n    needs: [plan, build, attest]\n    if: ${{ always() }}\n", "verify must not have an if:");
}

test "mutant: a dry run's signatures cannot be published or mis-pinned" {
    // verify pins the trigger of the run that signed; a hardcoded `push` would refuse every dry run.
    try mutant("verify without --trigger", " --trigger \"$GITHUB_EVENT_NAME\"", "", "verify must pass --trigger");
    try mutant("verify with a hardcoded push trigger", " --trigger \"$GITHUB_EVENT_NAME\"", " --trigger push", "verify must pass --trigger");
    // publish must never run on a dispatch, whose signatures verify accepted for a dry run.
    try mutant("publish on a dispatch", "    needs: [tag, verify]\n    " ++ push_main, "    needs: [tag, verify]\n    if: ${{ github.event_name == 'push' || github.event_name == 'workflow_dispatch' }}", "publish must run only under if");
}

test "mutant: an artifact attest's release-* download would merge into dist" {
    // 'Re-run all jobs' would download these with the build's artifacts and wedge the run.
    try mutant("attest uploads release-assets", "          name: signed-assets\n          path: |", "          name: release-assets\n          path: |", "attest's download pattern release-* would also match");
    try mutant("verify uploads release-notes", "          name: notes-pin\n          path: notes/", "          name: release-notes\n          path: notes/", "attest's download pattern release-* would also match");
    try mutant("attest uploads another name", "          name: signed-assets\n          path: |", "          name: other\n          path: |", "attest must upload exactly the artifact signed-assets");
}

test "mutant: no signatures" {
    try mutant("attest does not sign", "        run: '\"$RUNNER_TEMP/release\" sign dist'", "        run: '\"$RUNNER_TEMP/release\" check dist'", "attest must sign the files");
    try mutant("verify without cosign", "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n        with:\n          cosign-release: 'v3.0.6'\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Verify", "      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Verify", "verify needs cosign");
}

test "release.yml: each install of cosign names the release the retry reads" {
    // The install in `verify` and the one in `attest`: the action's default, another release, and a renamed input are each refused.
    const step = "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n        with:\n          cosign-release: 'v3.0.6'\n";
    const bare = "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n";
    const needle = "installs cosign without `cosign-release: v3.0.6`";
    try mutantAfter(release_path, "\n  verify:\n", "verify takes the action's default", step, bare, needle);
    try mutantAfter(release_path, "\n  attest:\n", "attest takes the action's default", step, bare, needle);
    try mutantAfter(release_path, "\n  verify:\n", "verify installs another release", "cosign-release: 'v3.0.6'", "cosign-release: 'v3.0.5'", needle);
    try mutantAfter(release_path, "\n  attest:\n", "attest names the input wrongly", "cosign-release: 'v3.0.6'", "cosign-version: 'v3.0.6'", needle);
}

test "mutant: triggers and concurrency" {
    try mutant("a tag trigger", "    branches: [main]\n    # A push", "    branches: [main]\n    tags: [\"v*\"]\n    # A push", "push has the key `tags`");
    try mutant("any branch", "    branches: [main]\n    # A push", "    branches: [main, dev]\n    # A push", "push must be limited to branches [main]");
    try mutant("a pull_request trigger", "  workflow_dispatch:\n\npermissions:", "  workflow_dispatch:\n  pull_request:\n\npermissions:", "not exactly push and workflow_dispatch");
    try mutant("cancelling runs", "  cancel-in-progress: false", "  cancel-in-progress: true", "concurrency must be group");
    // The old group: a manual dry run would share it and displace a pending push release.
    try mutant("one group for dry runs and releases", "  group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}\n", "  group: release\n", "concurrency must be group");
    try mutant("a group per ref", "  group: release-${{ github.event_name == 'push' && 'push' || github.run_id }}\n", "  group: release-${{ github.ref }}\n", "concurrency must be group");
}

test "mutant: the path filter" {
    try mutant("a filter that skips sources", "      - \".github/**\"\n", "      - \".github/**\"\n      - \"src/**\"\n", "paths-ignore skips src/cli/main.zig");
    try mutant("a filter that skips VERSION", "      - \"**.md\"\n", "      - \"**.md\"\n      - \"VERSION\"\n", "paths-ignore skips VERSION");
    try mutant("a filter that releases docs", "      - \"docs/**\"\n", "", "paths-ignore does not skip docs/design/overview.txt");
    try mutant("a filter that releases a CI change", "      - \".github/**\"\n", "", "paths-ignore does not skip .github/workflows/ci.yml");
    try mutant("a filter that releases a markdown change", "      - \"**.md\"\n", "", "paths-ignore does not skip README.md");
    try mutant("a `paths` filter instead", "    paths-ignore:\n", "    paths:\n", "push uses `paths`");
}

test "mutant: a platform leg of the user-level beta is skipped, optional or missing" {
    try userMutant("no macOS leg", "          - { target: macos-arm64, os: macos-14 }\n", "", "lacks the leg macos-arm64 on macos-14");
    try userMutant("no linux arm64 leg", "          - { target: linux-aarch64, os: ubuntu-24.04-arm }\n", "", "lacks the leg linux-aarch64 on ubuntu-24.04-arm");
    try userMutant("no linux x86_64 leg", "          - { target: linux-x86_64, os: ubuntu-24.04 }\n", "", "lacks the leg linux-x86_64 on ubuntu-24.04");
    try userMutant("a leg on another runner", "{ target: macos-arm64, os: macos-14 }", "{ target: macos-arm64, os: macos-15 }", "lacks the leg macos-arm64 on macos-14");
    try userMutant("an extra leg", "          - { target: macos-arm64, os: macos-14 }\n", "          - { target: macos-arm64, os: macos-14 }\n          - { target: linux-riscv64, os: ubuntu-24.04 }\n", "the matrix has 4 legs");
    try userMutant("an excluded leg", "      matrix:\n        include:", "      matrix:\n        exclude:\n          - { target: macos-arm64 }\n        include:", "the matrix has the key exclude");
    try userMutant("legs that may fail", "    timeout-minutes: 90\n", "    timeout-minutes: 90\n    continue-on-error: true\n", "user must not set continue-on-error");
    try userMutant("legs that run only sometimes", "    timeout-minutes: 90\n", "    timeout-minutes: 90\n    if: ${{ github.event_name == 'push' }}\n", "user must not set if");
    try userMutant("a step that skips macOS", "      - name: Install Zig 0.12.0 (sha256-pinned)\n", "      - name: Install Zig 0.12.0 (sha256-pinned)\n        if: ${{ matrix.os != 'macos-14' }}\n", "must not set if");
    try userMutant("a step that may fail", "      - name: Build the user walk (tests/drivers/user_beta.zig)\n", "      - name: Build the user walk (tests/drivers/user_beta.zig)\n        continue-on-error: true\n", "must not set continue-on-error");
    try userMutant("another trigger", "on:\n  workflow_call:", "on:\n  pull_request:\n  workflow_call:", "not exactly workflow_call");
}

test "mutant: the user-level beta tests something other than the candidate, or less than the walk" {
    try userMutant("a fixed artifact", "          name: release-${{ matrix.target }}\n", "          name: release-linux-x86_64\n", "user must download exactly the build's artifact");
    try userMutant("no version check", " --version \"$VERSION\" --tarball", " --tarball", "the walk must be given --version");
    try userMutant("no install path", " --install-sh site/static/install.sh", "", "the walk must be given --install-sh");
    try userMutant("no mojo", " --mojo-env tests/e2e/.pixi/envs/default", "", "the walk must be given --mojo-env");
    try userMutant("no registry", " --fake-registry \"$RUNNER_TEMP/mopm-fake-registry\"", "", "the walk must be given --fake-registry");
    try userMutant("the walk not built", "        run: zig build-exe tests/drivers/user_beta.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/user_beta\"", "        run: zig build-exe tools/release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/user_beta\"", "user must build tests/drivers/user_beta.zig");
    try userMutant("write permission", "permissions:\n  contents: read\n\njobs:\n  user:\n", "permissions:\n  contents: read\n\njobs:\n  user:\n    permissions:\n      contents: write\n", "user holds a permission other than read");
    // The walk must really run, in full, on the candidate, and fail the leg when it fails.
    try userMutant("no pixi (the walk would skip sync and the build against the dependency)", " --pixi pixi --ci'", " --ci'", "the walk must be given --pixi pixi");
    try userMutant("no --ci (a skipped step stays green)", " --pixi pixi --ci'", " --pixi pixi'", "the walk must be given --ci");
    try userMutant("a mopm from PATH instead of the candidate", " \"$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET/mopm\" \"$RUNNER_TEMP/walk\"", " mopm \"$RUNNER_TEMP/walk\"", "first argument must be the candidate binary");
    try userMutant("a binary beside the candidate", "\"$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET/mopm\" \"$RUNNER_TEMP/walk\"", "\"$RUNNER_TEMP/candidate/mopm\" \"$RUNNER_TEMP/walk\"", "first argument must be the candidate binary");
    try userMutant("|| true on the walk", " --pixi pixi --ci'", " --pixi pixi --ci || true'", "must not contain |");
    try userMutant("|| : on the walk", " --pixi pixi --ci'", " --pixi pixi --ci || :'", "must not contain |");
    try userMutant("; true on the walk", " --pixi pixi --ci'", " --pixi pixi --ci; true'", "must not contain ;");
    try userMutant("a tarball that is not the candidate", "--tarball \"$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET.tar.gz\"", "--tarball \"$RUNNER_TEMP/other.tar.gz\"", "the walk must be given --tarball");
    // What passed is what is attested.
    try userMutant("the record names another tarball", "record \"$RUNNER_TEMP/candidate/mopm-$VERSION-$TARGET.tar.gz\" \"$RUNNER_TEMP/tested\"", "record \"$RUNNER_TEMP/candidate/mopm-$VERSION-linux-x86_64.tar.gz\" \"$RUNNER_TEMP/tested\"", "user must run exactly");
    try userMutant("the record is not uploaded under the leg's name", "          name: tested-${{ matrix.target }}\n", "          name: tested\n", "user must upload the record as the artifact tested-");
    try userMutant("the release tool is not built", "      - name: Build the release tool\n        run: zig build-exe tools/release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/release\"\n", "", "user must build tools/release.zig");
}

test "mutant: attest signs files the user beta did not pass" {
    try mutant("attest does not compare with the tested records", "        run: '\"$RUNNER_TEMP/release\" tested dist tested'", "        run: '\"$RUNNER_TEMP/release\" check dist'", "attest must run exactly");
    try mutant("attest does not download the records", "          pattern: tested-*\n", "          pattern: release-*\n", "attest must download the records");
    try mutant("attest checks the records only after writing SHA256SUMS", "        run: '\"$RUNNER_TEMP/release\" tested dist tested'\n      - name: Write SHA256SUMS (exactly the three tarballs and the two .debs) and check it\n        run: '\"$RUNNER_TEMP/release\" sums dist'\n", "        run: '\"$RUNNER_TEMP/release\" sums dist'\n      - name: Write SHA256SUMS (exactly the three tarballs and the two .debs) and check it\n        run: '\"$RUNNER_TEMP/release\" tested dist tested'\n", "attest must check the tested records before it writes SHA256SUMS");
}

test "the glob matcher reads patterns as GitHub does" {
    const t = std.testing;
    try t.expect(rl.globMatch("**.md", "README.md"));
    try t.expect(rl.globMatch("**.md", "spec/a/b.md"));
    try t.expect(!rl.globMatch("**.md", "README.mdx"));
    try t.expect(rl.globMatch("docs/**", "docs/a/b.txt"));
    try t.expect(!rl.globMatch("docs/**", "docsx/a"));
    try t.expect(!rl.globMatch("docs/**", "src/docs/a"));
    try t.expect(rl.globMatch("*.md", "README.md"));
    try t.expect(!rl.globMatch("*.md", "docs/README.md"));
    try t.expect(rl.globMatch(".github/**", ".github/workflows/release.yml"));
    try t.expect(rl.globMatch("VERSION", "VERSION"));
    try t.expect(!rl.globMatch("VERSION", "VERSIONS"));
    try t.expect(!rl.globMatch("", "x"));
}

// ---- bump: the last stage, which writes to komira-internal through the release bot's App token ----

const bump_head = "  bump:\n    needs: [tag, publish]\n    ";
const bump_perms = "    permissions:\n      contents: read\n    steps:\n      - uses: actions/checkout";
const app_use = "        uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510 # v3.3.0\n";

test "mutant: bump does not need publish, or runs on a manual run" {
    try mutant("bump without publish", bump_head ++ push_main, "  bump:\n    needs: [tag]\n    " ++ push_main, "bump must need publish");
    try mutant("bump with no if", bump_head ++ push_main ++ "\n", "  bump:\n    needs: [tag, publish]\n", "bump must run only under if");
    try mutant("bump on any branch", bump_head ++ push_main, bump_head ++ "if: ${{ github.event_name == 'push' }}", "bump must run only under if");
    try mutant("bump on a manual run", bump_head ++ push_main, bump_head ++ "if: ${{ always() }}", "bump must run only under if");
}

test "mutant: bump holds a write scope here, or more than contents" {
    try mutant("bump writes contents", bump_perms, "    permissions:\n      contents: write\n    steps:\n      - uses: actions/checkout", "bump: contents: write is not allowed here");
    try mutant("bump writes pull requests", bump_perms, "    permissions:\n      contents: read\n      pull-requests: write\n    steps:\n      - uses: actions/checkout", "bump: pull-requests: write is not allowed here");
    try mutant("bump reads more than contents", bump_perms, "    permissions:\n      contents: read\n      id-token: read\n    steps:\n      - uses: actions/checkout", "bump: permissions must be exactly contents: read");
    try mutant("bump with no permissions", bump_perms, "    steps:\n      - uses: actions/checkout", "bump: permissions must be exactly contents: read");
    try mutant("bump with write-all", bump_perms, "    permissions: write-all\n    steps:\n      - uses: actions/checkout", "grants every scope");
    try mutant("bump that may fail quietly", bump_head ++ push_main ++ "\n", bump_head ++ push_main ++ "\n    continue-on-error: true\n", "bump must not set continue-on-error");
}

test "mutant: a failed bump must not stop or un-release anything" {
    try mutant("publish needs bump", "  publish:\n    needs: [tag, verify]", "  publish:\n    needs: [tag, verify, bump]", "publish must not need bump");
    try mutant("verify needs bump", "    needs: [plan, build, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "    needs: [plan, build, attest, bump]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "verify must not need bump");
}

test "mutant: another job names the App token" {
    try mutant("publish mints the token", "  publish:\n    needs: [tag, verify]\n    " ++ push_main ++ "\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: write\n    steps:\n", "  publish:\n    needs: [tag, verify]\n    " ++ push_main ++ "\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: write\n    steps:\n      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n", "publish names the release bot's App token");
    try mutant("plan reads the key", "          GH_TOKEN: ${{ github.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" plan", "          GH_TOKEN: ${{ github.token }}\n          KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" plan", "plan names the release bot's App token");
    try mutant("verify reads the app id", "          VERSION: ${{ needs.plan.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "          VERSION: ${{ needs.plan.outputs.version }}\n          ID: ${{ vars.RELEASE_BOT_APP_ID }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "verify names the release bot's App token");
    try mutant("publish takes the token of bump", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "          VERSION: ${{ needs.tag.outputs.version }}\n          T: ${{ steps.app.outputs.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "publish names the release bot's App token");
    try mutant("the workflow's env holds the key", "permissions:\n  contents: read\n\n# One release run", "permissions:\n  contents: read\nenv:\n  K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n\n# One release run", "env names the release bot's App token");
}

test "mutant: the App token step of bump" {
    try mutant("an unpinned action", "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@v3", "bump must use actions/create-github-app-token@<full commit sha>");
    try mutant("a short sha", "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@64ab729", "bump must use actions/create-github-app-token@<full commit sha>");
    try mutant("another action mints the token", app_use, "        uses: someone/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n", "bump must use actions/create-github-app-token@");
    try mutant("no token step", "      - name: Mint the installation token of the release bot, for komira-internal only\n        id: app\n" ++ app_use ++ "        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          owner: komira-ai\n          repositories: komira-internal\n          permission-contents: write\n          permission-pull-requests: write\n", "", "bump must mint the token with exactly one actions/create-github-app-token step, has 0");
    try mutant("the app id from a literal", "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "          app-id: 5395718", "the token step must set app-id");
    try mutant("another key", "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "          private-key: ${{ secrets.OTHER_KEY }}", "the token step must set private-key");
    try mutant("another owner", "          owner: komira-ai\n", "          owner: someone\n", "the token step must set owner");
    try mutant("a token for every repository of the owner", "          repositories: komira-internal\n", "", "the token step must set repositories");
    try mutant("a token for two repositories", "          repositories: komira-internal\n", "          repositories: komira-internal,mopm\n", "the token step must set repositories");
    try mutant("an extra input", "          permission-pull-requests: write\n", "          permission-pull-requests: write\n          permission-issues: write\n", "the token step takes exactly the inputs app-id, private-key, owner, repositories, permission-contents, permission-pull-requests");
    // The token holds only contents and pull-requests write on komira-internal, not every scope the App has.
    try mutant("a token with no pull-requests scope named", "          permission-pull-requests: write\n", "", "the token step must set permission-pull-requests");
    try mutant("a token with no contents scope named", "          permission-contents: write\n", "", "the token step must set permission-contents");
    try mutant("a token with a wider scope", "          permission-contents: write\n", "          permission-contents: admin\n", "the token step must set permission-contents");
    try mutant("no step id", "        id: app\n", "", "the token step must have id: app");
}

test "mutant: the step that runs the tool" {
    try mutant("the token in argv", " --workdir \"$RUNNER_TEMP/bump\"'", " --workdir \"$RUNNER_TEMP/bump\" --token \"$GH_TOKEN\"'", "bump must run exactly");
    try mutant("another submodule", " --submodule mopm ", " --submodule komira ", "bump must run exactly");
    try mutant("another repository", " --internal-repo komira-ai/komira-internal", " --internal-repo komira-ai/komira", "bump must run exactly");
    try mutant("another commit", " --sha \"$GITHUB_SHA\" --internal-repo", " --sha \"$GITHUB_REF\" --internal-repo", "bump must run exactly");
    try mutant("another version", " bump-internal --version \"$VERSION\"", " bump-internal --version 0.0.0", "bump must run exactly");
    try mutant("version from the plan", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n          VERSION: ${{ needs.tag.outputs.version }}", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n          VERSION: ${{ needs.plan.outputs.version }}", "bump must set VERSION to");
    try mutant("the default token", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "          GH_TOKEN: ${{ github.token }}\n", "the step that runs the tool must set GH_TOKEN to");
    try mutant("no token", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n          VERSION: ${{ needs.tag.outputs.version }}", "          VERSION: ${{ needs.tag.outputs.version }}", "the step that runs the tool must set GH_TOKEN to");
    try mutant("the tool does not run", " bump-internal --version", " bump-nothing --version", "bump must run the tool step containing `bump-internal`");
}

test "mutant: where the token lives in bump" {
    // Built after the token exists.
    try mutant("the tool built after the token", "      # Built before any step holds the token, so no build runs beside it.\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Mint", "      - name: Mint", "bump: build the tool (zig build-exe tools/cut_release.zig) before the token step");
    // Another step takes the token.
    try mutant("checkout with the token", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n      - name: Install Zig 0.12.0 (sha256-pinned)\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n      # Built before any step holds the token, so no build runs beside it.\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Mint", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          token: ${{ steps.app.outputs.token }}\n      - name: Install Zig 0.12.0 (sha256-pinned)\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n      # Built before any step holds the token, so no build runs beside it.\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Mint", "bump step 0 names the App token");
    // A step after the tool runs with the token still alive.
    const build_step = "      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n";
    const app_step = "      - name: Mint the installation token of the release bot, for komira-internal only\n        id: app\n" ++ app_use ++ "        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          owner: komira-ai\n          repositories: komira-internal\n          permission-contents: write\n          permission-pull-requests: write\n";
    try mutant("the token minted before the tool is built", build_step ++ app_step, app_step ++ build_step, "bump: build the tool (zig build-exe tools/cut_release.zig) before the token step");
    try mutant("a step after the tool"," --workdir \"$RUNNER_TEMP/bump\"'\n", " --workdir \"$RUNNER_TEMP/bump\"'\n      - run: echo done\n", "the step that runs the tool must be the last");
}

// ---- tag: the tag is created with a token of the release bot App for this repository alone ----

const tag_perms = "    permissions:\n      contents: read\n    outputs:\n";

test "the real tag job holds contents: read and mints its own token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a, release_path);
    const at = std.mem.indexOf(u8, text, "\n  tag:\n").?;
    const end = std.mem.indexOf(u8, text, "\n  publish:\n").?;
    const tag = text[at..end];
    try std.testing.expect(std.mem.indexOf(u8, tag, tag_perms) != null);
    try std.testing.expect(std.mem.indexOf(u8, tag, "repositories: mopm\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, tag, "GH_TOKEN: ${{ steps.tagapp.outputs.token }}") != null);
}

test "mutant: tag holds a write scope, or the job token is not read-only" {
    try tagMutant("tag writes contents", tag_perms, "    permissions:\n      contents: write\n    outputs:\n", "tag: contents: write is not allowed here");
    try tagMutant("tag writes contents (exact)", tag_perms, "    permissions:\n      contents: write\n    outputs:\n", "tag: permissions must be exactly contents: read");
    try tagMutant("tag with no permissions", tag_perms, "    outputs:\n", "tag: permissions must be exactly contents: read");
    try tagMutant("tag also reads more", tag_perms, "    permissions:\n      contents: read\n      id-token: read\n    outputs:\n", "tag: permissions must be exactly contents: read");
    try tagMutant("tag with write-all", tag_perms, "    permissions: write-all\n    outputs:\n", "grants every scope");
}

test "mutant: the token step of tag" {
    try tagMutant("tag token scoped to komira-internal", "          repositories: mopm\n", "          repositories: komira-internal\n", "tag: the token step must set repositories");
    try tagMutant("tag token widened to two repositories", "          repositories: mopm\n", "          repositories: mopm,komira-internal\n", "tag: the token step must set repositories");
    try tagMutant("tag token for every repository of the owner", "          repositories: mopm\n", "", "tag: the token step must set repositories");
    try tagMutant("tag token with a wider scope", "          permission-contents: write\n", "          permission-contents: admin\n", "tag: the token step must set permission-contents");
    try tagMutant("tag token with an extra scope", "          permission-contents: write\n", "          permission-contents: write\n          permission-pull-requests: write\n", "tag: the token step takes exactly the inputs");
    try tagMutant("tag token of another owner", "          owner: komira-ai\n", "          owner: someone\n", "tag: the token step must set owner");
    try tagMutant("tag token from another key", "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "          private-key: ${{ secrets.OTHER_KEY }}", "tag: the token step must set private-key");
    try tagMutant("tag token from a literal app id", "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "          app-id: 5395718", "tag: the token step must set app-id");
    try tagMutant("tag token action unpinned", "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@v3", "tag must use actions/create-github-app-token@<full commit sha>");
    try tagMutant("tag token step without its id", "        id: tagapp\n", "", "tag: the token step must have id: tagapp");
    try tagMutant("tag token step removed", "      - name: Mint the installation token of the release bot, for this repository only, with contents write for the tag\n        id: tagapp\n" ++ app_use ++ "        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          owner: komira-ai\n          repositories: mopm\n          permission-contents: write\n", "", "tag must mint the token with exactly one actions/create-github-app-token step, has 0");
}

test "mutant: the step that runs the tag tool" {
    try tagMutant("tag with the job token", "          GH_TOKEN: ${{ steps.tagapp.outputs.token }}\n", "          GH_TOKEN: ${{ github.token }}\n", "tag: the step that runs the tool must set GH_TOKEN to");
    try tagMutant("tag with the token of bump", "          GH_TOKEN: ${{ steps.tagapp.outputs.token }}\n", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "tag: the step that runs the tool must set GH_TOKEN to");
    try tagMutant("tag with the token of bump (used outside its job)", "          GH_TOKEN: ${{ steps.tagapp.outputs.token }}\n", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "tag names the token of bump");
    try mutant("bump with the token of tag", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "          GH_TOKEN: ${{ steps.tagapp.outputs.token }}\n", "bump names the token of tag");
    try tagMutant("tag token in argv", " --out \"$GITHUB_OUTPUT\"'", " --out \"$GITHUB_OUTPUT\" --token \"$GH_TOKEN\"'", "tag must run exactly");
    try tagMutant("the tool built after the tag token", "      # Built before any step holds the token, so no build runs beside it.\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Mint", "      - name: Mint", "tag: build the tool (zig build-exe tools/cut_release.zig) before the token step");
    try tagMutant("a step after the tag tool", " --out \"$GITHUB_OUTPUT\"'\n", " --out \"$GITHUB_OUTPUT\"'\n      - run: echo done\n", "tag: the step that runs the tool must be the last");
}

test "mutant: a token named outside its own step" {
    try mutant("tag token in publish", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "          VERSION: ${{ needs.tag.outputs.version }}\n          T: ${{ steps.tagapp.outputs.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "publish names the release bot's App token");
    try mutant("bot key in publish", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "          VERSION: ${{ needs.tag.outputs.version }}\n          K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "publish names the release bot's App token");
    try mutant("a token step in publish", "    permissions:\n      contents: write\n    steps:\n", "    permissions:\n      contents: write\n    steps:\n      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          repositories: mopm\n", "publish names the release bot's App token");
    try tagMutant("tag's checkout takes the bump token", "          persist-credentials: false\n", "          persist-credentials: false\n          token: ${{ steps.app.outputs.token }}\n", "tag names the token of bump");
    try mutant("bump token scoped to mopm", "          repositories: komira-internal\n", "          repositories: mopm\n", "bump: the token step must set repositories");
    try mutant("a second token step in bump", "      - name: Open the komira-internal pull request", "      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n      - name: Open the komira-internal pull request", "bump must mint the token with exactly one actions/create-github-app-token step, has 2");
}

// ---- publish creates the release of the existing tag: `gh release create --verify-tag` ----

const tool_path = "tools/cut_release.zig";

test "the real tool passes --verify-tag to gh release create" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = c.Out.init(a);
    try rl.publishToolProblems(a, try real(a, tool_path), &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

fn toolMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a, tool_path);
    const planted = try std.mem.replaceOwned(u8, a, text, from, to);
    if (std.mem.eql(u8, planted, text)) {
        std.debug.print("tool mutant '{s}' does not apply\n", .{name});
        return error.TestUnexpectedResult;
    }
    var out = c.Out.init(a);
    try rl.publishToolProblems(a, planted, &out);
    var found = false;
    for (out.items) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) found = true;
    }
    std.debug.print("{s} mutant: {s} ({d} problem(s))\n", .{ if (found) "red " else "NOT RED", name, out.items.len });
    if (!found) return error.TestUnexpectedResult;
}

test "mutant: gh release create without --verify-tag" {
    try toolMutant("no --verify-tag", "\"--verify-tag\", ", "", "must be given --verify-tag");
    try toolMutant("a second release create", "args.appendSlice(&.{ \"release\", \"upload\", tag })", "args.appendSlice(&.{ \"release\", \"create\", tag })", "more than one `gh release create` call");
    try toolMutant("no release create", "\"release\", \"create\"", "\"release\", \"edit\"", "no longer calls `gh release create`");
}

const tag_env_lines = "    # The release bot's key lives only in this environment, which is restricted to main (RELEASING.md).\n    environment: release\n";
const bump_env_lines = "    # Same environment as tag: the key is readable only here and in tag (RELEASING.md).\n    environment: release\n";

test "mutant: the jobs that read the release bot's key declare environment release, and no other job declares one" {
    try mutant("tag without the environment", tag_env_lines, "", "tag reads RELEASE_BOT_* so it must declare `environment: release`, got nil");
    try mutant("bump without the environment", bump_env_lines, "", "bump reads RELEASE_BOT_* so it must declare `environment: release`, got nil");
    try mutant("tag in the wrong environment", tag_env_lines, "    environment: relase\n", "tag reads RELEASE_BOT_* so it must declare `environment: release`, got \"relase\"");
    try mutant("bump in prod", bump_env_lines, "    environment: prod\n", "bump reads RELEASE_BOT_* so it must declare `environment: release`, got \"prod\"");
    try mutant("publish in the release environment", "  publish:\n    needs: [tag, verify]\n    " ++ push_main, "  publish:\n    needs: [tag, verify]\n    environment: release\n    " ++ push_main, "publish must not use an environment");
    try mutant("verify in the release environment", "  verify:\n    needs: [plan, build, attest]\n", "  verify:\n    needs: [plan, build, attest]\n    environment: release\n", "verify must not use an environment");
}

// ---- the .deb wiring: a mutant for each hop a .deb takes from the build to the release and the lint --------------

fn buildMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantIn(build_path, name, from, to, needle);
}


const provenance_tail = "            dist/mopm-*.tar.gz\n            dist/mopm_*.deb\n            dist/SHA256SUMS\n      - uses: actions/upload-artifact";

test "mutant: the provenance subjects and the signed-assets upload leave out the .debs" {
    try mutant("provenance without the .debs", provenance_tail, "            dist/mopm-*.tar.gz\n            dist/SHA256SUMS\n      - uses: actions/upload-artifact", "attest's build provenance subject-path lists");
    try mutant("provenance with a misspelled .deb glob", provenance_tail, "            dist/mopm-*.tar.gz\n            dist/mopm-*.deb\n            dist/SHA256SUMS\n      - uses: actions/upload-artifact", "attest's build provenance subject-path lists");
    try mutant("provenance without the sums", provenance_tail, "            dist/mopm-*.tar.gz\n            dist/mopm_*.deb\n      - uses: actions/upload-artifact", "attest's build provenance subject-path lists");
    try mutant("signed-assets without the .debs", "            dist/mopm_*.deb\n            dist/SHA256SUMS\n            dist/*.sigstore.json", "            dist/SHA256SUMS\n            dist/*.sigstore.json", "attest's signed-assets artifact path lists");
}

test "mutant: the package matrix is not exactly the three release targets" {
    const macos = "          - { target: macos-arm64, zig_target: aarch64-macos, os: macos-14, deb_arch: \"\" }\n";
    try buildMutant("an added macos-x86_64 leg", macos, macos ++ "          - { target: macos-x86_64, zig_target: x86_64-macos, os: macos-13, deb_arch: \"\" }\n", "the package matrix has 4 legs, expected exactly the 3 release targets");
    try buildMutant("an added leg of another kind", macos, macos ++ "          - { target: windows-x86_64, zig_target: x86_64-windows, os: windows-2022, deb_arch: \"\" }\n", "the package matrix has 4 legs");
    try buildMutant("the macos leg dropped", macos, "", "the package matrix has 2 legs");
    try buildMutant("the macos leg dropped (its absence is named)", macos, "", "the package matrix has no leg macos-arm64");
    try buildMutant("an exclude key", "      matrix:\n        include:", "      matrix:\n        exclude:\n          - { target: macos-arm64 }\n        include:", "the package matrix has the key exclude");
    try buildMutant("an include key that adds legs at run time", "      matrix:\n        include:", "      matrix:\n        extra: [1]\n        include:", "the package matrix has the key extra");
    try buildMutant("a leg on another runner", "os: macos-14,", "os: macos-15,", "the package leg macos-arm64 must run on macos-14");
    try buildMutant("a leg for another Zig target", "zig_target: x86_64-linux-musl,", "zig_target: x86_64-linux-gnu,", "the package leg linux-x86_64 must run on ubuntu-24.04 and build x86_64-linux-musl");
}

test "mutant: the matrix gives a leg the wrong Debian architecture" {
    try buildMutant("amd64 leg without deb_arch", "deb_arch: amd64 }", "deb_arch: \"\" }", "the package leg linux-x86_64 has deb_arch");
    try buildMutant("aarch64 leg with the amd64 architecture", "deb_arch: arm64 }", "deb_arch: amd64 }", "the package leg linux-aarch64 has deb_arch");
    try buildMutant("a macos leg that gets a .deb", "os: macos-14, deb_arch: \"\" }", "os: macos-14, deb_arch: amd64 }", "the package leg macos-arm64 has deb_arch");
}

test "mutant: the .deb is not made from the binary of the tarball, for the architecture, at the path the upload takes" {
    try buildMutant("--binary is not the tarball's binary", "--binary \"$RUNNER_TEMP/mopm-$VERSION-$TARGET/mopm\"", "--binary \"$RUNNER_TEMP/out/mopm\"", "deb-package must take --binary");
    try buildMutant("the unpacked tarball is another leg's", "mopm-$VERSION-$TARGET.tar.gz\" -C", "mopm-$VERSION-linux-x86_64.tar.gz\" -C", "must first unpack mopm from this leg's tarball");
    try buildMutant("--arch is fixed", "--arch \"$DEB_ARCH\"", "--arch amd64", "deb-package must take --arch");
    try buildMutant("--packaging is another directory", "--packaging packaging/deb", "--packaging packaging", "deb-package must take --packaging packaging/deb");
    try buildMutant("--out is outside the upload", "/out/mopm_${VERSION}_${DEB_ARCH}.deb\"", "/mopm_${VERSION}_${DEB_ARCH}.deb\"", "deb-package must write --out");
    try buildMutant("DEB_ARCH is fixed", "DEB_ARCH: ${{ matrix.deb_arch }}", "DEB_ARCH: amd64", "the .deb step must set DEB_ARCH");
    try buildMutant("the .deb step runs for every leg", "      - name: Package the binary of the tarball as mopm_<version>_<arch>.deb\n        if: matrix.deb_arch != ''\n", "      - name: Package the binary of the tarball as mopm_<version>_<arch>.deb\n", "the .deb step must run only for the legs that have a deb_arch");
    try buildMutant("the channels build runs for every leg", "      - name: Build the channels tool (tools/channels)\n        if: matrix.deb_arch != ''\n", "      - name: Build the channels tool (tools/channels)\n", "the channels build step must run only for the legs that have a deb_arch");
}

test "mutant: the build's upload leaves out the .debs" {
    try buildMutant("upload without *.deb", "            ${{ runner.temp }}/out/*.deb\n", "", "the artifact upload path lists");
    try buildMutant("upload that tolerates no files", "if-no-files-found: error", "if-no-files-found: ignore", "the artifact upload must set if-no-files-found: error");
}

test "mutant: lintian does not gate on errors, or does not lint the build's .debs" {
    const lint_cmd = "lintian --version && lintian --fail-on error --tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb";
    try buildMutant("lintian without --fail-on error", lint_cmd, "lintian --version && lintian --tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb", "package must run `lintian --fail-on error`");
    try buildMutant("lintian that may not fail", "--tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb", "--tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb || true", "lintian must not be allowed to fail");
    try buildMutant("lintian that lints another directory", "--tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb", "--tag-display-limit 0 dist/*.deb", "lintian must lint \"$RUNNER_TEMP\"/out/*.deb");
    try buildMutant("lintian step that may fail", "      - name: lintian, every tag printed, an error fails\n        if: matrix.deb_arch != ''\n", "      - name: lintian, every tag printed, an error fails\n        continue-on-error: true\n        if: matrix.deb_arch != ''\n", "lintian must not be allowed to fail");
    try buildMutant("lintian for every leg (the macos one has no .deb)", "      - name: lintian, every tag printed, an error fails\n        if: matrix.deb_arch != ''\n", "      - name: lintian, every tag printed, an error fails\n", "the lintian step must run only for the legs that have a deb_arch");
    try buildMutant("lintian never installed", "sudo apt-get update -qq && sudo apt-get install -y -qq lintian", "sudo apt-get update -qq", "package must install lintian");
    try buildMutant("lintian install without the legs' condition", "      - name: Install lintian\n        if: matrix.deb_arch != ''\n", "      - name: Install lintian\n", "the lintian install must run only for the legs that have a deb_arch");
}

test "mutant: lintian runs before the .deb exists or after the upload" {
    // Lintian moved ahead of the step that makes the .deb: it would lint nothing.
    const make = "      - name: Package the binary of the tarball as mopm_<version>_<arch>.deb\n";
    const lint_step = "      - name: lintian, every tag printed, an error fails\n        if: matrix.deb_arch != ''\n        run: lintian --version && lintian --fail-on error --tag-display-limit 0 \"$RUNNER_TEMP\"/out/*.deb\n";
    try buildMutant("lintian before the .deb is made", make, lint_step ++ make, "lintian must run after the step that makes the .deb");
    // Lintian moved after the upload: an error no longer stops the leg before the .deb is carried on.
    const upload = "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n        with:\n          name: release-${{ matrix.target }}\n          path: |\n            ${{ runner.temp }}/out/*.tar.gz\n            ${{ runner.temp }}/out/*.deb\n          if-no-files-found: error\n          retention-days: 7\n          overwrite: true\n";
    try buildMutant("lintian after the upload", lint_step ++ upload, upload ++ lint_step, "lintian must run before the artifact upload");
}

// ---- tap: the Homebrew formula is rendered from the verified SHA256SUMS and its pull request opened with the third App token ----

/// A mutant inside the `tap` job (the first occurrence after its header).
fn tapMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantAfter(release_path, "\n  tap:\n", name, from, to, needle);
}

const tap_head = "  tap:\n    needs: [tag, publish, verify]\n    ";
const tap_perms = "    permissions:\n      contents: read\n    steps:\n";
const tap_env_lines = "    # Same environment as tag and bump: the key is readable only there (RELEASING.md).\n    environment: release\n";
const tap_app_step = "      - name: Mint the installation token of the release bot, for homebrew-tap only\n        id: tapapp\n" ++ app_use ++ "        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          owner: komira-ai\n          repositories: homebrew-tap\n          permission-contents: write\n          permission-pull-requests: write\n";
const tap_render_step = "      - name: Render Formula/mopm.rb from the verified SHA256SUMS, with the flags the tap's guard expects\n        env:\n          VERSION: ${{ needs.tag.outputs.version }}\n        run: '" ++ rl.render_run ++ "'\n";
const tap_build_renderer = "      - name: Build the formula renderer\n        run: zig build-exe tools/channels/main.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/channels\"\n";
const tap_build_cut = "      # Built before any step holds the token, so no build runs beside it.\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n";

test "the real tap job holds contents: read, renders with render_run and runs tap_run last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a, release_path);
    const at = std.mem.indexOf(u8, text, "\n  tap:\n").?;
    const end = std.mem.indexOf(u8, text, "\n  bump:\n").?;
    const tap = text[at..end];
    try std.testing.expect(std.mem.indexOf(u8, tap, tap_perms) != null);
    try std.testing.expect(std.mem.indexOf(u8, tap, tap_render_step) != null);
    try std.testing.expect(std.mem.indexOf(u8, tap, tap_app_step) != null);
    try std.testing.expect(std.mem.indexOf(u8, tap, "run: '" ++ rl.tap_run ++ "'\n") != null);
}

test "mutant: tap does not need publish, verify or tag, or runs on a manual run" {
    try mutant("tap without publish", tap_head ++ push_main, "  tap:\n    needs: [tag, verify]\n    " ++ push_main, "tap must need publish");
    try mutant("tap without verify", tap_head ++ push_main, "  tap:\n    needs: [tag, publish]\n    " ++ push_main, "tap must need verify");
    try mutant("tap without tag (the version comes from its output)", tap_head ++ push_main, "  tap:\n    needs: [publish, verify]\n    " ++ push_main, "tap must need tag");
    try mutant("tap with no if", tap_head ++ push_main ++ "\n", "  tap:\n    needs: [tag, publish, verify]\n", "tap must run only under if");
    try mutant("tap on any branch", tap_head ++ push_main, tap_head ++ "if: ${{ github.event_name == 'push' }}", "tap must run only under if");
    try mutant("tap on a manual run", tap_head ++ push_main, tap_head ++ "if: ${{ always() }}", "tap must run only under if");
    try mutant("tap that may fail quietly", tap_head ++ push_main ++ "\n", tap_head ++ push_main ++ "\n    continue-on-error: true\n", "tap must not set continue-on-error");
}

test "mutant: tap holds a write scope here, or more than contents" {
    try tapMutant("tap writes contents", tap_perms, "    permissions:\n      contents: write\n    steps:\n", "tap: contents: write is not allowed here");
    try tapMutant("tap writes pull requests", tap_perms, "    permissions:\n      contents: read\n      pull-requests: write\n    steps:\n", "tap: pull-requests: write is not allowed here");
    try tapMutant("tap reads more than contents", tap_perms, "    permissions:\n      contents: read\n      id-token: read\n    steps:\n", "tap: permissions must be exactly contents: read");
    try tapMutant("tap with no permissions", tap_perms, "    steps:\n", "tap: permissions must be exactly contents: read");
    try tapMutant("tap with write-all", tap_perms, "    permissions: write-all\n    steps:\n", "grants every scope");
}

test "mutant: nothing may need tap, and no other job names its token or the key" {
    try mutant("publish needs tap", "  publish:\n    needs: [tag, verify]", "  publish:\n    needs: [tag, verify, tap]", "publish must not need tap");
    try mutant("bump needs tap", bump_head ++ push_main, "  bump:\n    needs: [tag, publish, tap]\n    " ++ push_main, "bump must not need tap");
    try mutant("publish takes the token of tap", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "          VERSION: ${{ needs.tag.outputs.version }}\n          T: ${{ steps.tapapp.outputs.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "publish names the release bot's App token");
    try mutant("bump with the token of tap", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n", "bump names the token of tap");
    try tapMutant("tap with the token of bump", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n", "          GH_TOKEN: ${{ steps.app.outputs.token }}\n", "tap names the token of bump");
    try tapMutant("tap with the token of tag", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n", "          GH_TOKEN: ${{ steps.tagapp.outputs.token }}\n", "tap names the token of tag");
    try tagMutant("tag's checkout takes the tap token", "          persist-credentials: false\n", "          persist-credentials: false\n          token: ${{ steps.tapapp.outputs.token }}\n", "tag names the token of tap");
}

test "mutant: the key is named exactly three times" {
    try tapMutant("a fourth reference to the key in the render step", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/channels\"", "          VERSION: ${{ needs.tag.outputs.version }}\n          K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n        run: '\"$RUNNER_TEMP/channels\"", "RELEASE_BOT_PRIVATE_KEY is named 4 times, expected exactly 3");
    try tapMutant("the tap token step without the key", "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n", "", "RELEASE_BOT_PRIVATE_KEY is named 2 times, expected exactly 3");
    try tapMutant("the tap token step with another key", "          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}", "          private-key: ${{ secrets.OTHER_KEY }}", "tap: the token step must set private-key");
}

test "mutant: the App token step of tap" {
    try tapMutant("tap action unpinned", "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@v3", "tap must use actions/create-github-app-token@<full commit sha>");
    try tapMutant("tap action with a short sha", "actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510", "actions/create-github-app-token@64ab729", "tap must use actions/create-github-app-token@<full commit sha>");
    try tapMutant("tap another action mints the token", app_use, "        uses: someone/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n", "tap must use actions/create-github-app-token@");
    try tapMutant("tap token step removed", tap_app_step, "", "tap must mint the token with exactly one actions/create-github-app-token step, has 0");
    try tapMutant("a second token step in tap", "      - name: Open the homebrew-tap pull request", "      - uses: actions/create-github-app-token@64ab729a6294000f5aa4a4bc0b73d1f32bc45510\n      - name: Open the homebrew-tap pull request", "tap must mint the token with exactly one actions/create-github-app-token step, has 2");
    try tapMutant("tap app id from a literal", "          app-id: ${{ vars.RELEASE_BOT_APP_ID }}", "          app-id: 5395718", "tap: the token step must set app-id");
    try tapMutant("tap token of another owner", "          owner: komira-ai\n", "          owner: someone\n", "tap: the token step must set owner");
    try tapMutant("tap token for every repository of the owner", "          repositories: homebrew-tap\n", "", "tap: the token step must set repositories");
    try tapMutant("tap token for two repositories", "          repositories: homebrew-tap\n", "          repositories: homebrew-tap,mopm\n", "tap: the token step must set repositories");
    try tapMutant("tap token scoped to mopm", "          repositories: homebrew-tap\n", "          repositories: mopm\n", "tap: the token step must set repositories");
    try tapMutant("tap token scoped to komira-internal", "          repositories: homebrew-tap\n", "          repositories: komira-internal\n", "tap: the token step must set repositories");
    try tapMutant("tap token with an extra scope", "          permission-pull-requests: write\n", "          permission-pull-requests: write\n          permission-workflows: write\n", "tap: the token step takes exactly the inputs");
    try tapMutant("tap token without the pull-requests scope", "          permission-pull-requests: write\n", "", "tap: the token step must set permission-pull-requests");
    try tapMutant("tap token without the contents scope", "          permission-contents: write\n", "", "tap: the token step must set permission-contents");
    try tapMutant("tap token with a wider scope", "          permission-contents: write\n", "          permission-contents: admin\n", "tap: the token step must set permission-contents");
    try tapMutant("tap token step without its id", "        id: tapapp\n", "", "tap: the token step must have id: tapapp");
}

test "mutant: the step that runs the tap tool" {
    try tapMutant("the token in argv", " --workdir \"$RUNNER_TEMP/tap-clone\"'", " --workdir \"$RUNNER_TEMP/tap-clone\" --token \"$GH_TOKEN\"'", "tap must run exactly");
    try tapMutant("another tap repository", " --tap-repo komira-ai/homebrew-tap", " --tap-repo komira-ai/mopm", "tap must run exactly");
    try tapMutant("another formula", " --formula mopm ", " --formula buildrules ", "tap must run exactly");
    try tapMutant("another formula file", " --formula-file \"$RUNNER_TEMP/tap/mopm.rb\"", " --formula-file \"$RUNNER_TEMP/other.rb\"", "tap must run exactly");
    try tapMutant("another version", " tap --version \"$VERSION\"", " tap --version 0.0.0", "tap must run exactly");
    try tapMutant("version from the plan", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n          VERSION: ${{ needs.tag.outputs.version }}", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n          VERSION: ${{ needs.plan.outputs.version }}", "tap: the step that runs the tool must set VERSION");
    try tapMutant("the default token", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n", "          GH_TOKEN: ${{ github.token }}\n", "tap: the step that runs the tool must set GH_TOKEN to");
    try tapMutant("no token", "          GH_TOKEN: ${{ steps.tapapp.outputs.token }}\n          VERSION: ${{ needs.tag.outputs.version }}", "          VERSION: ${{ needs.tag.outputs.version }}", "tap: the step that runs the tool must set GH_TOKEN to");
    try tapMutant("the tool does not run", " tap --version", " tap-nothing --version", "tap must run the tool step containing ` tap --version`");
}

test "mutant: where the token lives in tap" {
    try tapMutant("the tool built after the token", tap_build_cut ++ tap_build_renderer ++ tap_render_step ++ tap_app_step, tap_build_renderer ++ tap_render_step ++ tap_app_step ++ tap_build_cut, "tap: build the tool (zig build-exe tools/cut_release.zig) before the token step");
    try tapMutant("the token minted before the formula is rendered", tap_render_step ++ tap_app_step, tap_app_step ++ tap_render_step, "tap: render the formula before the token step");
    try tapMutant("checkout with the token", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          persist-credentials: false\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          token: ${{ steps.tapapp.outputs.token }}\n", "tap step 0 names the App token");
    try tapMutant("a step after the tool", " --workdir \"$RUNNER_TEMP/tap-clone\"'\n", " --workdir \"$RUNNER_TEMP/tap-clone\"'\n      - run: echo done\n", "tap: the step that runs the tool must be the last");
}

test "mutant: tap renders the formula with other flags than the tap's guard expects, or from other sums" {
    try tapMutant("no --repo (no release url)", " --repo \"$GITHUB_REPOSITORY\" --no-explicit-version --out", " --no-explicit-version --out", "tap must render the formula with exactly");
    try tapMutant("another url base", " --repo \"$GITHUB_REPOSITORY\" --no-explicit-version --out", " --url-base https://example.com/dl --no-explicit-version --out", "tap must render the formula with exactly");
    try tapMutant("the version line is rendered again", " --no-explicit-version --out", " --out", "tap must render the formula with exactly");
    try tapMutant("another name", " --name mopm --version", " --name mopm-edge --version", "tap must render the formula with exactly");
    try tapMutant("another version", " --version \"$VERSION\" --desc", " --version 0.0.0 --desc", "tap must render the formula with exactly");
    try tapMutant("sums that were not downloaded from the verified artifact", " --sums dist/SHA256SUMS", " --sums SHA256SUMS", "tap must render the formula with exactly");
    try tapMutant("render step without the version of the tag", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/channels\"", "          VERSION: ${{ needs.plan.outputs.version }}\n        run: '\"$RUNNER_TEMP/channels\"", "tap: the render step must set VERSION");
    try tapMutant("no render step", tap_render_step, "", "tap must render the formula with `channels formula --sums`");
    try tapMutant("the renderer is not built", tap_build_renderer, "", "tap: build the renderer (zig build-exe tools/channels/main.zig) before the step that renders");
    try tapMutant("tap downloads the signed files, not the verified ones", "          name: verified-assets\n", "          name: signed-assets\n", "tap must download exactly the artifact verified-assets");
    try tapMutant("tap downloads nothing", "      - uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2\n        with:\n          name: verified-assets\n          path: dist\n", "", "tap must download exactly the artifact verified-assets");
}

test "mutant: the environment of tap" {
    try tapMutant("tap without the environment", tap_env_lines, "", "tap reads RELEASE_BOT_* so it must declare `environment: release`, got nil");
    try tapMutant("tap in the wrong environment", tap_env_lines, "    environment: relase\n", "tap reads RELEASE_BOT_* so it must declare `environment: release`, got \"relase\"");
    try tapMutant("tap in prod", tap_env_lines, "    environment: prod\n", "tap reads RELEASE_BOT_* so it must declare `environment: release`, got \"prod\"");
}

// ---- the apt jobs: read (the role), index (the signing key), write (the role), three attempts; a mutant for each rule ----

const gate_if = "        if: steps.gate.outputs.enabled == 'true'\n";
const read_head = "  apt-deploy-read:\n";
const index_head = "  apt-index:\n";
const write_head = "  apt-deploy-write:\n";

fn aptMutant(anchor: []const u8, name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    return mutantAfter(release_path, anchor, name, from, to, needle);
}

test "mutant: the apt jobs' environments" {
    try aptMutant(read_head, "the read without its environment", "    environment: apt-publish\n", "", "apt-deploy-read holds the publish role so it must declare `environment: apt-publish`");
    try aptMutant(write_head, "the write in the signing environment", "    environment: apt-publish\n", "    environment: apt-signing\n", "apt-deploy-write holds the publish role so it must declare `environment: apt-publish`");
    try aptMutant(index_head, "the index without its environment", "    environment: apt-signing\n", "", "apt-index holds the signing key so it must declare `environment: apt-signing`");
    try aptMutant(index_head, "the index in the publish environment", "    environment: apt-signing\n", "    environment: apt-publish\n", "apt-index holds the signing key so it must declare `environment: apt-signing`");
    try aptMutant("  apt-deploy-read-3:\n", "the third read in the release environment", "    environment: apt-publish\n", "    environment: release\n", "apt-deploy-read-3 holds the publish role so it must declare `environment: apt-publish`");
    try aptMutant("\n  plan:\n", "plan in an environment", "    timeout-minutes: 10\n", "    timeout-minutes: 10\n    environment: apt-publish\n", "plan must not use an environment");
}

test "mutant: id-token only in the OIDC jobs and attest" {
    try aptMutant(index_head, "the index with id-token", "    permissions:\n      contents: read\n    outputs:\n", "    permissions:\n      contents: read\n      id-token: write\n    outputs:\n", "apt-index: permissions must be exactly contents: read");
    try aptMutant(write_head, "the write without id-token", "      contents: read\n      id-token: write\n", "      contents: read\n", "apt-deploy-write: permissions must be exactly contents: read and id-token: write");
    try aptMutant(read_head, "the read with contents write", "      contents: read\n      id-token: write\n", "      contents: write\n      id-token: write\n", "apt-deploy-read: contents: write is not allowed here");
    try aptMutant("\n  verify:\n", "verify with id-token", "      contents: read\n      attestations: read\n", "      contents: read\n      attestations: read\n      id-token: write\n", "verify: id-token: write is not allowed here");
    try aptMutant("\n  tag:\n", "tag with id-token", "    permissions:\n      contents: read\n", "    permissions:\n      contents: read\n      id-token: write\n", "tag: id-token: write is not allowed here");
    try aptMutant(write_head, "the write with attestations", "      contents: read\n      id-token: write\n", "      contents: read\n      id-token: write\n      attestations: write\n", "apt-deploy-write: attestations: write is not allowed here");
}

test "mutant: no job holds both the signing key and the role" {
    const sign_env = "          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}\n";
    try aptMutant(index_head, "the index job takes the role", sign_env, sign_env ++ "          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n", "apt-index holds both the signing key");
    try aptMutant(index_head, "the index job assumes the role", "      - name: Sign Release", "      - name: Assume\n        run: '\"$RUNNER_TEMP/apt_publish\" assume --env-file \"$GITHUB_ENV\"'\n      - name: Sign Release", "apt-index holds both the signing key");
    try aptMutant(write_head, "the write job takes the key", "          APT_BUCKET: ${{ vars.APT_BUCKET }}\n          APT_DISTRIBUTION_ID", "          APT_GPG_PRIVATE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n          APT_BUCKET: ${{ vars.APT_BUCKET }}\n          APT_DISTRIBUTION_ID", "apt-deploy-write holds both the signing key");
    try aptMutant(read_head, "the read job takes the key", "          APT_BUCKET: ${{ vars.APT_BUCKET }}\n        run: '\"$RUNNER_TEMP/apt_publish\" read", "          APT_BUCKET: ${{ vars.APT_BUCKET }}\n          APT_GPG_PASSPHRASE: ${{ secrets.APT_GPG_PASSPHRASE }}\n        run: '\"$RUNNER_TEMP/apt_publish\" read", "apt-deploy-read holds both the signing key");
    try aptMutant("\n  plan:\n", "plan names the key", "          GH_TOKEN: ${{ github.token }}\n", "          GH_TOKEN: ${{ github.token }}\n          K: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n", "plan names the signing key (APT_GPG_*); only the apt-index jobs may");
    try aptMutant("\n  verify:\n", "verify names the role", "          VERSION: ${{ needs.plan.outputs.version }}\n", "          VERSION: ${{ needs.plan.outputs.version }}\n          R: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n", "verify names the publish role");
    try aptMutant("\n  attest:\n", "attest (which holds id-token) names the key", "      - uses: sigstore/cosign-installer", "      - env:\n          K: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n        run: 'true'\n      - uses: sigstore/cosign-installer", "attest holds both the signing key");
    try mutant("the workflow's env holds the key", "permissions:\n  contents: read\n\n# One release run", "permissions:\n  contents: read\nenv:\n  K: ${{ secrets.APT_GPG_PRIVATE_KEY }}\n\n# One release run", "env names the apt signing key or the publish role");
    try mutant("the workflow's env holds the role", "permissions:\n  contents: read\n\n# One release run", "permissions:\n  contents: read\nenv:\n  R: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n\n# One release run", "env names the apt signing key or the publish role");
}

test "mutant: the fail-safe gate (without the owner's settings an apt job does nothing and ends green)" {
    const assume = "      - name: Assume the publish role through OIDC\n" ++ gate_if;
    try aptMutant(read_head, "the assume step without the gate", assume, "      - name: Assume the publish role through OIDC\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(read_head, "the read step without the gate", "        " ++ "if: steps.gate.outputs.enabled == 'true'\n        env:\n          APT_BUCKET", "        env:\n          APT_BUCKET", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(read_head, "the upload without the gate", "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n" ++ gate_if, "      - uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(index_head, "the signing step without the gate", "        id: sign\n" ++ gate_if, "        id: sign\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(index_head, "the merge without the gate", "      - name: Merge the .debs into the index that was read (the index of every product is kept)\n" ++ gate_if, "      - name: Merge the .debs into the index that was read (the index of every product is kept)\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(write_head, "the write step without the gate", "        id: write\n" ++ gate_if, "        id: write\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(write_head, "the write's assume step without the gate", assume, "      - name: Assume the publish role through OIDC\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant("  apt-deploy-write-3:\n", "the last write step with another condition", "        id: write\n" ++ gate_if, "        id: write\n        if: always()\n", "after the gate must carry `if: steps.gate.outputs.enabled == 'true'`");
    try aptMutant(read_head, "no gate step", "        id: gate\n", "        id: gate2\n", "apt-deploy-read: has no step with id `gate`");
    try aptMutant(index_head, "a gate that does not run the tool's gate", "gate --label \"apt index\"", "version --label \"apt index\"", "apt-index: the step `gate` must run `apt_publish gate`");
    try aptMutant(read_head, "a gate that skips a variable", "--env APT_DISTRIBUTION_ID --env APT_HOSTNAME'", "--env APT_DISTRIBUTION_ID'", "apt-deploy-read: the gate must check --env APT_HOSTNAME");
    try aptMutant(read_head, "a gate that skips the role", "--env APT_PUBLISH_ROLE_ARN --env APT_BUCKET", "--env APT_BUCKET", "apt-deploy-read: the gate must check --env APT_PUBLISH_ROLE_ARN");
    try aptMutant(index_head, "a gate that skips the key", " --true HAVE_KEY", "", "apt-index: the gate must check --true HAVE_KEY");
    try aptMutant(index_head, "a gate that skips the read", "--true READ_ENABLED --true HAVE_KEY", "--true HAVE_KEY", "apt-index: the gate must check --true READ_ENABLED");
    try aptMutant(write_head, "a write gate that skips the signing", " --true INDEX_SIGNED", "", "apt-deploy-write: the gate must check --true INDEX_SIGNED");
    try aptMutant(write_head, "a write gate that ignores the read", "READ_ENABLED: ${{ needs.apt-deploy-read.outputs.enabled }}", "READ_ENABLED: ${{ needs.apt-index.outputs.enabled }}", "apt-deploy-write: the gate must be given READ_ENABLED");
    try aptMutant(write_head, "a write gate that ignores the signing", "INDEX_SIGNED: ${{ needs.apt-index.outputs.signed }}", "INDEX_SIGNED: ${{ needs.apt-deploy-read.outputs.signed }}", "apt-deploy-write: the gate must be given READ_ENABLED");
    try aptMutant(index_head, "a gate that reads the key itself", "HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY != '' }}", "HAVE_KEY: ${{ secrets.APT_GPG_PRIVATE_KEY }}", "apt-index: the gate must be given HAVE_KEY");
    // A step before the gate that already reads a setting or reaches the cloud.
    try aptMutant(read_head, "an early assume", "      - name: Build the apt publish tool\n", "      - name: Early\n        run: '\"$RUNNER_TEMP/apt_publish\" assume --env-file \"$GITHUB_ENV\"'\n      - name: Build the apt publish tool\n", "runs before the gate but reads a setting, a secret or the cloud");
    try aptMutant(index_head, "an early secret", "      - name: Build the apt publish tool\n", "      - name: Early\n        env:\n          K: ${{ secrets.APT_GPG_PASSPHRASE }}\n        run: 'true'\n      - name: Build the apt publish tool\n", "runs before the gate but reads a setting, a secret or the cloud");
    try aptMutant(write_head, "an early variable", "      - name: Build the apt publish tool\n", "      - name: Early\n        env:\n          B: ${{ vars.APT_BUCKET }}\n        run: 'true'\n      - name: Build the apt publish tool\n", "runs before the gate but reads a setting, a secret or the cloud");
    // The assume comes after the gate and before the read or write that needs it.
    try aptMutant(write_head, "a write that never assumes the role", "      - name: Assume the publish role through OIDC\n" ++ gate_if ++ "        env:\n          APT_PUBLISH_ROLE_ARN: ${{ vars.APT_PUBLISH_ROLE_ARN }}\n        run: '\"$RUNNER_TEMP/apt_publish\" assume --env-file \"$GITHUB_ENV\"'\n", "", "apt-deploy-write: must assume the publish role");
}

test "mutant: the order and the retries of the apt jobs" {
    try aptMutant(read_head, "the read runs on a manual run", "    needs: [publish]\n    if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}\n", "    needs: [publish]\n", "apt-deploy-read must run only under if");
    try aptMutant(read_head, "the read without publish", "    needs: [publish]\n", "    needs: [verify]\n", "apt-deploy-read must need publish");
    try aptMutant("  apt-deploy-read-2:\n", "a retry that always runs", "    if: ${{ needs.apt-deploy-write.outputs.conflict == 'true' }}\n", "    if: ${{ always() }}\n", "apt-deploy-read-2 must run only under if");
    try aptMutant("  apt-deploy-read-3:\n", "a retry that starts on the wrong attempt", "    if: ${{ needs.apt-deploy-write-2.outputs.conflict == 'true' }}\n", "    if: ${{ needs.apt-deploy-write.outputs.conflict == 'true' }}\n", "apt-deploy-read-3 must run only under if");
    try aptMutant("  apt-deploy-read-2:\n", "a retry that does not wait for the write", "    needs: [apt-deploy-write]\n", "    needs: [publish]\n", "apt-deploy-read-2 must need apt-deploy-write");
    try aptMutant(write_head, "a write that does not wait for the index", "    needs: [apt-deploy-read, apt-index]\n", "    needs: [apt-deploy-read]\n", "apt-deploy-write must need apt-index");
    try aptMutant(index_head, "an index that does not wait for the read", "    needs: [apt-deploy-read]\n", "    needs: [publish]\n", "apt-index must need apt-deploy-read");
    try aptMutant("\n  bump:\n", "bump waits for an apt job", "    needs: [tag, publish]\n", "    needs: [tag, publish, apt-deploy-write]\n", "bump must not need apt-deploy-write");
    try aptMutant("\n  publish:\n", "publish waits for an apt job", "    needs: [tag, verify]\n", "    needs: [tag, verify, apt-index]\n", "publish must not need apt-index");
    try aptMutant(index_head, "an apt job that may fail quietly", "    environment: apt-signing\n", "    environment: apt-signing\n    continue-on-error: true\n", "apt-index must not set continue-on-error");
    try aptMutant(write_head, "an apt job with an if of its own", "    environment: apt-publish\n", "    environment: apt-publish\n    if: ${{ always() }}\n", "apt-deploy-write must not have an if:");
    try aptMutant("  apt-deploy-write-3:\n", "the last write without --last", " --out \"$GITHUB_OUTPUT\" --last'", " --out \"$GITHUB_OUTPUT\"'", "`--last` belongs to the write of the last attempt only");
    try aptMutant(write_head, "the first write with --last", " --out \"$GITHUB_OUTPUT\"'", " --out \"$GITHUB_OUTPUT\" --last'", "`--last` belongs to the write of the last attempt only");
}

test "mutant: what the apt jobs pass on" {
    try aptMutant("  apt-deploy-read-2:\n", "a read that uploads another name", "          name: apt-current-2\n", "          name: apt-current\n", "apt-deploy-read-2: must upload exactly the artifact apt-current-2");
    try aptMutant("  apt-index-2:\n", "an index that downloads the first read", "          name: apt-current-2\n", "          name: apt-current\n", "apt-index-2: must download exactly the artifacts apt-current-2 and verified-assets");
    try aptMutant(index_head, "an index that merges other .debs", "          name: verified-assets\n", "          name: signed-assets\n", "apt-index: must download exactly the artifacts apt-current and verified-assets");
    try aptMutant(index_head, "an index that uploads another name", "          name: apt-next\n", "          name: release-apt\n", "apt-index: must upload exactly the artifact apt-next");
    try aptMutant(write_head, "a write that uploads the .debs of another run", "          name: verified-assets\n", "          name: notes-pin\n", "apt-deploy-write: must download exactly the artifacts apt-next and verified-assets");
    try aptMutant(write_head, "a write that reads the next attempt's index", "          name: apt-next\n", "          name: apt-next-2\n", "apt-deploy-write: must download exactly the artifacts apt-next and verified-assets");
    try aptMutant(read_head, "a read that does not output the gate", "      enabled: ${{ steps.gate.outputs.enabled }}\n", "      enabled: ${{ steps.read.outputs.enabled }}\n", "apt-deploy-read: must output enabled");
    try aptMutant(index_head, "an index that does not output signed", "      signed: ${{ steps.sign.outputs.signed }}\n", "      signed: 'true'\n", "apt-index: must output signed");
    try aptMutant(write_head, "a write that does not output the conflict", "      conflict: ${{ steps.write.outputs.conflict }}\n", "      conflict: 'false'\n", "apt-deploy-write: must output conflict");
    try aptMutant(index_head, "a merge after the signing", "      - name: Merge the .debs into the index that was read (the index of every product is kept)\n" ++ gate_if ++ "        env:\n          OWNER: ${{ github.repository_owner }}\n        run: '\"$RUNNER_TEMP/apt_publish\" index", "      - name: Sign first\n" ++ gate_if ++ "        run: '\"$RUNNER_TEMP/apt_publish\" sign --dir x --work y --fingerprint z'\n      - name: Merge the .debs into the index that was read (the index of every product is kept)\n" ++ gate_if ++ "        env:\n          OWNER: ${{ github.repository_owner }}\n        run: '\"$RUNNER_TEMP/apt_publish\" index", "apt-index: must merge the index");
}

// ---- tools/apt_publish.zig: the puts the publish role allows ----

const apt_tool_path = "tools/apt_publish.zig";

test "the real apt tool makes exactly the puts the role allows, in the right order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = c.Out.init(a);
    try rl.aptToolProblems(a, try real(a, apt_tool_path), &out);
    for (out.items) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

fn aptToolMutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a, apt_tool_path);
    const planted = try std.mem.replaceOwned(u8, a, text, from, to);
    if (std.mem.eql(u8, planted, text)) {
        std.debug.print("apt tool mutant '{s}' does not apply\n", .{name});
        return error.TestUnexpectedResult;
    }
    var out = c.Out.init(a);
    try rl.aptToolProblems(a, planted, &out);
    var found = false;
    for (out.items) |l| {
        if (std.mem.indexOf(u8, l, needle) != null) found = true;
    }
    std.debug.print("{s} mutant: {s} ({d} problem(s))\n", .{ if (found) "red " else "NOT RED", name, out.items.len });
    if (!found) return error.TestUnexpectedResult;
}

test "mutant: the apt tool's puts" {
    try aptToolMutant("a .deb put without If-None-Match", "try std.fs.path.join(a, &.{ debs_dir, name }), .{ \"--if-none-match\", \"*\" })", "try std.fs.path.join(a, &.{ debs_dir, name }), .{ \"--if-match\", \"x\" })", "a .deb must be put with If-None-Match");
    try aptToolMutant("an index put that never uses If-Match", "else .{ \"--if-match\", tag.? }", "else .{ \"--if-none-match\", \"*\" }", "the condition of an index put must be If-Match on the ETag that was read");
    try aptToolMutant("an index put that always creates", "if (tag == null or std.mem.eql(u8, tag.?, state.absent))", "if (true)", "the condition of an index put must be If-Match on the ETag that was read");
    try aptToolMutant("an index put that drops its condition", "cond[0], cond[1] }", "}", "`put` must pass its condition to put-object");
    try aptToolMutant("an index object put without the condition", "try std.fs.path.join(a, &.{ root, rel }), cond)", "try std.fs.path.join(a, &.{ root, rel }), .{ \"--if-none-match\", \"*\" })", "every object of the index must be put with the condition `cond`");
    try aptToolMutant("a second put-object call", "\"cloudfront\", \"create-invalidation\"", "\"s3api\", \"put-object\"", "there must be exactly one put-object call");
    try aptToolMutant("the index read through something else", "\"get-object\"", "\"head-object\"", "the index must be read with s3api get-object");
    try aptToolMutant("no invalidation", "\"create-invalidation\"", "\"list-invalidations\"", "the index must be invalidated after the write");
    try aptToolMutant("an invalidation before the index", "// The pool first:", "_ = aws(a, aws_exe, &.{ \"cloudfront\", \"create-invalidation\" });\n    // The pool first:", "the invalidation must come after the index is written");
    try aptToolMutant("no by-hash files", "state.byHashKey(a, rel, &hash)", "state.poolKey(a, rel, &hash)", "the Packages files must be written by their hash");
    try aptToolMutant("a by-hash file put without If-None-Match", "put(a, aws_exe, bucket, key, file_path, .{ \"--if-none-match\", \"*\" })", "put(a, aws_exe, bucket, key, file_path, .{ \"--if-match\", \"x\" })", "a by-hash file must be put with If-None-Match");
    try aptToolMutant("the by-hash files after the index", "// The by-hash copies of every Packages", "// try std.fs.path.join(a, &.{ root, rel }), cond)\n    // The by-hash copies of every Packages", "the by-hash files must be put before the plain files of the index");
    try aptToolMutant("the by-hash files before the .debs", "// The pool first:", "// state.byHashKey(a, rel, &hash)\n    // The pool first:", "the .debs must be put before the by-hash files");
    try aptToolMutant("the index before the .debs", "// The pool first:", "// try std.fs.path.join(a, &.{ root, rel }), cond)\n    // The pool first:", "the .debs must be put before the index");
}
