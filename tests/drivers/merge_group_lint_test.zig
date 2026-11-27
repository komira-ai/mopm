//! //:merge_group_workflows: the merge queue lint (tests/drivers/merge_group_lint.zig) over the real workflows, which must pass, and
//! over faulty variants of them, one per rule, each of which must be refused with its reason.

const std = @import("std");
const c = @import("lint_common.zig");
const mg = @import("merge_group_lint.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

fn realWorkflows(a: Allocator) ![]mg.Workflow {
    const tree = try c.loadTree(a);
    var list = std.ArrayList(mg.Workflow).init(a);
    for (try c.workflowFiles(a, tree)) |f| try list.append(.{ .name = c.basename(f), .text = try tree.read(a, f) });
    return list.items;
}

fn problemsOf(a: Allocator, workflows: []const mg.Workflow) ![]const []const u8 {
    var out = c.Out.init(a);
    try mg.problems(a, workflows, &out);
    return out.items;
}

fn find(workflows: []mg.Workflow, name: []const u8) !*mg.Workflow {
    for (workflows) |*w| if (std.mem.eql(u8, w.name, name)) return w;
    std.debug.print("there is no .github/workflows/{s}\n", .{name});
    return error.TestUnexpectedResult;
}

/// The real workflows with the first `from` in `file` replaced by `to`; the anchor must be in the real file, so a variant cannot go stale.
fn expectVariant(file: []const u8, from: []const u8, to: []const u8, want: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workflows = try realWorkflows(a);
    const w = try find(workflows, file);
    const at = std.mem.indexOf(u8, w.text, from) orelse {
        std.debug.print("the variant does not apply: {s} is not in {s}\n", .{ from, file });
        return error.TestUnexpectedResult;
    };
    w.text = try std.mem.concat(a, u8, &.{ w.text[0..at], to, w.text[at + from.len ..] });
    try c.expectLines(file, try problemsOf(a, workflows), want);
}

const trigger = "  merge_group:\n    types: [checks_requested]\n    branches: [main]\n";

test "the real workflows: every required check runs on a merge group, under its name, and cannot be skipped or cancelled there" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try c.expectLines("real", try problemsOf(a, try realWorkflows(a)), &.{});
    // The table names ten checks in five workflows, each on a line of its own (the ruleset script reads `.context = "` lines).
    try std.testing.expectEqual(@as(usize, 10), mg.required_checks.len);
}

test "the trigger: every required workflow runs on merge_group of type checks_requested into main, and no other workflow does" {
    // Defect caught: a required workflow loses the trigger; the queue would wait for its checks until the timeout.
    try expectVariant("ci.yml", trigger, "", &.{"merge_group: ci.yml: does not run on merge_group"});
    // Defect caught: another type, another branch, no filter at all.
    try expectVariant("lint.yml", trigger, "  merge_group:\n    types: [destroyed]\n    branches: [main]\n", &.{"lint.yml: the merge_group trigger must be exactly `types: [checks_requested]` and `branches: [main]`"});
    try expectVariant("service-ci.yml", trigger, "  merge_group:\n    types: [checks_requested]\n    branches: [develop]\n", &.{"service-ci.yml: the merge_group trigger must be exactly"});
    try expectVariant("farm.yml", trigger, "  merge_group:\n", &.{"farm.yml: the merge_group trigger must be exactly `types: [checks_requested]` and `branches: [main]`, got nil"});
    // Defect caught: a release workflow runs on a merge group (it holds no required check, and publishes).
    try expectVariant("release.yml", "\n  workflow_dispatch:\n", "\n" ++ trigger ++ "  workflow_dispatch:\n", &.{
        "release.yml: runs on merge_group but holds no required check",
        "release.yml: runs on merge_group but not on pull_request",
    });
    // Defect caught: a required workflow runs on a merge group but no longer on a pull request.
    try expectVariant("pin-verify.yml", "on:\n  pull_request:\n  merge_group:", "on:\n  merge_group:", &.{"pin-verify.yml: runs on merge_group but not on pull_request"});
}

test "the jobs: every required job is there, reports under its context, and is one context on a merge group" {
    try expectVariant("service-ci.yml", "\n  access:\n", "\n  access2:\n", &.{"service-ci.yml: job access is gone, but main requires its check access"});
    try expectVariant("pin-verify.yml", "    name: pin-verify\n", "    name: pin verify\n", &.{"pin-verify.yml: job pin-verify reports as \"pin verify\" on a merge group, but main requires \"pin-verify\""});
    // Defect caught: a merge group gets two runners (two contexts, neither the one required), or the matrix of a pull request alone.
    try expectVariant("ci.yml", "|| github.event_name == 'merge_group') && '[\"ubuntu-24.04\"]'", "|| github.event_name == 'merge_group') && '[\"ubuntu-24.04\",\"ubuntu-24.04-arm\"]'", &.{"ci.yml: job test: a merge group gets 2 runners, [\"ubuntu-24.04\", \"ubuntu-24.04-arm\"]"});
    try expectVariant("ci.yml", "(github.event_name == 'pull_request' || github.event_name == 'merge_group') && ", "github.event_name == 'pull_request' && ", &.{"ci.yml: job test: the runners of a merge group cannot be read from matrix.os"});
    // A matrix written as a list is read too: one runner passes, two are two contexts.
    const ci_os = "        os: ${{ fromJSON((github.event_name == 'pull_request' || github.event_name == 'merge_group') && '[\"ubuntu-24.04\"]' || vars.MACOS_ON_FARM == 'true' && '[\"ubuntu-24.04\",\"ubuntu-24.04-arm\"]' || '[\"ubuntu-24.04\",\"ubuntu-24.04-arm\",\"macos-15\"]') }}\n";
    try expectVariant("ci.yml", ci_os, "        os: [ubuntu-24.04]\n", &.{});
    try expectVariant("ci.yml", ci_os, "        os: [ubuntu-24.04, macos-15]\n", &.{"ci.yml: job test: a merge group gets 2 runners, [\"ubuntu-24.04\", \"macos-15\"]"});
    // Defect caught: a name with an expression the lint cannot fill in.
    try expectVariant("lint.yml", "    name: lint (hygiene, workflows, self-test)\n", "    name: lint (${{ github.event_name }})\n", &.{"lint.yml: job lint: its name lint (${{ github.event_name }}) has an expression the lint cannot fill in"});
    // Defect caught: a required check checks out a ref of its own instead of the merge group's head.
    try expectVariant("ci.yml", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n", "      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1\n        with:\n          ref: main\n", &.{"ci.yml: job test step 0: checks out a ref of its own"});
}

test "the condition: a required job runs on every merge group" {
    // Defect caught: farm.yml's build job without its merge group term (a skipped required check counts as passed).
    try expectVariant("farm.yml", " || github.event_name == 'merge_group' || (", " || (", &.{"farm.yml: job build can be skipped on a merge group"});
    // Defect caught: the term is there but tied to another condition by &&.
    try expectVariant("farm.yml", "github.event_name == 'merge_group' || (", "github.event_name == 'merge_group' && vars.X == 'y' || (", &.{"farm.yml: job build can be skipped on a merge group"});
    // The condition read on its own: none, !cancelled(), and a top-level term pass; a near miss, a term under &&, and a non-string do not.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(try mg.runsOnMergeGroup(a, null));
    try std.testing.expect(try mg.runsOnMergeGroup(a, Value{ .null = {} }));
    try std.testing.expect(try mg.runsOnMergeGroup(a, Value{ .string = "${{ !cancelled() }}" }));
    try std.testing.expect(try mg.runsOnMergeGroup(a, Value{ .string = "${{ github.event_name == 'push' || github.event_name == 'merge_group' }}" }));
    try std.testing.expect(!try mg.runsOnMergeGroup(a, Value{ .string = "github.event_name == 'merge_groups' || github.event_name == 'push'" }));
    try std.testing.expect(!try mg.runsOnMergeGroup(a, Value{ .string = "github.event_name == 'merge_group' && false" }));
    try std.testing.expect(!try mg.runsOnMergeGroup(a, Value{ .bool = false }));
    // The terms are split outside parentheses and quotes.
    try c.expectLines("terms", try mg.topLevelOr(a, "a || (b || c) && d || 'x||y'"), &.{ "a", "(b || c) && d", "'x||y'" });
    try std.testing.expectEqual(@as(usize, 3), (try mg.topLevelOr(a, "a || (b || c) && d || 'x||y'")).len);
}

test "concurrency: no run of a merge group is cancelled, and no two merge groups share a group" {
    // Defect caught: service-ci.yml cancels any older run of its group, a merge group's too.
    try expectVariant("service-ci.yml", "cancel-in-progress: ${{ github.event_name != 'merge_group' }}", "cancel-in-progress: true", &.{"service-ci.yml: the workflow: cancel-in-progress is true"});
    // Defect caught: a group every merge group shares (the pull request number is empty on a merge group).
    try expectVariant("service-ci.yml", "group: service-ci-${{ github.ref }}", "group: service-ci-${{ github.event.pull_request.number }}", &.{"service-ci.yml: the workflow: the concurrency group \"service-ci-${{ github.event.pull_request.number }}\" names neither"});
    // The short form, a bare group name: shared by every merge group unless it names the commit, the ref or the run.
    try expectVariant("pin-verify.yml", "\njobs:\n", "\nconcurrency: pin-verify\n\njobs:\n", &.{"pin-verify.yml: the workflow: the concurrency group \"pin-verify\" names neither"});
    try expectVariant("pin-verify.yml", "\njobs:\n", "\nconcurrency: pin-verify-${{ github.sha }}\n\njobs:\n", &.{});
    // Defect caught: a job-level group that cancels.
    try expectVariant("pin-verify.yml", "    name: pin-verify\n", "    name: pin-verify\n    concurrency:\n      group: pv-${{ github.sha }}\n      cancel-in-progress: true\n", &.{"pin-verify.yml: job pin-verify: cancel-in-progress is true"});
}

test "farm.yml: a merge group with no farm fails, never skips green, and builds the pull request tier" {
    try expectVariant("farm.yml", "if: ${{ vars.FARM_ADDRESS == '' && github.event_name == 'pull_request' }}", "if: ${{ vars.FARM_ADDRESS == '' && github.event_name != 'push' }}", &.{"farm.yml: job build: the step that skips with a notice has if:"});
    try expectVariant("farm.yml", "if: ${{ vars.FARM_ADDRESS == '' && github.event_name != 'pull_request' }}", "if: ${{ vars.FARM_ADDRESS == '' && github.event_name == 'push' }}", &.{"farm.yml: job build: the step that refuses has if:"});
    try expectVariant("farm.yml", "Set it, or the farm check is not a check.\"; exit 1", "Set it, or the farm check is not a check.\"", &.{"farm.yml: job build: the step that refuses must end with exit 1"});
    try expectVariant("farm.yml", "::error title=farm::", "::warning title=farm::", &.{"farm.yml: job build: no step fails, with an ::error"});
    // Defect caught: the build step is handed the event as it is (a merge group would build every target), or no EVENT at all.
    try expectVariant("farm.yml", "EVENT: ${{ github.event_name == 'merge_group' && 'pull_request' || github.event_name }}", "EVENT: ${{ github.event_name }}", &.{"farm.yml: job build: the build step's EVENT is \"${{ github.event_name }}\", expected"});
    try expectVariant("farm.yml", "EVENT: ${{ github.event_name == 'merge_group' && 'pull_request' || github.event_name }}", "OTHER: x", &.{"farm.yml: job build: the build step's EVENT is nil, expected"});
    try expectVariant("farm.yml", "./buck2 uquery", "./buck2 cquery", &.{"farm.yml: job build: no step builds the pull request tier"});
    try expectVariant("farm.yml", "      - name: the farm is not configured (push to main or merge group)\n", "      - name: the farm is not configured (push to main or merge group)\n        continue-on-error: true\n", &.{"farm.yml: job build: the step that refuses must not set continue-on-error"});
}

test "a required workflow that is missing or unreadable is a finding, not a pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const all = try realWorkflows(a);
    var without = std.ArrayList(mg.Workflow).init(a);
    for (all) |w| if (!std.mem.eql(u8, w.name, "pin-verify.yml")) try without.append(w);
    try c.expectLines("missing", try problemsOf(a, without.items), &.{"merge_group: pin-verify.yml: missing, but main requires its check pin-verify"});
    (try find(all, "lint.yml")).text = "on:\n\t- x\n";
    try c.expectLines("unreadable", try problemsOf(a, all), &.{"merge_group: lint.yml: not readable as YAML"});
}
