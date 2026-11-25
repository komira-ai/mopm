//! The rules for e2e.yml's read-only sign-in checks (tests/drivers/signin_e2e.zig), called by workflow_lint.zig's `repoProblems`.
//! Messages read (`workflow-lint: e2e.yml: ...`) like the rest of the workflow lint.
//!
//! The checks are a step of the smoke-linux job, after "Read-only checks, site", so they run in every e2e run, after the
//! beta, gamma and prod deploys alike: the job runs on main with no condition on the stage and keeps exactly its grants
//! (id-token write for the AWS steps before it, contents read). The step runs the program the job built (Zig installed
//! by the pinned installer, then `zig build signin-e2e`) with the stage's two origins from service/config/<stage>.json,
//! exactly one command line, so nothing can tolerate its failure. It reads no secret and needs no id-token: its env is
//! the stage and the three AWS credential variables set empty, so the credentials the assume step put in the job's
//! environment do not reach it. No step of the three has an `if` or `continue-on-error`.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

const prefix = "workflow-lint: e2e.yml: ";

const job_name = "smoke-linux";
pub const step_name = "Read-only checks, sign-in and sandbox routes";
const site_step = "Read-only checks, site";
const zig_step = "Install Zig 0.12.0 (sha256-pinned), for the sign-in check";
const build_step = "Build the sign-in check";

const zig_cmd = "echo \"$(tools/install_zig.sh \"$RUNNER_TEMP/zig\")\" >> \"$GITHUB_PATH\"";
const build_cmd = "zig build signin-e2e -Doptimize=ReleaseSafe";
pub const check_cmd = "./zig-out/bin/mopm-signin-e2e --site \"https://$(jq -r .siteDomain \"service/config/${STAGE}.json\")\" --api \"https://$(jq -r .apiDomain \"service/config/${STAGE}.json\")\"";

/// The step's env, exactly.
const env = [_][2][]const u8{
    .{ "STAGE", "${{ inputs.stage }}" },
    .{ "AWS_ACCESS_KEY_ID", "" },
    .{ "AWS_SECRET_ACCESS_KEY", "" },
    .{ "AWS_SESSION_TOKEN", "" },
};

pub fn problems(a: Allocator, doc: Value, out: *Out) !void {
    const job = c.get(c.get(doc, "jobs"), job_name) orelse return c.problem(a, out, prefix ++ "the " ++ job_name ++ " job is missing", .{});
    if (!c.isStr(c.get(job, "if"), "github.ref == 'refs/heads/main'")) {
        try c.problem(a, out, prefix ++ job_name ++ " must run on main for every stage (`if: github.ref == 'refs/heads/main'`), so the sign-in checks run in every e2e run", .{});
    }
    if (c.truthy(c.get(job, "continue-on-error"))) try c.problem(a, out, prefix ++ job_name ++ " must not set continue-on-error", .{});
    const perms = c.get(job, "permissions");
    const exact = perms != null and perms.? == .object and perms.?.object.count() == 2 and
        c.isStr(c.get(perms, "id-token"), "write") and c.isStr(c.get(perms, "contents"), "read");
    if (!exact) try c.problem(a, out, prefix ++ job_name ++ " must grant exactly id-token write and contents read", .{});

    const steps: []const Value = if (c.get(job, "steps")) |s| (if (s == .array) s.array.items else &.{}) else &.{};
    const site = try only(a, steps, site_step, out);
    const zig = try only(a, steps, zig_step, out);
    const build = try only(a, steps, build_step, out);
    const check = try only(a, steps, step_name, out) orelse return;
    if (site == null or site.? > check) try c.problem(a, out, prefix ++ "`" ++ step_name ++ "` must come after `" ++ site_step ++ "`", .{});
    if (zig == null or build == null or zig.? > build.? or build.? > check) {
        try c.problem(a, out, prefix ++ "`" ++ zig_step ++ "` and then `" ++ build_step ++ "` must come before `" ++ step_name ++ "`", .{});
    }
    if (zig) |i| try runIs(a, steps[i], zig_step, zig_cmd, out);
    if (build) |i| try runIs(a, steps[i], build_step, build_cmd, out);
    try runIs(a, steps[check], step_name, check_cmd, out);

    const st = steps[check];
    for ([_][]const u8{ "uses", "with", "working-directory", "shell" }) |k| {
        if (c.get(st, k) != null) try c.problem(a, out, prefix ++ "`" ++ step_name ++ "` must not set `{s}`", .{k});
    }
    const e = c.get(st, "env");
    var ok = e != null and e.? == .object and e.?.object.count() == env.len;
    for (env) |kv| ok = ok and c.isStr(c.get(e, kv[0]), kv[1]);
    if (!ok) {
        try c.problem(a, out, prefix ++ "`" ++ step_name ++ "` must set exactly env STAGE: ${{{{ inputs.stage }}}} and AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY and AWS_SESSION_TOKEN empty (no secret, no credential), got {s}", .{try c.inspect(a, e)});
    }
}

/// The index of the one step of `steps` named `name`: a problem and null when there is none or more than one.
fn only(a: Allocator, steps: []const Value, name: []const u8, out: *Out) !?usize {
    var found: ?usize = null;
    var n: usize = 0;
    for (steps, 0..) |st, i| if (c.isStr(c.get(st, "name"), name)) {
        found = i;
        n += 1;
    };
    if (n == 1) return found;
    if (n == 0) try c.problem(a, out, prefix ++ job_name ++ " lost the step `{s}`", .{name}) else try c.problem(a, out, prefix ++ job_name ++ " has {d} steps named `{s}`, 1 expected", .{ n, name });
    return null;
}

/// The step runs exactly `cmd`, and has no `if` and no `continue-on-error`.
fn runIs(a: Allocator, st: Value, name: []const u8, cmd: []const u8, out: *Out) !void {
    const run = std.mem.trimRight(u8, c.str(c.get(st, "run")) orelse "", "\n");
    if (!std.mem.eql(u8, run, cmd)) try c.problem(a, out, prefix ++ "`{s}` must run exactly `{s}`, got {s}", .{ name, cmd, try c.inspectStr(a, run) });
    if (c.get(st, "if") != null) try c.problem(a, out, prefix ++ "`{s}` must not have an `if` (it runs in every e2e run)", .{name});
    if (c.truthy(c.get(st, "continue-on-error"))) try c.problem(a, out, prefix ++ "`{s}` must not set continue-on-error", .{name});
}
