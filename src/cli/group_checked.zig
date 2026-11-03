//! The checks of `mopm publish --staged` that come before any request but the read of `/health`: the staged directory's
//! plan, files and readmes (`checkedPlan`), and the form in which this run sends the readmes (`formOf`). Used by
//! group_publish.zig, which re-exports them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const io = @import("group_io.zig");
const plan_mod = @import("group_plan.zig");
const readmes = @import("group_readmes.zig");
const Net = io.Net;
const Console = io.Console;

/// A staged directory fit to run: its plan, what each upload member puts in the commit (`entries`, empty for `--abort`, which
/// sends no commit) and the check of the inline form: its `commit_body`, or in `over` the reason it is too large for the
/// registry's function (null `commit_body`). Whether that refusal stands depends on the form the registry takes
/// (`readmes.choose`); an `--abort` has neither.
pub const Checked = struct {
    plan: plan_mod.Plan,
    commit_body: ?[]const u8,
    entries: []const plan_mod.CommitEntry = &.{},
    over: ?[]const u8 = null,

    /// The inline form's check, as `readmes.choose` takes it. Not for an `--abort`.
    pub fn inlineCommit(c: Checked) plan_mod.Commit {
        return if (c.over) |why| .{ .bad = why } else .{ .body = c.commit_body.? };
    }
};

/// The checked plan of a staged directory, or why the run stops before any request: the plan cannot be read or parsed,
/// refuses a member, or its files or readmes are not as it says.
pub const Planned = union(enum) { ok: Checked, bad: []const u8 };

/// Reads the plan of `dir` and, unless the run is an `--abort`, checks it. An abort only ends the group `state.json` names
/// and sends no file or readme, so it reads the plan and nothing more: a set that can no longer be published can still be
/// aborted.
pub fn checkedPlan(arena: Allocator, dir: std.fs.Dir, staged: []const u8, abort: bool) anyerror!Planned {
    const text = dir.readFileAlloc(arena, plan_mod.plan_name, 1 << 26) catch |e| {
        return .{ .bad = try std.fmt.allocPrint(arena, "{s}/{s}: {s}", .{ staged, plan_mod.plan_name, @errorName(e) }) };
    };
    const plan = switch (try plan_mod.parsePlan(arena, text)) {
        .ok => |p| p,
        .bad => |why| return .{ .bad = why },
    };
    if (abort) return .{ .ok = .{ .plan = plan, .commit_body = null } };
    if (plan_mod.refusedMember(plan)) |m| {
        return .{ .bad = try std.fmt.allocPrint(arena, "the plan refuses {s} {s}{s}{s}; nothing was sent", .{ m.name, m.version, if (m.reason.len > 0) ": " else "", m.reason }) };
    }
    const entries = switch (try plan_mod.verify(arena, dir, plan)) {
        .ok => |e| e,
        .bad => |why| return .{ .bad = try std.fmt.allocPrint(arena, "{s}; nothing was sent", .{why}) },
    };
    return switch (try plan_mod.commitOf(arena, entries)) {
        .body => |body| .{ .ok = .{ .plan = plan, .commit_body = body, .entries = entries } },
        .bad => |why| .{ .ok = .{ .plan = plan, .commit_body = null, .entries = entries, .over = why } },
    };
}

/// The state of the group an earlier run made in `dir`, when state.json names one. A state file that is another registry's,
/// another plan's or not a state file is answered by `loadStateFor`, later.
pub fn resumedGroup(arena: Allocator, dir: std.fs.Dir) ?plan_mod.State {
    const loaded = plan_mod.loadState(arena, dir) catch return null;
    return switch (loaded) {
        .ok => |s| if (s.group_id.len > 0) s else null,
        else => null,
    };
}

/// How the readmes are sent in this run, and what refuses it later.
pub const Form = struct { choice: readmes.Choice, refusal: ?readmes.Refusal };

/// The form of the readmes for this run (`resumed` is the group an earlier run made, if any). A run with no group refuses an
/// oversized inline commit here, before any request but the read of /health. A run that resumes a group defers the refusal
/// until the group's status is known (`Publisher.refusal`), and a group whose commit was sent needs no form at all. Null
/// after saying why the run stops.
pub fn formOf(arena: Allocator, net: Net, api_url: []const u8, checked: Checked, resumed: ?plan_mod.State, console: *Console) Allocator.Error!?Form {
    if (resumed) |old| {
        const r = try readmes.decideResumed(arena, net, api_url, checked.entries, checked.inlineCommit(), old.committed);
        return .{ .choice = r.choice, .refusal = r.refusal };
    }
    const choice = (try readmes.decide(arena, net, api_url, checked.entries, checked.inlineCommit(), console)) orelse return null;
    return .{ .choice = choice, .refusal = null };
}

