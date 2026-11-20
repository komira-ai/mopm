//! The rules for the one build of the Rust Lambda zips and what each deploy does with it (called by workflow_lint.zig's `repoProblems`).
//! Messages read (`workflow-lint: <file>: ...`) like the rest of the workflow lint.
//!
//! promote.yml: a `function-zips` job with no needs that calls function-zips.yml, passes nothing (no secret, no input) and holds exactly
//! id-token write and contents read; every deploy call is given that artifact's name.
//! function-zips.yml: a call-only workflow with one job that fails without a farm, builds the one target on the farm, checks that no
//! action ran on the runner, and uploads the directory as the artifact `function-zips` with a retention of 1 to 7 days.
//! deploy.yml: a call-only workflow whose credential job downloads that artifact, checks it against its sums before the deploy, gives
//! the directory to CDK as rustZipDir, and compares each deployed function's CodeSha256 with the sums after it, with nothing able to
//! skip or fail quietly; no step of it builds a zip.

const std = @import("std");
const c = @import("lint_common.zig");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const Out = c.Out;

const prefix = "workflow-lint: ";

/// The artifact's name, and the job of promote.yml that builds it.
pub const artifact = "function-zips";
const zips_dir = "${{ runner.temp }}/function-zips";
const build_cmd = "./buck2 build //service/infra/stacks:function_zips --out \"$RUNNER_TEMP/function-zips\"";
const check_zips_cmd = "npx ts-node --prefer-ts-exts bin/function-zips.ts check-zips --zip-dir \"$ZIP_DIR\"";
const check_deployed_cmd = "npx ts-node --prefer-ts-exts bin/function-zips.ts check-deployed --stage \"$STAGE\" --zip-dir \"$ZIP_DIR\" --account \"$AWS_ACCOUNT_ID\" --region \"$AWS_DEFAULT_REGION\"";
const rust_context = "--context \"rustZipDir=${ZIP_DIR}\"";
const download_name = "${{ inputs.function_zips }}";
const stage_input = "${{ inputs.stage }}";
/// What a deploy must not do: any of these in a run, or an upload, means it makes zips of its own.
const builders = [_][]const u8{ "buck2", "cargo", "zip_pack", "lambda_zip" };

pub fn problems(a: Allocator, ctx: anytype, out: *Out) !void {
    try promoteProblems(a, try ctx.read(a, "promote.yml"), out);
    try buildProblems(a, try ctx.read(a, "function-zips.yml"), out);
    try deployProblems(a, try ctx.read(a, "deploy.yml"), out);
}

fn stepsOf(job: Value) []const Value {
    const s = c.get(job, "steps") orelse return &.{};
    return if (s == .array) s.array.items else &.{};
}

fn runOf(step: Value) []const u8 {
    return c.str(c.get(step, "run")) orelse "";
}

fn usesOf(step: Value, action: []const u8) bool {
    const u = c.str(c.get(step, "uses")) orelse return false;
    return std.mem.startsWith(u8, u, action) and u.len > action.len and u[action.len] == '@';
}

fn has(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

/// Only `workflow_call` triggers the workflow.
fn onlyCall(a: Allocator, f: []const u8, doc: Value, why: []const u8, out: *Out) !void {
    const on = try c.onKeys(a, doc);
    if (!(on.len == 1 and std.mem.eql(u8, on[0], "workflow_call"))) {
        try c.problem(a, out, prefix ++ "{s}: triggers must be exactly workflow_call ({s}), got {s}", .{ f, why, try c.inspectList(a, on) });
    }
}

// ---- promote.yml ---------------------------------------------------------------------

fn promoteProblems(a: Allocator, text: []const u8, out: *Out) !void {
    // A file that is not YAML is reported by the rules that read it first.
    const doc = c.load(a, text) catch return;
    const jobs = c.get(doc, "jobs");
    if (c.get(jobs, artifact)) |job| {
        const need = try c.arrayOf(a, c.get(job, "needs"));
        if (need.len != 0) try c.problem(a, out, prefix ++ "promote.yml: " ++ artifact ++ " needs {s}, expected []", .{try c.inspectList(a, need)});
        if (!c.isStr(c.get(job, "uses"), "./.github/workflows/function-zips.yml")) {
            try c.problem(a, out, prefix ++ "promote.yml: " ++ artifact ++ " must call ./.github/workflows/function-zips.yml", .{});
        }
        if (c.get(job, "secrets") != null) try c.problem(a, out, prefix ++ "promote.yml: " ++ artifact ++ " must not set secrets (it reads none)", .{});
        if (c.get(job, "with") != null) try c.problem(a, out, prefix ++ "promote.yml: " ++ artifact ++ " must not set with (it takes no input)", .{});
        const perms = c.get(job, "permissions");
        const exact = perms != null and perms.? == .object and perms.?.object.count() == 2 and
            c.isStr(c.get(perms, "id-token"), "write") and c.isStr(c.get(perms, "contents"), "read");
        if (!exact) try c.problem(a, out, prefix ++ "promote.yml: " ++ artifact ++ " must grant exactly id-token write and contents read", .{});
    }
    if (jobs) |js| if (js == .object) {
        var it = js.object.iterator();
        while (it.next()) |e| {
            if (!c.isStr(c.get(e.value_ptr.*, "uses"), "./.github/workflows/deploy.yml")) continue;
            if (!c.isStr(c.get(c.get(e.value_ptr.*, "with"), "function_zips"), artifact)) {
                try c.problem(a, out, prefix ++ "promote.yml: {s} must pass function_zips: " ++ artifact ++ " (every stage deploys the one build)", .{e.key_ptr.*});
            }
        }
    };
}

// ---- function-zips.yml -----------------------------------------------------------------

fn buildProblems(a: Allocator, text: []const u8, out: *Out) !void {
    const f = "function-zips.yml";
    const doc = c.load(a, text) catch |err| return c.problem(a, out, prefix ++ f ++ ": not readable as YAML: {s}", .{@errorName(err)});
    try onlyCall(a, f, doc, "a promotion calls it and nothing else", out);
    const js = c.get(doc, "jobs");
    const n = if (js != null and js.? == .object) js.?.object.count() else 0;
    if (n != 1) return c.problem(a, out, prefix ++ f ++ ": expected exactly one job, got {d}", .{n});
    const job = js.?.object.values()[0];
    if (c.get(job, "continue-on-error") != null) try c.problem(a, out, prefix ++ f ++ ": the job must not set continue-on-error", .{});
    if (!c.isStr(c.get(job, "if"), "github.ref == 'refs/heads/main'")) try c.problem(a, out, prefix ++ f ++ ": the job must say `if: github.ref == 'refs/heads/main'` (no farm login, no build, off main)", .{});

    var build: ?usize = null;
    var local0 = false;
    var upload: ?usize = null;
    var refuses = false;
    for (stepsOf(job), 0..) |st, i| {
        if (c.get(st, "continue-on-error") != null) try c.problem(a, out, prefix ++ f ++ ": step {d} must not set continue-on-error", .{i});
        const run = runOf(st);
        if (has(run, build_cmd) and build == null) build = i;
        if (has(run, "local: 0")) local0 = true;
        if (usesOf(st, "actions/upload-artifact") and upload == null) upload = i;
        // The step for an unset FARM_ADDRESS: with no farm nothing built the zips, so it fails.
        if (has(c.str(c.get(st, "if")) orelse "", "FARM_ADDRESS == ''") and has(run, "exit 1")) refuses = true;
    }
    if (!refuses) try c.problem(a, out, prefix ++ f ++ ": no step fails (exit 1) when FARM_ADDRESS is not set: a deploy must never go out unbuilt", .{});
    if (build == null) try c.problem(a, out, prefix ++ f ++ ": no step runs `" ++ build_cmd ++ "`", .{});
    if (!local0) try c.problem(a, out, prefix ++ f ++ ": no step checks that the build's summary line says `local: 0`", .{});
    const up = upload orelse return c.problem(a, out, prefix ++ f ++ ": no step uploads the artifact with actions/upload-artifact", .{});
    if (build) |b| if (up < b) try c.problem(a, out, prefix ++ f ++ ": the upload (step {d}) comes before the build (step {d})", .{ up, b });
    const with = c.get(stepsOf(job)[up], "with");
    if (!c.isStr(c.get(with, "name"), artifact)) try c.problem(a, out, prefix ++ f ++ ": the upload must set name: " ++ artifact, .{});
    if (!c.isStr(c.get(with, "path"), zips_dir)) try c.problem(a, out, prefix ++ f ++ ": the upload must set path: {s}", .{zips_dir});
    if (!c.isStr(c.get(with, "if-no-files-found"), "error")) try c.problem(a, out, prefix ++ f ++ ": the upload must set if-no-files-found: error", .{});
    const days = c.get(with, "retention-days");
    if (!(days != null and days.? == .integer and days.?.integer >= 1 and days.?.integer <= 7)) {
        try c.problem(a, out, prefix ++ f ++ ": the upload must set retention-days from 1 to 7, got {s}", .{try c.toS(a, days)});
    }
}

// ---- deploy.yml ------------------------------------------------------------------------

/// A step of the deploy that must run, in order, and cannot be skipped or allowed to fail.
fn mustRun(a: Allocator, out: *Out, job: []const u8, i: usize, st: Value) !void {
    if (c.get(st, "if") != null) try c.problem(a, out, prefix ++ "deploy.yml: {s} step {d} must not have an if (the deploy cannot skip it)", .{ job, i });
    if (c.get(st, "continue-on-error") != null) try c.problem(a, out, prefix ++ "deploy.yml: {s} step {d} must not set continue-on-error", .{ job, i });
}

fn zipDirEnv(a: Allocator, out: *Out, job: []const u8, i: usize, st: Value) !void {
    if (!c.isStr(c.get(c.get(st, "env"), "ZIP_DIR"), zips_dir)) {
        try c.problem(a, out, prefix ++ "deploy.yml: {s} step {d} must set env ZIP_DIR to {s}", .{ job, i, zips_dir });
    }
}

fn deployProblems(a: Allocator, text: []const u8, out: *Out) !void {
    const f = "deploy.yml";
    const doc = c.load(a, text) catch return;
    try onlyCall(a, f, doc, "a manual deploy would have no zips; run promote.yml by hand", out);
    const input = c.get(c.get(c.get(c.onValue(doc), "workflow_call"), "inputs"), "function_zips");
    const required = c.get(input, "required");
    if (!(required != null and required.? == .bool and required.?.bool and c.isStr(c.get(input, "type"), "string"))) {
        try c.problem(a, out, prefix ++ f ++ ": the input function_zips must be required and a string", .{});
    }
    const js = c.get(doc, "jobs") orelse return;
    if (js != .object) return;
    var it = js.object.iterator();
    while (it.next()) |e| {
        const jn = e.key_ptr.*;
        for (stepsOf(e.value_ptr.*), 0..) |st, i| {
            var makes = usesOf(st, "actions/upload-artifact");
            for (builders) |b| {
                if (has(runOf(st), b)) makes = true;
            }
            if (makes) try c.problem(a, out, prefix ++ f ++ ": {s} step {d} builds its own zips; a deploy takes the " ++ artifact ++ " artifact", .{ jn, i });
        }
        if (c.isStr(c.get(c.get(e.value_ptr.*, "permissions"), "id-token"), "write")) try credentialProblems(a, out, jn, e.value_ptr.*);
    }
}

/// The credential job: download, check against the sums, deploy with rustZipDir, then compare CodeSha256.
fn credentialProblems(a: Allocator, out: *Out, jn: []const u8, job: Value) !void {
    var download: ?usize = null;
    var check: ?usize = null;
    var deploy: ?usize = null;
    var compare: ?usize = null;
    for (stepsOf(job), 0..) |st, i| {
        const run = runOf(st);
        if (usesOf(st, "actions/download-artifact") and c.isStr(c.get(c.get(st, "with"), "name"), download_name) and c.isStr(c.get(c.get(st, "with"), "path"), zips_dir)) download = download orelse i;
        if (std.mem.eql(u8, std.mem.trim(u8, run, " \r\n\t"), check_zips_cmd)) check = check orelse i;
        if (has(run, "cdk deploy")) deploy = deploy orelse i;
        if (std.mem.eql(u8, std.mem.trim(u8, run, " \r\n\t"), check_deployed_cmd)) compare = compare orelse i;
    }
    const steps = stepsOf(job);
    const dep = deploy orelse return c.problem(a, out, prefix ++ "deploy.yml: {s} has no cdk deploy step", .{jn});
    if (!has(runOf(steps[dep]), rust_context)) try c.problem(a, out, prefix ++ "deploy.yml: the cdk deploy step must pass `{s}`", .{rust_context});
    try zipDirEnv(a, out, jn, dep, steps[dep]);
    try mustRun(a, out, jn, dep, steps[dep]);

    if (download) |d| {
        if (d > dep) try c.problem(a, out, prefix ++ "deploy.yml: {s} downloads the function zips (step {d}) after the cdk deploy step", .{ jn, d });
        try mustRun(a, out, jn, d, steps[d]);
    } else {
        try c.problem(a, out, prefix ++ "deploy.yml: {s} has no download-artifact step with name {s} and path {s}", .{ jn, download_name, zips_dir });
    }
    if (check) |k| {
        if (k > dep) try c.problem(a, out, prefix ++ "deploy.yml: the check of the zips against their sums (step {d}) runs after the cdk deploy step", .{k});
        try zipDirEnv(a, out, jn, k, steps[k]);
        try mustRun(a, out, jn, k, steps[k]);
    } else {
        try c.problem(a, out, prefix ++ "deploy.yml: no step runs `" ++ check_zips_cmd ++ "` before the deploy", .{});
    }
    if (compare) |m| {
        if (m < dep) try c.problem(a, out, prefix ++ "deploy.yml: the CodeSha256 comparison (step {d}) runs before the cdk deploy step", .{m});
        try zipDirEnv(a, out, jn, m, steps[m]);
        if (!c.isStr(c.get(c.get(steps[m], "env"), "STAGE"), stage_input)) {
            try c.problem(a, out, prefix ++ "deploy.yml: {s} step {d} must set env STAGE to {s}", .{ jn, m, stage_input });
        }
        try mustRun(a, out, jn, m, steps[m]);
    } else {
        try c.problem(a, out, prefix ++ "deploy.yml: no step runs `" ++ check_deployed_cmd ++ "`: the deploy skips the CodeSha256 comparison", .{});
    }
}
