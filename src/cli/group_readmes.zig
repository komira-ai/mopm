//! The two forms in which a staged member's readme reaches the registry, and the choice between them
//! (spec/api/openapi.yaml, `ReadmeRef`, `GroupUploadReadme` and the `features` of `GET /health`).
//!
//! A registry that lists `group_readme_objects` in the `features` of its `/health` takes a readme as an uploaded object: the
//! create names it by sha256 and size, the run PUTs it to the URL the registry signs, and the commit names it by digest
//! again, so the commit request stays small however long the readmes are. Any other registry takes the readme as text in the
//! commit request, which is held to what the registry's function receives (`group_plan.commitOf`).
//!
//! The form is chosen on every run, from `/health`, and is not stored: a run reads `GET <api>/health` (no token, and before
//! any token exchange) when at least one member to upload has a non-empty readme. A run with no group yet refuses an oversized
//! inline commit at once; a run that resumes a group refuses it only when the group is found open (it is the commit that is
//! too large), and a group whose commit was sent is waited for without reading /health (`decideResumed`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("mopm_core");
const http = core.http;
const io = @import("group_io.zig");
const plan_mod = @import("group_plan.zig");

/// The name in `/health`'s `features` of a registry that takes readmes as objects.
pub const feature = "group_readme_objects";

/// Said under a refusal of an oversized inline commit that was chosen because `/health` did not list `feature`.
pub const inline_note = "the registry does not take readmes as objects (its /health lists no " ++ feature ++ ")";

/// Whether some member to upload has a readme with text: only then does the form matter.
pub fn hasReadme(entries: []const plan_mod.CommitEntry) bool {
    for (entries) |e| {
        if (e.readme) |r| {
            if (r.len > 0) return true;
        }
    }
    return false;
}

/// Whether `GET <api_url>/health` lists `feature`. An answer that is not a success, is not JSON or has no list of names is
/// "no"; a request that fails is an error (the GET is repeated by the policy first).
pub fn takesObjects(arena: Allocator, net: io.Net, api_url: []const u8) anyerror!bool {
    const url = try std.fmt.allocPrint(arena, "{s}/health", .{api_url});
    const answer = try net.request(arena, .GET, url, .{});
    if (!answer.ok()) return false;
    const health = std.json.parseFromSliceLeaky(struct { features: []const []const u8 = &.{} }, arena, answer.body, .{ .ignore_unknown_fields = true }) catch return false;
    for (health.features) |name| {
        if (std.mem.eql(u8, name, feature)) return true;
    }
    return false;
}

/// How the commit will be sent: `objects` names the readmes by digest; otherwise `commit_body` is the whole inline body.
pub const Choice = struct { objects: bool, commit_body: []const u8 };

pub const Chosen = union(enum) {
    ok: Choice,
    /// The inline body is over the limit and the registry does not take objects: the reason, and whether `/health` was read
    /// (so the refusal can say what it listed).
    refused: struct { why: []const u8, health_read: bool },
    /// `/health` could not be read: what failed.
    failed: []const u8,
};

/// The form for this run. `inline_commit` is the check of `plan_mod.commitOf` on the inline body.
pub fn choose(arena: Allocator, net: io.Net, api_url: []const u8, entries: []const plan_mod.CommitEntry, inline_commit: plan_mod.Commit) Allocator.Error!Chosen {
    const asked = hasReadme(entries);
    if (asked) {
        const objects = takesObjects(arena, net, api_url) catch |e| {
            return .{ .failed = try std.fmt.allocPrint(arena, "GET /health: {s}", .{@errorName(e)}) };
        };
        if (objects) return .{ .ok = .{ .objects = true, .commit_body = "" } };
    }
    return switch (inline_commit) {
        .body => |b| .{ .ok = .{ .objects = false, .commit_body = b } },
        .bad => |why| .{ .refused = .{ .why = why, .health_read = asked } },
    };
}

/// `choose`, with a refusal or a failure said on `console`; null when the run stops.
pub fn decide(arena: Allocator, net: io.Net, api_url: []const u8, entries: []const plan_mod.CommitEntry, inline_commit: plan_mod.Commit, console: *io.Console) Allocator.Error!?Choice {
    switch (try choose(arena, net, api_url, entries, inline_commit)) {
        .ok => |c| return c,
        .failed => |why| console.fail("{s}; nothing more was sent\n", .{why}),
        .refused => |r| {
            // A run that read /health sent that read and nothing else; a group an earlier run made is kept as it is.
            console.fail("{s}; {s}\n", .{ r.why, if (r.health_read) "this run created and uploaded nothing" else "nothing was sent" });
            if (r.health_read) console.note("{s}\n", .{inline_note});
        },
    }
    return null;
}

/// A refusal of this run that waits for the group's status: a run that resumes a group sends a commit only when the group is
/// open, so a group the registry already holds past open is not refused for a commit it will not need.
pub const Refusal = struct { why: []const u8, note: ?[]const u8 = null };

pub const Resumed = struct { choice: Choice, refusal: ?Refusal };

/// The form for a run that resumes a group (state.json names one). A group whose commit was sent (`committed`) is not asked
/// about `/health`: no commit follows. Otherwise `/health` is read as in `choose`, and what would refuse or stop the run is
/// returned in `refusal`, for the publisher to say when the group turns out to be open.
pub fn decideResumed(arena: Allocator, net: io.Net, api_url: []const u8, entries: []const plan_mod.CommitEntry, inline_commit: plan_mod.Commit, committed: bool) Allocator.Error!Resumed {
    const none = Choice{ .objects = false, .commit_body = "" };
    if (committed) {
        return switch (inline_commit) {
            .body => |b| .{ .choice = .{ .objects = false, .commit_body = b }, .refusal = null },
            .bad => |why| .{ .choice = none, .refusal = .{ .why = why } },
        };
    }
    return switch (try choose(arena, net, api_url, entries, inline_commit)) {
        .ok => |c| .{ .choice = c, .refusal = null },
        .failed => |why| .{ .choice = none, .refusal = .{ .why = why } },
        .refused => |r| .{ .choice = none, .refusal = .{ .why = r.why, .note = if (r.health_read) inline_note else null } },
    };
}

/// What a registry's create answer says about a member's readme.
pub const ReadmeAnswer = struct {
    sha256: []const u8 = "",
    size: u64 = 0,
    upload_id: []const u8 = "",
    uploaded: bool = false,
    put_url: ?[]const u8 = null,
    put_headers: ?std.json.Value = null,
};

/// How an answer's readme stands against the declaration of `e`.
pub const Verdict = union(enum) {
    /// The answer echoes the declared sha256 and size and is an upload descriptor.
    confirmed,
    /// The answer has no readme.
    absent,
    /// The answer names another sha256 or size than the one declared.
    differs,
    /// The answer is not an upload descriptor: what is wrong with it.
    malformed: []const u8,
};

pub fn judge(e: plan_mod.CommitEntry, got: ?ReadmeAnswer) Verdict {
    const r = got orelse return .absent;
    if (!std.mem.eql(u8, r.sha256, e.readme_sha256) or r.size != e.readme.?.len) return .differs;
    if (!r.uploaded) {
        if (r.put_url == null) return .{ .malformed = "it is not uploaded and has no put_url" };
        if (r.put_headers) |h| {
            if (h != .object) return .{ .malformed = "its put_headers is not an object" };
        }
    }
    return .confirmed;
}

/// The create request's `readme` member of `e`, or nothing for a member without a readme to upload.
pub fn writeRef(w: anytype, e: plan_mod.CommitEntry) !void {
    try w.print(",\"readme\":{{\"sha256\":\"{s}\",\"size\":{d}}}", .{ e.readme_sha256, e.readme.?.len });
}

/// The entry of upload member `name`, when it has a readme with text.
pub fn entryWithReadme(entries: []const plan_mod.CommitEntry, name: []const u8) ?plan_mod.CommitEntry {
    for (entries) |e| {
        if (!std.mem.eql(u8, e.name, name)) continue;
        const r = e.readme orelse return null;
        return if (r.len > 0) e else null;
    }
    return null;
}

/// `--dry-run`: what the run would do, from the plan, and the form of the commit. Returns the exit status.
pub fn dryRun(arena: Allocator, console: *io.Console, net: io.Net, api_url: []const u8, no_commit: bool, plan: plan_mod.Plan, uploads: []const plan_mod.Member, entries: []const plan_mod.CommitEntry, inline_commit: plan_mod.Commit) anyerror!u8 {
    const choice = (try decide(arena, net, api_url, entries, inline_commit, console)) orelse return 1;
    var files: usize = 0;
    for (uploads) |m| files += m.files.len;
    console.say("would create one group of {d} members ({d} files), in this order:\n", .{ uploads.len, files });
    for (uploads) |m| console.say("  {s} {s} ({d} files)\n", .{ m.name, m.version, m.files.len });
    for (plan.members) |m| {
        if (m.action == .skip) console.say("would skip {s} {s}: {s}\n", .{ m.name, m.version, if (m.reason.len > 0) m.reason else "skipped by the plan" });
    }
    const body = if (choice.objects) try plan_mod.objectsBody(arena, entries) else choice.commit_body;
    if (hasReadme(entries)) {
        console.say("would send the readmes {s}; the commit request is {d} bytes\n", .{ if (choice.objects) "as uploaded objects (the registry lists " ++ feature ++ ")" else "inline", body.len });
    }
    const end = if (hasReadme(entries)) "dry run: nothing was created or uploaded; the registry was only read (its config.json and GET /health)\n" else "dry run: nothing was sent\n";
    if (no_commit) {
        console.say("would upload each file the registry does not hold, and stop with the group open (--no-commit)\n{s}", .{end});
    } else {
        console.say("would upload each file the registry does not hold, commit the group, and wait for it to be visible\n{s}", .{end});
    }
    return 0;
}
