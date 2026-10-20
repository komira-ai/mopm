//! //:release_workflow: the release pipeline's lint rules (tests/drivers/release_lint.zig) over the
//! real .github/workflows/release.yml and release-beta-user.yml, and each rule shown able to fail: a
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

fn real(a: Allocator, path: []const u8) ![]u8 {
    const tree = try c.loadTree(a);
    return tree.read(a, path);
}

fn problemsOf(a: Allocator, path: []const u8, text: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    if (std.mem.eql(u8, path, user_path)) try rl.userBetaProblems(a, text, &out) else try rl.problems(a, text, &out);
    return out.items;
}

test "the real release.yml and release-beta-user.yml pass every rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{ release_path, user_path }) |p| {
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
    try mutant("attest with contents write", "    permissions:\n      contents: read\n      id-token: write", "    permissions:\n      contents: write\n      id-token: write", "attest: contents: write is not allowed here");
    try mutant("the user-level beta with a scope", "  beta-user:\n    needs: [plan, build]\n    permissions:\n      contents: read\n", "  beta-user:\n    needs: [plan, build]\n    permissions:\n      contents: read\n      id-token: write\n", "beta-user: id-token: write is not allowed here");
}

test "mutant: a bare write-all, a continue-on-error, an if where none belongs" {
    try mutant("verify with write-all", "    permissions:\n      contents: read\n      attestations: read\n", "    permissions: write-all\n", "grants every scope");
    try mutant("beta continue-on-error", "  beta:\n    permissions:\n      contents: read\n", "  beta:\n    continue-on-error: true\n    permissions:\n      contents: read\n", "beta must not set continue-on-error");
    try mutant("beta-user continue-on-error", "  beta-user:\n    needs: [plan, build]\n", "  beta-user:\n    needs: [plan, build]\n    continue-on-error: true\n", "beta-user must not set continue-on-error");
    try mutant("build with an if", "  build:\n    needs: plan\n", "  build:\n    needs: plan\n    if: ${{ always() }}\n", "build must not have an if:");
    try mutant("beta-user with an if", "  beta-user:\n    needs: [plan, build]\n", "  beta-user:\n    needs: [plan, build]\n    if: ${{ github.event_name == 'push' }}\n", "beta-user must not have an if:");
    try mutant("plan with an if", "  plan:\n    needs: [beta, lint]\n", "  plan:\n    needs: [beta, lint]\n    if: ${{ github.event_name == 'workflow_dispatch' }}\n", "plan must not have an if:");
}

test "mutant: the order of the stages" {
    try mutant("build without plan", "  build:\n    needs: plan", "  build:\n    needs: beta", "build must need plan");
    try mutant("attest without build", "  attest:\n    needs: [plan, build, beta-user]", "  attest:\n    needs: [plan, beta-user]", "attest must need build");
    try mutant("attest without beta-user (it would sign untested files)", "  attest:\n    needs: [plan, build, beta-user]", "  attest:\n    needs: [plan, build]", "attest must need beta-user");
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
    try mutant("publish downloads the unverified assets", "          name: verified-assets\n          path: dist\n", "          name: signed-assets\n          path: dist\n", "publish must download exactly the artifacts verified-assets and notes-pin");
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
    try mutant("verify without cosign", "      - uses: sigstore/cosign-installer@6f9f17788090df1f26f669e9d70d6ae9567deba6 # v4.1.2\n      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Verify", "      - name: Build the release tool\n        run: zig build-exe tools/cut_release.zig -O ReleaseSafe -femit-bin=\"$RUNNER_TEMP/cut_release\"\n      - name: Verify", "verify needs cosign");
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
    try userMutant("an extra leg", "          - { target: macos-arm64, os: macos-14 }\n", "          - { target: macos-arm64, os: macos-14 }\n          - { target: macos-x86_64, os: macos-13 }\n", "the matrix has 4 legs");
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
    try mutant("attest checks the records only after writing SHA256SUMS", "        run: '\"$RUNNER_TEMP/release\" tested dist tested'\n      - name: Write SHA256SUMS (exactly the four tarballs) and check it\n        run: '\"$RUNNER_TEMP/release\" sums dist'\n", "        run: '\"$RUNNER_TEMP/release\" sums dist'\n      - name: Write SHA256SUMS (exactly the four tarballs) and check it\n        run: '\"$RUNNER_TEMP/release\" tested dist tested'\n", "attest must check the tested records before it writes SHA256SUMS");
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
const app_use = "        uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1 # v3.2.0\n";

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
    try mutant("bump behind an environment", bump_head ++ push_main ++ "\n", bump_head ++ push_main ++ "\n    environment: prod\n", "bump must not use an environment");
    try mutant("bump that may fail quietly", bump_head ++ push_main ++ "\n", bump_head ++ push_main ++ "\n    continue-on-error: true\n", "bump must not set continue-on-error");
}

test "mutant: a failed bump must not stop or un-release anything" {
    try mutant("publish needs bump", "  publish:\n    needs: [tag, verify]", "  publish:\n    needs: [tag, verify, bump]", "publish must not need bump");
    try mutant("verify needs bump", "    needs: [plan, build, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "    needs: [plan, build, attest, bump]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "verify must not need bump");
}

test "mutant: another job names the App token" {
    try mutant("publish mints the token", "  publish:\n    needs: [tag, verify]\n    " ++ push_main ++ "\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: write\n    steps:\n", "  publish:\n    needs: [tag, verify]\n    " ++ push_main ++ "\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: write\n    steps:\n      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1\n", "publish names the release bot's App token");
    try mutant("plan reads the key", "          GH_TOKEN: ${{ github.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" plan", "          GH_TOKEN: ${{ github.token }}\n          KEY: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" plan", "plan names the release bot's App token");
    try mutant("verify reads the app id", "          VERSION: ${{ needs.plan.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "          VERSION: ${{ needs.plan.outputs.version }}\n          ID: ${{ vars.RELEASE_BOT_APP_ID }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" verify-dir", "verify names the release bot's App token");
    try mutant("publish takes the token of bump", "          VERSION: ${{ needs.tag.outputs.version }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "          VERSION: ${{ needs.tag.outputs.version }}\n          T: ${{ steps.app.outputs.token }}\n        run: '\"$RUNNER_TEMP/cut_release\" --repo \"$GITHUB_REPOSITORY\" publish", "publish names the release bot's App token");
    try mutant("the workflow's env holds the key", "permissions:\n  contents: read\n\n# One release run", "permissions:\n  contents: read\nenv:\n  K: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n\n# One release run", "env names the release bot's App token");
}

test "mutant: the App token step of bump" {
    try mutant("an unpinned action", "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1", "actions/create-github-app-token@v3", "bump must use actions/create-github-app-token@<full commit sha>");
    try mutant("a short sha", "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1", "actions/create-github-app-token@bcd2ba4", "bump must use actions/create-github-app-token@<full commit sha>");
    try mutant("another action mints the token", app_use, "        uses: someone/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1\n", "bump must use actions/create-github-app-token@");
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
    try tagMutant("tag token action unpinned", "actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1", "actions/create-github-app-token@v3", "tag must use actions/create-github-app-token@<full commit sha>");
    try tagMutant("tag token step without its id", "        id: tagapp\n", "", "tag: the token step must have id: tagapp");
    try tagMutant("tag token step removed", "      - name: Mint the installation token of the release bot, for this repository only (contents write: the tag)\n        id: tagapp\n" ++ app_use ++ "        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          owner: komira-ai\n          repositories: mopm\n          permission-contents: write\n", "", "tag must mint the token with exactly one actions/create-github-app-token step, has 0");
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
    try mutant("a token step in publish", "    permissions:\n      contents: write\n    steps:\n", "    permissions:\n      contents: write\n    steps:\n      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1\n        with:\n          app-id: ${{ vars.RELEASE_BOT_APP_ID }}\n          private-key: ${{ secrets.RELEASE_BOT_PRIVATE_KEY }}\n          repositories: mopm\n", "publish names the release bot's App token");
    try tagMutant("tag's checkout takes the bump token", "          persist-credentials: false\n", "          persist-credentials: false\n          token: ${{ steps.app.outputs.token }}\n", "tag names the token of bump");
    try mutant("bump token scoped to mopm", "          repositories: komira-internal\n", "          repositories: mopm\n", "bump: the token step must set repositories");
    try mutant("a second token step in bump", "      - name: Open the komira-internal pull request", "      - uses: actions/create-github-app-token@bcd2ba49218906704ab6c1aa796996da409d3eb1\n      - name: Open the komira-internal pull request", "bump must mint the token with exactly one actions/create-github-app-token step, has 2");
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
