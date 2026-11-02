//! Which registry token a `mopm publish --staged --oidc` run asks for, and what it says when the registry did not grant the
//! scope asked for (spec/staged-set.md, "The split between staging and committing").
//!
//! The run that stages without committing (`--no-commit`) exchanges its identity token with `"purpose": "stage"`, and the
//! registry answers a token that can create a group, read it and abort it, and cannot commit it: the split is enforced by
//! the registry, and this run never tries to commit. Every other run (the commit, the one-shot stage-and-commit, and
//! `--abort`) sends no `purpose`, which is the default `publish` on every registry, so those runs are what they were.
//! A registry from before `purpose` ignores it and answers a publish token: the run goes on with it (an older registry
//! keeps working) and prints one line saying staging was done with a publish token. The token is in memory only.

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const ci_oidc = core.ci_oidc;
const gp = @import("group_publish.zig");
const plan_mod = @import("group_plan.zig");

/// The one line printed when a staging run asked for a stage token and the registry answered a publish one.
pub const publish_for_staging_notice =
    "the registry did not grant a stage-only token, so staging used a publish token (a registry that predates stage tokens ignores the request); this run still only stages\n";

/// What the run's registry token is for: `stage` for a run that stops with the group open, `publish` for all the others.
pub fn purposeOf(no_commit: bool, abort: bool) ci_oidc.Purpose {
    if (abort) return .publish;
    return if (no_commit) .stage else .publish;
}

/// The registry token of an `--oidc` staged run for `purpose`: one identity token, one exchange of the `packages` form. When
/// `purpose` is `stage` and the registry answers a token of another kind, `notes` gets `publish_for_staging_notice` once
/// (`notes` has a `writeAll`) and the token is returned all the same.
pub fn token(arena: Allocator, net: gp.Net, act: ci_oidc.Actions, api_url: []const u8, stage: []const u8, uploads: []const plan_mod.Member, purpose: ci_oidc.Purpose, notes: anytype) anyerror!ci_oidc.Result {
    const packages = try arena.alloc(ci_oidc.Package, uploads.len);
    for (uploads, packages) |m, *p| p.* = .{ .name = m.name, .version = m.version };
    switch (try ci_oidc.obtainPackagesFor(arena, net, net.policy, act, api_url, stage, packages, purpose)) {
        .bad => |why| return .{ .bad = why },
        .ok => |minted| {
            if (purpose == .stage and minted.kind != .stage) try notes.writeAll(publish_for_staging_notice);
            return .{ .ok = minted.token };
        },
    }
}

// ---------------------------------------------------------------------- tests

const gt = @import("group_publish_test.zig");

/// A scripted run: the identity request, then the exchange, which answers `exchange`.
fn script(a: Allocator, exchange: []const u8) gt.Script {
    const steps = a.dupe(gt.Script.Step, &.{
        .{ .method = .GET, .suffix = "audience=beta.mopm.dev", .status = 200, .body = "{\"value\":\"head.payload.sig\"}" },
        .{ .method = .POST, .suffix = "/auth/oidc/exchange", .status = 200, .body = exchange },
    }) catch @panic("out of memory");
    return .{ .steps = steps, .seen = std.ArrayList(gt.Script.Seen).init(a) };
}

/// The body of the exchange request the script saw.
fn exchangeBody(s: *const gt.Script) []const u8 {
    return s.seen.items[1].body.?;
}

const job = ci_oidc.Actions{ .url = "https://pipelines.example/idtoken?api-version=2.0", .token = "request-token" };
const api = "https://api.beta.mopm.dev/api/v1";
const members = [_]plan_mod.Member{
    .{ .name = "a", .version = "1.0.0", .action = .upload },
};
const new_registry = "{\"token\":\"tok\",\"token_kind\":\"stage\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"packages\":[]}";
const publish_answer = "{\"token\":\"tok\",\"token_kind\":\"publish\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"packages\":[]}";
const old_registry = "{\"token\":\"tok\",\"expires_at\":\"2026-10-25T00:15:00Z\",\"packages\":[]}";

fn run(a: Allocator, f: *gt.Script, purpose: ci_oidc.Purpose, notes: *std.ArrayList(u8)) !ci_oidc.Result {
    return token(a, f.net(), job, api, "beta", &members, purpose, notes.writer());
}

test "only the run that stops with the group open asks for a stage token" {
    try std.testing.expectEqual(ci_oidc.Purpose.stage, purposeOf(true, false));
    try std.testing.expectEqual(ci_oidc.Purpose.publish, purposeOf(false, false));
    // --abort and --no-commit are never given together; abort ends a group and keeps the token it always had.
    try std.testing.expectEqual(ci_oidc.Purpose.publish, purposeOf(false, true));
    try std.testing.expectEqual(ci_oidc.Purpose.publish, purposeOf(true, true));
}

test "a staging run against a registry with stage tokens asks for purpose stage, uses the stage token, and prints nothing" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = script(a, new_registry);
    var notes = std.ArrayList(u8).init(a);
    const got = try run(a, &f, purposeOf(true, false), &notes);
    try std.testing.expectEqualStrings("tok", got.ok);
    try std.testing.expect(std.mem.indexOf(u8, exchangeBody(&f), "\"purpose\":\"stage\"") != null);
    try std.testing.expectEqual(@as(usize, 2), f.seen.items.len);
    try std.testing.expectEqual(@as(usize, 0), notes.items.len);
}

test "a commit run, and the one-shot run, ask for no purpose and get the publish token as before" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    // The same request on an old and a new registry; both answers are a publish token and neither prints anything.
    for ([_][]const u8{ publish_answer, old_registry }) |answer| {
        var f = script(a, answer);
        var notes = std.ArrayList(u8).init(a);
        const got = try run(a, &f, purposeOf(false, false), &notes);
        try std.testing.expectEqualStrings("tok", got.ok);
        try std.testing.expect(std.mem.indexOf(u8, exchangeBody(&f), "purpose") == null);
        try std.testing.expectEqual(@as(usize, 0), notes.items.len);
    }
}

test "a staging run against a registry that predates stage tokens still stages, and says so once" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    for ([_][]const u8{ publish_answer, old_registry }) |answer| {
        var f = script(a, answer);
        var notes = std.ArrayList(u8).init(a);
        const got = try run(a, &f, purposeOf(true, false), &notes);
        try std.testing.expectEqualStrings("tok", got.ok);
        try std.testing.expectEqualStrings(publish_for_staging_notice, notes.items);
        try std.testing.expect(std.mem.indexOf(u8, notes.items, "tok\n") == null);
    }
}

test "a refused exchange prints no notice and returns the refusal" {
    var st = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer st.deinit();
    const a = st.allocator();
    var f = script(a, "{\"token\":\"tok\",\"token_kind\":\"session\",\"packages\":[]}");
    var notes = std.ArrayList(u8).init(a);
    const got = try run(a, &f, .stage, &notes);
    try std.testing.expect(got == .bad);
    try std.testing.expectEqual(@as(usize, 0), notes.items.len);
}
