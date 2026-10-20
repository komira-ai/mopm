//! //:release_workflow: the release pipeline's lint rules (tests/drivers/release_lint.zig) over the
//! real .github/workflows/release.yml, and each rule shown able to fail: a copy of the real file with
//! one planted defect must report the matching message.
//!
//! What the rules protect: only `tag` and `publish` may write `contents`, both under the exact
//! push-to-main `if:`, so a manual run cannot tag or publish; only `attest` may write the attestation
//! scopes; `publish` needs `verify`, `verify` needs `build`, `tag` needs `beta`, so a red stage stops
//! everything after it; and the path filter skips docs and CI only.

const std = @import("std");
const c = @import("lint_common.zig");
const rl = @import("release_lint.zig");
const Allocator = std.mem.Allocator;

fn real(a: Allocator) ![]u8 {
    const tree = try c.loadTree(a);
    return tree.read(a, ".github/workflows/release.yml");
}

fn problemsOf(a: Allocator, text: []const u8) ![]const []const u8 {
    var out = c.Out.init(a);
    try rl.problems(a, text, &out);
    return out.items;
}

test "the real release.yml passes every rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const got = try problemsOf(a, try real(a));
    for (got) |l| std.debug.print("{s}\n", .{l});
    try std.testing.expectEqual(@as(usize, 0), got.len);
}

/// Plants `to` where `from` is (it must apply, once) and requires a problem containing `needle`.
fn mutant(name: []const u8, from: []const u8, to: []const u8, needle: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = try real(a);
    const at = std.mem.indexOf(u8, text, from) orelse {
        std.debug.print("mutant '{s}' does not apply: {s} is not in release.yml\n", .{ name, from });
        return error.TestUnexpectedResult;
    };
    if (std.mem.indexOfPos(u8, text, at + 1, from) != null) {
        std.debug.print("mutant '{s}' is ambiguous: {s} is in release.yml twice\n", .{ name, from });
        return error.TestUnexpectedResult;
    }
    const planted = try std.mem.concat(a, u8, &.{ text[0..at], to, text[at + from.len ..] });
    const got = try problemsOf(a, planted);
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

const push_main = "if: ${{ github.event_name == 'push' && github.ref == 'refs/heads/main' }}";

test "mutant: publish does not need verify" {
    try mutant("publish without verify", "  publish:\n    needs: [tag, verify]", "  publish:\n    needs: [tag]", "publish must need verify");
}

test "mutant: verify does not need build" {
    try mutant("verify without build", "    needs: [tag, build, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "    needs: [tag, attest]\n    runs-on: ubuntu-24.04\n    timeout-minutes: 15\n    permissions:\n      contents: read\n      attestations: read", "verify must need build");
}

test "mutant: tag does not need beta" {
    try mutant("tag without beta", "  tag:\n    needs: beta", "  tag:\n    needs: []", "tag must need beta");
}

test "mutant: contents: write in verify" {
    try mutant("verify writes contents", "      contents: read\n      attestations: read", "      contents: write\n      attestations: read", "verify: contents: write is not allowed here");
}

test "mutant: tag runs on a manual run" {
    try mutant("tag on dispatch", "  tag:\n    needs: beta\n    " ++ push_main, "  tag:\n    needs: beta\n    if: ${{ github.event_name == 'push' || github.event_name == 'workflow_dispatch' }}", "tag must run only under if");
    try mutant("tag with no if", "  tag:\n    needs: beta\n    " ++ push_main ++ "\n", "  tag:\n    needs: beta\n", "tag must run only under if");
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
}

test "mutant: a bare write-all, a continue-on-error, an if where none belongs" {
    try mutant("verify with write-all", "    permissions:\n      contents: read\n      attestations: read\n", "    permissions: write-all\n", "grants every scope");
    try mutant("beta continue-on-error", "  beta:\n    permissions:\n      contents: read\n", "  beta:\n    continue-on-error: true\n    permissions:\n      contents: read\n", "beta must not set continue-on-error");
    try mutant("build with an if", "  build:\n    needs: tag\n", "  build:\n    needs: tag\n    if: ${{ always() }}\n", "build must not have an if:");
    try mutant("plan on every run", "  plan:\n    needs: beta\n    if: ${{ github.event_name == 'workflow_dispatch' }}\n", "  plan:\n    needs: beta\n", "plan must run only under if");
}

test "mutant: the order of the stages" {
    try mutant("build without tag", "  build:\n    needs: tag", "  build:\n    needs: beta", "build must need tag");
    try mutant("attest without build", "  attest:\n    needs: [tag, build]", "  attest:\n    needs: [tag]", "attest must need build");
}

test "mutant: triggers and concurrency" {
    try mutant("a tag trigger", "    branches: [main]\n    # A push", "    branches: [main]\n    tags: [\"v*\"]\n    # A push", "push has the key `tags`");
    try mutant("any branch", "    branches: [main]\n    # A push", "    branches: [main, dev]\n    # A push", "push must be limited to branches [main]");
    try mutant("a pull_request trigger", "  workflow_dispatch:\n\npermissions:", "  workflow_dispatch:\n  pull_request:\n\npermissions:", "not exactly push and workflow_dispatch");
    try mutant("cancelling runs", "  cancel-in-progress: false", "  cancel-in-progress: true", "concurrency must be group `release`");
    try mutant("another concurrency group", "  group: release\n", "  group: release-${{ github.ref }}\n", "concurrency must be group `release`");
}

test "mutant: the path filter" {
    try mutant("a filter that skips sources", "      - \".github/**\"\n", "      - \".github/**\"\n      - \"src/**\"\n", "paths-ignore skips src/cli/main.zig");
    try mutant("a filter that skips VERSION", "      - \"**.md\"\n", "      - \"**.md\"\n      - \"VERSION\"\n", "paths-ignore skips VERSION");
    try mutant("a filter that releases docs", "      - \"docs/**\"\n", "", "paths-ignore does not skip docs/design/overview.txt");
    try mutant("a filter that releases a CI change", "      - \".github/**\"\n", "", "paths-ignore does not skip .github/workflows/ci.yml");
    try mutant("a filter that releases a markdown change", "      - \"**.md\"\n", "", "paths-ignore does not skip README.md");
    try mutant("a `paths` filter instead", "    paths-ignore:\n", "    paths:\n", "push uses `paths`");
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
