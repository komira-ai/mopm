//! The rules of tests/drivers/signin_e2e_lint.zig over the repository's e2e.yml (run with the workflow lint, //:workflows), and
//! each rule shown able to fail: a copy of the real file with one known defect must print the message. The real file passing is
//! workflow_lint_test.zig's "every workflow of the repository passes".

const std = @import("std");
const c = @import("lint_common.zig");
const wl = @import("workflow_lint.zig");
const se = @import("signin_e2e_lint.zig");
const Allocator = std.mem.Allocator;

const Repo = struct {
    tree: c.Tree,
    from: []const u8,
    to: []const u8,
    /// A second change, applied after the first (empty: none).
    from2: []const u8 = "",
    to2: []const u8 = "",

    pub fn read(self: Repo, a: Allocator, name: []const u8) ![]u8 {
        const text = try self.tree.read(a, try std.fmt.allocPrint(a, ".github/workflows/{s}", .{name}));
        if (!std.mem.eql(u8, name, "e2e.yml")) return text;
        if (std.mem.count(u8, text, self.from) != 1) {
            std.debug.print("the faulty change does not apply to e2e.yml once: {s}\n", .{self.from});
            return error.TestUnexpectedResult;
        }
        const once = try std.mem.replaceOwned(u8, a, text, self.from, self.to);
        if (self.from2.len == 0) return once;
        if (std.mem.count(u8, once, self.from2) != 1) {
            std.debug.print("the second faulty change does not apply to e2e.yml once: {s}\n", .{self.from2});
            return error.TestUnexpectedResult;
        }
        return std.mem.replaceOwned(u8, a, once, self.from2, self.to2);
    }
};

/// e2e.yml with `from` (found exactly once) replaced by `to`: the whole-repository rules must print `want`, one line each.
fn expect(from: []const u8, to: []const u8, want: []const []const u8) !void {
    return expect2(from, to, "", "", want);
}

/// As `expect`, with a second change applied after the first.
fn expect2(from: []const u8, to: []const u8, from2: []const u8, to2: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out = c.Out.init(a);
    try wl.repoProblems(a, Repo{ .tree = try c.loadTree(a), .from = from, .to = to, .from2 = from2, .to2 = to2 }, &out);
    try c.expectLines("e2e.yml", out.items, want);
}

const head = "      - name: " ++ se.step_name ++ "\n";
const env_block = "        env:\n          STAGE: ${{ inputs.stage }}\n          AWS_ACCESS_KEY_ID: \"\"\n          AWS_SECRET_ACCESS_KEY: \"\"\n          AWS_SESSION_TOKEN: \"\"\n";
const run_line = "        run: " ++ se.check_cmd ++ "\n";
const step = head ++ env_block ++ run_line;
const build = "      - name: Build the sign-in check\n        run: zig build signin-e2e -Doptimize=ReleaseSafe\n";
const assume = "      - name: Assume the e2e role through OIDC\n";
const job_if = "    if: github.ref == 'refs/heads/main'\n    runs-on: ubuntu-24.04\n    timeout-minutes: 20\n";

test "e2e.yml: the sign-in step is there once, after the site checks, and the check is built before it" {
    try expect(step, "", &.{"e2e.yml: smoke-linux lost the step `Read-only checks, sign-in and sandbox routes`"});
    try expect(step, step ++ step, &.{"e2e.yml: smoke-linux has 2 steps named `Read-only checks, sign-in and sandbox routes`, 1 expected"});
    try expect("      - name: Read-only checks, site\n", "      - name: Read-only checks, the site\n", &.{
        "e2e.yml: smoke-linux lost the step `Read-only checks, site`",
        "e2e.yml: `Read-only checks, sign-in and sandbox routes` must come after `Read-only checks, site`",
    });
    try expect(build, "", &.{
        "e2e.yml: smoke-linux lost the step `Build the sign-in check`",
        "e2e.yml: `Install Zig 0.12.0 (sha256-pinned), for the sign-in check` and then `Build the sign-in check` must come before",
    });
    // The build moved to just before the check, after the assume step: it would run with the credentials in the environment.
    try expect2(build, "", head, build ++ head, &.{"e2e.yml: `Install Zig 0.12.0 (sha256-pinned), for the sign-in check` and then `Build the sign-in check` must come before `Assume the e2e role through OIDC`"});
    try expect(assume, "      - name: Assume the e2e role, OIDC\n", &.{
        "e2e.yml: smoke-linux lost the step `Assume the e2e role through OIDC`",
        "e2e.yml: `Install Zig 0.12.0 (sha256-pinned), for the sign-in check` and then `Build the sign-in check` must come before",
    });
    try expect("zig build signin-e2e -Doptimize=ReleaseSafe", "zig build -Doptimize=ReleaseSafe", &.{"e2e.yml: `Build the sign-in check` must run exactly `zig build signin-e2e -Doptimize=ReleaseSafe`"});
    try expect("      - name: Install Zig 0.12.0 (sha256-pinned), for the sign-in check\n        run: echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"\n", "      - name: Install Zig 0.12.0 (sha256-pinned), for the sign-in check\n        run: tools/install_zig.sh /opt/zig\n", &.{"e2e.yml: `Install Zig 0.12.0 (sha256-pinned), for the sign-in check` must run exactly"});
}

test "e2e.yml: the sign-in step runs in every e2e run, after every stage's deploy, and nothing lets it fail quietly" {
    try expect(job_if, "    if: github.ref == 'refs/heads/main' && inputs.stage != 'prod'\n    runs-on: ubuntu-24.04\n    timeout-minutes: 20\n", &.{"e2e.yml: smoke-linux must run on main for every stage"});
    try expect(job_if, "    if: github.ref == 'refs/heads/main'\n    continue-on-error: true\n    runs-on: ubuntu-24.04\n    timeout-minutes: 20\n", &.{"e2e.yml: smoke-linux must not set continue-on-error"});
    try expect(head, head ++ "        if: ${{ inputs.stage != 'prod' }}\n", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must not have an `if`"});
    try expect(head, head ++ "        continue-on-error: true\n", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must not set continue-on-error"});
    try expect(build, "      - name: Build the sign-in check\n        if: always()\n        run: zig build signin-e2e -Doptimize=ReleaseSafe\n", &.{"e2e.yml: `Build the sign-in check` must not have an `if`"});
    try expect(run_line, "        run: " ++ se.check_cmd ++ " || true\n", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must run exactly"});
    try expect(head, head ++ "        working-directory: service\n", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must not set `working-directory`"});
}

test "e2e.yml: the sign-in step checks the stage's own two origins over https" {
    try expect("--api \"https://$(jq -r .apiDomain", "--api \"https://$(jq -r .siteDomain", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must run exactly"});
    try expect("--site \"https://$(jq -r .siteDomain", "--site \"http://$(jq -r .siteDomain", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must run exactly"});
}

test "e2e.yml: the sign-in step reads no secret and no credential, and the job keeps exactly its grants" {
    try expect("          AWS_SESSION_TOKEN: \"\"\n        run: ./zig-out", "        run: ./zig-out", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must set exactly env STAGE"});
    try expect("          AWS_ACCESS_KEY_ID: \"\"\n          AWS_SECRET", "          AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}\n          AWS_SECRET", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must set exactly env STAGE"});
    try expect("          AWS_SESSION_TOKEN: \"\"\n        run: ./zig-out", "          AWS_SESSION_TOKEN: \"\"\n          GH_TOKEN: ${{ github.token }}\n        run: ./zig-out", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must set exactly env STAGE"});
    try expect(env_block, "", &.{"e2e.yml: `Read-only checks, sign-in and sandbox routes` must set exactly env STAGE"});
    try expect("    timeout-minutes: 20\n    environment: ${{ inputs.stage }}\n    permissions:\n      id-token: write\n      contents: read\n", "    timeout-minutes: 20\n    environment: ${{ inputs.stage }}\n    permissions:\n      id-token: write\n      contents: read\n      actions: read\n", &.{"e2e.yml: smoke-linux must grant exactly id-token write and contents read"});
}
